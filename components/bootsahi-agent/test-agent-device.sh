#!/usr/bin/env bash
# test-agent-device.sh — focused unit tests for bootsahi-agent-device.sh.
#
# Tests the block-device resolution and partition-safety library in isolation
# without invoking the orchestrator or requiring root privileges.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LIB="$HERE/bootsahi-agent-device.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok() {
	echo "ok: $1"
}
check() { # description expected actual
	if [ "$2" != "$3" ]; then
		echo "FAIL: $1 (expected '$2', got '$3')"
		fail=1
	else
		echo "ok: $1"
	fi
}

echo "==> sourcing bootsahi-agent-device.sh in isolation"
if [ ! -r "$LIB" ]; then
	echo "FAIL: $LIB is not readable"
	exit 1
fi
# shellcheck source=components/bootsahi-agent/bootsahi-agent-device.sh
source "$LIB"
ok "library sourced successfully"

echo "==> Apple partition GUID discrimination"
for guid in "7C3457EF-0000-11AA-AA11-00306543ECAC" \
            "48465300-0000-11AA-AA11-00306543ECAC" \
            "52637672-0000-11AA-AA11-00306543ECAC" \
            "53746F72-0000-11AA-AA11-00306543ECAC"; do
	if is_apple_partition_type "$guid"; then
		ok "recognized Apple GUID: ${guid:0:8}"
	else
		echo "FAIL: did not recognize Apple GUID: $guid"
		fail=1
	fi
done

if is_apple_partition_type "0FC63DAF-8483-4772-8E79-3D69D8477DE4"; then
	echo "FAIL: Linux FS GUID falsely flagged as Apple"
	fail=1
else
	ok "Linux FS GUID not flagged as Apple"
fi

echo "==> Linux partition GUID discrimination"
if is_linux_partition_type "0FC63DAF-8483-4772-8E79-3D69D8477DE4"; then
	ok "recognized Linux FS GUID"
else
	echo "FAIL: did not recognize Linux FS GUID"
	fail=1
fi

if is_linux_partition_type "7C3457EF-0000-11AA-AA11-00306543ECAC"; then
	echo "FAIL: Apple GUID falsely flagged as Linux"
	fail=1
else
	ok "Apple GUID not flagged as Linux"
fi

echo "==> refuse_active_root: equal root and ESP devices"
cat >"$WORK/equal-devices.json" <<'EOF'
{
  "rootPartition": "/dev/nvme0n1p5",
  "espPartition": "/dev/nvme0n1p5"
}
EOF
set +e
refuse_active_root "$WORK/equal-devices.json" >/dev/null 2>&1
status=$?
set -e
check "equal root and ESP refused" 1 "$status"

echo "==> resolve_role_device: non-block device PARTUUID is refused"
mkdir -p "$WORK/by-partuuid"
TARGET_UUID="11111111-1111-1111-1111-111111111111"
ESP_UUID="22222222-2222-2222-2222-222222222222"
touch "$WORK/target-dev" "$WORK/esp-dev"
ln -sf "$WORK/target-dev" "$WORK/by-partuuid/$TARGET_UUID"
ln -sf "$WORK/esp-dev" "$WORK/by-partuuid/$ESP_UUID"

cat >"$WORK/valid-stub.json" <<EOF
{
  "partitions": [
    {"name": "EFI", "role": "esp", "uuid": "$ESP_UUID"},
    {"name": "Root", "role": "target", "uuid": "$TARGET_UUID"}
  ]
}
EOF

PARTUUID_DIR="$WORK/by-partuuid"
set +e
resolve_role_device "$WORK/valid-stub.json" target >/dev/null 2>&1
status=$?
set -e
check "non-block target device refused" 1 "$status"

echo "==> resolve_role_device: ambiguous roles"
cat >"$WORK/ambiguous-stub.json" <<EOF
{
  "partitions": [
    {"name": "Root1", "role": "target", "uuid": "$TARGET_UUID"},
    {"name": "Root2", "role": "target", "uuid": "$TARGET_UUID"}
  ]
}
EOF
set +e
resolve_role_device "$WORK/ambiguous-stub.json" target >/dev/null 2>&1
status=$?
set -e
check "ambiguous role refused" 1 "$status"

echo "==> resolve_role_device: missing role"
cat >"$WORK/missing-stub.json" <<EOF
{
  "partitions": [
    {"name": "EFI", "role": "esp", "uuid": "$ESP_UUID"}
  ]
}
EOF
set +e
resolve_role_device "$WORK/missing-stub.json" target >/dev/null 2>&1
status=$?
set -e
check "missing role refused" 1 "$status"

echo "==> resolve_install_devices: missing stub and no override"
cat >"$WORK/plain-config.json" <<'EOF'
{
  "rootPartition": "/dev/nvme0n1p5",
  "espPartition": "/dev/nvme0n1p4"
}
EOF
set +e
resolve_install_devices "$WORK/plain-config.json" >/dev/null 2>&1
status=$?
set -e
check "missing stub refused by default" 1 "$status"

echo "==> resolve_install_devices: dev/test override BOOTSAHI_ALLOW_CONFIG_DEVICES=1"
BOOTSAHI_ALLOW_CONFIG_DEVICES=1
res=$(resolve_install_devices "$WORK/plain-config.json")
check "dev override resolves config paths" "/dev/nvme0n1p5 /dev/nvme0n1p4" "$res"
unset BOOTSAHI_ALLOW_CONFIG_DEVICES

echo "==> verify_target: unknown GPT type is refused (#176)"
# Stub the probes so verify_target runs without real block devices. These
# overrides replace the library functions for the rest of this file.
LINUX_GUID="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
ESP_GUID="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
block_device_id() { echo "8:$1"; }
active_root_device_id() { echo "8:root"; }
device_is_mounted() { return 1; }
parent_disk_of() { echo ""; }
gpt_type_of() {
	case "$1" in
		target) echo "$STUB_TARGET_TYPE" ;;
		esp) echo "$STUB_ESP_TYPE" ;;
	esac
}

STUB_TARGET_TYPE="$LINUX_GUID" STUB_ESP_TYPE="$ESP_GUID"
set +e
verify_target target esp >/dev/null 2>&1
status=$?
set -e
check "known Linux target and ESP types accepted" 0 "$status"

STUB_TARGET_TYPE="" STUB_ESP_TYPE="$ESP_GUID"
set +e
verify_target target esp >/dev/null 2>&1
status=$?
set -e
check "empty target GPT type refused" 1 "$status"

STUB_TARGET_TYPE="$LINUX_GUID" STUB_ESP_TYPE=""
set +e
verify_target target esp >/dev/null 2>&1
status=$?
set -e
check "empty ESP GPT type refused" 1 "$status"

if [ "$fail" -ne 0 ]; then
	echo "DEVICE UNIT TESTS FAILED"
	exit 1
fi
echo "DEVICE UNIT TESTS PASSED"
