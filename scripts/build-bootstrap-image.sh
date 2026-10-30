#!/usr/bin/env bash
# build-bootstrap-image.sh — build the bootsahi bootstrap image (issue #27).
#
# Until this existed, the payload pipeline repackaged a stock desktop image, so
# what CI produced contained no bootsahi-agent, no unit, no fisherman and no
# cosign. "The payload boots" was demonstrated; "the bootstrap installs
# anything" was never tested, because there was nothing to test.
#
# Staging happens here rather than in the Containerfile because the sources live
# in components/ and scripts/ — a Containerfile cannot COPY from outside its
# build context, and making the repo root the context would ship the whole tree
# into the image.
#
# Usage:
#   ./build-bootstrap-image.sh [tag]
# Env:
#   BASE_IMAGE           base to derive from (default: bonito gnome-asahi)
#   FISHERMAN_REPO/REV   which fisherman to vendor, pinned by default
#   SKIP_FISHERMAN_BUILD =1 to reuse an already-staged binary (local iteration)
set -euo pipefail

TAG="${1:-localhost/bootsahi-bootstrap:dev}"
HERE=$(cd "$(dirname "$0")/.." && pwd)
CTX="$HERE/bootstrap-image"

# tuna-os publishes no minimal asahi tag today (only bonito:gnome-asahi and
# :gnome-asahi-testing), so this derives from a full GNOME image and is much
# larger than DESIGN.md's ~1.5 GB target. Dakota-asahi is the destination; the
# swap is this one variable, which is why it is a variable.
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/tuna-os/bonito:gnome-asahi}"

# Pinned, not floating. Issue #26 requires knowing exactly which fisherman a
# payload was tested against; a floating tag makes that unanswerable after the
# fact.
#
# This used to point at projectbluefin/fisherman, because tuna-os/fisherman
# lacked the explicit `mount -t` fix (a883428) without which an xfs root gets
# attempted as ext4 and the install dies. That was a workaround for a fork
# divergence, not a preference.
#
# tuna-os/fisherman is now synced (tuna-os/fisherman#59 brought over all 14
# commits, which also turned that fork's own CI from red to green) and carries
# two things projectbluefin does not: TPM2 enrolment on first boot, and the
# customMounts validation this project needs (#58 — rejects unsupported
# fstypes and refuses encryption on manual layouts, both of which are defects
# we hit here). So the pin now points at our own fork.
FISHERMAN_REPO="${FISHERMAN_REPO:-https://github.com/tuna-os/fisherman}"
# TEMPORARY: head of tuna-os/fisherman#70, which adds -O verity to the
# manual-layout ext4 mkfs. bootc's --composefs-backend calls
# FS_IOC_ENABLE_VERITY, which ext4 refuses unless the feature was set at format
# time, so without this a composefs install onto customMounts fails *after* the
# target is formatted and the image deployed. Move to the merged SHA on dev
# once that PR lands.
FISHERMAN_REV="${FISHERMAN_REV:-d6b21ddfb9c4e97ea13ee35b2b966e5dd5c028e2}"

echo "==> base image:        $BASE_IMAGE"
echo "==> fisherman:         $FISHERMAN_REPO @ ${FISHERMAN_REV:0:12}"
echo "==> output tag:        $TAG"

# ── Stage the pieces the Containerfile COPYs ────────────────────────────────
echo "==> Staging agent, units and schema into the build context"
install -m 0755 "$HERE/components/bootsahi-agent/bootsahi-agent.sh" "$CTX/bootsahi-agent"
install -m 0644 "$HERE/components/bootsahi-agent/bootsahi-agent-recipe.sh" "$CTX/bootsahi-agent-recipe.sh"
install -m 0644 "$HERE/components/bootsahi-agent/bootsahi-agent-policy.sh" "$CTX/bootsahi-agent-policy.sh"
install -m 0644 "$HERE/components/bootsahi-agent/bootsahi-agent-device.sh" "$CTX/bootsahi-agent-device.sh"
install -m 0755 "$HERE/components/asahi-bootbin-sync/asahi-bootbin-sync.sh" "$CTX/asahi-bootbin-sync"
install -m 0644 "$HERE/components/bootsahi-agent/bootsahi-agent.service" "$CTX/bootsahi-agent.service"
install -m 0644 "$HERE/components/asahi-bootbin-sync/asahi-bootbin-sync.service" "$CTX/asahi-bootbin-sync.service"
install -m 0644 "$HERE/components/bootsahi-agent/install-config.schema.json" "$CTX/install-config.schema.json"

# ── fisherman ───────────────────────────────────────────────────────────────
if [ "${SKIP_FISHERMAN_BUILD:-0}" = "1" ] && [ -f "$CTX/fisherman" ]; then
	echo "==> Reusing already-staged fisherman (SKIP_FISHERMAN_BUILD=1)"
else
	echo "==> Building fisherman from source at the pinned revision"
	command -v go >/dev/null || { echo "ERROR: go toolchain required to build fisherman" >&2; exit 1; }
	SRC=$(mktemp -d)
	trap 'rm -rf "$SRC"' EXIT
	git clone --quiet "$FISHERMAN_REPO" "$SRC/fisherman"
	git -C "$SRC/fisherman" checkout --quiet "$FISHERMAN_REV"
	# The module lives in a fisherman/ subdirectory of the repo.
	(cd "$SRC/fisherman/fisherman" && CGO_ENABLED=0 go build -trimpath \
		-o "$CTX/fisherman" ./cmd/fisherman)
	chmod 0755 "$CTX/fisherman"
fi
file "$CTX/fisherman" 2>/dev/null || true

# ── Build ───────────────────────────────────────────────────────────────────
echo "==> Building image"
podman build \
	--build-arg "BASE_IMAGE=$BASE_IMAGE" \
	--build-arg "FISHERMAN_REVISION=$FISHERMAN_REV" \
	-t "$TAG" \
	"$CTX"

echo "==> Built $TAG"
echo "    Feed it to make-payload.sh to produce a payload that can actually install."
