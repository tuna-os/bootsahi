#!/usr/bin/env bash
# test-agent-disk.sh — prove the agent picks the RIGHT partition, against a real
# GPT disk with real PARTUUIDs.
#
# test-agent.sh covers the config->recipe transform with /dev/null placeholders.
# It cannot cover the question that actually destroys machines: given a disk
# carrying both the bootstrap the agent is running from AND the target it may
# format, does the agent choose correctly, and does it refuse when it cannot
# prove ownership? (issues #19, #22)
#
# So this builds a loopback GPT disk shaped like a real install — ESP +
# Bootstrap + Target — reads back the PARTUUIDs the kernel actually assigned,
# and drives the agent through them. fisherman is still a stub here: this
# asserts SELECTION, not formatting. Running the real fisherman against this
# disk is issue #26.
#
# Needs root (losetup). Usage: sudo ./test-agent-disk.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/bootsahi-agent.sh"

if [ "$(id -u)" -ne 0 ]; then
	echo "SKIP: needs root for losetup (run: sudo $0)"
	exit 0
fi
for t in sgdisk blkid losetup jq; do
	command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; exit 0; }
done

WORK=$(mktemp -d)
LOOP=""
cleanup() {
	[ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

fail=0
check() { # description expected actual
	if [ "$2" != "$3" ]; then
		echo "FAIL: $1"
		echo "      expected: $2"
		echo "      actual:   $3"
		fail=1
	else
		echo "ok: $1"
	fi
}

# check_exit takes the rundir so it can dump the agent's own output on a
# mismatch. Deliberately explicit rather than a global set inside run_agent:
# run_agent is called via $(...) — a subshell — so anything it assigns is lost
# in the parent, and the diagnostics would silently never appear.
check_exit() { # description expected rundir
	local actual
	actual="$(cat "$3/exit" 2>/dev/null || echo "?")"
	check "$1" "$2" "$actual"
	if [ "$2" != "$actual" ]; then
		echo "      ---- agent stdout ----"
		sed 's/^/      | /' "$3/stdout" 2>/dev/null || echo "      | (none captured)"
		echo "      ----------------------"
	fi
	return 0
}

# ── Build a disk shaped like a real install ─────────────────────────────────
echo "==> Building a GPT loop disk (ESP + Bootstrap + Target)"
truncate -s 96M "$WORK/disk.img"
sgdisk --clear \
	--new=1:0:+16M --typecode=1:EF00 --change-name=1:"EFI - selftest" \
	--new=2:0:+24M --typecode=2:8300 --change-name=2:"Bootstrap - selftest" \
	--new=3:0:0    --typecode=3:8300 --change-name=3:"Root - selftest" \
	"$WORK/disk.img" >/dev/null
LOOP=$(losetup --find --show -P "$WORK/disk.img")
udevadm settle 2>/dev/null || sleep 1

ESP_DEV="${LOOP}p1"
BOOTSTRAP_DEV="${LOOP}p2"
TARGET_DEV="${LOOP}p3"
for d in "$ESP_DEV" "$BOOTSTRAP_DEV" "$TARGET_DEV"; do
	[ -b "$d" ] || { echo "FAIL: $d did not appear; loop partition scanning unavailable"; exit 1; }
done

partuuid() { blkid -s PARTUUID -o value "$1"; }
ESP_UUID=$(partuuid "$ESP_DEV")
BOOTSTRAP_UUID=$(partuuid "$BOOTSTRAP_DEV")
TARGET_UUID=$(partuuid "$TARGET_DEV")
echo "    esp=$ESP_DEV($ESP_UUID) bootstrap=$BOOTSTRAP_DEV($BOOTSTRAP_UUID) target=$TARGET_DEV($TARGET_UUID)"

# The agent resolves through a by-partuuid directory. Point it at our own so
# this test never depends on, or interferes with, the host's real one.
PU="$WORK/by-partuuid"
mkdir -p "$PU"
ln -sf "$ESP_DEV" "$PU/$ESP_UUID"
ln -sf "$BOOTSTRAP_DEV" "$PU/$BOOTSTRAP_UUID"
ln -sf "$TARGET_DEV" "$PU/$TARGET_UUID"

write_stub_info() { # path role-for-target-uuid...
	cat >"$1"
}

cat >"$WORK/install-config.json" <<'EOF'
{
  "targetImgref": "ghcr.io/tuna-os/bonito:gnome-asahi",
  "rootPartition": "/dev/null",
  "espPartition": "/dev/zero",
  "filesystem": "xfs",
  "hostname": "disk-selftest",
  "encryption": {"type": "none"}
}
EOF

# The stub records exactly what the backend would after partitioning.
# Shaped like the REAL producer, not like a minimal fixture of our own design.
# asahi-installer records name/role/type/uuid/macos_device/size per partition
# (see its stub_info["partitions"] block); a fixture carrying only the fields we
# happen to read cannot catch us reading the wrong one.
#
# macos_device is deliberately MISLEADING here: every entry claims to be the
# bootstrap's macOS device name. Under Linux those names mean nothing — macOS
# calls it disk0s5, Linux calls it nvme0n1p5 — so an agent that ever resolved
# by this field would format the partition it is running from. Getting the
# right answer with these values present is the assertion.
cat >"$WORK/stub_info.json" <<EOF
{"vgid": "selftest",
 "partitions": [
  {"name": "EFI", "role": "esp", "type": "EFI", "uuid": "$ESP_UUID",
   "macos_device": "disk0s2", "size": 16777216},
  {"name": "Bootstrap", "role": "bootstrap", "type": "Linux", "uuid": "$BOOTSTRAP_UUID",
   "macos_device": "disk0s2", "size": 25165824},
  {"name": "Root", "role": "target", "type": "Linux", "uuid": "$TARGET_UUID",
   "macos_device": "disk0s2", "size": 55574528}
 ]}
EOF

RECORDER="$WORK/fisherman-record"
printf '#!/bin/sh\ncp "$1" "%s/recipe-captured.json"\nexit 0\n' "$WORK" >"$RECORDER"
chmod +x "$RECORDER"

run_agent() { # stub_info_path [extra_env...]
	local stub="$1" rundir
	rundir=$(mktemp -d -p "$WORK")
	# Per-run COPY of the config, never the shared fixture: the agent deletes
	# install-config.json on success (it can carry a LUKS passphrase, and the
	# ESP is world-readable). Passing the fixture directly lets the first
	# succeeding test destroy the input every later test needs — which is
	# exactly what happened here, and it presented as "exit 2" refusals that
	# looked like a resolution bug.
	cp "$WORK/install-config.json" "$rundir/install-config.json"
	set +e
	env BOOTSAHI_RUN_DIR="$rundir" BOOTSAHI_NO_REBOOT=1 \
		BOOTSAHI_CONFIG_PATH="$rundir/install-config.json" \
		BOOTSAHI_STUB_INFO_PATH="$stub" \
		BOOTSAHI_PARTUUID_DIR="$PU" \
		BOOTSAHI_SKIP_HW_CHECK=1 \
		BOOTSAHI_ALLOW_UNVERIFIED=1 \
		BOOTSAHI_FISHERMAN_BIN="$RECORDER" "${@:2}" \
		bash "$AGENT" >"$rundir/stdout" 2>&1
	echo $? >"$rundir/exit"
	set -e
	echo "$rundir"
}

# ── 1. The core question: does it choose the target, not the bootstrap? ─────
echo
echo "==> resolves the TARGET partition, not the bootstrap it is running from"
rm -f "$WORK/recipe-captured.json"
r=$(run_agent "$WORK/stub_info.json")
check_exit "exit code" 0 "$r"
if [ -f "$WORK/recipe-captured.json" ]; then
	got_root=$(jq -r '.customMounts[] | select(.target == "/") | .partition' "$WORK/recipe-captured.json")
	got_esp=$(jq -r '.customMounts[] | select(.target == "/boot/efi") | .partition' "$WORK/recipe-captured.json")
	check "root mount is the TARGET partition" "$TARGET_DEV" "$got_root"
	check "ESP mount is the ESP partition" "$ESP_DEV" "$got_esp"
	# The single most important negative: the bootstrap must never be handed
	# to a formatter. Asserted explicitly rather than implied by the above.
	if [ "$got_root" = "$BOOTSTRAP_DEV" ] || [ "$got_esp" = "$BOOTSTRAP_DEV" ]; then
		echo "FAIL: the bootstrap partition was handed to fisherman"
		fail=1
	else
		echo "ok: bootstrap partition never appears in the recipe"
	fi
	check "config's bogus rootPartition was ignored in favour of the PARTUUID" \
		"" "$(jq -r '.customMounts[] | select(.partition == "/dev/null") | .partition' "$WORK/recipe-captured.json")"
else
	echo "FAIL: no recipe was produced"
	sed 's/^/  | /' "$r/stdout"
	fail=1
fi

# ── 1b. The real consumer's own validator (issue #26) ───────────────────────
# Every assertion above is OUR opinion of what fisherman accepts. That is
# exactly how the `vfat` bug survived: the recipe looked right to us and was
# never shown to fisherman, which rejects "vfat" (it knows "fat32") only once
# it reaches formatPartition — mid-install, after partitioning.
#
# So run fisherman's own `validate` against the recipe the agent actually
# produced. Non-destructive: validate parses and checks, it does not mutate.
echo
echo "==> the REAL fisherman validates the generated recipe"
FISHERMAN_VALIDATE_BIN="${FISHERMAN_VALIDATE_BIN:-$(command -v fisherman 2>/dev/null || true)}"
if [ -z "$FISHERMAN_VALIDATE_BIN" ] || [ ! -x "$FISHERMAN_VALIDATE_BIN" ]; then
	echo "  SKIP no fisherman binary available."
	echo "       This is the assertion that would have caught the vfat bug, so its"
	echo "       absence is worth noticing rather than passing over silently."
	echo "       Set FISHERMAN_VALIDATE_BIN=/path/to/fisherman to enable."
elif [ ! -f "$WORK/recipe-captured.json" ]; then
	echo "FAIL: no recipe was captured to validate"
	fail=1
else
	# A validator built from another revision than the image ships proves
	# nothing about the image. The selftest.yml build step and
	# bootstrap-image/fisherman.rev are separate edits, so check, don't trust.
	if "$HERE/../../scripts/fisherman-rev.sh" --check "$FISHERMAN_VALIDATE_BIN"; then
		echo "ok: the validating fisherman is the revision the bootstrap image ships"
	else
		echo "FAIL: the validating fisherman is not the revision in bootstrap-image/fisherman.rev"
		fail=1
	fi

	if out=$("$FISHERMAN_VALIDATE_BIN" validate "$WORK/recipe-captured.json" 2>&1); then
		echo "ok: fisherman validate accepted the generated recipe"
		echo "    ($("$FISHERMAN_VALIDATE_BIN" version 2>/dev/null | head -1))"
	else
		echo "FAIL: fisherman REJECTED the recipe this agent generates"
		echo "$out" | sed 's/^/      | /'
		fail=1
	fi

	# And prove the validator is actually discriminating, not rubber-stamping:
	# feed it the exact defect that shipped. If this passes, the check above
	# proves nothing.
	sed 's/"fstype": "unformatted"/"fstype": "vfat"/' "$WORK/recipe-captured.json" \
		>"$WORK/recipe-vfat.json"
	if "$FISHERMAN_VALIDATE_BIN" validate "$WORK/recipe-vfat.json" >/dev/null 2>&1; then
		echo "  note: this fisherman ACCEPTS fstype=vfat at validate time — it will"
		echo "        fail later in formatPartition instead. Fixed by"
		echo "        projectbluefin/fisherman#12; until that lands, our own"
		echo "        fstype assertions in test-agent.sh are the only gate."
	else
		echo "ok: fisherman rejects the vfat defect at validate time (#12 is in)"
	fi
fi

# ── 2. Refusals ─────────────────────────────────────────────────────────────
echo
echo "==> refuses when the recorded target is the ACTIVE root"
active_src=$(awk '$5 == "/" { print $3; exit }' /proc/self/mountinfo 2>/dev/null || true)
active_dev=""
for d in /dev/* /dev/mapper/*; do
	[ -b "$d" ] || continue
	hex=$(stat -Lc '%t:%T' "$d" 2>/dev/null) || continue
	[ "$(printf '%d:%d' "0x${hex%%:*}" "0x${hex##*:}" 2>/dev/null)" = "$active_src" ] || continue
	active_dev="$d"; break
done
if [ -n "$active_dev" ]; then
	ln -sf "$active_dev" "$PU/deadbeef-active"
	jq --arg u deadbeef-active '(.partitions[] | select(.role=="target") | .uuid) = $u' \
		"$WORK/stub_info.json" >"$WORK/stub-active.json"
	rm -f "$WORK/recipe-captured.json"
	r=$(run_agent "$WORK/stub-active.json")
	check_exit "exit code (target == active root)" 1 "$r"
	check "no recipe generated" "" "$(ls "$WORK/recipe-captured.json" 2>/dev/null || true)"
else
	echo "  skip: / is not backed by a discoverable block device here"
fi

echo
echo "==> refuses when the recorded target is currently MOUNTED"
mkfs.ext4 -q -F "$TARGET_DEV" 2>/dev/null
mkdir -p "$WORK/mnt"
if mount "$TARGET_DEV" "$WORK/mnt" 2>/dev/null; then
	rm -f "$WORK/recipe-captured.json"
	r=$(run_agent "$WORK/stub_info.json")
	check_exit "exit code (target mounted)" 1 "$r"
	check "no recipe generated for a mounted target" "" "$(ls "$WORK/recipe-captured.json" 2>/dev/null || true)"
	grep -q 'currently mounted' "$r/install.log" ||
		{ echo "FAIL: refusal did not say the target was mounted"; fail=1; }
	umount "$WORK/mnt"
else
	echo "  skip: could not mount the target to test the mounted-refusal"
fi

echo
echo "==> refuses an AMBIGUOUS role (two partitions claiming 'target')"
jq '.partitions += [{"name":"Root2","role":"target","type":"Linux","uuid":"'"$BOOTSTRAP_UUID"'"}]' \
	"$WORK/stub_info.json" >"$WORK/stub-ambiguous.json"
rm -f "$WORK/recipe-captured.json"
r=$(run_agent "$WORK/stub-ambiguous.json")
check_exit "exit code (two 'target' roles)" 1 "$r"
check "no recipe generated for an ambiguous role" "" "$(ls "$WORK/recipe-captured.json" 2>/dev/null || true)"

echo
echo "==> refuses a PARTUUID that resolves to nothing"
jq '(.partitions[] | select(.role=="target") | .uuid) = "00000000-dead-dead-dead-000000000000"' \
	"$WORK/stub_info.json" >"$WORK/stub-missing.json"
rm -f "$WORK/recipe-captured.json"
r=$(run_agent "$WORK/stub-missing.json")
check_exit "exit code (unresolvable PARTUUID)" 1 "$r"
check "no recipe generated for an unresolvable PARTUUID" "" "$(ls "$WORK/recipe-captured.json" 2>/dev/null || true)"

echo
echo "==> refuses a SWAPPED UUID (target PARTUUID pointing to the bootstrap)"
# The target's recorded PARTUUID is the bootstrap's actual UUID — so the
# resolved device is the bootstrap partition. verify_target refuses it
# because it IS mounted (the bootstrap is running from it).
jq --arg u "$BOOTSTRAP_UUID" '(.partitions[] | select(.role=="target") | .uuid) = $u' \
	"$WORK/stub_info.json" >"$WORK/stub-swapped.json"
rm -f "$WORK/recipe-captured.json"
r=$(run_agent "$WORK/stub-swapped.json")
check_exit "exit code (swapped UUID -> bootstrap as target)" 1 "$r"
check "no recipe generated for a swapped UUID" "" "$(ls "$WORK/recipe-captured.json" 2>/dev/null || true)"

echo
echo "==> refuses an Apple APFS partition type on the target"
# Change the target's GPT type to APFS (7C3457EF-...). The PARTUUID still
# points to a valid block device, but the type says this is not a Linux
# filesystem — tampered stub_info, or the backend recorded the wrong partition.
sgdisk --typecode=3:7C3457EF-0000-11AA-AA11-00306543ECAC "$WORK/disk.img" >/dev/null
udevadm settle 2>/dev/null || sleep 1
rm -f "$WORK/recipe-captured.json"
r=$(run_agent "$WORK/stub_info.json")
check_exit "exit code (Apple APFS type on target)" 1 "$r"
check "no recipe generated for an Apple GPT type" "" "$(ls "$WORK/recipe-captured.json" 2>/dev/null || true)"
# Restore the correct type so later tests (if any are added) are not affected.
sgdisk --typecode=3:8300 "$WORK/disk.img" >/dev/null
udevadm settle 2>/dev/null || sleep 1

echo
echo "==> refuses a non-Linux, non-ESP GPT type on the target"
# Change the target to "Microsoft basic data" — plausible on a dual-boot
# machine but not an install target the backend created.
sgdisk --typecode=3:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 "$WORK/disk.img" >/dev/null
udevadm settle 2>/dev/null || sleep 1
rm -f "$WORK/recipe-captured.json"
r=$(run_agent "$WORK/stub_info.json")
check_exit "exit code (non-Linux GPT type on target)" 1 "$r"
# Restore.
sgdisk --typecode=3:8300 "$WORK/disk.img" >/dev/null
udevadm settle 2>/dev/null || sleep 1

echo
echo "==> refuses when stub_info.json has no partition with the target role"
jq 'del(.partitions[] | select(.role == "target"))' \
	"$WORK/stub_info.json" >"$WORK/stub-no-target.json"
rm -f "$WORK/recipe-captured.json"
r=$(run_agent "$WORK/stub-no-target.json")
check_exit "exit code (no partition with role 'target')" 1 "$r"
check "no recipe generated when role is absent" "" "$(ls "$WORK/recipe-captured.json" 2>/dev/null || true)"

echo
echo "==> refuses when the target role has no PARTUUID at all"
jq '(.partitions[] | select(.role=="target") | .uuid) = null' \
	"$WORK/stub_info.json" >"$WORK/stub-null-uuid.json"
rm -f "$WORK/recipe-captured.json"
r=$(run_agent "$WORK/stub-null-uuid.json")
check_exit "exit code (null PARTUUID)" 1 "$r"

echo
if [ "$fail" -ne 0 ]; then
	echo "DISK SELFTEST FAILED"
	exit 1
fi
echo "DISK SELFTEST PASSED"
