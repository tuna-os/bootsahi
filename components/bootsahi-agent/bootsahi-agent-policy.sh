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

# find_trusted_signers locates trusted-signers.json, the list of signers this
# bootstrap accepts. Same lookup order as the schema: production installs it to
# /usr/share/bootsahi/; dev/test checks BOOTSAHI_TRUSTED_SIGNERS_PATH or
# AGENT_LIB_DIR.
find_trusted_signers() {
    if [ -n "${BOOTSAHI_TRUSTED_SIGNERS_PATH:-}" ]; then
        [ -f "$BOOTSAHI_TRUSTED_SIGNERS_PATH" ] && echo "$BOOTSAHI_TRUSTED_SIGNERS_PATH"
        return 0
    fi
    if [ -f "/usr/share/bootsahi/trusted-signers.json" ]; then
        echo "/usr/share/bootsahi/trusted-signers.json"
        return 0
    fi
    if [ -f "$AGENT_LIB_DIR/trusted-signers.json" ]; then
        echo "$AGENT_LIB_DIR/trusted-signers.json"
        return 0
    fi
    return 0
}

# signer_is_trusted reports whether an (identity, issuer) pair is one this
# bootstrap ships as trusted. Exact string match on both, as a pair.
#
# The config names the signer it expects, but the config lives on the ESP next
# to the image reference it is meant to constrain. Whoever can write one can
# write the other, and a keyless signature from one's own workflow costs
# nothing. So the config's pair only selects among signers the bootstrap
# already trusts; it never introduces one.
#
# Fails closed: a missing or unparsable list is a refusal, not a pass. The list
# ships in the bootstrap image, so its absence is a packaging defect.
signer_is_trusted() {
    local identity="$1" issuer="$2" signers_file
    signers_file=$(find_trusted_signers)
    if [ -z "$signers_file" ]; then
        log "trusted-signers.json not found; cannot tell whether the config's signer is one this bootstrap accepts"
        return 1
    fi
    jq -e --arg id "$identity" --arg iss "$issuer" '
        any(.signers[]?; .cosignIdentity == $id and .cosignIssuer == $iss)
    ' "$signers_file" >/dev/null 2>>"$LOG_FILE"
}

# signer_allows_image reports whether a trusted signer may vouch for imgref:
# the reference must start with one of that signer's imagePrefixes.
#
# The identity does not tie an image to tunaOS by itself. The trusted identity
# is a reusable workflow, and a keyless certificate names the reusable workflow
# a job runs, not the repository that called it. Any repository can call a
# public reusable workflow, push to its own registry namespace and get a
# signature with this identity. What such a caller cannot do is write to the
# namespace of the project. cosign reads a signature from the repository of the
# image it verifies, so a reference under a listed prefix can only carry
# signatures that the owner of that namespace pushed.
#
# A prefix must end with "/": "ghcr.io/tuna-os" would also match
# "ghcr.io/tuna-os-evil/image". Fails closed: a signer with no usable prefix
# vouches for no image, and so does a missing or unparsable list.
signer_allows_image() {
    local identity="$1" issuer="$2" imgref="$3" signers_file
    signers_file=$(find_trusted_signers)
    [ -n "$signers_file" ] || return 1
    jq -e --arg id "$identity" --arg iss "$issuer" --arg ref "$imgref" '
        any(.signers[]?
            | select(.cosignIdentity == $id and .cosignIssuer == $iss)
            | .imagePrefixes[]?;
            type == "string" and endswith("/") and (. as $prefix | $ref | startswith($prefix)))
    ' "$signers_file" >/dev/null 2>>"$LOG_FILE"
}

# resolve_platform_digest prints the digest of the linux/arm64 image manifest
# behind imgref, the one manifest this machine can run.
#
# tunaOS signs each platform manifest, not the multi-arch index its tags point
# at, so `cosign verify <tag>` finds no signature. Verifying the arm64 manifest
# is also the tighter check: those are the bytes bootc pulls on this machine.
#
# An index must list exactly one linux/arm64 manifest; none or several is a
# refusal. A single-arch manifest is its own digest: the SHA-256 of the exact
# bytes the registry served, hashed from a file because command substitution
# would strip a trailing newline and change the hash.
resolve_platform_digest() {
    local imgref="$1" raw media digest
    raw="$RUN_DIR/target-manifest.json"
    if ! skopeo inspect --raw "docker://$imgref" >"$raw" 2>>"$LOG_FILE"; then
        log "could not read the manifest of $imgref from the registry"
        return 1
    fi
    media=$(jq -r '.mediaType // empty' "$raw" 2>>"$LOG_FILE")
    case "$media" in
        application/vnd.oci.image.index.v1+json | application/vnd.docker.distribution.manifest.list.v2+json)
            digest=$(jq -r '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "arm64")]
                | if length == 1 then .[0].digest else empty end' "$raw" 2>>"$LOG_FILE")
            ;;
        application/vnd.oci.image.manifest.v1+json | application/vnd.docker.distribution.manifest.v2+json)
            digest="sha256:$(sha256sum "$raw" | cut -d' ' -f1)"
            ;;
        *)
            log "$imgref has an unknown manifest type '${media:-none}'"
            return 1
            ;;
    esac
    if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        log "$imgref does not list exactly one linux/arm64 manifest; refusing"
        return 1
    fi
    printf '%s\n' "$digest"
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
#     for the same identity string from ANY OIDC provider. The pair must also
#     be one the bootstrap ships in trusted-signers.json (see
#     signer_is_trusted): a policy the config can rewrite is no more a policy
#     than one it can omit. The image must also be in a registry namespace
#     that the list gives that signer (see signer_allows_image), because the
#     config names the image too.
#  2. Verify and deploy the SAME BYTES. Verifying a tag and then handing that
#     tag to the installer is a TOCTOU race — the tag can move between the two,
#     so what was verified is not necessarily what lands. The agent resolves
#     the tag once to the linux/arm64 manifest digest (resolve_platform_digest),
#     has cosign verify THAT digest, checks cosign reports the same digest, and
#     deploys it.
verify_signature() {
    local cfg="$1" imgref="$2"
    local identity issuer out digest platform_digest pinned

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
    if ! signer_is_trusted "$identity" "$issuer"; then
        log "install-config.json names a signer this bootstrap does not trust:"
        log "  cosignIdentity=$identity"
        log "  cosignIssuer=$issuer"
        log "refusing: a signature only proves authenticity against a signer the bootstrap ships"
        return 1
    fi
    if ! signer_allows_image "$identity" "$issuer" "$imgref"; then
        log "targetImgref=$imgref is not in an image namespace this bootstrap trusts that signer for"
        log "refusing: any repository can get a signature with this identity for its own image"
        return 1
    fi
    if ! command -v cosign >/dev/null 2>&1; then
        log "signature policy is set but cosign is missing from the bootstrap image; refusing"
        return 1
    fi
    if ! command -v skopeo >/dev/null 2>&1; then
        log "skopeo is missing from the bootstrap image, so the arm64 manifest cannot be resolved; refusing"
        return 1
    fi

    if ! platform_digest=$(resolve_platform_digest "$imgref"); then
        log "could not resolve $imgref to one linux/arm64 manifest; refusing"
        return 1
    fi
    pinned="${imgref%%@*}@$platform_digest"

    log "verifying cosign signature for $pinned (linux/arm64 manifest of $imgref)"
    if ! out=$(cosign verify \
        --certificate-identity "$identity" \
        --certificate-oidc-issuer "$issuer" \
        --output json \
        "$pinned" 2>>"$LOG_FILE"); then
        log "cosign verification FAILED for $pinned"
        return 1
    fi
    printf '%s' "$out" >>"$LOG_FILE"

    # Deploy only what cosign reports it verified, and only if that is the
    # digest we asked about. Refuse rather than fall back to the tag — a
    # fallback here would silently reintroduce the race this exists to close.
    digest=$(printf '%s' "$out" | jq -r '.[0].critical.image."docker-manifest-digest" // empty' 2>/dev/null)
    case "$digest" in
        sha256:*) ;;
        *)
            log "cosign verified $pinned but no manifest digest could be read from its output;"
            log "refusing rather than deploying a tag that may have moved since verification"
            return 1
            ;;
    esac
    if [ "$digest" != "$platform_digest" ]; then
        log "cosign verified $digest, not the resolved arm64 manifest $platform_digest; refusing"
        return 1
    fi

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
