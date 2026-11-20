#!/usr/bin/env bash
# publish-payload-r2.sh — publish a tested payload as an immutable release and
# then move the installer_data.json pointer to it (#99, #132).
#
# Layout under DEST (the asahi/ prefix; nothing outside it is touched):
#
#   releases/<version>/<name>.zip                 immutable payload
#   releases/<version>/installer_data.json        names the versioned zip URL
#   releases/<version>/<name>.provenance.json     bootstrap digest, source SHA, run
#   releases/<version>/SHA256SUMS                 of the three files above
#   releases/<version>/previous-installer_data.json   pointer it replaced, if any
#   installer_data.json                           the pointer clients fetch
#
# Order, so a client never sees a half-published release:
#   1. refuse if releases/<version>/ already holds anything (never overwrite);
#   2. upload the release with --immutable and verify it with rclone check;
#   3. optionally verify the public URLs serve exactly those bytes;
#   4. only then copy the release's installer_data.json over the pointer, and
#      verify the pointer.
# Nothing is deleted. Rolling back is copying an older
# releases/<version>/installer_data.json over the pointer
# (runbooks/r2-payload-rollback.md).
#
# Usage:
#   publish-payload-r2.sh OUT_DIR NAME VERSION DEST PUBLIC_BASE
#     OUT_DIR      directory with <name>.zip, installer_data.json, <name>.provenance.json
#     DEST         rclone path of the asahi/ prefix, e.g. R2:bucket/asahi
#     PUBLIC_BASE  public URL of DEST, e.g. https://download.tunaos.org/asahi
# Env:
#   VERIFY_PUBLIC=0  skip the HTTP checks (local tests have no public URL)
#   RCLONE           rclone binary (default: rclone)
set -euo pipefail

OUT="${1:?usage: $0 OUT_DIR NAME VERSION DEST PUBLIC_BASE}"
NAME="${2:?usage: $0 OUT_DIR NAME VERSION DEST PUBLIC_BASE}"
VERSION="${3:?usage: $0 OUT_DIR NAME VERSION DEST PUBLIC_BASE}"
DEST="${4:?usage: $0 OUT_DIR NAME VERSION DEST PUBLIC_BASE}"
PUBLIC_BASE="${5:?usage: $0 OUT_DIR NAME VERSION DEST PUBLIC_BASE}"
RCLONE="${RCLONE:-rclone}"
VERIFY_PUBLIC="${VERIFY_PUBLIC:-1}"

die() { echo "publish: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || die "version '$VERSION' is not a plain name"
[[ "$NAME" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || die "name '$NAME' is not a plain name"
case "$DEST" in */asahi) ;; *) die "DEST must be the asahi/ prefix (got $DEST)" ;; esac

RELEASE="$DEST/releases/$VERSION"
RELEASE_URL="$PUBLIC_BASE/releases/$VERSION"
ZIP="$OUT/$NAME.zip"
DATA="$OUT/installer_data.json"
PROV="$OUT/$NAME.provenance.json"
for f in "$ZIP" "$DATA" "$PROV"; do [ -s "$f" ] || die "missing $f"; done

# The release's installer_data.json must point at the release's own zip, or the
# pointer would hand clients a mutable or foreign URL.
want="$RELEASE_URL/$NAME.zip"
got=$(jq -r '.os_list[0].package // empty' "$DATA")
[ "$got" = "$want" ] || die "installer_data.json package is '$got', expected '$want'"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "$ZIP" "$DATA" "$PROV" "$STAGE/"
(cd "$STAGE" && sha256sum "$NAME.zip" installer_data.json "$NAME.provenance.json" >SHA256SUMS)

# 1. Never overwrite a release.
if [ -n "$("$RCLONE" lsf "$RELEASE/" 2>/dev/null || true)" ]; then
	die "$RELEASE already exists; releases are immutable"
fi

# Keep the pointer this release replaces next to it, so the rollback target
# is recorded where the release is.
if "$RCLONE" cat "$DEST/installer_data.json" >"$STAGE/previous-installer_data.json" 2>/dev/null &&
	[ -s "$STAGE/previous-installer_data.json" ]; then
	echo "publish: current pointer saved as previous-installer_data.json"
else
	rm -f "$STAGE/previous-installer_data.json"
	echo "publish: no current pointer (first release)"
fi

# 2. Upload and verify the release.
echo "publish: uploading release $VERSION to $RELEASE"
"$RCLONE" copy --immutable --checksum --s3-no-check-bucket \
	--header-upload "Cache-Control: public, max-age=31536000, immutable" \
	"$STAGE/" "$RELEASE/"
"$RCLONE" check --one-way "$STAGE/" "$RELEASE/" || die "uploaded release does not match the tested files"
echo "publish: release objects verified"

# 3. The public URLs must serve those bytes before anything points at them.
if [ "$VERIFY_PUBLIC" = "1" ]; then
	size=$(stat -c %s "$ZIP")
	head=$(curl -fsSI "$RELEASE_URL/$NAME.zip") || die "HEAD $RELEASE_URL/$NAME.zip failed"
	served=$(tr -d '\r' <<<"$head" | awk 'tolower($1)=="content-length:"{print $2}' | tail -1)
	[ "$served" = "$size" ] || die "$RELEASE_URL/$NAME.zip serves $served bytes, expected $size"
	curl -fsS "$RELEASE_URL/installer_data.json" | cmp -s - "$DATA" ||
		die "$RELEASE_URL/installer_data.json does not match the tested file"
	echo "publish: public release URLs verified ($size-byte zip)"
fi

# 4. Promote: move the pointer, then verify it.
echo "publish: pointing $DEST/installer_data.json at release $VERSION"
"$RCLONE" copyto --checksum --s3-no-check-bucket \
	--header-upload "Cache-Control: no-cache" \
	"$STAGE/installer_data.json" "$DEST/installer_data.json"
"$RCLONE" cat "$DEST/installer_data.json" | cmp -s - "$DATA" || die "pointer does not match the release"
if [ "$VERIFY_PUBLIC" = "1" ]; then
	curl -fsS -H "Cache-Control: no-cache" "$PUBLIC_BASE/installer_data.json" | cmp -s - "$DATA" ||
		die "$PUBLIC_BASE/installer_data.json does not serve the new pointer"
fi
echo "publish: released $VERSION — $PUBLIC_BASE/installer_data.json -> $want"
