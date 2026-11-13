#!/usr/bin/env bash
# test-agent.sh — proves bootsahi-agent's install-config.json -> fisherman
# recipe.json transform and its exit-code contract, without needing real
# disks, network, or a fisherman/bootc binary. Stubs FISHERMAN_BIN with
# generated scripts (see STUBS below — deliberately not host binaries) to
# exercise the success/failure paths; the greetd fallback logic downstream
# depends on the exit codes checked here being exactly right (see
# bootsahi-agent.sh's header comment for the contract).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/bootsahi-agent.sh"
source "$HERE/bootsahi-agent-recipe.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # description expected actual
	if [ "$2" != "$3" ]; then
		echo "FAIL: $1 (expected $2, got $3)"
		fail=1
	else
		echo "ok: $1"
	fi
}

# dump_agent_output prints the agent's own stdout + install.log for a run
# directory. Without this a failure only tells you the exit code was wrong,
# not WHERE the agent stopped — and the EXIT trap deletes $WORK, so the
# evidence is gone before you can look. Bit me diagnosing a macOS-only
# failure; same lesson as dakota's error-lines truncation.
dump_agent_output() { # rundir label
	echo "  ---- $2: agent stdout ----"
	sed 's/^/  | /' "$1/stdout" 2>/dev/null || echo "  | (no stdout captured)"
	echo "  ---- $2: install.log ----"
	sed 's/^/  | /' "$1/install.log" 2>/dev/null || echo "  | (no install.log written)"
	echo "  ---- $2: files in rundir ----"
	ls -la "$1" 2>/dev/null | sed 's/^/  | /'
	echo "  --------------------------------"
}

# check_exit wraps check() and dumps diagnostics when the exit code is wrong.
check_exit() { # description expected rundir
	local actual
	actual="$(cat "$3/exit")"
	check "$1" "$2" "$actual"
	[ "$2" != "$actual" ] && dump_agent_output "$3" "$1"
	return 0
}

# Fisherman stand-ins as generated scripts, NOT host binaries. This used to
# pass /bin/true and /bin/false — which exist on Linux and DO NOT exist on
# macOS (it ships /usr/bin/true and /usr/bin/false; /bin has neither). On a
# Mac the exec failed, the agent correctly reported "fisherman install failed"
# and exited 1, and the two success-path assertions failed for a reason that
# had nothing to do with the agent.
#
# It also made "==> fisherman itself fails" pass for the wrong reason: it
# expected exit 1 and got exit 1 because /bin/false was ABSENT, not because a
# present fisherman returned nonzero. Generating the stubs means the stub's
# exit status is the only variable, on every host.
STUBS="$WORK/stubs"
mkdir -p "$STUBS"

printf '#!/bin/sh\nexit 0\n' >"$STUBS/fisherman-ok"
printf '#!/bin/sh\nexit 1\n' >"$STUBS/fisherman-fail"
# Echoes the recipe it was handed into the agent's log, AND keeps a verbatim
# copy the assertions can run jq over. The copy is needed because install.log
# interleaves the JSON with the agent's own log lines, and because the agent
# shreds recipe.json itself on success.
printf '#!/bin/sh\ncat "$1"\ncp "$1" "$(dirname "$1")/recipe-captured.json"\n' >"$STUBS/fisherman-dump"
chmod +x "$STUBS"/fisherman-*

# cosign stubs (issue #24). Placed in their own directory that gets PREPENDED
# to PATH, so the agent's `command -v cosign` finds the stub rather than a real
# cosign that might be installed on the host — otherwise these tests would pass
# or fail depending on the machine.
#
# The success stub emits the real shape of `cosign verify --output json`: an
# array whose [0].critical.image."docker-manifest-digest" is the digest cosign
# actually verified. The agent pins the deploy to that digest, so getting this
# shape right is the difference between testing the contract and testing a
# mock of our own invention.
COSIGN_OK_DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
mkdir -p "$STUBS/bin-ok" "$STUBS/bin-fail" "$STUBS/bin-nodigest"
cat >"$STUBS/bin-ok/cosign" <<EOF
#!/bin/sh
[ "\$1" = "verify" ] || exit 1
printf '[{"critical":{"image":{"docker-manifest-digest":"$COSIGN_OK_DIGEST"}}}]\n'
EOF
# Verification itself fails — a wrong signer or wrong issuer looks like this.
printf '#!/bin/sh\necho "error: no matching signatures" >&2\nexit 1\n' >"$STUBS/bin-fail/cosign"
# Verification succeeds but the output carries no digest. The agent must refuse
# rather than fall back to the tag, or the verify/deploy race reopens silently.
printf '#!/bin/sh\nprintf "[{}]\\n"\n' >"$STUBS/bin-nodigest/cosign"
chmod +x "$STUBS"/bin-*/cosign

# Sanity-check the stubs by RUNNING them, not with `[ -x ]`. The whole bug
# being fixed here was a stand-in that couldn't execute, so verify the thing
# that actually matters. (`[ -x ]` is also not trustworthy everywhere: it
# returns false for mode-755 files under /tmp in some sandboxes even though
# those files execute fine.)
if ! "$STUBS/fisherman-ok"; then
	echo "FAIL: fisherman-ok stub did not run and exit 0 — cannot trust this suite"
	echo "      stub path: $STUBS/fisherman-ok"
	echo "      If this says 'Permission denied', \$TMPDIR is likely mounted noexec"
	echo "      (common on hardened servers, and in some agent sandboxes). Re-run with"
	echo "      TMPDIR pointed somewhere executable, e.g. TMPDIR=\$PWD/.tmp $0"
	exit 1
fi
if "$STUBS/fisherman-fail"; then
	echo "FAIL: fisherman-fail stub exited 0 — cannot trust this suite"
	exit 1
fi

run_agent() { # config_path fisherman_bin [extra_env...]
	local cfg="$1" fbin="$2" rundir usedcfg
	rundir=$(mktemp -d -p "$WORK")
	# Hand the agent a per-run COPY of the config, never the shared fixture.
	# The agent deletes install-config.json on success (it carries the LUKS
	# passphrase and lives on a world-readable vfat ESP), so passing the fixture
	# directly would let the first success-path test delete a file the later
	# tests still need — a self-inflicted ordering dependency.
	usedcfg="$rundir/install-config.json"
	if [ -f "$cfg" ]; then
		cp "$cfg" "$usedcfg"
	else
		usedcfg="$cfg" # nonexistent-on-purpose, for the "no config" case
	fi
	set +e
	# BOOTSAHI_SKIP_HW_CHECK: CI and macOS are not Apple Silicon Linux boxes, so
	# the agent's /proc/device-tree/compatible guard would exit 2 everywhere.
	# Tests that WANT the guard active pass BOOTSAHI_SKIP_HW_CHECK=0 as extra
	# env — a later duplicate assignment wins in env(1), verified.
	# PATH is prepended with the SUCCEEDING cosign stub by default, so the
	# default path through these tests is the production one: a real signature
	# policy, verified. Tests that need cosign to fail or to be absent pass
	# their own PATH= as extra env, which wins as the later assignment.
	env BOOTSAHI_RUN_DIR="$rundir" BOOTSAHI_NO_REBOOT=1 BOOTSAHI_CONFIG_PATH="$usedcfg" \
		BOOTSAHI_SKIP_HW_CHECK=1 \
		BOOTSAHI_ALLOW_CONFIG_DEVICES=1 \
		BOOTSAHI_TRUSTED_SIGNERS_PATH="$WORK/trusted-signers.json" \
		PATH="$STUBS/bin-ok:$PATH" \
		BOOTSAHI_FISHERMAN_BIN="$fbin" "${@:3}" bash "$AGENT" >"$rundir/stdout" 2>&1
	echo $? >"$rundir/exit"
	set -e
	echo "$rundir"
}

cat >"$WORK/good.json" <<'EOF'
{
  "targetImgref": "ghcr.io/tuna-os/bonito:gnome-asahi",
  "rootPartition": "/dev/null",
  "espPartition": "/dev/zero",
  "filesystem": "btrfs",
  "hostname": "tuna-mac",
  "user": {"username": "james", "groups": ["wheel"]},
  "encryption": {"type": "none"},
  "cosignIdentity": "https://example.test/signer",
  "cosignIssuer": "https://example.test/oidc"
}
EOF

# The signers this suite's bootstrap "ships". The fixtures' example.test signer
# is listed here rather than in the real trusted-signers.json, so the shipped
# list never has to carry a test identity.
cat >"$WORK/trusted-signers.json" <<'EOF'
{"signers": [{"cosignIdentity": "https://example.test/signer", "cosignIssuer": "https://example.test/oidc"}]}
EOF

# A signer the bootstrap does not ship: someone's own workflow, validly signed.
jq '.targetImgref = "ghcr.io/someone-else/image:latest"
    | .cosignIdentity = "https://github.com/someone-else/image/.github/workflows/build.yml@refs/heads/main"
    | .cosignIssuer = "https://token.actions.githubusercontent.com"' \
	"$WORK/good.json" >"$WORK/untrusted-signer.json"

# A trusted identity paired with a different issuer. Trust is in the pair.
jq '.cosignIssuer = "https://issuer.example.test/other"' "$WORK/good.json" >"$WORK/untrusted-issuer.json"

# Same config with NO signature policy. Since #24 this must be REFUSED rather
# than installed, so it is a fixture for the refusal test, not the happy path.
jq 'del(.cosignIdentity, .cosignIssuer)' "$WORK/good.json" >"$WORK/no-policy.json"

# Identity present, issuer missing. Must also be refused: a certificate
# identity without a pinned issuer would be accepted from ANY OIDC provider,
# so "half a policy" is not a weaker policy, it is no policy at all.
jq 'del(.cosignIssuer)' "$WORK/good.json" >"$WORK/half-policy.json"

cat >"$WORK/missing-field.json" <<'EOF'
{"targetImgref": "x", "rootPartition": "/dev/null", "espPartition": "/dev/zero", "filesystem": "btrfs"}
EOF

cat >"$WORK/cosign.json" <<'EOF'
{
  "targetImgref": "x", "rootPartition": "/dev/null", "espPartition": "/dev/zero",
  "filesystem": "btrfs", "hostname": "h",
  "cosignIdentity": "https://example.test/signer", "cosignIssuer": "https://example.test/oidc"
}
EOF

cat >"$WORK/encrypted.json" <<'EOF'
{
  "targetImgref": "ghcr.io/tuna-os/bonito:gnome-asahi",
  "rootPartition": "/dev/null", "espPartition": "/dev/zero",
  "filesystem": "btrfs", "hostname": "h",
  "encryption": {"type": "tpm2-luks", "passphrase": "hunter2"}
}
EOF

echo "==> success path (fisherman succeeds)"
r=$(run_agent "$WORK/good.json" "$STUBS/fisherman-ok")
check_exit "exit code" 0 "$r"
check "recipe.json shredded after success" "" "$(ls "$r/recipe.json" 2>/dev/null || true)"
check "install-config.json removed after success" "" "$(ls "$r/install-config.json" 2>/dev/null || true)"
# The agent reports an unexecutable fisherman and a fisherman that ran and
# returned nonzero identically (both "install failed", exit 1). Assert the
# stub was actually EXECUTED, so a future path/permission regression can't
# masquerade as a legitimately-failing install the way /bin/true did.
if grep -q 'No such file or directory' "$r/install.log" 2>/dev/null; then
	echo "FAIL: fisherman stub was never executed (see install.log)"
	dump_agent_output "$r" "stub not executable"
	fail=1
fi

echo "==> recipe.json shape (fisherman dumps the recipe into install.log)"
r=$(run_agent "$WORK/good.json" "$STUBS/fisherman-dump")
r_dump="$r"
# shape_fail is separate from the global `fail` on purpose: this block used to
# gate its "ok" on `fail`, so any EARLIER failing test silenced it entirely and
# the shape checks reported neither ok nor FAIL — leaving you unable to tell
# whether they ran, passed, or were skipped.
shape_fail=0
grep -q '"bootloader": "systemd"' "$r/install.log" || { echo "FAIL: recipe missing bootloader=systemd"; shape_fail=1; }
# Asserted as a PAIR, because bootc treats it as one. --bootloader systemd is
# only honoured on the composefs deployment path; on the ostree path bootc
# hands bootloader installation to bootupd and aborts with "bootupd is required
# for ostree-based installs". Requesting one without the other is an install
# that cannot succeed, and it fails after the target is already formatted.
# Observed for real in CI before this assertion existed.
grep -q '"composeFsBackend": true' "$r/install.log" || { echo "FAIL: recipe sets bootloader=systemd without composeFsBackend — bootc will demand bootupd and fail mid-install"; shape_fail=1; }
# The deployed image must be the DIGEST cosign verified, not the tag (#24).
# Verifying a tag and then installing that tag is a TOCTOU race: the tag can
# move in between, so the bytes verified need not be the bytes deployed.
grep -q "\"image\": \".*@$COSIGN_OK_DIGEST\"" "$r/install.log" ||
	{ echo "FAIL: recipe does not deploy the digest cosign verified — verify/deploy race is open"; shape_fail=1; }
# ...while targetImgref stays the mutable tag, or the installed machine would
# be pinned to one build forever and never take an upgrade.
grep -q '"targetImgref": "ghcr.io/tuna-os/bonito:gnome-asahi"' "$r/install.log" ||
	{ echo "FAIL: targetImgref should remain the tag so upgrades still track it"; shape_fail=1; }
grep -q '"target": "/"' "$r/install.log" || { echo "FAIL: recipe missing root customMount"; shape_fail=1; }
grep -q '"target": "/boot/efi"' "$r/install.log" || { echo "FAIL: recipe missing ESP customMount"; shape_fail=1; }
grep -q '"hostname": "tuna-mac"' "$r/install.log" || { echo "FAIL: recipe missing expected hostname"; shape_fail=1; }
grep -q '"imageType": "bootc"' "$r/install.log" || { echo "FAIL: recipe missing imageType=bootc"; shape_fail=1; }
if [ "$shape_fail" -eq 0 ]; then
	echo "ok: recipe.json shape"
else
	dump_agent_output "$r" "recipe.json shape"
	fail=1
fi

# ── the backend pairing is a constant, and must stay unreachable from config ──
# Issue #26 asks for "representative ostree and composefs-native target
# metadata". There is no ostree variant to be representative OF: the agent
# writes bootloader=systemd and composeFsBackend=true as literals, and the
# install-config schema has no field that can express either. An ostree-backend
# install is not a configuration this project supports and fails to test — it is
# one bootc rejects outright ("bootupd is required for ostree-based installs").
#
# So the testable property is twofold:
# 1) Unexpected backend keys in install-config are rejected at the schema gate (issue #121).
# 2) Even if passed to the recipe adapter, build_recipe hardcodes the literals.
echo "==> config cannot override the composefs/systemd pairing"
jq '. + {"bootloader":"grub2","composeFsBackend":false,
         "backend":"ostree","imageType":"ostree"}' \
	"$WORK/good.json" >"$WORK/override-backend.json"
r_override=$(run_agent "$WORK/override-backend.json" "$STUBS/fisherman-dump")
check_exit "exit code (unexpected config keys refused at schema gate)" 1 "$r_override"

RECIPE_FILE="$WORK/override-recipe.json"
build_recipe "$WORK/override-backend.json" "/dev/null" "/dev/zero" "dummy@sha256:123"
override_fail=0
grep -q '"bootloader": "systemd"' "$RECIPE_FILE" ||
	{ echo "FAIL: a config key overrode bootloader — grub2 has no persistent EFI vars under U-Boot"; override_fail=1; }
grep -q '"composeFsBackend": true' "$RECIPE_FILE" ||
	{ echo "FAIL: a config key overrode composeFsBackend — bootc will demand bootupd and fail after formatting"; override_fail=1; }
grep -q '"imageType": "bootc"' "$RECIPE_FILE" ||
	{ echo "FAIL: a config key overrode imageType"; override_fail=1; }
if [ "$override_fail" -eq 0 ]; then
	echo "ok: config cannot override the composefs/systemd pairing"
else
	fail=1
fi

# ── fstype tokens must be ones fisherman actually accepts ────────────────
# The grep-for-substrings assertions above are why a bogus fstype survived: they
# checked that a /boot/efi mount EXISTED, never what it would DO. fisherman's
# recipe.Validate() doesn't check customMounts fstypes either, so an unknown
# token isn't caught until disk.formatPartition() fatals at install step 1 —
# on real hardware, after the disk has already been repartitioned.
#
# Accepted set is disk.formatPartition()'s switch plus the two skip-format
# sentinels. Keep in sync with internal/disk/custom.go.
CAPTURED="$r_dump/recipe-captured.json"
if [ ! -f "$CAPTURED" ]; then
	echo "FAIL: fisherman-dump did not capture a recipe to inspect"
	fail=1
else
	bad=$(jq -r '
		["fat32","ext4","ext3","xfs","btrfs","unformatted","swap",""] as $ok
		| .customMounts[]
		| select((.fstype // "") as $f | $ok | index($f) | not)
		| "\(.target)=\(.fstype)"
	' "$CAPTURED")
	if [ -n "$bad" ]; then
		echo "FAIL: fstype not accepted by fisherman's formatPartition: $bad"
		fail=1
	else
		echo "ok: all customMounts fstypes are tokens fisherman accepts"
	fi

	# The ESP must never be reformatted: it already holds m1n1/boot.bin, the
	# bootloader, and vendorfw/ — on-device-extracted Apple firmware that is not
	# redistributable and cannot be recovered. Anything but a skip-format token
	# here is a DFU-restore-grade bug, so assert it explicitly rather than
	# relying on it being in the accepted set above.
	esp_fstype=$(jq -r '.customMounts[] | select(.target == "/boot/efi") | .fstype' "$CAPTURED")
	case "$esp_fstype" in
	unformatted | "") echo "ok: ESP is not reformatted (fstype=${esp_fstype:-<empty>})" ;;
	*)
		echo "FAIL: ESP fstype is '$esp_fstype' — this runs mkfs on the ESP and destroys m1n1/boot.bin + vendorfw"
		fail=1
		;;
	esac
fi

echo "==> no install-config.json present"
r=$(run_agent "$WORK/does-not-exist.json" "$STUBS/fisherman-ok")
check_exit "exit code (no config -> fall through to interactive UI)" 2 "$r"

echo "==> install-config.json missing a required field"
r=$(run_agent "$WORK/missing-field.json" "$STUBS/fisherman-ok")
check_exit "exit code (missing field)" 1 "$r"

echo "==> install-config.json with unexpected root field (schema additionalProperties)"
jq '.unexpectedRootField = "disallowed"' "$WORK/good.json" >"$WORK/unexpected-field.json"
r=$(run_agent "$WORK/unexpected-field.json" "$STUBS/fisherman-ok")
check_exit "exit code (unexpected root field rejected)" 1 "$r"

echo "==> install-config.json with unexpected user field (schema additionalProperties)"
jq '.user.extra = "disallowed"' "$WORK/good.json" >"$WORK/unexpected-user.json"
r=$(run_agent "$WORK/unexpected-user.json" "$STUBS/fisherman-ok")
check_exit "exit code (unexpected user field rejected)" 1 "$r"

echo "==> install-config.json with invalid filesystem enum"
jq '.filesystem = "ntfs"' "$WORK/good.json" >"$WORK/invalid-fs.json"
r=$(run_agent "$WORK/invalid-fs.json" "$STUBS/fisherman-ok")
check_exit "exit code (invalid filesystem rejected)" 1 "$r"

echo "==> install-config.json with invalid encryption type enum"
jq '.encryption.type = "unsupported-cipher"' "$WORK/good.json" >"$WORK/invalid-enc.json"
r=$(run_agent "$WORK/invalid-enc.json" "$STUBS/fisherman-ok")
check_exit "exit code (invalid encryption type rejected)" 1 "$r"


echo "==> fisherman itself fails"
r=$(run_agent "$WORK/good.json" "$STUBS/fisherman-fail")
check_exit "exit code (fisherman failure)" 1 "$r"
# The complement of the deletion above: on failure the config must SURVIVE, or
# the interactive fisherman UI we fall back to has nothing to retry from.
check "install-config.json preserved after failure" "$r/install-config.json" \
	"$(ls "$r/install-config.json" 2>/dev/null || true)"

# ── Signature verification must FAIL CLOSED (issue #24) ─────────────────────
# Before this, verify_signature returned 0 whenever cosignIdentity was absent,
# so the DEFAULT path deployed an unverified mutable tag while DESIGN.md
# claimed signatures were verified. The install-config lives on the ESP — a
# world-readable vfat partition — so "policy you can omit" means anyone who can
# write that file chooses what gets installed.

echo "==> NO signature policy -> refuse (the #24 default-path defect)"
r=$(run_agent "$WORK/no-policy.json" "$STUBS/fisherman-ok")
check_exit "exit code (no cosign policy -> refuse)" 1 "$r"
check "no recipe generated without a policy" "" \
	"$(ls "$r/recipe.json" 2>/dev/null || true)"

echo "==> identity WITHOUT issuer -> refuse (half a policy is no policy)"
r=$(run_agent "$WORK/half-policy.json" "$STUBS/fisherman-ok")
check_exit "exit code (identity without issuer -> refuse)" 1 "$r"

# The config sits on the ESP beside the image reference, so a signer it names
# proves nothing by itself: anyone can sign their own image with their own
# workflow. The cosign stub SUCCEEDS in these three cases, so only the
# trusted-signers check can produce the refusal.
echo "==> signer not shipped in trusted-signers.json -> refuse, even though cosign would verify"
r=$(run_agent "$WORK/untrusted-signer.json" "$STUBS/fisherman-ok")
check_exit "exit code (untrusted signer -> refuse)" 1 "$r"
check "no recipe generated for an untrusted signer" "" \
	"$(ls "$r/recipe.json" 2>/dev/null || true)"
if grep -q "verifying cosign signature" "$r/install.log"; then
	echo "FAIL: cosign was consulted for a signer the bootstrap does not trust"
	fail=1
else
	echo "ok: untrusted signer refused before cosign ran"
fi

echo "==> trusted identity with a different issuer -> refuse (the pair is what is trusted)"
r=$(run_agent "$WORK/untrusted-issuer.json" "$STUBS/fisherman-ok")
check_exit "exit code (trusted identity, other issuer -> refuse)" 1 "$r"

echo "==> trusted-signers.json missing -> refuse (fail closed, like the schema)"
r=$(run_agent "$WORK/good.json" "$STUBS/fisherman-ok" BOOTSAHI_TRUSTED_SIGNERS_PATH="$WORK/no-such-signers.json")
check_exit "exit code (no trusted-signers list -> refuse)" 1 "$r"

echo "==> cosign verification FAILS (wrong signer / wrong issuer)"
r=$(run_agent "$WORK/good.json" "$STUBS/fisherman-ok" PATH="$STUBS/bin-fail:$PATH")
check_exit "exit code (cosign verify failed -> refuse)" 1 "$r"

echo "==> cosign succeeds but reports no digest -> refuse, never fall back to the tag"
r=$(run_agent "$WORK/good.json" "$STUBS/fisherman-ok" PATH="$STUBS/bin-nodigest:$PATH")
check_exit "exit code (verified but undigested -> refuse)" 1 "$r"

echo "==> policy set but cosign missing from the image"
# Runs with the ORIGINAL PATH (no stub dir), so this only means anything on a
# host without a real cosign. Stated rather than assumed: silently passing
# because the host happens to lack a binary is not the same as asserting the
# refusal, and PATH cannot be emptied here because the agent still needs jq.
if command -v cosign >/dev/null 2>&1; then
	echo "  skip: a real cosign is installed on this host, so its absence cannot be simulated"
else
	r=$(run_agent "$WORK/cosign.json" "$STUBS/fisherman-ok" PATH="$PATH")
	check_exit "exit code (cosign required, binary absent)" 1 "$r"
fi

echo "==> BOOTSAHI_ALLOW_UNVERIFIED escape hatch taints the run"
r=$(run_agent "$WORK/no-policy.json" "$STUBS/fisherman-ok" BOOTSAHI_ALLOW_UNVERIFIED=1)
check_exit "exit code (explicit unverified override)" 0 "$r"
# The override must be self-identifying in the artifacts. A dev bypass that
# leaves a clean-looking run behind is how an unverified install gets mistaken
# for evidence that verification works.
if [ -f "$r/UNVERIFIED-INSTALL" ]; then
	echo "ok: unverified run left a taint marker"
else
	echo "FAIL: BOOTSAHI_ALLOW_UNVERIFIED left no taint marker in the run dir"
	fail=1
fi

# ── Secrets must not survive, on any path (issue #21) ───────────────────────

echo "==> a Wi-Fi passphrase in the config -> refuse (secrets never travel on the ESP)"
jq '.wifi = {"ssid":"home","psk":"correct-horse"}' "$WORK/good.json" >"$WORK/wifi-psk.json"
r=$(run_agent "$WORK/wifi-psk.json" "$STUBS/fisherman-ok")
check_exit "exit code (wifi.psk present -> refuse)" 1 "$r"
check "no recipe generated for a config carrying a Wi-Fi secret" "" \
	"$(ls "$r/recipe.json" 2>/dev/null || true)"

echo "==> a LUKS passphrase in the config -> refuse"
jq '.encryption = {"type":"none","passphrase":"hunter2"}' "$WORK/good.json" >"$WORK/luks-pass.json"
r=$(run_agent "$WORK/luks-pass.json" "$STUBS/fisherman-ok")
check_exit "exit code (encryption.passphrase present -> refuse)" 1 "$r"

echo "==> SSID alone is fine, and the password is ASKED FOR rather than read"
# The stub stands in for systemd-ask-password: the agent has no TTY (oneshot,
# Before=greetd), so a password agent is the only way to reach the user. Its
# being called at all is the assertion — that is what proves the secret came
# from the person at the machine and not from the ESP.
printf '#!/bin/sh\necho "asked: $*" >>"%s/ask.log"\nprintf "s3cret\\n"\n' "$WORK" >"$STUBS/ask-ok"
chmod +x "$STUBS/ask-ok"
: >"$WORK/ask.log"
jq '.wifi = {"ssid":"home"}' "$WORK/good.json" >"$WORK/wifi-ssid.json"
r=$(run_agent "$WORK/wifi-ssid.json" "$STUBS/fisherman-ok" BOOTSAHI_ASK_PASSWORD_BIN="$STUBS/ask-ok")
check_exit "exit code (ssid only, password prompted)" 0 "$r"
if grep -q "Wi-Fi password for home" "$WORK/ask.log" 2>/dev/null; then
	echo "ok: the agent asked the user for the Wi-Fi password"
else
	echo "FAIL: the agent never prompted for the Wi-Fi password"
	sed 's/^/      | /' "$WORK/ask.log" 2>/dev/null
	fail=1
fi
# And the answer must not end up written anywhere.
if grep -rqF "s3cret" "$r" 2>/dev/null; then
	echo "FAIL: the prompted Wi-Fi password was persisted in the run dir:"
	grep -rlF "s3cret" "$r" 2>/dev/null | sed 's/^/      | /'
	fail=1
else
	echo "ok: the prompted Wi-Fi password was never written to disk"
fi

echo "==> plaintext account password -> refuse (ESP is world-readable and survives failure)"
jq '.user.password = "hunter2"' "$WORK/good.json" >"$WORK/plaintext-pw.json"
r=$(run_agent "$WORK/plaintext-pw.json" "$STUBS/fisherman-ok")
check_exit "exit code (plaintext password -> refuse)" 1 "$r"
check "no recipe generated for a plaintext password" "" \
	"$(ls "$r/recipe.json" 2>/dev/null || true)"

echo "==> \$6\$ crypt hash is accepted (fisherman applies it via chpasswd -e)"
jq '.user.password = "$6$abcdefgh$0123456789abcdef"' "$WORK/good.json" >"$WORK/hashed-pw.json"
r=$(run_agent "$WORK/hashed-pw.json" "$STUBS/fisherman-ok")
check_exit "exit code (hashed password accepted)" 0 "$r"

# The assertion #21 actually asks for: force a failure AFTER the recipe exists
# and prove no secret canary is left behind in runtime state. The recipe is the
# dangerous artifact — it carries the LUKS passphrase and the password — and it
# is derived, so unlike install-config.json there is no retry argument for
# keeping it.
echo "==> secret canary must not survive a failure after the recipe is written"
SECRET_CANARY='SUPERSECRET-CANARY-b7f3'
jq --arg p "\$6\$salt\$$SECRET_CANARY" '.user.password = $p' \
	"$WORK/good.json" >"$WORK/canary.json"
r=$(run_agent "$WORK/canary.json" "$STUBS/fisherman-fail")
check_exit "exit code (fisherman failed after recipe creation)" 1 "$r"

# Everything the agent DERIVES must be clean: the shredded recipe, and — easy
# to forget — install.log, which the agent writes itself and which would
# happily contain a secret if anything ever echoed the recipe into it.
leaked=$(grep -rlF "$SECRET_CANARY" "$r" 2>/dev/null | grep -v '/install-config\.json$' || true)
if [ -n "$leaked" ]; then
	echo "FAIL: a secret canary survived a post-recipe failure in derived state:"
	printf '%s\n' "$leaked" | sed 's/^/      | /'
	fail=1
else
	echo "ok: no secret canary in any derived artifact after a failed install"
fi

# install-config.json is excluded above because the agent PRESERVES it on
# failure on purpose, so the fallback UI can retry. That is the known open half
# of #21 ("retry state contains non-secret intent only; retry prompts again for
# secrets"), not an accident — so assert it explicitly rather than letting the
# exclusion above quietly imply the file is clean.
#
# What has changed: since the password must now be a crypt hash, the retained
# file no longer holds a reusable account credential. The Wi-Fi PSK and (once
# implemented) the LUKS passphrase are still plaintext there, which is why #21
# stays open.
if grep -qF "$SECRET_CANARY" "$r/install-config.json" 2>/dev/null; then
	echo "ok: install-config.json is retained on failure, as designed (#21 open half)"
else
	echo "FAIL: install-config.json was NOT retained after a failure — the fallback"
	echo "      UI can no longer retry, which contradicts the documented behaviour."
	echo "      If this is intentional, #21 and the retry design need updating."
	fail=1
fi

echo "==> encryption requested (fisherman's manual path cannot do LUKS -> must fail closed)"
r=$(run_agent "$WORK/encrypted.json" "$STUBS/fisherman-ok")
check_exit "exit code (encryption unsupported -> fail closed)" 1 "$r"
# The whole point is that it refuses BEFORE touching a disk: fisherman must
# never have been invoked, so no recipe should have been handed to it.
check "no recipe generated for a rejected encrypted config" "" \
	"$(ls "$r/recipe-captured.json" 2>/dev/null || true)"

echo "==> recipe removed even when fisherman FAILS (secrets must not linger)"
r=$(run_agent "$WORK/good.json" "$STUBS/fisherman-fail")
check "recipe.json removed on the failure path too" "" "$(ls "$r/recipe.json" 2>/dev/null || true)"

echo "==> non-Apple hardware guard (no skip override)"
r=$(run_agent "$WORK/good.json" "$STUBS/fisherman-ok" BOOTSAHI_SKIP_HW_CHECK=0)
check_exit "exit code (not Apple Silicon -> nothing to do, NOT success)" 2 "$r"

echo "==> run dir is not world-readable"
r=$(run_agent "$WORK/good.json" "$STUBS/fisherman-ok")
check "run dir mode" "700" "$(stat -c '%a' "$r" 2>/dev/null || stat -f '%Lp' "$r" 2>/dev/null)"

echo "==> config naming the ACTIVE root partition must be refused (issue #19)"
# Build a config whose rootPartition is literally the device backing / on this
# machine. Handing that to fisherman means mkfs on the filesystem containing
# PID 1. Skipped where / is not backed by a real block device (container
# overlayfs, macOS) — there is nothing to name, so nothing to refuse.
active_src=$(awk '$5 == "/" { print $3; exit }' /proc/self/mountinfo 2>/dev/null || true)
active_dev=""
if [ -n "$active_src" ]; then
	for d in /dev/* /dev/mapper/* /dev/nvme*; do
		[ -b "$d" ] || continue
		hex=$(stat -Lc '%t:%T' "$d" 2>/dev/null) || continue
		[ "$(printf '%d:%d' "0x${hex%%:*}" "0x${hex##*:}" 2>/dev/null)" = "$active_src" ] || continue
		active_dev="$d"
		break
	done
fi
if [ -n "$active_dev" ]; then
	jq --arg dev "$active_dev" '.rootPartition = $dev' "$WORK/good.json" >"$WORK/active-root.json"
	r=$(run_agent "$WORK/active-root.json" "$STUBS/fisherman-ok")
	check_exit "exit code (rootPartition == active root -> refuse)" 1 "$r"
	check "no recipe generated when refusing the active root" "" \
		"$(ls "$r/recipe-captured.json" 2>/dev/null || true)"
	grep -q 'is the device backing /' "$r/install.log" ||
		{ echo "FAIL: refusal did not explain itself in the log"; fail=1; }
else
	echo "  skip: / is not backed by a discoverable block device here ($active_src)"
fi

echo "==> rootPartition == espPartition must be refused"
jq '.espPartition = .rootPartition' "$WORK/good.json" >"$WORK/same-dev.json"
r=$(run_agent "$WORK/same-dev.json" "$STUBS/fisherman-ok")
check_exit "exit code (root == esp -> refuse)" 1 "$r"

echo "==> without the dev override, config device paths must be REFUSED"
# The whole suite runs with BOOTSAHI_ALLOW_CONFIG_DEVICES=1 because it has no
# stub_info.json. Prove the default is the safe one: production must not be able
# to reach that path by accident.
r=$(run_agent "$WORK/good.json" "$STUBS/fisherman-ok" BOOTSAHI_ALLOW_CONFIG_DEVICES=0)
check_exit "exit code (no stub_info, no override -> refuse)" 1 "$r"
check "no recipe generated without a resolvable target" "" \
	"$(ls "$r/recipe-captured.json" 2>/dev/null || true)"

# ── D1 recipe validated by the REAL fisherman (issue #26) ─────────────────
# Every assertion above is OUR opinion of what fisherman accepts. That is
# exactly how the vfat defect survived: the recipe looked right to us and was
# never shown to the real consumer. This step hands the generated recipe to
# fisherman's own `validate` so a future schema change or unsupported fstype
# does not survive to the install phase.
#
# This is the bridge between the stub-based tests (which check the agent's
# config→recipe logic on every machine, no fisherman required) and the
# real-install test (test-agent-install.sh, which runs a full install but
# needs a loop device and a target image). validate is non-destructive — it
# parses and checks, it does not mutate — so it is cheap enough to run here.
echo
echo "==> the REAL fisherman validates the generated recipe (issue #26)"
FISHERMAN_BIN="${FISHERMAN_BIN:-$(command -v fisherman 2>/dev/null || true)}"
if [ -z "$FISHERMAN_BIN" ] || [ ! -x "$FISHERMAN_BIN" ]; then
	echo "  SKIP no fisherman binary available."
	echo "       This is the assertion that would have caught the vfat bug (#17), so"
	echo "       its absence is worth noticing. Set FISHERMAN_BIN=/path/to/fisherman"
	echo "       to enable. In CI (selftest.yml), the pinned fisherman is built and"
	echo "       this check runs green against the EXACT revision the bootstrap ships."
elif [ ! -f "$CAPTURED" ]; then
	echo "FAIL: no recipe was captured by the dump stub — cannot validate"
	fail=1
else
	if out=$("$FISHERMAN_BIN" validate "$CAPTURED" 2>&1); then
		echo "ok: fisherman validate accepted the generated recipe"
		echo "    ($("$FISHERMAN_BIN" version 2>/dev/null | head -1))"
	else
		echo "FAIL: fisherman REJECTED the recipe this agent generates"
		echo "$out" | sed 's/^/      | /'
		fail=1
	fi

	# Belt-and-braces: prove the validator is actually discriminating.
	# Feed it the exact defect that shipped — fstype=vfat on the ESP — and
	# confirm it is rejected (or note that it would be caught later).
	sed 's/"fstype": "unformatted"/"fstype": "vfat"/' "$CAPTURED" \
		>"$WORK/recipe-vfat.json"
	if "$FISHERMAN_BIN" validate "$WORK/recipe-vfat.json" >/dev/null 2>&1; then
		echo "  note: this fisherman ACCEPTS fstype=vfat at validate time — it will"
		echo "        fail later in formatPartition instead. Fixed by"
		echo "        projectbluefin/fisherman#12; our own fstype assertions above"
		echo "        are the gate until that lands."
	else
		echo "ok: fisherman rejects the vfat defect at validate time"
	fi

	# Also try an unsupported customMount fstype. The agent's fstype-accepted
	# set above asserts this, but fisherman's own validator is the authority.
	sed 's/"fstype": "btrfs"/"fstype": "zfs"/' "$CAPTURED" \
		>"$WORK/recipe-zfs.json"
	if "$FISHERMAN_BIN" validate "$WORK/recipe-zfs.json" >/dev/null 2>&1; then
		echo "  note: fisherman ACCEPTS fstype=zfs — it would fail in"
		echo "        formatPartition. Our own fstype check catches this."
	else
		echo "ok: fisherman rejects unsupported fstype=zfs at validate time"
	fi
fi

echo
# test-agent-disk.sh and test-agent-install.sh refuse a fisherman that was not
# built from bootstrap-image/fisherman.rev. CI only runs those as root with a
# freshly built binary, so the guard's verdicts are pinned here, against fake
# build stamps, on every machine.
echo "==> fisherman revision guard (scripts/fisherman-rev.sh)"
REVTOOL="$HERE/../../scripts/fisherman-rev.sh"
pinned=$("$REVTOOL")
check "fisherman.rev holds a 40-character commit SHA" "40" "${#pinned}"
other=1111111111111111111111111111111111111111
stamp() { # file revision modified
	printf 'junk\0build\tvcs=git\nbuild\tvcs.revision=%s\nbuild\tvcs.modified=%s\n' "$2" "$3" >"$1"
}
rev_rc() { # bin [pin-file]
	local rc=0
	if [ -n "${2:-}" ]; then
		FISHERMAN_REV_FILE="$2" "$REVTOOL" --check "$1" >/dev/null 2>&1 || rc=$?
	else
		"$REVTOOL" --check "$1" >/dev/null 2>&1 || rc=$?
	fi
	echo "$rc"
}
stamp "$WORK/fm-pinned" "$pinned" false
stamp "$WORK/fm-other" "$other" false
stamp "$WORK/fm-dirty" "$pinned" true
printf 'no build info here\n' >"$WORK/fm-unstamped"
printf '# comment only\n' >"$WORK/rev-empty"
check "accepts a binary built from the pinned revision" "0" "$(rev_rc "$WORK/fm-pinned")"
check "rejects a binary built from another revision" "1" "$(rev_rc "$WORK/fm-other")"
check "rejects a binary built from a modified checkout" "1" "$(rev_rc "$WORK/fm-dirty")"
check "cannot vouch for a binary with no vcs stamp" "2" "$(rev_rc "$WORK/fm-unstamped")"
check "fails closed on a pin file with no SHA" "2" "$(rev_rc "$WORK/fm-pinned" "$WORK/rev-empty")"

echo "==> device resolution & partition safety unit tests"
if "$HERE/test-agent-device.sh"; then
	echo "ok: device library unit tests passed"
else
	echo "FAIL: device library unit tests failed"
	fail=1
fi

if [ "$fail" -ne 0 ]; then
	echo "SELFTEST FAILED"
	exit 1
fi
echo "SELFTEST PASSED"
