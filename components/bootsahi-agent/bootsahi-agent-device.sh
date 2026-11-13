#!/usr/bin/env bash
# bootsahi-agent-device.sh — block-device discovery, partition inspection,
# and destructive-target safety checks.
#
# This file is sourced by bootsahi-agent.sh or imported independently by
# test harnesses. It provides block-device resolution and target safety guards
# behind an explicit interface, decoupled from first-boot lifecycle management.

# ── Target resolution by PARTUUID (issue #22) ────────────────────────────────
# The macOS app cannot name the target: it knows the partition as disk0s5 while
# this agent sees nvme0n1p5. And a partition ORDINAL must never be trusted —
# since ADR 0001 there are two Linux partitions, and picking the wrong one means
# mkfs on the filesystem this agent is running from.
#
# So the backend records each partition it created (PARTUUID + declared role)
# into <ESP>/asahi/stub_info.json, and we resolve from that. PARTUUID is stable
# across macOS/Linux and immune to renumbering.
PARTUUID_DIR="${BOOTSAHI_PARTUUID_DIR:-/dev/disk/by-partuuid}"

# Provide a fallback logger if not sourced within bootsahi-agent.sh
if ! declare -F log >/dev/null 2>&1; then
    log() {
        printf '%s: %s\n' "${AGENT_NAME:-bootsahi-device}" "$*" >&2
    }
fi

# block_device_id echoes a device's "major:minor" in decimal, or nothing.
# Comparing major:minor rather than paths is deliberate: /dev/nvme0n1p5,
# /dev/disk/by-partuuid/<uuid>, and a symlink chain all name the same device,
# and a path comparison would call them different.
block_device_id() {
    local dev="$1" hex
    hex=$(stat -Lc '%t:%T' "$dev" 2>/dev/null) || return 0
    [ -n "$hex" ] && [ "$hex" != ":" ] || return 0
    printf '%d:%d\n' "0x${hex%%:*}" "0x${hex##*:}" 2>/dev/null || true
}

# active_root_device_id echoes major:minor of whatever backs "/", from
# /proc/self/mountinfo — a plain file read, no findmnt/util-linux dependency,
# and mountinfo reports major:minor directly (field 3).
active_root_device_id() {
    awk '$5 == "/" { print $3; exit }' /proc/self/mountinfo 2>/dev/null || true
}

# refuse_active_root is the guard that makes the current half-finished state
# safe to have in tree. Since ADR 0001 the disk carries TWO Linux partitions —
# the bootstrap this agent is running from, and the target it installs into —
# so a stale or guessed rootPartition now names a plausible-looking Linux
# partition either way. Handing fisherman the bootstrap's own partition means
# mkfs on the filesystem containing PID 1 (issue #19).
#
# Until the runtime PARTUUID resolution in #22 lands, positively refusing the
# one catastrophic value is what stands between "documented as wrong" and
# "destroys the running system".
refuse_active_root() {
    local cfg="$1" root esp root_id esp_id active_id
    root=$(jq -r '.rootPartition // empty' "$cfg")
    esp=$(jq -r '.espPartition // empty' "$cfg")

    if [ -n "$root" ] && [ "$root" = "$esp" ]; then
        log "rootPartition and espPartition are the same device ($root); refusing"
        return 1
    fi

    active_id=$(active_root_device_id)
    if [ -z "$active_id" ]; then
        # Cannot read mountinfo: not a running Linux system (the test harness on
        # macOS, for instance). Nothing destructive can be verified here, and
        # check_apple_hardware has already gated real hardware.
        log "cannot determine the device backing /; skipping active-root check"
        return 0
    fi

    root_id=$(block_device_id "$root")
    if [ -n "$root_id" ] && [ "$root_id" = "$active_id" ]; then
        log "rootPartition ($root) is the device backing / — fisherman would mkfs the"
        log "filesystem this agent is running from. Refusing (see issue #19 / ADR 0001)."
        return 1
    fi
    esp_id=$(block_device_id "$esp")
    if [ -n "$esp_id" ] && [ "$esp_id" = "$active_id" ]; then
        log "espPartition ($esp) is the device backing /; refusing"
        return 1
    fi
    return 0
}

# find_stub_info echoes the backend's stub_info.json, or nothing. It lives
# beside install-config.json because both arrive through the same
# copy_installer_data channel into <ESP>/asahi/. Always exits 0 — absence is a
# valid dev/test state, and the caller runs under `set -e`.
find_stub_info() {
    local cfg="$1" candidate
    if [ -n "${BOOTSAHI_STUB_INFO_PATH:-}" ]; then
        [ -f "$BOOTSAHI_STUB_INFO_PATH" ] && printf '%s\n' "$BOOTSAHI_STUB_INFO_PATH"
        return 0
    fi
    candidate="$(dirname "$cfg")/stub_info.json"
    [ -f "$candidate" ] && printf '%s\n' "$candidate"
    return 0
}

# parent_disk_of echoes the parent block device name for a partition device,
# via sysfs (/sys/class/block/<part> is a symlink into its parent disk), or
# nothing. Used to prove the target lives on the same disk as our ESP.
parent_disk_of() {
    local dev base parent
    base=$(basename "$(readlink -f "$1" 2>/dev/null)" 2>/dev/null) || return 0
    [ -n "$base" ] || return 0
    parent=$(readlink -f "/sys/class/block/$base" 2>/dev/null) || return 0
    dev=$(basename "$(dirname "$parent")" 2>/dev/null) || return 0
    # A whole disk's sysfs parent is "block", not another device.
    [ "$dev" != "block" ] && printf '%s\n' "$dev"
    return 0
}

# device_is_mounted reports whether a device is mounted anywhere right now.
# Formatting a mounted filesystem is how you destroy a running system, so this
# is a refusal, not a warning.
device_is_mounted() {
    local id
    id=$(block_device_id "$1")
    [ -n "$id" ] || return 1
    awk -v want="$id" '$3 == want { found = 1 } END { exit !found }' \
        /proc/self/mountinfo 2>/dev/null
}

# resolve_role_device maps a declared role ("target"/"esp"/"bootstrap") to a
# block device via its recorded PARTUUID. Refuses on zero or multiple matches
# rather than picking one — an ambiguous identity is not an identity.
resolve_role_device() {
    local stub="$1" role="$2" uuid n dev
    n=$(jq -r --arg r "$role" '[.partitions[]? | select(.role == $r)] | length' "$stub" 2>/dev/null)
    case "$n" in
    1) : ;;
    ""|0) log "stub_info.json records no partition with role '$role'"; return 1 ;;
    *) log "stub_info.json records $n partitions with role '$role'; ambiguous, refusing"; return 1 ;;
    esac
    uuid=$(jq -r --arg r "$role" '.partitions[] | select(.role == $r) | .uuid' "$stub")
    if [ -z "$uuid" ] || [ "$uuid" = "null" ]; then
        log "partition with role '$role' has no recorded PARTUUID"
        return 1
    fi
    dev=$(readlink -f "$PARTUUID_DIR/$uuid" 2>/dev/null || true)
    if [ -z "$dev" ] || [ ! -b "$dev" ]; then
        log "PARTUUID $uuid (role '$role') does not resolve to a block device under $PARTUUID_DIR"
        return 1
    fi
    printf '%s\n' "$dev"
    return 0
}

# gpt_type_of echoes the GPT partition type GUID of a partition, or nothing.
gpt_type_of() {
    # -p forces a low-level probe, bypassing blkid's cache: the selftest
    # rewrites the GPT table with sgdisk between runs, and a cached
    # PART_ENTRY_TYPE would report the OLD type and let a foreign partition
    # through. Fall back to udev's view (lsblk) if the probe is blocked.
    local t
    t=$(blkid -p -s PART_ENTRY_TYPE -o value "$1" 2>/dev/null || true)
    if [ -z "$t" ]; then
        t=$(lsblk -rno PARTTYPE "$1" 2>/dev/null | head -1 || true)
    fi
    # Normalise to upper case: blkid -p reports GUIDs in lower case, and the
    # is_*_partition_type comparisons are upper-case. A case mismatch here
    # would refuse every valid Linux target (or accept every foreign one).
    printf '%s\n' "${t^^}"
}

# device_is_removable reports whether a block device is flagged as removable
# (USB stick, SD card, etc.). Formatting the install target on removable media
# during an automated agent run is not a safe default.
device_is_removable() {
    local syspath
    syspath="/sys/class/block/$(basename "$(readlink -f "$1" 2>/dev/null)" 2>/dev/null)/removable" 2>/dev/null
    [ -f "$syspath" ] && [ "$(cat "$syspath" 2>/dev/null)" = "1" ]
}

# Apple partition type GUIDs — any of these on the target is a refusal.
# 7C3457EF: APFS
# 48465300: HFS+
# 52637672: Apple Recovery (APFS)
# 53746F72: Apple Boot
is_apple_partition_type() {
    local t="$1"
    case "$t" in
        7C3457EF-*) return 0 ;;
        48465300-*) return 0 ;;
        52637672-*) return 0 ;;
        53746F72-*) return 0 ;;
    esac
    return 1
}

# Linux filesystem partition type GUID (0FC63DAF-8483-4772-8E79-3D69D8477DE4).
is_linux_partition_type() {
    local t="$1"
    [ "$t" = "0FC63DAF-8483-4772-8E79-3D69D8477DE4" ]
}

# verify_target verifies a resolved target is safe to hand to a formatter, and
# prints the evidence. #22's requirement: never format anything whose identity
# and ownership have not been positively established.
verify_target() {
    local target="$1" esp="$2" active_id target_id tparent eparent sectors
    local tguid eguid removable
    target_id=$(block_device_id "$target")
    active_id=$(active_root_device_id)

    if [ -n "$active_id" ] && [ "$target_id" = "$active_id" ]; then
        log "resolved target $target is the device backing /; refusing"
        return 1
    fi
    if device_is_mounted "$target"; then
        log "resolved target $target is currently mounted; refusing to format it"
        return 1
    fi

    # GPT partition type: the target must be a Linux filesystem partition.
    # An Apple/APFS/recovery partition handed as 'target' means the recorded
    # PARTUUID is not from this install — the backend creates Linux partitions.
    # An empty type (probe failed, or not a GPT partition) is not proof of a
    # Linux target, so it is a refusal too (#176).
    tguid=$(gpt_type_of "$target")
    if [ -z "$tguid" ]; then
        log "could not determine GPT type for resolved target $target; refusing to format"
        return 1
    fi
    if is_apple_partition_type "$tguid"; then
        log "resolved target $target has Apple GPT type $tguid; refusing (not an install target)"
        return 1
    fi
    if ! is_linux_partition_type "$tguid"; then
        log "resolved target $target has GPT type $tguid, not the expected Linux filesystem type; refusing"
        return 1
    fi
    # ESP must be an EFI System Partition. An empty type is a refusal.
    eguid=$(gpt_type_of "$esp")
    if [ -z "$eguid" ]; then
        log "could not determine GPT type for resolved ESP $esp; refusing to use it"
        return 1
    fi
    if [ "$eguid" != "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" ]; then
        log "resolved ESP $esp has GPT type $eguid, not the expected ESP type; refusing"
        return 1
    fi

    tparent=$(parent_disk_of "$target")
    eparent=$(parent_disk_of "$esp")
    if [ -n "$tparent" ] && [ -n "$eparent" ] && [ "$tparent" != "$eparent" ]; then
        log "resolved target $target is on disk '$tparent' but our ESP is on '$eparent'; refusing"
        log "(a target on a different disk means the recorded identities are not from this install)"
        return 1
    fi

    # Refuse removable parent disks. An install to a USB stick during an
    # automated agent run is almost certainly a misconfiguration, and the
    # safety argument for it is unverified.
    if [ -n "$tparent" ]; then
        removable=$(cat "/sys/class/block/$tparent/removable" 2>/dev/null || echo "0")
        if [ "$removable" = "1" ]; then
            log "resolved target $target is on removable disk '$tparent'; refusing"
            return 1
        fi
    fi

    sectors=$(cat "/sys/class/block/$(basename "$target")/size" 2>/dev/null || echo "?")
    log "preflight: target=$target parent=${tparent:-?} dev=$target_id type=${tguid:-?} sectors=$sectors mounted=no removable=${removable:-0}"
    log "preflight: esp=$esp parent=${eparent:-?} dev=$(block_device_id "$esp") type=${eguid:-?}"
    return 0
}

# resolve_install_devices identifies and verifies the block devices to operate
# on: (target_device, esp_device).
#
# Preference order is deliberate:
#   1. stub_info.json's recorded PARTUUIDs — the only trustworthy source,
#      written by the backend that created the partitions.
#   2. install-config.json's rootPartition/espPartition — dev/test override
#      only, and already screened by refuse_active_root above.
# There is no third option: if neither yields a device we abort rather than
# guess, because the failure mode of guessing is an unrecoverable machine.
#
# Emits "<target_dev> <esp_dev>" to stdout on success and returns 0.
# Logs failure diagnostics and returns 1 on refusal. Callers parse stdout, so
# every diagnostic in this call chain MUST go through log/stderr, never stdout.
resolve_install_devices() {
    local cfg="$1"
    local stub target_dev esp_dev bootstrap_dev

    if ! refuse_active_root "$cfg"; then
        return 1
    fi

    stub=$(find_stub_info "$cfg")
    if [ -n "$stub" ]; then
        log "resolving install target from $stub (recorded PARTUUIDs)"
        target_dev=$(resolve_role_device "$stub" target) || return 1
        esp_dev=$(resolve_role_device "$stub" esp) || return 1

        # The resolved target must not be the bootstrap partition itself. A
        # swapped PARTUUID (target role claiming the bootstrap's UUID) would
        # otherwise pass the type/mount checks whenever the bootstrap is not
        # mounted (read-only media, selftest loop devices); refusing on device
        # identity makes the swap impossible to miss (#22).
        if jq -e '.partitions[]? | select(.role == "bootstrap")' "$stub" >/dev/null 2>&1; then
            bootstrap_dev=$(resolve_role_device "$stub" bootstrap) || bootstrap_dev=""
            if [ -n "$bootstrap_dev" ] && [ "$(block_device_id "$target_dev")" = "$(block_device_id "$bootstrap_dev")" ]; then
                log "resolved target $target_dev is the bootstrap partition itself; refusing (swapped PARTUUID)"
                return 1
            fi
        fi

        if ! verify_target "$target_dev" "$esp_dev"; then
            return 1
        fi
        printf '%s %s\n' "$target_dev" "$esp_dev"
        return 0
    elif [ "${BOOTSAHI_ALLOW_CONFIG_DEVICES:-0}" = "1" ]; then
        # Explicitly-enabled dev/test path only. It is gated behind an env var
        # rather than merely warned about because the safety argument for it is
        # UNVERIFIED: refuse_active_root screens the device backing /, which
        # covers the bootstrap partition only if the bootstrap boots directly
        # from it. Under an initramfs pivot or a composefs deployment, / may
        # report something other than the bootstrap partition device — and then
        # nothing stops fisherman being handed the bootstrap.
        #
        # We cannot test that today: no bootstrap image exists yet (issue #27),
        # so no one has ever observed what / reports on a real bootsahi boot.
        # An unverifiable assumption guarding an unrecoverable operation is not
        # a safety property, so production must not be able to reach this path
        # by accident — only by someone typing the variable.
        target_dev=$(jq -r '.rootPartition // empty' "$cfg")
        esp_dev=$(jq -r '.espPartition // empty' "$cfg")
        if [ -z "$target_dev" ] || [ -z "$esp_dev" ]; then
            log "BOOTSAHI_ALLOW_CONFIG_DEVICES=1 but the config has no rootPartition/espPartition"
            return 1
        fi
        log "WARNING: BOOTSAHI_ALLOW_CONFIG_DEVICES=1 — using the config's device paths"
        log "WARNING: dev/test only. Production installs resolve by PARTUUID (issue #22)."
        printf '%s %s\n' "$target_dev" "$esp_dev"
        return 0
    else
        log "no stub_info.json found at the expected location, so the install target cannot be"
        log "identified by PARTUUID. Refusing rather than trusting the config's device paths:"
        log "the app cannot know Linux device names, and this disk carries two Linux partitions."
        log "(dev/test override: BOOTSAHI_ALLOW_CONFIG_DEVICES=1 — see issue #22)"
        return 1
    fi
}
