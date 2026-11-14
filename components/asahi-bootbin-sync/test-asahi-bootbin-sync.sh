#!/usr/bin/env bash
# test-asahi-bootbin-sync.sh — hermetic tests for asahi-bootbin-sync.sh.
#
# The script hardcodes host paths (/proc/device-tree, /boot/efi, /usr/lib/...)
# and only does anything on Apple Silicon, so it cannot run as-is in CI. This
# test copies it, rewrites every absolute host path to live under a throwaway
# fixture root, and stubs `update-m1n1` and `sync` on PATH. The production
# script is never modified. No root, no Apple hardware.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/asahi-bootbin-sync.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # description expected actual
	if [ "$2" != "$3" ]; then
		echo "FAIL: $1 (expected '$2', got '$3')"
		fail=1
	else
		echo "ok: $1"
	fi
}

# Known defect (#195): the kernel-discovery loop aborts the script under
# `set -e`/pipefail when the last-sorted module dir has no dtb/apple. These
# checks are expected to fail until that fix lands; once it does they pass,
# xcheck reports it, and the xcheck calls should become plain check calls.
xcheck() { # description expected actual
	if [ "$2" != "$3" ]; then
		echo "xfail: $1 (known defect #195; expected '$2', got '$3')"
	else
		echo "FAIL: $1 unexpectedly passes — #195 is fixed, switch xcheck to check"
		fail=1
	fi
}

ROOT="$WORK/root"
BIN="$WORK/bin"
CALLS="$WORK/calls"
mkdir -p "$BIN"

# Rewrite host paths (a path token starting with /proc, /boot, /efi or /usr)
# into the fixture root.
SYNC="$WORK/asahi-bootbin-sync.sh"
sed -E "s#(^|[ \"=(])/(proc/|boot|efi|usr/)#\1$ROOT/\2#g" "$SCRIPT" >"$SYNC"
chmod +x "$SYNC"

# Guard against drift: if the script grows a new absolute host path the sed
# above does not reach, fail loudly instead of touching the real host.
leftover=$(grep -vE '^[[:space:]]*#' "$SYNC" | grep -E "(^|[ \"=(])/(proc/|boot|efi|usr/)" || true)
check "no unrewritten host paths in script copy" "" "$leftover"

# update-m1n1 stub: UPDATE_M1N1_MODE=ok writes a fresh boot.bin; =fail corrupts
# it and exits non-zero (a partially written boot.bin is the case the restore
# path exists for).
cat >"$BIN/update-m1n1" <<'EOF'
#!/usr/bin/env bash
echo "update-m1n1 $*" >>"$CALLS"
if [ "${UPDATE_M1N1_MODE:-ok}" = ok ]; then
	echo "NEW-BOOT-BIN" >"$1/boot.bin"
else
	echo "CORRUPT-PARTIAL" >"$1/boot.bin"
	exit 3
fi
EOF
cat >"$BIN/sync" <<'EOF'
#!/usr/bin/env bash
echo "sync $*" >>"$CALLS"
EOF
chmod +x "$BIN/update-m1n1" "$BIN/sync"
export CALLS

reset_fixture() { # build a fully populated Apple Silicon host
	rm -rf "$ROOT"
	: >"$CALLS"
	mkdir -p "$ROOT/proc/device-tree" "$ROOT/boot/efi/m1n1" \
		"$ROOT/usr/lib64/m1n1" "$ROOT/usr/lib/asahi-boot" \
		"$ROOT/usr/lib/modules/6.9.0-asahi/dtb/apple" \
		"$ROOT/usr/lib/modules/6.10.0-asahi/dtb/apple" \
		"$ROOT/usr/lib/modules/6.11.0-generic"
	printf 'apple,j274\0apple,t8103\0' >"$ROOT/proc/device-tree/compatible"
	echo m1n1-payload >"$ROOT/usr/lib64/m1n1/m1n1.bin"
	echo uboot-payload >"$ROOT/usr/lib/asahi-boot/u-boot-nodtb.bin"
	echo dtb-old >"$ROOT/usr/lib/modules/6.9.0-asahi/dtb/apple/t8103.dtb"
	echo dtb-new >"$ROOT/usr/lib/modules/6.10.0-asahi/dtb/apple/t8103.dtb"
	echo ORIGINAL-BOOT-BIN >"$ROOT/boot/efi/m1n1/boot.bin"
}

expected_stamp() { # sha256 over m1n1 + u-boot + the NEWEST asahi kernel's dtbs
	cat "$ROOT/usr/lib64/m1n1/m1n1.bin" "$ROOT/usr/lib/asahi-boot/u-boot-nodtb.bin" \
		"$ROOT/usr/lib/modules/6.10.0-asahi/dtb/apple/"*.dtb | sha256sum | cut -d' ' -f1
}

OUT="$WORK/out"
run() { # sets RC; combined output in $OUT
	RC=0
	PATH="$BIN:$PATH" "$SYNC" >"$OUT" 2>&1 || RC=$?
}
ncalls() { grep -c "^$1" "$CALLS" || true; }

echo "==> no-op: not Apple hardware"
reset_fixture
printf 'fsl,imx8mq\0' >"$ROOT/proc/device-tree/compatible"
run
check "exit 0" 0 "$RC"
check "update-m1n1 not called" 0 "$(ncalls update-m1n1)"
check "no stamp written" "no" "$([ -e "$ROOT/boot/efi/m1n1/.bootbin.sha256" ] && echo yes || echo no)"

echo "==> no-op: no device-tree at all (x86 host)"
reset_fixture
rm -f "$ROOT/proc/device-tree/compatible"
run
check "exit 0" 0 "$RC"
check "update-m1n1 not called" 0 "$(ncalls update-m1n1)"

echo "==> no-op: no ESP with m1n1/"
reset_fixture
rm -rf "$ROOT/boot/efi/m1n1"
run
check "exit 0" 0 "$RC"
check "update-m1n1 not called" 0 "$(ncalls update-m1n1)"
check "reports skip" "yes" "$(grep -q 'no ESP with m1n1/ found' "$OUT" && echo yes || echo no)"

echo "==> no-op: no Asahi kernel (no dtb/apple in any module dir)"
reset_fixture
rm -rf "$ROOT/usr/lib/modules/6.9.0-asahi" "$ROOT/usr/lib/modules/6.10.0-asahi"
run
xcheck "exit 0" 0 "$RC"
check "update-m1n1 not called" 0 "$(ncalls update-m1n1)"
xcheck "reports skip" "yes" "$(grep -q 'no Asahi kernel found' "$OUT" && echo yes || echo no)"

echo "==> Asahi kernel present but a later-sorting non-Asahi module dir exists"
reset_fixture
mkdir -p "$ROOT/usr/lib/modules/7.0.0-generic"
run
xcheck "exit 0" 0 "$RC"
xcheck "update-m1n1 called" 1 "$(ncalls update-m1n1)"

echo "==> no-op: m1n1 payload missing"
reset_fixture
rm -f "$ROOT/usr/lib64/m1n1/m1n1.bin"
run
check "exit 0" 0 "$RC"
check "update-m1n1 not called" 0 "$(ncalls update-m1n1)"
check "reports skip" "yes" "$(grep -q 'payloads not in image' "$OUT" && echo yes || echo no)"

echo "==> no-op: u-boot payload missing"
reset_fixture
rm -f "$ROOT/usr/lib/asahi-boot/u-boot-nodtb.bin"
run
check "exit 0" 0 "$RC"
check "update-m1n1 not called" 0 "$(ncalls update-m1n1)"

echo "==> first run (no stamp): regenerates, backs up, stamps, syncs"
reset_fixture
run
check "exit 0" 0 "$RC"
check "update-m1n1 called once on <ESP>/m1n1" "update-m1n1 $ROOT/boot/efi/m1n1" "$(grep '^update-m1n1' "$CALLS")"
check "boot.bin regenerated" "NEW-BOOT-BIN" "$(cat "$ROOT/boot/efi/m1n1/boot.bin")"
check "backup holds previous boot.bin" "ORIGINAL-BOOT-BIN" "$(cat "$ROOT/boot/efi/m1n1/boot.bin.bak")"
check "stamp is sha256 of m1n1+u-boot+newest kernel dtbs" "$(expected_stamp)" "$(cat "$ROOT/boot/efi/m1n1/.bootbin.sha256")"
check "sync -f on the ESP" "sync -f $ROOT/boot/efi" "$(grep '^sync' "$CALLS")"

echo "==> second run (stamp matches): no-op"
: >"$CALLS"
run
check "exit 0" 0 "$RC"
check "update-m1n1 not called" 0 "$(ncalls update-m1n1)"
check "sync not called" 0 "$(ncalls sync)"
check "boot.bin untouched" "NEW-BOOT-BIN" "$(cat "$ROOT/boot/efi/m1n1/boot.bin")"

echo "==> older kernel's dtbs do not affect the stamp"
echo dtb-old-changed >"$ROOT/usr/lib/modules/6.9.0-asahi/dtb/apple/t8103.dtb"
run
check "exit 0" 0 "$RC"
check "update-m1n1 not called" 0 "$(ncalls update-m1n1)"

echo "==> newest kernel picked by version sort (6.10 > 6.9), dtb change re-triggers"
echo dtb-new-changed >"$ROOT/usr/lib/modules/6.10.0-asahi/dtb/apple/t8103.dtb"
run
check "exit 0" 0 "$RC"
check "update-m1n1 called once" 1 "$(ncalls update-m1n1)"
check "stamp updated" "$(expected_stamp)" "$(cat "$ROOT/boot/efi/m1n1/.bootbin.sha256")"
check "backup is the previous regenerated boot.bin" "NEW-BOOT-BIN" "$(cat "$ROOT/boot/efi/m1n1/boot.bin.bak")"

echo "==> m1n1 payload change re-triggers"
echo m1n1-payload-v2 >"$ROOT/usr/lib64/m1n1/m1n1.bin"
: >"$CALLS"
run
check "update-m1n1 called once" 1 "$(ncalls update-m1n1)"
check "stamp updated" "$(expected_stamp)" "$(cat "$ROOT/boot/efi/m1n1/.bootbin.sha256")"

echo "==> update-m1n1 fails: backup restored, exit 1, stamp not advanced"
reset_fixture
old_stamp=$(expected_stamp)
echo "stale-stamp" >"$ROOT/boot/efi/m1n1/.bootbin.sha256"
UPDATE_M1N1_MODE=fail run
check "exit 1" 1 "$RC"
check "update-m1n1 was attempted" 1 "$(ncalls update-m1n1)"
check "boot.bin restored from backup" "ORIGINAL-BOOT-BIN" "$(cat "$ROOT/boot/efi/m1n1/boot.bin")"
check "stamp left stale so the next run retries" "stale-stamp" "$(cat "$ROOT/boot/efi/m1n1/.bootbin.sha256")"
check "stamp is not the new one" "no" "$([ "$(cat "$ROOT/boot/efi/m1n1/.bootbin.sha256")" = "$old_stamp" ] && echo yes || echo no)"
check "sync not called on failure" 0 "$(ncalls sync)"
check "reports failure on stderr" "yes" "$(grep -q 'update-m1n1 FAILED' "$OUT" && echo yes || echo no)"

echo "==> update-m1n1 fails with no prior boot.bin: exit 1, no backup invented"
reset_fixture
rm -f "$ROOT/boot/efi/m1n1/boot.bin"
UPDATE_M1N1_MODE=fail run
check "exit 1" 1 "$RC"
check "no backup created" "no" "$([ -e "$ROOT/boot/efi/m1n1/boot.bin.bak" ] && echo yes || echo no)"

echo "==> ESP discovery order: /boot/efi wins over /boot"
reset_fixture
mkdir -p "$ROOT/boot/m1n1"
run
check "exit 0" 0 "$RC"
check "update-m1n1 targets /boot/efi/m1n1" "update-m1n1 $ROOT/boot/efi/m1n1" "$(grep '^update-m1n1' "$CALLS")"

echo "==> ESP discovery falls back to /boot"
reset_fixture
mv "$ROOT/boot/efi/m1n1" "$ROOT/boot/m1n1"
run
check "exit 0" 0 "$RC"
check "update-m1n1 targets /boot/m1n1" "update-m1n1 $ROOT/boot/m1n1" "$(grep '^update-m1n1' "$CALLS")"

echo "==> alternate m1n1 payload location (/usr/lib/m1n1)"
reset_fixture
mkdir -p "$ROOT/usr/lib/m1n1"
mv "$ROOT/usr/lib64/m1n1/m1n1.bin" "$ROOT/usr/lib/m1n1/m1n1.bin"
run
check "exit 0" 0 "$RC"
check "update-m1n1 called" 1 "$(ncalls update-m1n1)"

echo
if [ "$fail" -ne 0 ]; then
	echo "FAILED"
	exit 1
fi
echo "all asahi-bootbin-sync tests passed"
