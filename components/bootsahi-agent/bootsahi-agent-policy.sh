#!/usr/bin/env bash
# bootsahi-agent policy boundary.
#
# Sourced by bootsahi-agent.sh. Functions here validate install intent and
# enforce first-boot safety policy; lifecycle setup and fisherman orchestration
# remain in the entrypoint.

# The entrypoint initializes `AGENT_LIB_DIR`, `LOG_FILE`, and `RUN_DIR`, and
# defines `log()` before invoking these functions. `ASK_PASSWORD_BIN` is owned
# by this library so its prompt dependency stays within the policy boundary.

# find_install_config_schema locates install-config.schema.json.
# Production installs it to /usr/share/bootsahi/install-config.schema.json;
# dev/test checks BOOTSAHI_SCHEMA_PATH or AGENT_LIB_DIR.
find_install_config_schema() {
    if [ -n "${BOOTSAHI_SCHEMA_PATH:-}" ] && [ -f "${BOOTSAHI_SCHEMA_PATH}" ]; then
        echo "${BOOTSAHI_SCHEMA_PATH}"
        return 0
    fi
    if [ -f "/usr/share/bootsahi/install-config.schema.json" ]; then
        echo "/usr/share/bootsahi/install-config.schema.json"
        return 0
    fi
    if [ -f "$AGENT_LIB_DIR/install-config.schema.json" ]; then
        echo "$AGENT_LIB_DIR/install-config.schema.json"
        return 0
    fi
    return 0
}

# validate_install_config_schema evaluates install-config.json against the
# shipped JSON Schema before any network, secret, or device operations run (issue #121).
# Every rule comes from the schema itself — the draft-07 subset it uses: type,
# enum, required, properties, additionalProperties:false and array items — so
# the schema and the agent cannot drift apart. A null value is treated as an
# absent key (the app omits unset optionals). Required strings must also be
# non-empty. When BOOTSAHI_ALLOW_UNVERIFIED=1 is set, cosignIdentity and
# cosignIssuer are excused from the required checks.
#
# Fails closed: a missing schema or a jq failure is a refusal, not a pass. The
# schema ships in the bootstrap image, so its absence is a packaging defect.
validate_install_config_schema() {
    local cfg="$1"
    local schema_file
    schema_file=$(find_install_config_schema)

    if [ -z "$schema_file" ]; then
        log "install-config.schema.json not found; refusing to install from an unvalidated config"
        return 1
    fi

    local allow_unverified=false
    if [ "${BOOTSAHI_ALLOW_UNVERIFIED:-0}" = "1" ]; then
        allow_unverified=true
    fi

    local errors
    if ! errors=$(jq -r --slurpfile schema "$schema_file" --argjson allow_unverified "$allow_unverified" '
        def type_ok($t):
          if $t == "integer" then type == "number" and . == floor
          else type == $t end;
        def present: with_entries(select(.value != null));
        def validate($s; $where; $excused):
          if ($s.type != null) and (type_ok($s.type) | not) then
            "\($where) must be of type \($s.type)"
          elif ($s.enum != null) and (. as $v | $s.enum | index([$v]) | not) then
            "\($where) must be one of \($s.enum | join(", ")) (got \(tostring))"
          elif type == "object" then
            present as $obj |
            ((($s.required // []) - $excused) as $req |
              (($req - ($obj | keys)) as $missing |
                if ($missing | length) > 0 then
                  "\($where) missing required field: \($missing | join(", "))"
                else empty end),
              ($req[] as $k | select($obj[$k] == "") |
                "\($where).\($k) must be a non-empty string")),
            (if $s.additionalProperties == false then
              (($obj | keys) - ($s.properties // {} | keys)) as $extra |
              if ($extra | length) > 0 then
                "\($where) contains unexpected field: \($extra | join(", "))"
              else empty end
            else empty end),
            ($obj | to_entries[] | . as $e | ($s.properties // {})[$e.key] as $ps |
              select($ps != null) | $e.value | validate($ps; "\($where).\($e.key)"; []))
          elif type == "array" and $s.items != null then
            to_entries[] | . as $e | $e.value | validate($s.items; "\($where)[\($e.key)]"; [])
          else empty end;
        validate($schema[0]; "install-config.json";
          if $allow_unverified then ["cosignIdentity", "cosignIssuer"] else [] end)
    ' "$cfg" 2>>"$LOG_FILE"); then
        log "install-config.json could not be validated against $schema_file (jq failed); refusing"
        return 1
    fi

    if [ -n "$errors" ]; then
        while IFS= read -r err; do
            [ -n "$err" ] && log "$err"
        done <<< "$errors"
        return 1
    fi
    return 0
}


# prompt_secret asks the user for a secret at first boot and prints it on stdout.
#
# This unit is Type=oneshot and runs Before=greetd, so it has no controlling
# terminal — systemd-ask-password is the mechanism designed for exactly this:
# it hands the prompt to whatever password agent is present (console, plymouth)
# and never echoes. Overridable for tests, mirroring BOOTSAHI_FISHERMAN_BIN,
# because CI has no agent to answer the prompt.
ASK_PASSWORD_BIN="${BOOTSAHI_ASK_PASSWORD_BIN:-systemd-ask-password}"

prompt_secret() { # prompt-text
    if ! command -v "$ASK_PASSWORD_BIN" >/dev/null 2>&1; then
        log "no password agent available ($ASK_PASSWORD_BIN not found); cannot ask for a secret"
        return 1
    fi
    "$ASK_PASSWORD_BIN" --timeout=300 "$1"
}

# connect_wifi joins the network named in the config, asking for the password
# HERE rather than reading one from the ESP (issue #21).
#
# The config carries the SSID only. The passphrase is never written to disk by
# the macOS app, because install-config.json lives on an unencrypted,
# world-readable FAT partition that survives a failed install — and encrypting
# it there would not help: any key the agent could use unattended would have to
# sit on the same disk an attacker already has. Asking once, at first boot, is
# the only version of this with a real boundary.
connect_wifi() {
    local cfg="$1"
    local ssid psk
    ssid=$(jq -r '.wifi.ssid // empty' "$cfg")
    [ -n "$ssid" ] || return 0
    log "connecting to Wi-Fi network '$ssid'"

    if ! psk=$(prompt_secret "Wi-Fi password for $ssid"); then
        log "could not obtain the Wi-Fi password; continuing (ethernet may still work)"
        return 0
    fi

    if [ -z "$psk" ]; then
        # An open network, or the user declined. Try without credentials.
        nmcli device wifi connect "$ssid" ||
            log "Wi-Fi connect failed; continuing (ethernet may still work)"
        return 0
    fi

    # Fed over stdin, never as an argument: `nmcli ... password <psk>` puts the
    # passphrase in argv, where any local user can read it out of ps for the
    # lifetime of the call.
    if ! printf '%s\n' "$psk" | nmcli --ask device wifi connect "$ssid" >>"$LOG_FILE" 2>&1; then
        log "Wi-Fi connect failed; continuing (ethernet may still work)"
    fi
    unset psk
}

# verify_signature FAILS CLOSED and prints the digest-pinned reference that the
# install must actually deploy. Callers use that output, never the tag.
#
# It used to `return 0` whenever cosignIdentity was absent, which meant the
# DEFAULT path installed an unverified, mutable tag while DESIGN.md claimed
# "verifies cosign signatures before deploying" (issue #24). A policy you can
# omit is not a policy; anyone able to edit install-config.json on the ESP — a
# world-readable FAT partition — could select arbitrary content and the UI
# would still say the image was verified.
#
# Two separate guarantees here, and the second is the one usually missed:
#
#  1. Fail closed. Missing identity OR issuer is a refusal, not a skip. Both
#     are required: an identity without an issuer would accept a certificate
#     for the same identity string from ANY OIDC provider.
#  2. Verify and deploy the SAME BYTES. Verifying a tag and then handing that
#     tag to the installer is a TOCTOU race — the tag can move between the two,
#     so what was verified is not necessarily what lands. cosign reports the
#     digest it actually verified, so we pin the deploy to that digest.
verify_signature() {
    local cfg="$1" imgref="$2"
    local identity issuer out digest

    identity=$(jq -r '.cosignIdentity // empty' "$cfg")
    issuer=$(jq -r '.cosignIssuer // empty' "$cfg")

    if [ "${BOOTSAHI_ALLOW_UNVERIFIED:-0}" = "1" ]; then
        # Deliberately loud, and it TAINTS the evidence: the marker file lands
        # in the run dir so any test artifact produced under this override is
        # self-identifying rather than looking like a clean pass. The bootstrap
        # image never sets it; it exists for harnesses that have no signed
        # image to point at.
        log "WARNING: BOOTSAHI_ALLOW_UNVERIFIED=1 — deploying WITHOUT signature verification"
        log "WARNING: dev/test only. Any result produced under this flag is tainted (issue #24)."
        echo "unverified" >"$RUN_DIR/UNVERIFIED-INSTALL" 2>/dev/null || true
        printf '%s\n' "$imgref"
        return 0
    fi

    if [ -z "$identity" ] || [ -z "$issuer" ]; then
        log "no signature policy in install-config.json (cosignIdentity and cosignIssuer are both required)"
        log "refusing to deploy an unverified image — see issue #24"
        log "(dev/test override: BOOTSAHI_ALLOW_UNVERIFIED=1, which taints the run)"
        return 1
    fi
    if ! command -v cosign >/dev/null 2>&1; then
        log "signature policy is set but cosign is missing from the bootstrap image; refusing"
        return 1
    fi

    log "verifying cosign signature for $imgref"
    if ! out=$(cosign verify \
        --certificate-identity "$identity" \
        --certificate-oidc-issuer "$issuer" \
        --output json \
        "$imgref" 2>>"$LOG_FILE"); then
        log "cosign verification FAILED for $imgref"
        return 1
    fi
    printf '%s' "$out" >>"$LOG_FILE"

    # Pin to what cosign actually verified. If we cannot extract that digest we
    # refuse rather than falling back to the tag — a fallback here would
    # silently reintroduce exactly the race this exists to close.
    digest=$(printf '%s' "$out" | jq -r '.[0].critical.image."docker-manifest-digest" // empty' 2>/dev/null)
    case "$digest" in
        sha256:*) ;;
        *)
            log "cosign verified $imgref but no manifest digest could be read from its output;"
            log "refusing rather than deploying a tag that may have moved since verification"
            return 1
            ;;
    esac

    log "verified digest $digest — deploying by digest, not by tag"
    printf '%s@%s\n' "${imgref%%@*}" "$digest"
}

# reject_stored_secrets refuses a config that carries a secret at all (#21).
#
# Since first-boot prompting landed, no secret has any business being in this
# file: the Wi-Fi passphrase and the LUKS passphrase are asked for on the
# machine, and the account password travels as a crypt hash. A config
# containing one is either produced by an older writer or by someone who should
# not be writing it, and in both cases the secret is already exposed — the ESP
# is world-readable FAT that survives a failed install.
#
# Refusing is the only useful response: continuing would consume the secret and
# imply the channel is supported, and the file has already been readable for
# the whole download window by then. Fail loudly so the writer gets fixed.
reject_stored_secrets() {
    local cfg="$1" found=""
    [ -n "$(jq -r '.wifi.psk // empty' "$cfg")" ] && found="wifi.psk"
    if [ -n "$(jq -r '.encryption.passphrase // empty' "$cfg")" ]; then
        found="${found:+$found, }encryption.passphrase"
    fi
    [ -n "$found" ] || return 0

    log "install-config.json contains a secret in the clear: $found"
    log "The ESP is unencrypted, world-readable, and is kept after a failed install,"
    log "so secrets must never be written there. They are asked for on this machine"
    log "at first boot instead. Remove the field from the writer. See issue #21."
    return 1
}

# reject_plaintext_password refuses an account password that is not already a
# crypt hash (issue #21).
#
# install-config.json is written to the ESP: an unencrypted, world-readable FAT
# partition that persists for the whole download-and-install window, and which
# is deliberately PRESERVED on failure so the fallback UI can retry. A password
# as typed sitting there is readable by anything that can mount the ESP —
# including macOS, before the machine ever boots Linux — and unlinking a file
# on FAT flash is not erasure.
#
# A $6$ hash is not secret-free, but it is not a reusable credential the way the
# typed password is: the user's password is very often reused elsewhere, and
# that is the exposure worth eliminating first. This matches what wootc already
# does on the Windows side, so both hosts feed fisherman the same shape.
#
# fisherman handles this natively: a password beginning with "$" is passed to
# chpasswd with -e (verbatim hash), anything else is treated as plaintext. So
# requiring the hash form here costs nothing downstream.
reject_plaintext_password() {
    local cfg="$1" pw
    pw=$(jq -r '.user.password // empty' "$cfg")
    [ -n "$pw" ] || return 0
    case "$pw" in
        '$'*) return 0 ;;
    esac
    log "user.password is not a crypt hash. install-config.json lives on the ESP,"
    log "which is world-readable and survives a failed install, so a password as"
    log "typed must never be written there. Supply a \$6\$ (SHA-512 crypt) hash;"
    log "fisherman applies it verbatim via chpasswd -e. See issue #21."
    return 1
}

# Authoritative Apple Silicon check, mirroring asahi-bootbin-sync.sh. The unit's
# ConditionPathExists only proves we're on *some* device-tree machine; this
# proves it's Apple. Defence in depth, and the reason it exists in the script
# rather than only the unit: issue #23 was a unit-level predicate that silently
# never matched, which no amount of script correctness would have caught.
# Exits 2 (nothing to do), never 0 — 0 means "installed, go ahead and reboot".
check_apple_hardware() {
    [ "${BOOTSAHI_SKIP_HW_CHECK:-0}" = "1" ] && return 0
    if ! grep -q "apple," /proc/device-tree/compatible 2>/dev/null; then
        log "not Apple Silicon hardware (no 'apple,' in /proc/device-tree/compatible); nothing to do"
        exit 2
    fi
    return 0
}

# fisherman's manual/customMounts path does NOT do LUKS: luksFormat/luksOpen
# happen only in its auto-partition branch, and TPM enrolment needs an
# activeRootPart that manual mode leaves empty. Since this agent always sets
# customMounts, an encrypted install would silently complete UNENCRYPTED while
# the app's UI said otherwise — a security-boundary failure, not a missing
# feature (issue #20). Fail closed BEFORE any disk mutation until fisherman's
# manual path implements encryption.
reject_unsupported_encryption() {
    local cfg="$1" etype
    etype=$(jq -r '.encryption.type // "none"' "$cfg")
    if [ "$etype" != "none" ]; then
        log "encryption.type='$etype' requested, but fisherman's customMounts path does not apply LUKS"
        log "refusing to continue: an install would silently complete UNENCRYPTED (see issue #20)"
        return 1
    fi
    return 0
}
