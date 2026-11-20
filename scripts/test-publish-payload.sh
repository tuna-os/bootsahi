#!/usr/bin/env bash
# test-publish-payload.sh — hermetic test of publish-payload-r2.sh against a
# local rclone destination (no network, no R2).
#
# Covers: the release layout and checksums, the pointer moving only after the
# release is in place, the previous pointer kept for rollback, a re-publish of
# the same version refused, nothing deleted, and a mismatched installer_data
# package URL refused before any upload.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
PUBLISH="$HERE/scripts/publish-payload-r2.sh"
command -v rclone >/dev/null || { echo "test-publish-payload: rclone is required" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
DEST="$WORK/bucket/asahi"
BASE="https://download.example.test/asahi"
mkdir -p "$WORK/bucket/live-isos"
echo "other prefix" >"$WORK/bucket/live-isos/keep.iso"
fail=0
check() { # description expected actual
	if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; fail=1; fi
}

make_out() { # dir version payload-bytes
	mkdir -p "$1"
	printf '%s' "$3" >"$1/tunaos-bootstrap.zip"
	jq -n --arg pkg "$BASE/releases/$2/tunaos-bootstrap.zip" \
		'{os_list: [{name: "TunaOS", package: $pkg}]}' >"$1/installer_data.json"
	jq -n --arg v "$2" '{bootstrapImage: "ghcr.io/tuna-os/bootsahi-bootstrap@sha256:00", version: $v}' \
		>"$1/tunaos-bootstrap.provenance.json"
}
publish() { VERIFY_PUBLIC=0 "$PUBLISH" "$1" tunaos-bootstrap "$2" "$DEST" "$BASE" >"$WORK/log" 2>&1; }

echo "==> first release"
make_out "$WORK/out1" v1 "payload one"
rc=0; publish "$WORK/out1" v1 || { rc=$?; cat "$WORK/log"; }
check "first release published" 0 "$rc"
for f in tunaos-bootstrap.zip installer_data.json tunaos-bootstrap.provenance.json SHA256SUMS; do
	check "release v1 has $f" yes "$([ -s "$DEST/releases/v1/$f" ] && echo yes || echo no)"
done
check "SHA256SUMS verifies" 0 "$(cd "$DEST/releases/v1" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1; echo $?)"
check "no previous pointer on the first release" no \
	"$([ -e "$DEST/releases/v1/previous-installer_data.json" ] && echo yes || echo no)"
check "pointer names the v1 zip" "$BASE/releases/v1/tunaos-bootstrap.zip" \
	"$(jq -r '.os_list[0].package' "$DEST/installer_data.json")"

echo "==> second release"
make_out "$WORK/out2" v2 "payload two"
rc=0; publish "$WORK/out2" v2 || { rc=$?; cat "$WORK/log"; }
check "second release published" 0 "$rc"
check "pointer names the v2 zip" "$BASE/releases/v2/tunaos-bootstrap.zip" \
	"$(jq -r '.os_list[0].package' "$DEST/installer_data.json")"
check "v2 keeps the pointer it replaced (v1) for rollback" "$BASE/releases/v1/tunaos-bootstrap.zip" \
	"$(jq -r '.os_list[0].package' "$DEST/releases/v2/previous-installer_data.json")"
check "v1 is untouched" "payload one" "$(cat "$DEST/releases/v1/tunaos-bootstrap.zip")"

echo "==> re-publishing an existing version is refused"
make_out "$WORK/out3" v2 "different bytes"
rc=0; publish "$WORK/out3" v2 || rc=$?
check "re-publish of v2 refused" 1 "$rc"
check "v2 zip unchanged" "payload two" "$(cat "$DEST/releases/v2/tunaos-bootstrap.zip")"
check "pointer still v2" "$BASE/releases/v2/tunaos-bootstrap.zip" \
	"$(jq -r '.os_list[0].package' "$DEST/installer_data.json")"

echo "==> installer_data naming another URL is refused before upload"
make_out "$WORK/out4" v3 "payload three"
jq '.os_list[0].package = "https://download.example.test/asahi/tunaos-bootstrap.zip"' \
	"$WORK/out4/installer_data.json" >"$WORK/d" && mv "$WORK/d" "$WORK/out4/installer_data.json"
rc=0; publish "$WORK/out4" v3 || rc=$?
check "mutable package URL refused" 1 "$rc"
check "nothing uploaded for v3" no "$([ -e "$DEST/releases/v3" ] && echo yes || echo no)"

echo "==> a destination outside asahi/ is refused"
rc=0; VERIFY_PUBLIC=0 "$PUBLISH" "$WORK/out4" tunaos-bootstrap v3 "$WORK/bucket" "$BASE" >/dev/null 2>&1 || rc=$?
check "bucket root refused" 1 "$rc"

check "other prefixes untouched" "other prefix" "$(cat "$WORK/bucket/live-isos/keep.iso")"

[ "$fail" -eq 0 ] && echo "PUBLISH SELFTEST PASSED" || { echo "PUBLISH SELFTEST FAILED"; exit 1; }
