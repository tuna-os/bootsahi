#!/usr/bin/env bash
# fisherman-rev.sh — the one fisherman revision this repository ships and tests.
#
# The bootstrap image and the disk and real-install selftests must use the same
# fisherman. A selftest that validates a different binary than the image
# contains proves nothing about the image.
#
# Usage:
#   ./scripts/fisherman-rev.sh              print the pinned revision
#   ./scripts/fisherman-rev.sh --check BIN  exit 0 if BIN was built from it
#
# --check reads the vcs.revision that `go build` stamps into a binary built
# from a git checkout (the text `go version -m` prints). It reads the stamp
# with grep, not go, because the selftests run under sudo, where the runner's
# go is not on PATH. It exits 1 on a mismatch or a modified checkout, and 2
# when it cannot tell (no stamp, or conflicting stamps). Callers treat any
# non-zero exit as a failure.
#
# Env:
#   FISHERMAN_REV_FILE  pin file (default: bootstrap-image/fisherman.rev)
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
REV_FILE="${FISHERMAN_REV_FILE:-$HERE/bootstrap-image/fisherman.rev}"

pinned_rev() {
	local rev
	rev=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$REV_FILE" | head -n 1 | tr -d '[:space:]') || true
	if ! [[ "$rev" =~ ^[0-9a-f]{40}$ ]]; then
		echo "fisherman-rev: $REV_FILE does not hold a 40-character commit SHA" >&2
		return 2
	fi
	printf '%s\n' "$rev"
}

case "${1:-}" in
"")
	pinned_rev
	;;
--check)
	bin="${2:?usage: $0 --check BIN}"
	want=$(pinned_rev)
	[ -r "$bin" ] || { echo "fisherman-rev: cannot read $bin" >&2; exit 2; }
	got=$(grep -a -o -E 'vcs\.revision=[0-9a-f]{40}' "$bin" | sort -u | cut -d= -f2) || true
	modified=$(grep -a -o -E 'vcs\.modified=(true|false)' "$bin" | sort -u | cut -d= -f2) || true
	if [ -z "$got" ]; then
		echo "fisherman-rev: $bin has no vcs.revision stamp (not built by go from a git checkout)" >&2
		exit 2
	fi
	if [ "$(wc -l <<<"$got")" -ne 1 ] || [ "$(wc -l <<<"${modified:-x}")" -ne 1 ]; then
		echo "fisherman-rev: $bin carries conflicting vcs stamps: ${got//$'\n'/ } ${modified//$'\n'/ }" >&2
		exit 2
	fi
	if [ "$got" != "$want" ] || [ "$modified" = "true" ]; then
		echo "fisherman-rev: $bin was built from $got (modified=${modified:-unknown})," >&2
		echo "               but $REV_FILE pins $want" >&2
		exit 1
	fi
	echo "fisherman-rev: $bin is the pinned $want"
	;;
*)
	echo "usage: $0 [--check BIN]" >&2
	exit 2
	;;
esac
