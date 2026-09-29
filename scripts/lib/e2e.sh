#!/usr/bin/env bash
# Helpers shared by the end-to-end scripts (e2e-providers.sh, e2e-tools.sh). Sourced, not executed.
#
# They drive the real Debug app the way a person would, without a person: settings go into a throwaway preferences domain (the
# user's own are never touched), the app is pointed at scripts/mock-llm-server.py, commands are typed in through the app's debug
# hooks, and what happened is read back from the app's audit trail, its status report and the mock's request log.

source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"

PORT="${PORT:-8899}"
APP="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
SUITE="com.rohitsainier.voxa.e2e"
WORK="$(mktemp -d)"
FAILURES=0
MOCK_PID=""

e2e_cleanup() {
    pkill -x "$APP_NAME" 2>/dev/null || true
    if [[ -n "$MOCK_PID" ]]; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
    fi
    defaults delete "$SUITE" 2>/dev/null || true
    rm -rf "$WORK"
}

e2e_init() {
    [[ -d "$APP" ]] || die "no Debug app at $APP; run scripts/build.sh first"
    require python3 "python3 is needed for the mock server"
    trap e2e_cleanup EXIT
    pkill -x "$APP_NAME" 2>/dev/null || true
    log "Starting the mock server on port $PORT"
    python3 "$ROOT/scripts/mock-llm-server.py" --port "$PORT" --log "$WORK/requests.jsonl" >"$WORK/mock.out" 2>&1 &
    MOCK_PID=$!
    wait_for 5 curl -s "http://127.0.0.1:$PORT/api/version" || die "the mock server did not start"
}

check() { # check <description> <exit status of the condition>
    if [[ "$2" -eq 0 ]]; then
        printf '  \033[32mpass\033[0m  %s\n' "$1"
    else
        printf '  \033[31mFAIL\033[0m  %s\n' "$1"
        FAILURES=$((FAILURES + 1))
    fi
}

e2e_finish() {
    echo
    if [[ $FAILURES -eq 0 ]]; then log "All checks passed"; else die "$FAILURES check(s) failed"; fi
}

wait_for() { # wait_for <seconds> <command...>
    local limit="$1"; shift
    for _ in $(seq 1 $((limit * 10))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done
    return 1
}

# Settings for one run, as the JSON the app stores. Everything else takes its default.
write_settings() { # write_settings <json>
    defaults delete "$SUITE" 2>/dev/null || true
    local hex
    hex="$(printf '%s' "$1" | xxd -p | tr -d '\n')"
    defaults write "$SUITE" voxa.settings -data "$hex"
}

# launch [extra --env NAME=value ...]: starts the app pointed at the mock and waits until it answers its debug hooks.
launch() {
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.5
    rm -f "$WORK/audit.jsonl" "$WORK/report.txt"
    open -n --env "VOXA_ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT" --env VOXA_DEBUG_API_KEY=sk-ant-mock \
        --env VOXA_DEBUG_OPENAI_API_KEY=sk-mock --env "VOXA_DEBUG_DEFAULTS_SUITE=$SUITE" \
        --env "VOXA_DEBUG_COMMAND_FILE=$WORK/command.txt" --env "VOXA_DEBUG_REPORT_FILE=$WORK/report.txt" \
        --env "VOXA_DEBUG_AUDIT_PATH=$WORK/audit.jsonl" --env "VOXA_DEBUG_SAY_FILE=$WORK/say.txt" "$@" "$APP"
    wait_for 15 pgrep -x "$APP_NAME" || die "the app did not start"
    # A freshly built app can take a few seconds to start (macOS scans it first). It is ready once it answers a report request.
    wait_for 40 ready || die "the app started but never answered its debug hooks"
}

report() { rm -f "$WORK/report.txt"; notifyutil -p com.rohitsainier.voxa.debug.report; wait_for 3 test -s "$WORK/report.txt"; cat "$WORK/report.txt"; }
ready() { report | grep -q "status="; }
report_has() { report | grep -q "$1"; }

# --- the audit trail ---------------------------------------------------------------------------------------------------

audit_lines() { [[ -f "$WORK/audit.jsonl" ]] && wc -l <"$WORK/audit.jsonl" | tr -d ' ' || echo 0; }

# audit_has <after-line> <kind> [tool] [outcome]: whether an entry like that was written after line <after-line>.
audit_has() {
    python3 - "$WORK/audit.jsonl" "$1" "$2" "${3:-}" "${4:-}" <<'PY'
import json, sys
path, after, kind, tool, outcome = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
try:
    lines = open(path).read().splitlines()[after:]
except OSError:
    sys.exit(1)
for line in lines:
    entry = json.loads(line)
    if entry.get("kind") != kind: continue
    if tool and entry.get("tool") != tool: continue
    if outcome and entry.get("outcome") != outcome: continue
    sys.exit(0)
sys.exit(1)
PY
}

# audit_reply <after-line>: the text of the reply (or failure) written after that line.
audit_reply() {
    python3 - "$WORK/audit.jsonl" "$1" <<'PY'
import json, sys
path, after = sys.argv[1], int(sys.argv[2])
for line in reversed(open(path).read().splitlines()[after:]):
    entry = json.loads(line)
    if entry.get("kind") in ("reply", "failure"):
        print(entry.get("detail") or ""); break
PY
}

# --- typing a command and answering what it asks -----------------------------------------------------------------------

# ask <text>: types the command in and waits for it to finish (a reply or a failure), or to stop and wait for an answer.
# Sets MARK to the audit line count before the command, for the checks that follow.
ask() {
    MARK="$(audit_lines)"
    printf '%s' "$1" >"$WORK/command.txt"
    notifyutil -p com.rohitsainier.voxa.debug.ask
    wait_for 20 finished_or_asking
}
finished_or_asking() { audit_has "$MARK" reply || audit_has "$MARK" failure || report_has "awaiting=true"; }
is_asking() { report_has "awaiting=true"; }

# answer allow|deny: presses the card's button (after the moment during which the card ignores presses).
answer() {
    wait_for 10 is_asking || true
    sleep 1
    notifyutil -p "com.rohitsainier.voxa.debug.button.$1"
    wait_for 20 finished
}
finished() { audit_has "$MARK" reply || audit_has "$MARK" failure; }

# The mock's own log: was every request a valid one?
requests_valid() { # requests_valid <dialect>
    python3 - "$WORK/requests.jsonl" "$1" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
sys.exit(0 if rows and all(r.get("valid") and r.get("dialect") == sys.argv[2] for r in rows) else 1)
PY
}
