#!/usr/bin/env bash
# test-backend-contract.sh — hold the D2 backend to the contract D1 depends on.
#
# The macOS backend (asahi-installer --json machine mode) and the Linux
# first-boot agent are developed in different repos, in different languages,
# and are exercised by different test suites that never meet. The only thing
# joining them is <ESP>/asahi/stub_info.json: the backend records which
# partitions it created, and the agent uses that to decide which partition it
# is allowed to format.
#
# That is the most dangerous handoff in the project. If the backend renames
# "role", stops lowercasing "uuid", or drops a field, nothing fails until an
# agent on a real Mac either refuses to install or — far worse — resolves to
# the wrong partition. Both sides' tests would stay green the whole time,
# because each side tests its own idea of the shape.
#
# So this asserts the two agree, at a PINNED backend revision:
#
#   1. the backend's own --json protocol suite still passes at that revision
#      (24 tests, no macOS needed — they mock stdin/stdout);
#   2. the producer still emits every key the agent consumes, checked against
#      the backend's real source rather than against our fixtures;
#   3. the terminal result contract from issue #25: a failing run emits a
#      structured {"event":"result","status":"failure",...} line on stdout
#      AND exits non-zero. The backend's own suite tests util.emit_result()
#      in isolation (capsys mocks); none of it runs main.py and observes the
#      exit status, which is exactly the gap that let the pre-fix backend
#      catch every exception, print warnings, and fall through to exit 0.
#      This runs the real main.py --json with a failure injected and checks
#      the process-level behaviour, so a pin regression can't go green.
#
# Usage: ./scripts/test-backend-contract.sh
set -euo pipefail

# Pinned deliberately, exactly like FISHERMAN_REV. "Which backend did we test
# against?" has to stay answerable after the fact, and a floating branch would
# make a green run mean nothing in a week.
#
# The fork that carried this revision (hanthor/asahi-installer) is no longer
# reachable, but GitHub keeps fork-network objects addressable from the
# upstream repo, so the same commit is fetched by SHA from there. The SHA is
# the identity; the rev-parse check below still proves we got exactly it.
BACKEND_REPO="${BACKEND_REPO:-https://github.com/AsahiLinux/asahi-installer}"
BACKEND_REV="${BACKEND_REV:-4cb26d8a0d831476b7e76bdf88cda0a8c5b5164e}"

for t in git python3; do
	command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; exit 0; }
done
if ! python3 -c "import pytest" 2>/dev/null; then
	echo "SKIP: pytest not available; cannot run the backend's own suite."
	echo "      This is the check that proves the pinned backend still works,"
	echo "      so its absence is worth noticing rather than passing silently."
	exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0

echo "==> Fetching the pinned backend ($BACKEND_REV)"
# Fetch the commit by SHA rather than cloning a branch: the pin need not be
# on any branch of $BACKEND_REPO, only reachable from it.
git init --quiet "$WORK/backend"
git -C "$WORK/backend" fetch --quiet --depth=1 "$BACKEND_REPO" "$BACKEND_REV"
git -C "$WORK/backend" checkout --quiet FETCH_HEAD
checked_out=$(git -C "$WORK/backend" rev-parse HEAD)
if [ "$checked_out" != "$BACKEND_REV" ]; then
	echo "FAIL: backend checkout resolved to $checked_out, expected pinned $BACKEND_REV"
	echo "      Refusing to run protocol checks against an unverified revision."
	exit 1
fi
echo "ok: backend checkout is exactly $checked_out"

# The executable and its protocol document are one release unit. A checkout
# that retains tests but loses a documented event or answer rule is not safe
# for the Swift driver to consume. Check both at the exact pinned revision.
echo
echo "==> --json protocol surface at the pinned revision"
protocol_fail=0
for required in 'JSON_MODE' 'ask_json' 'emit_result' '"--json"'; do
	if grep -q "$required" "$WORK/backend/src/main.py" "$WORK/backend/src/util.py" 2>/dev/null; then
		echo "ok: backend source contains $required"
	else
		echo "FAIL: backend source no longer contains $required"
		protocol_fail=1
	fi
done
for required in 'event": "message' 'event": "ask' 'event": "result' 'exactly one' 'answering the most recent'; do
	if grep -q "$required" "$WORK/backend/docs/json-mode.md" 2>/dev/null; then
		echo "ok: protocol document specifies $required"
	else
		echo "FAIL: protocol document no longer specifies $required"
		protocol_fail=1
	fi
done
if [ "$protocol_fail" -ne 0 ]; then
	fail=1
	echo "FAIL: pinned backend source and protocol documentation drifted"
fi

# Keep the consumer-side contract in this repository too. The backend's
# protocol document is the implementation reference; this copy is what the
# Swift driver and reviewers use when checking a change to the handoff.
echo
echo "==> repository-owned D2 consumer contract"
for required in 'exactly one JSON answer' 'Only one ask is outstanding' 'event":"result' 'subprocess exits zero' 'EFI PARTUUID'; do
	if grep -q "$required" docs/D2-JSON-MACHINE-MODE.md; then
		echo "ok: consumer contract specifies $required"
	else
		echo "FAIL: consumer contract omits $required"
		fail=1
	fi
done

# ── 1. The backend's own protocol suite, at the revision we target ───────────
echo
echo "==> The backend's --json protocol suite"
if (cd "$WORK/backend/src" && python3 -m pytest test_json_mode.py -q >"$WORK/pytest.log" 2>&1); then
	echo "ok: $(tail -1 "$WORK/pytest.log")"
else
	echo "FAIL: the pinned backend's own json-mode tests do not pass"
	tail -20 "$WORK/pytest.log" | sed 's/^/      | /'
	fail=1
fi

# ── 2. The stub_info contract ───────────────────────────────────────────────
# Read the keys straight out of the producer rather than trusting a fixture we
# wrote. A fixture agreeing with itself proves nothing; the point is to notice
# when the OTHER side changes.
echo
echo "==> stub_info.json keys: what the backend emits vs what the agent reads"

produced=$(python3 - "$WORK/backend/src/main.py" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
i = src.find('stub_info["partitions"]')
if i == -1:
    print("PRODUCER-BLOCK-NOT-FOUND")
    sys.exit(0)
# The assignment is a list comprehension over a dict literal; take up to the
# comprehension's `for`, which ends the dict body.
block = src[i:]
end = block.find("for part, info in")
block = block[:end if end != -1 else 2000]
keys = re.findall(r'"([a-z_]+)":', block)
print(" ".join(sorted(set(keys))))
PY
)

if [ "$produced" = "PRODUCER-BLOCK-NOT-FOUND" ]; then
	echo "FAIL: could not find the stub_info[\"partitions\"] producer in the backend."
	echo "      Either it moved or it was refactored away — either way the contract"
	echo "      this test exists to police is no longer where it was."
	fail=1
	produced=""
fi
echo "    backend emits: ${produced:-<none>}"

# What the agent actually reads out of each partition entry. Kept explicit
# rather than grepped: this is the list we are asserting the backend still
# satisfies, so it should be a deliberate statement, not an inference.
AGENT_NEEDS="role uuid"
echo "    agent needs:   $AGENT_NEEDS"

for k in $AGENT_NEEDS; do
	case " $produced " in
		*" $k "*) echo "ok: backend still emits '$k'" ;;
		*)
			echo "FAIL: the agent resolves its install target using '$k', and the pinned"
			echo "      backend no longer emits it. On hardware this is either a refusal"
			echo "      to install or a resolution to the wrong partition."
			fail=1
			;;
	esac
done

# The inverse direction, and the reason it matters: macos_device is present in
# the record and the agent must NEVER resolve by it — it is a macOS device name
# ("disk0s5") that means nothing under Linux, where the same partition is
# nvme0n1p5. Verified against the agent source, because this is a mistake that
# would look completely reasonable in review.
echo
echo "==> the agent must not resolve by the macOS device name"
# The agent is several shipped libraries, and stub_info.json is read in
# bootsahi-agent-device.sh, not in bootsahi-agent.sh (#156 moved it). So scan
# every shipped agent source. First check that the scan includes the code that
# reads the partition records. A scan that misses the reader passes whatever
# the reader does.
AGENT_SOURCES=(components/bootsahi-agent/bootsahi-agent*.sh)
if [ ! -f "${AGENT_SOURCES[0]}" ]; then
	echo "FAIL: no agent sources match components/bootsahi-agent/bootsahi-agent*.sh"
	fail=1
elif ! grep -q '\.partitions\[' "${AGENT_SOURCES[@]}"; then
	echo "FAIL: none of ${AGENT_SOURCES[*]} reads stub_info.json's .partitions."
	echo "      The reader moved, so this guard would check the wrong files."
	fail=1
elif grep -n "macos_device" "${AGENT_SOURCES[@]}"; then
	echo "FAIL: bootsahi-agent references macos_device. That field is a macOS device"
	echo "      name and does not identify anything under Linux."
	fail=1
else
	echo "ok: the agent never reads macos_device (${AGENT_SOURCES[*]})"
fi

# ── 3. The terminal result contract (issue #25) ───────────────────────────
# The pre-fix backend caught every exception (CalledProcessError, generic
# Exception), printed advice, and fell through to exit 0 with NO terminal
# event — so a driver treating exit 0 as its sole success observable told the
# user to bless and reboot an incomplete install. The fix (in the backend, at
# the pinned revision) emits one structured result event per run and exits
# non-zero on every failure. What is missing on THIS side is any CI-held
# check that the pinned backend actually does that: its own pytest suite only
# mocks util.emit_result() output and never observes the process exit status.
#
# So hold the PINNED backend to the process-level contract here. The injected
# failure needs no macOS, no disk and no network: a corrupt installer_data.json
# makes InstallerMain()'s constructor raise JSONDecodeError before any real
# probing happens, which is the generic-exception path the issue calls out.
# A pre-fix backend exits 0 with nothing on stdout; a fixed one exits 1 with
# {"event":"result","status":"failure","kind":"exception",...}.
echo
echo "==> terminal result contract (issue #25): injected failure => result event + non-zero exit"

TERM_DIR="$WORK/terminal"
mkdir -p "$TERM_DIR"
# Copy the source tree; src/asahi_firmware is a symlink to the clone root's
# firmware tree, so resolve it the same way mac-hardware-smoketest.sh does.
cp "$WORK/backend/src/"*.py "$TERM_DIR/"
ln -sf "$WORK/backend/asahi_firmware" "$TERM_DIR/asahi_firmware"
# Deliberately invalid JSON: InstallerMain.__init__ does json.load() first, so
# this raises JSONDecodeError without touching diskutil/system probing at all.
printf '{"os_list": [\n' >"$TERM_DIR/installer_data.json"
printf 'contract-test\n' >"$TERM_DIR/version.tag"

TERM_CODE=0
(cd "$TERM_DIR" && python3 main.py --json >"$WORK/terminal.out" 2>"$WORK/terminal.err") || TERM_CODE=$?

TERM_VERDICT=$(python3 - "$WORK/terminal.out" <<'PY'
import json, sys

events = []
parse_errors = []
with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            parse_errors.append(line)
            continue
        events.append(event)

results = [event for event in events if event.get("event") == "result"]
if parse_errors:
    print("NON_JSON_OUTPUT")
elif not results:
    print("NO_RESULT_EVENT")
elif len(results) != 1:
    print("DUPLICATE_RESULT_EVENTS")
elif events[-1] is not results[0]:
    print("RESULT_NOT_LAST")
elif results[0].get("status") == "success":
    print("UNEXPECTED_SUCCESS")
elif results[0].get("status") == "failure":
    print("FAILURE_RESULT_OK")
else:
    print("UNEXPECTED_STATUS")
PY
)

case "$TERM_VERDICT:$TERM_CODE" in
	FAILURE_RESULT_OK:0)
		echo "FAIL: injected failure emitted a failure result but exited 0 — the issue #25"
		echo "      regression, where exit 0 alone reads as success to a driver."
		fail=1
		;;
	FAILURE_RESULT_OK:*)
		echo "ok: injected failure exited $TERM_CODE and emitted a structured failure result"
		;;
	NO_RESULT_EVENT:*)
		echo "FAIL: injected failure exited $TERM_CODE with NO result event — the exact"
		echo "      pre-fix behaviour from issue #25 (warnings, then silent exit 0)."
		fail=1
		;;
	UNEXPECTED_SUCCESS:*)
		echo "FAIL: injected failure reported status=success"
		fail=1
		;;
	DUPLICATE_RESULT_EVENTS:*)
		echo "FAIL: injected failure emitted more than one terminal result event"
		fail=1
		;;
	RESULT_NOT_LAST:*)
		echo "FAIL: terminal result was not the final JSON event"
		fail=1
		;;
	NON_JSON_OUTPUT:*)
		echo "FAIL: backend emitted non-JSON stdout in machine mode"
		fail=1
		;;
	*)
		echo "FAIL: terminal-result check saw verdict '$TERM_VERDICT' with exit $TERM_CODE"
		fail=1
		;;
esac

if [ "$TERM_VERDICT" != "FAILURE_RESULT_OK" ] || [ "$TERM_CODE" -eq 0 ]; then
	echo "      backend stderr (tail — the traceback from the injected JSON error):"
	tail -6 "$WORK/terminal.err" 2>/dev/null | sed 's/^/      | /'
fi

echo
if [ "$fail" -ne 0 ]; then
	echo "BACKEND CONTRACT FAILED"
	exit 1
fi
echo "BACKEND CONTRACT PASSED (backend $BACKEND_REV)"
