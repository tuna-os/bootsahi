#!/usr/bin/env bash
# validate-catalog.sh — enforce that catalog.json's `verified` field is
# backed by evidence, not a hand flip. (#70)
#
# DESIGN.md's contract is a CI job that GENERATES catalog.json from
# registry-map.yaml, filtered through harness results per tuna-os/tunaOS#910.
# That generator does not exist: there is no registry-map.yaml and nothing
# feeds real harness output into this repo yet (it needs the ordered
# hardware checks in ROADMAP.md's Alpha checklist first). Until it does,
# `verified` was just a boolean a human could flip with no check at all —
# the exact gap #70 found.
#
# This is the minimal guard #70's own recommendation asked for in the
# meantime: every `verified: true` entry in catalog.json must have a
# matching record in docs/harness-results.json naming a clean pass (`N/N`,
# N>0) and a harnessRef a reviewer can open. Flipping the catalog boolean
# alone, with nothing else in the diff, now fails this check.
#
# It also checks that every entry's cosign signer is one the bootstrap ships
# in trusted-signers.json, and that the entry's image is in a registry
# namespace the list gives that signer, since the agent refuses any other.
#
# Usage: ./scripts/validate-catalog.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
CATALOG="$HERE/macos-app/Bootsahi/Sources/Bootsahi/Resources/catalog.json"
RECORDS="$HERE/docs/harness-results.json"
SIGNERS="$HERE/components/bootsahi-agent/trusted-signers.json"

for f in "$CATALOG" "$RECORDS" "$SIGNERS"; do
	[ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 1; }
	jq empty "$f" || { echo "ERROR: $f is not valid JSON" >&2; exit 1; }
done

fail=0

echo "==> Checking catalog.json's verified:true entries against docs/harness-results.json"
while IFS=$'\t' read -r variant desktop stream imgref; do
	record=$(jq --arg v "$variant" --arg d "$desktop" --arg s "$stream" --arg i "$imgref" \
		'[.records[] | select(.variant == $v and .desktop == $d and .stream == $s and .imgref == $i)] | first // empty' \
		"$RECORDS")

	if [ -z "$record" ]; then
		echo "FAIL: $variant/$desktop/$stream ($imgref) is verified:true in catalog.json but has no matching record in docs/harness-results.json"
		fail=1
		continue
	fi

	pass_rate=$(jq -r '.passRate // empty' <<<"$record")
	harness_ref=$(jq -r '.harnessRef // empty' <<<"$record")

	if [ -z "$harness_ref" ]; then
		echo "FAIL: $variant/$desktop/$stream harness record has no harnessRef (evidence link)"
		fail=1
	fi

	if [[ "$pass_rate" =~ ^([0-9]+)/([0-9]+)$ ]]; then
		passed="${BASH_REMATCH[1]}"
		total="${BASH_REMATCH[2]}"
		if [ "$total" -eq 0 ] || [ "$passed" -ne "$total" ]; then
			echo "FAIL: $variant/$desktop/$stream harness record is not a clean pass (passRate=$pass_rate)"
			fail=1
		else
			echo "ok: $variant/$desktop/$stream verified by $harness_ref ($pass_rate)"
		fi
	else
		echo "FAIL: $variant/$desktop/$stream harness record has no valid passRate (got '${pass_rate:-<empty>}')"
		fail=1
	fi
done < <(jq -r '.entries[] | select(.verified == true) | [.variant, .desktop, .stream, .imgref] | @tsv' "$CATALOG")

# bootsahi-agent installs only images signed by a signer the bootstrap ships.
# An entry naming any other signer would be offered by the app and then refused
# at first boot, after the disk has been repartitioned.
echo "==> Checking every catalog.json signer against trusted-signers.json"
while IFS=$'\t' read -r imgref identity issuer; do
	if jq -e --arg id "$identity" --arg iss "$issuer" \
		'any(.signers[]?; .cosignIdentity == $id and .cosignIssuer == $iss)' "$SIGNERS" >/dev/null; then
		echo "ok: $imgref signer is trusted by the bootstrap"
	else
		echo "FAIL: $imgref names signer '$identity' (issuer '$issuer'), which is not in components/bootsahi-agent/trusted-signers.json"
		fail=1
		continue
	fi
	# The agent holds a signer to its imagePrefixes (signer_allows_image in
	# bootsahi-agent-policy.sh; the same match is repeated here). An entry
	# outside them is refused at the same late point.
	if jq -e --arg id "$identity" --arg iss "$issuer" --arg ref "$imgref" \
		'any(.signers[]? | select(.cosignIdentity == $id and .cosignIssuer == $iss) | .imagePrefixes[]?;
		     type == "string" and endswith("/") and (. as $prefix | $ref | startswith($prefix)))' \
		"$SIGNERS" >/dev/null; then
		echo "ok: $imgref is in an image namespace of its signer"
	else
		echo "FAIL: $imgref is outside the imagePrefixes that components/bootsahi-agent/trusted-signers.json gives its signer"
		fail=1
	fi
done < <(jq -r '.entries[] | [.imgref, .cosignIdentity, .cosignIssuer] | @tsv' "$CATALOG")

exit "$fail"
