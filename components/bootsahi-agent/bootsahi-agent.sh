#!/usr/bin/env bash
# bootsahi-agent — D1 first-boot agent for the "bootsahi" bootstrap image.
#
# Reads install-config.json (written by the Bootsahi macOS app onto the ESP)
# and drives `bootc install to-filesystem` via fisherman — NOT
# `bootc install to-disk`, which is debug/QEMU-only (see D0's make-payload.sh /
# test-payload.sh). By the time this agent runs, the asahi-installer backend
# has already partitioned the disk (stub macOS, ESP, root partition); fisherman
# is handed those pre-made partitions through recipe.json's customMounts, not
# its own disk auto-partition path.
#
# Exit codes are deliberate, not incidental — the bootstrap's greetd session
# branches on them to decide whether to show progress or fall back to the
# interactive fisherman-driven UI (tuna-installer-*, see INSTALLER-FRONTENDS.md):
#   0 = installed successfully (system reboots into the target OS)
#   2 = no install-config.json found; fall through to interactive UI (not an error)
#   1 = install-config.json present but the install failed; log preserved for the UI
set -euo pipefail

AGENT_NAME="bootsahi-agent"
RUN_DIR="${BOOTSAHI_RUN_DIR:-/run/bootsahi}"
LOG_FILE="$RUN_DIR/install.log"
RECIPE_FILE="$RUN_DIR/recipe.json"
FISHERMAN_BIN="${BOOTSAHI_FISHERMAN_BIN:-fisherman}"
AGENT_LIB_DIR="${BOOTSAHI_AGENT_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# First-boot policy is a separate boundary from lifecycle and destructive
# install orchestration. Its functions use the globals initialized above.
# shellcheck source=components/bootsahi-agent/bootsahi-agent-policy.sh
source "$AGENT_LIB_DIR/bootsahi-agent-policy.sh"

# Recipe translation is a separate contract boundary: install-config.json is
# owned by the macOS app, while recipe.json is consumed by fisherman. Keep that
# adapter independently sourceable/testable instead of embedding it in the
# destructive first-boot orchestrator.
# shellcheck source=components/bootsahi-agent/bootsahi-agent-recipe.sh
source "$AGENT_LIB_DIR/bootsahi-agent-recipe.sh"

# Block-device discovery and destructive target safety checks are extracted
# into an independently testable library behind an explicit resolution interface.
# shellcheck source=components/bootsahi-agent/bootsahi-agent-device.sh
source "$AGENT_LIB_DIR/bootsahi-agent-device.sh"

# Write to both the log file and stderr WITHOUT a pipeline. The obvious
# `echo ... | tee -a "$LOG_FILE" >&2` puts a pipe on the hot path of every
# log line, and under `set -o pipefail` any tee hiccup kills the whole agent
# — including between "fisherman succeeded" and the credential cleanup
# below, which would leave recipe.json (LUKS passphrase, user password) on
# disk. No pipeline, no pipefail exposure.
log() {
	printf '%s: %s\n' "$AGENT_NAME" "$*" >>"$LOG_FILE" 2>/dev/null || true
	printf '%s: %s\n' "$AGENT_NAME" "$*" >&2
}

find_install_config() {
    # ${BOOTSAHI_CONFIG_PATH} is the test/dev override; production always reads
    # from the ESP, mirroring asahi-bootbin-sync's own ESP-detection candidates.
    #
    # Always returns 0 — "not found" is signalled by empty stdout, not a
    # nonzero exit, because the caller runs under `set -e` and "no config yet"
    # is an expected first-boot state, not a script error.
    if [ -n "${BOOTSAHI_CONFIG_PATH:-}" ]; then
        [ -f "$BOOTSAHI_CONFIG_PATH" ] && echo "$BOOTSAHI_CONFIG_PATH"
        return 0
    fi
    # <ESP>/asahi/ is checked first and is the intended production location:
    # asahi-installer already creates that directory and copies files into it
    # via copy_installer_data/collect_installer_data, AFTER partitioning — so
    # delivering install-config.json needs no new mechanism, just an entry in
    # the backend's copy_idata list. See docs/UNIFIED-INSTALL-CONTRACT.md.
    # <ESP>/bootsahi/ stays supported for hand-placed files and dev/test.
    for c in /boot/efi /efi /boot; do
        for d in asahi bootsahi; do
            if [ -f "$c/$d/install-config.json" ]; then
                echo "$c/$d/install-config.json"
                return 0
            fi
        done
    done
    return 0
}

main() {
    # 0700 so the recipe (LUKS passphrase, Wi-Fi PSK) and log are not readable by
    # other local users under a permissive umask; umask 077 covers files created
    # by redirection below, which does not honour any mode argument (issue #21).
    umask 077
    # umask 077 above already makes mkdir create this 0700; the explicit chmod
    # covers the case where RUN_DIR already exists from an earlier boot/run.
    # (No -m on mkdir: with -p it applies only to the deepest directory, which
    # is a subtle enough footgun that shellcheck flags it — SC2174.)
    mkdir -p "$RUN_DIR"
    if ! chmod 0700 "$RUN_DIR" 2>/dev/null; then
        # Only warn — RUN_DIR on tmpfs (tmpfs defaults to 1777 with sticky bit)
        # may be owned by another user on a misconfigured system, and aborting
        # here would prevent a known-working install path from proceeding.
        # The umask 077 above still protects any files we create inside it.
        log "WARNING: could not chmod RUN_DIR ($RUN_DIR); files we create under it are still umask-protected"
    fi
    : >"$LOG_FILE"
    chmod 0600 "$LOG_FILE" 2>/dev/null || true

    # Remove the derived recipe on EVERY exit path, not just the success path.
    # Previously a fisherman failure exited before the cleanup below, leaving a
    # file containing the LUKS passphrase and Wi-Fi PSK on disk while the
    # fallback UI kept running indefinitely (issue #21).
    #
    # The log file is NOT removed here: it is needed for diagnostics after a
    # failure, and it is already protected by the 0600 mode and 0700 RUN_DIR.
    # The recipe is the dangerous artifact — it carries the LUKS passphrase and
    # password — and it is derived, so there is no retry argument for keeping it.
    trap 'shred -u "$RECIPE_FILE" 2>/dev/null || rm -f "$RECIPE_FILE" 2>/dev/null || true' EXIT

    check_apple_hardware

    local cfg
    cfg=$(find_install_config)
    if [ -z "$cfg" ]; then
        log "no install-config.json found; nothing to do (interactive UI takes over)"
        exit 2
    fi
    log "found install-config.json at $cfg"

    if ! jq empty "$cfg" 2>>"$LOG_FILE"; then
        log "install-config.json is not valid JSON"
        exit 1
    fi

    if ! validate_install_config_schema "$cfg"; then
        exit 1
    fi

    local imgref
    imgref=$(jq -r '.targetImgref // empty' "$cfg")
    for field in targetImgref filesystem hostname; do
        if [ -z "$(jq -r ".$field // empty" "$cfg")" ]; then
            log "install-config.json missing required field: $field"
            exit 1
        fi
    done
    # rootPartition and espPartition are NOT required when stub_info.json is
    # present — the agent resolves by PARTUUID (issue #22). They are only
    # checked in the BOOTSAHI_ALLOW_CONFIG_DEVICES path below.

    if ! reject_stored_secrets "$cfg"; then
        exit 1
    fi

    if ! reject_plaintext_password "$cfg"; then
        exit 1
    fi

    # Before any network use or disk mutation: refuse configs we cannot honour,
    # and refuse the one that would destroy the running system.
    if ! reject_unsupported_encryption "$cfg"; then
        exit 1
    fi
    # Resolve and verify the devices to operate on via the extracted device subsystem.
    local resolved_devices TARGET_DEV ESP_DEV
    if ! resolved_devices=$(resolve_install_devices "$cfg"); then
        exit 1
    fi
    read -r TARGET_DEV ESP_DEV <<< "$resolved_devices"

    connect_wifi "$cfg"

    # DEPLOY_REF is what verification actually blessed — normally
    # <repo>:<tag>@sha256:<digest>. Everything downstream installs THAT, so the
    # bytes deployed are the bytes verified even if the tag moves in between.
    local deploy_ref
    if ! deploy_ref=$(verify_signature "$cfg" "$imgref"); then
        log "signature verification failed for $imgref; aborting install"
        exit 1
    fi
    if [ -z "$deploy_ref" ]; then
        log "internal error: verification succeeded but produced no reference to deploy; refusing"
        exit 1
    fi

    build_recipe "$cfg" "$TARGET_DEV" "$ESP_DEV" "$deploy_ref"
    log "running fisherman against $deploy_ref"
    if ! "$FISHERMAN_BIN" "$RECIPE_FILE" >>"$LOG_FILE" 2>&1; then
        log "fisherman install failed; see $LOG_FILE"
        exit 1
    fi

    log "install complete"
    # Zero out the recipe (it carries the LUKS passphrase / user password in
    # the clear) before reboot; RUN_DIR is tmpfs so this is belt-and-braces.
    # shred(1) is GNU coreutils and absent on macOS/BSD — the `|| rm -f`
    # fallback covers that, and the trailing `|| true` guarantees a failure
    # here can never abort the agent before the file is gone. Removal is
    # what actually matters; overwriting is the bonus when shred exists.
    shred -u "$RECIPE_FILE" 2>/dev/null || rm -f "$RECIPE_FILE" || true

    # Same reasoning, one layer up and worse: install-config.json can carry a
    # LUKS passphrase and a Wi-Fi PSK, and unlike RUN_DIR the ESP is NOT tmpfs.
    # It's vfat — no permission bits, world-readable by anything that can read
    # the filesystem — and it stays mounted on the installed system forever.
    # Leaving it there would publish the disk-encryption passphrase to every
    # local user on the machine we just encrypted.
    #
    # Only after a successful install: on failure the interactive fisherman UI
    # wants it. shred is best-effort here and largely theatre on vfat over
    # wear-levelled flash — removal is the part that matters.
    log "removing install-config.json (carries LUKS passphrase / Wi-Fi PSK; the ESP is world-readable and persists)"
    shred -u "$cfg" 2>/dev/null || rm -f "$cfg" || true

    if [ "${BOOTSAHI_NO_REBOOT:-0}" != "1" ]; then
        log "rebooting into the installed system"
        systemctl reboot
    fi
}

main "$@"
