#!/usr/bin/env bash
# test-bootstrap-contents.sh — static verification that a bootstrap image contains
# everything the first-boot agent needs to run and install. (issue #27)
#
# Until this existed, nothing proved the bootstrap image actually carried the
# agent, its enabled unit, fisherman, cosign, or the tools the agent shells out
# to. "The payload boots" was proven by test-payload.sh (kernel + modules +
# hardware tools), but "the bootstrap can install" was asserted by documentation
# alone. The only validation was the Containerfile itself, and a Containerfile
# is a build recipe, not a gate — it says what SHOULD be there; this proves what
# IS there.
#
# Usage:
#   ./test-bootstrap-contents.sh <image>            verify a built image
#   ./test-bootstrap-contents.sh --build             build then verify
#   ./test-bootstrap-contents.sh --negative          build a deliberately broken
#                                                     image and prove the checks
#                                                     catch it (the negative
#                                                     payload test #27 requires)
#
# Env:
#   BOOTSTRAP_IMAGE   image ref to verify (overrides positional arg)
#   BASE_IMAGE        base to derive from (default: bonito gnome-asahi)
#   FISHERMAN_REPO/REV which fisherman to vendor
#   SKIP_FISHERMAN_BUILD=1  reuse already-staged fisherman binary
#   SKIP_BUILD=1      skip image build, verify an existing image
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)

fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=$((fail + 1)); }

# ── Resolve the image to verify ─────────────────────────────────────────────
MODE="verify"
IMAGE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--build) MODE="build"; shift ;;
		--negative) MODE="negative"; shift ;;
		--verify) MODE="verify"; shift ;;
		*) IMAGE="$1"; shift ;;
	esac
done

IMAGE="${BOOTSTRAP_IMAGE:-$IMAGE}"

if [ "$MODE" = "build" ] || [ "$MODE" = "negative" ]; then
	if [ "${SKIP_BUILD:-0}" != "1" ]; then
		echo "==> Building bootstrap image for verification..."
		BUILD_TAG="localhost/bootsahi-bootstrap:verify-$$"
		# build-bootstrap-image.sh stages fisherman and builds the image.
		# On the negative path, we build the same image and then strip the
		# agent out afterward to create the negative fixture.
		"$HERE/scripts/build-bootstrap-image.sh" "$BUILD_TAG"
		IMAGE="$BUILD_TAG"
	else
		echo "==> SKIP_BUILD=1 — using existing image: $IMAGE"
		[ -n "$IMAGE" ] || { echo "ERROR: no image specified with SKIP_BUILD=1" >&2; exit 1; }
	fi
fi

if [ -z "$IMAGE" ]; then
	echo "ERROR: no image to verify. Usage: $0 <image-ref> or $0 --build" >&2
	exit 1
fi

# ── Negative fixture: strip the agent out ────────────────────────────────────
# Build a bootstrap image and deliberately remove the agent and its unit. The
# negative-payload test from issue #27: a payload missing the agent or with a
# disabled unit must fail this gate. This is a structural negative — the
# assertion is that the checker reports FAIL when the agent is absent, which
# proves the checker is discriminating and not just echoing its own
# assumptions.
if [ "$MODE" = "negative" ]; then
	echo "==> Creating negative fixture (agent removed)..."
	NEG_TAG="localhost/bootsahi-bootstrap:negative-$$"
	CTR=$(podman create "$IMAGE" true)
	trap 'podman rm -f "$CTR" >/dev/null 2>&1 || true' EXIT
	MNT=$(podman mount "$CTR")
	# Remove the agent and its unit. The unit stays installed but the binary
	# it references is gone — systemd will fail the unit, which is an
	# observable difference from "unit not present at all", and the static
	# checker must catch both.
	rm -f "$MNT/usr/libexec/bootsahi-agent"
	rm -f "$MNT/usr/lib/systemd/system/bootsahi-agent.service"
	podman commit "$CTR" "$NEG_TAG" >/dev/null
	podman umount "$CTR" >/dev/null
	podman rm -f "$CTR" >/dev/null
	trap - EXIT
	IMAGE="$NEG_TAG"
	echo "    negative fixture: $IMAGE"
fi

echo "==> Verifying bootstrap image: $IMAGE"
echo

# ── Static checks ───────────────────────────────────────────────────────────
CTR=$(podman create "$IMAGE" true)
trap 'podman rm -f "$CTR" >/dev/null 2>&1 || true' EXIT
MNT=$(podman mount "$CTR")
R="$MNT"

# Deployments on bootc images are nested under ostree/deploy/<stateroot>/<hash>.
# But we control the Containerfile — it copies files into the image directly,
# and those files are in the rootfs, not under a deployment. On a
# composefs-native install they may move, but in the packed image used for
# static verification (podman mount) they are where we put them.
OSROOT="$R"
if [ ! -f "$R/usr/share/bootsahi/bootstrap-release" ]; then
	# The image might be a bootc deployment where the real root is nested.
	moddir=$(find "$R/ostree/deploy" -maxdepth 8 -type d -path "*/usr/lib/modules" 2>/dev/null | head -1)
	[ -n "$moddir" ] && OSROOT="${moddir%/usr/lib/modules}"
fi

# ── 1. Bootstrap marker ──────────────────────────────────────────────────
echo "== 1. Bootstrap identity =="
if [ -f "$OSROOT/usr/share/bootsahi/bootstrap-release" ]; then
	ok "bootstrap-release marker present"
	sed 's/^/       /' "$OSROOT/usr/share/bootsahi/bootstrap-release" || true

	# The marker must record the pinned fisherman revision. Without this a
	# "green" install proves nothing: you cannot answer "which fisherman did
	# we test this against?" and the pin becomes unverifiable after the fact.
	if grep -q 'fisherman_revision=' "$OSROOT/usr/share/bootsahi/bootstrap-release" 2>/dev/null; then
		ok "bootstrap-release records fisherman revision"
	else
		bad "bootstrap-release does not record fisherman_revision"
	fi

	# The cosign version must be recorded for the same reason — it is the
	# trust root for every install this bootstrap performs.
	if grep -q 'cosign_version=' "$OSROOT/usr/share/bootsahi/bootstrap-release" 2>/dev/null; then
		ok "bootstrap-release records cosign version"
	else
		bad "bootstrap-release does not record cosign_version"
	fi
else
	bad "NO /usr/share/bootsahi/bootstrap-release — this is not a bootstrap image"
fi

# ── 2. Agent and unit ────────────────────────────────────────────────────
echo
echo "== 2. bootsahi-agent =="
if [ -f "$OSROOT/usr/libexec/bootsahi-agent" ]; then
	ok "bootsahi-agent installed"
	# Must be executable — an unexecutable agent is functionally absent.
	[ -x "$OSROOT/usr/libexec/bootsahi-agent" ] && ok "bootsahi-agent is executable" ||
		bad "bootsahi-agent is NOT executable — it would never run"
else
	bad "bootsahi-agent MISSING — this bootstrap cannot install"
fi
[ -r "$OSROOT/usr/libexec/bootsahi-agent-recipe.sh" ] &&
	ok "recipe adapter installed" ||
	bad "recipe adapter MISSING — bootsahi-agent cannot start"
[ -r "$OSROOT/usr/libexec/bootsahi-agent-policy.sh" ] &&
	ok "policy library installed" ||
	bad "policy library MISSING — bootsahi-agent cannot start"
[ -r "$OSROOT/usr/libexec/bootsahi-agent-device.sh" ] &&
	ok "device adapter installed" ||
	bad "device adapter MISSING — bootsahi-agent cannot start"

if [ -f "$OSROOT/usr/lib/systemd/system/bootsahi-agent.service" ]; then
	ok "agent unit shipped"
else
	bad "agent unit MISSING — systemd cannot start the agent"
fi

# Check that the unit is ENABLED. A shipped-but-unenabled unit is a silent
# no-op on first boot. Check both possible wants directories: /etc takes
# precedence when present, /usr/lib is the image default.
enabled=0
for d in "$OSROOT/etc/systemd/system/multi-user.target.wants" \
         "$OSROOT/usr/lib/systemd/system/multi-user.target.wants"; do
	if [ -L "$d/bootsahi-agent.service" ] 2>/dev/null; then
		ok "agent unit ENABLED (wants symlink in ${d#$OSROOT})"
		enabled=1
		break
	fi
done
if [ "$enabled" -eq 0 ]; then
	bad "agent unit NOT enabled — it would never run on first boot"
fi

# Check for the never-matching ConditionKernelVersion=asahi bug (#23).
if [ -f "$OSROOT/usr/lib/systemd/system/bootsahi-agent.service" ]; then
	if grep -q '^ConditionKernelVersion=asahi$' \
	   "$OSROOT/usr/lib/systemd/system/bootsahi-agent.service" 2>/dev/null; then
		bad "unit has ConditionKernelVersion=asahi (never matches — #23 regression)"
	else
		ok "unit condition is not the never-matching literal (#23)"
	fi
fi

# ── 3. Tools the agent shells out to ────────────────────────────────────
echo
echo "== 3. Required tools =="
for t in fisherman jq cosign nmcli blkid; do
	found=0
	for p in "$OSROOT/usr/bin/$t" "$OSROOT/usr/sbin/$t" "$OSROOT/usr/libexec/$t"; do
		if [ -x "$p" ] || [ -f "$p" ]; then
			ok "tool present: $t ($(file -b "$p" 2>/dev/null | head -c 60))"
			found=1
			break
		fi
	done
	if [ "$found" -eq 0 ]; then
		bad "tool MISSING: $t — agent fails on first boot without it"
	fi
done

# ── 3b. fisherman version is recorded and extractable ────────────────────
echo
echo "== 3b. fisherman version =="
FISHERMAN_BIN=""
for p in "$OSROOT/usr/bin/fisherman" "$OSROOT/usr/sbin/fisherman" "$OSROOT/usr/libexec/fisherman"; do
	[ -x "$p" ] && FISHERMAN_BIN="$p" && break
done
if [ -n "$FISHERMAN_BIN" ] && [ -x "$FISHERMAN_BIN" ]; then
	if out=$("$FISHERMAN_BIN" version 2>&1); then
		ok "fisherman reports version: $(echo "$out" | head -1)"
	else
		# The binary might not run on this host (wrong arch), but its
		# presence is what matters for static verification.
		ok "fisherman binary present (cannot execute on this host: $(echo "$out" | head -1))"
	fi
else
	bad "fisherman binary not found or not executable"
fi

# ── 4. cosign version and binary ────────────────────────────────────────
echo
echo "== 4. cosign =="
COSIGN_BIN=""
if [ -x "$OSROOT/usr/bin/cosign" ]; then
	COSIGN_BIN="$OSROOT/usr/bin/cosign"
fi
if [ -n "$COSIGN_BIN" ]; then
	if out=$("$COSIGN_BIN" version 2>&1); then
		ok "cosign version: $(echo "$out" | head -1)"
	else
		ok "cosign binary present (cannot execute on this host)"
	fi
else
	bad "cosign MISSING — signature verification is impossible"
fi

# ── 5. bootbin-sync ──────────────────────────────────────────────────────
echo
echo "== 5. asahi-bootbin-sync =="
if [ -f "$OSROOT/usr/libexec/asahi-bootbin-sync" ]; then
	ok "asahi-bootbin-sync installed"
	[ -x "$OSROOT/usr/libexec/asahi-bootbin-sync" ] && ok "bootbin-sync is executable" ||
		bad "bootbin-sync not executable"
else
	echo "  WARN asahi-bootbin-sync not found (not yet a hard requirement)"
fi

if [ -f "$OSROOT/usr/lib/systemd/system/asahi-bootbin-sync.service" ]; then
	ok "bootbin-sync unit shipped"
else
	echo "  WARN bootbin-sync unit not found"
fi

# ── 6. NetworkManager ────────────────────────────────────────────────────
echo
echo "== 6. NetworkManager =="
if systemctl --root="$OSROOT" list-unit-files NetworkManager.service >/dev/null 2>&1; then
	ok "NetworkManager.service present"
else
	# systemctl --root may not work across OS boundaries; check for the binary
	if [ -x "$OSROOT/usr/sbin/NetworkManager" ] || [ -f "$OSROOT/usr/lib/systemd/system/NetworkManager.service" ]; then
		ok "NetworkManager present (binary or unit found)"
	else
		bad "NetworkManager MISSING — Wi-Fi handoff is broken"
	fi
fi

# ── 7. Schema ────────────────────────────────────────────────────────────
echo
echo "== 7. Schema =="
if [ -f "$OSROOT/usr/share/bootsahi/install-config.schema.json" ]; then
	ok "install-config schema shipped"
else
	echo "  WARN schema not found (not yet a hard requirement)"
fi

# ── 8. SSH toggle (headless install path) ────────────────────────────────
echo
echo "== 8. SSH =="
if systemctl --root="$OSROOT" list-unit-files sshd.service >/dev/null 2>&1; then
	ok "sshd.service present (headless install possible)"
elif [ -f "$OSROOT/usr/lib/systemd/system/sshd.service" ] || \
     [ -f "$OSROOT/usr/lib/systemd/system/ssh.service" ]; then
	ok "sshd unit present"
else
	echo "  WARN sshd not found — headless installs will have no access"
fi

# ── 9. Payload-level static verification (mirrors test-payload.sh §3b) ──
echo
echo "== 9. Payload-level contract (what test-payload.sh checks from the outside) =="
# These are the same checks test-payload.sh runs against a payload zip. Viewed
# from inside the image they are redundant, but verifying them here catches the
# case where the image is correct and the payload pipeline strips something.
# Deliberate redundancy — it is the assertion that the two views agree.

# update-m1n1 must be in the image for the boot.bin lifecycle.
if [ -x "$OSROOT/usr/bin/update-m1n1" ]; then
	ok "update-m1n1 present"
else
	bad "update-m1n1 MISSING — boot.bin cannot be updated on the installed system"
fi

# speakersafetyd must be present so speakers aren't left disabled.
if [ -x "$OSROOT/usr/bin/speakersafetyd" ]; then
	ok "speakersafetyd present"
else
	bad "speakersafetyd MISSING — speakers stay disabled"
fi

# dracut asahi-firmware module — consumes vendorfw/ on the ESP.
if ls -d "$OSROOT"/usr/lib/dracut/modules.d/99asahi-firmware >/dev/null 2>&1; then
	ok "dracut asahi-firmware module present"
else
	echo "  WARN dracut asahi-firmware not found"
fi

# ── Summary ──────────────────────────────────────────────────────────────
podman umount "$CTR" >/dev/null
podman rm -f "$CTR" >/dev/null
trap - EXIT

echo
if [ "$MODE" = "negative" ]; then
	# The negative fixture MUST fail — we deliberately removed the agent.
	if [ "$fail" -eq 0 ]; then
		echo "NEGATIVE TEST FAILED: the negative fixture (agent removed) PASSED all checks."
		echo "This means the checker is NOT discriminating — it is rubber-stamping every"
		echo "image rather than actually verifying the agent is present."
		exit 1
	fi
	echo "NEGATIVE TEST PASSED: the checker correctly reported $fail failures on an image"
	echo "with the agent removed."
	exit 0
fi

if [ "$fail" -ne 0 ]; then
	echo "BOOTSTRAP CONTENTS CHECK FAILED ($fail failures)"
	exit 1
fi
echo "BOOTSTRAP CONTENTS CHECK PASSED"
echo
echo "  This proves the bootstrap image contains everything the first-boot agent"
echo "  needs. The next step — proving it actually boots and runs the agent — is"
echo "  covered by test-bootstrap-boot.sh, which is opt-in (needs qemu +"
echo "  u-boot-qemu)."
exit 0
