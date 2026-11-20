#!/usr/bin/env bash
# verify-image.sh — resolve an image to its linux/arm64 manifest, verify that
# digest's cosign signature against exactly one signer, and print the pinned
# reference to use instead of the input.
#
# CI runs this before it builds FROM, packages or runs an image --privileged
# (#97). It uses the agent's own resolve_platform_digest, so CI and the Mac
# pin the same manifest the same way: tunaOS signs per-platform manifests, not
# the multi-arch index its tags point at, and the bootstrap is single-arch.
#
# Usage: ./scripts/verify-image.sh REF IDENTITY ISSUER
#   prints  <repo>@sha256:<digest>   on success; exits non-zero otherwise.
# Needs skopeo, jq and cosign on PATH.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
REF="${1:?usage: $0 REF IDENTITY ISSUER}"
IDENTITY="${2:?usage: $0 REF IDENTITY ISSUER}"
ISSUER="${3:?usage: $0 REF IDENTITY ISSUER}"

# What bootsahi-agent-policy.sh expects its caller to define.
RUN_DIR=$(mktemp -d)
trap 'rm -rf "$RUN_DIR"' EXIT
# shellcheck disable=SC2034 # read by the sourced library
LOG_FILE=/dev/stderr
AGENT_LIB_DIR="$HERE/components/bootsahi-agent"
log() { echo "verify-image: $*" >&2; }
# shellcheck source=components/bootsahi-agent/bootsahi-agent-policy.sh
source "$AGENT_LIB_DIR/bootsahi-agent-policy.sh"

digest=$(resolve_platform_digest "$REF")

# Strip any digest, then a tag (a colon after the last slash; a registry port
# comes before it).
repo="${REF%%@*}"
case "${repo##*/}" in *:*) repo="${repo%:*}" ;; esac
pinned="$repo@$digest"

log "verifying $pinned (from $REF) against $IDENTITY"
out=$(cosign verify --certificate-identity "$IDENTITY" --certificate-oidc-issuer "$ISSUER" \
	--output json "$pinned")
got=$(jq -r '.[0].critical.image."docker-manifest-digest" // empty' <<<"$out")
if [ "$got" != "$digest" ]; then
	log "cosign verified '${got:-nothing}', not $digest; refusing"
	exit 1
fi
log "verified $pinned"
printf '%s\n' "$pinned"
