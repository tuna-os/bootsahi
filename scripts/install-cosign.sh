#!/usr/bin/env bash
# install-cosign.sh — install, on an arm64 CI runner, the cosign the bootstrap
# image ships.
#
# The version and SHA-256 are read from bootstrap-image/Containerfile, so the
# cosign that signs and verifies in CI is the cosign the agent verifies with on
# the Mac. The checksum there is for cosign-linux-arm64, so this refuses other
# architectures rather than install an unchecked binary.
#
# Usage: ./scripts/install-cosign.sh DEST_DIR
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
DEST="${1:?usage: $0 DEST_DIR}"
CONTAINERFILE="$HERE/bootstrap-image/Containerfile"

version=$(sed -n 's/^ARG COSIGN_VERSION=//p' "$CONTAINERFILE")
sha=$(sed -n 's/^ARG COSIGN_SHA256=//p' "$CONTAINERFILE")
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "install-cosign: no COSIGN_VERSION in $CONTAINERFILE" >&2; exit 1; }
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "install-cosign: no COSIGN_SHA256 in $CONTAINERFILE" >&2; exit 1; }
[ "$(uname -m)" = "aarch64" ] || { echo "install-cosign: the pinned checksum is for arm64; this host is $(uname -m)" >&2; exit 1; }

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL -o "$tmp" "https://github.com/sigstore/cosign/releases/download/${version}/cosign-linux-arm64"
echo "${sha}  ${tmp}" | sha256sum -c - >/dev/null
mkdir -p "$DEST"
install -m 0755 "$tmp" "$DEST/cosign"
"$DEST/cosign" version >/dev/null
echo "install-cosign: installed cosign $version to $DEST/cosign"
