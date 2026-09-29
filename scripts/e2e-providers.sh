#!/usr/bin/env bash
# End-to-end check of the model providers (Claude, OpenAI, Ollama) through the real Debug app, against the local mock server.
#
#   scripts/build.sh                 # build the Debug app first
#   scripts/e2e-providers.sh         # then run this
#
# For each provider it: writes settings into a throwaway preferences domain (your real settings are never touched), launches
# the app pointed at scripts/mock-llm-server.py, submits a typed command that needs a confirmation, approves it, and checks
# the app's audit trail and the mock's request log. Nothing here uses a real key, the real Keychain, or the network.
#
# Needs: the Debug app, python3, and a free port (PORT, default 8899).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

PORT="${PORT:-8899}"
APP="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
SUITE="com.rohitsainier.voxa.e2e"
WORK="$(mktemp -d)"
FAILURES=0

[[ -d "$APP" ]] || die "no Debug app at $APP; run scripts/build.sh first"
require python3 "python3 is needed for the mock server"

cleanup() {
    pkill -x "$APP_NAME" 2>/dev/null || true
    if [[ -n "${MOCK_PID:-}" ]]; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
    fi
    defaults delete "$SUITE" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

check() { # check <description> <condition-exit-status>
    if [[ "$2" -eq 0 ]]; then printf '  \033[32mpass\033[0m  %s\n' "$1"; else printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); fi
}

wait_for() { # wait_for <seconds> <command...>
    local limit="$1"; shift
    for _ in $(seq 1 $((limit * 10))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done
    return 1
}

pkill -x "$APP_NAME" 2>/dev/null || true
log "Starting the mock server on port $PORT"
python3 "$ROOT/scripts/mock-llm-server.py" --port "$PORT" --log "$WORK/requests.jsonl" >"$WORK/mock.out" 2>&1 &
MOCK_PID=$!
wait_for 5 curl -s "http://127.0.0.1:$PORT/api/version" || die "the mock server did not start"

# Settings for one provider, as the JSON the app stores. Everything else takes its default.
write_settings() { # write_settings <json>
    defaults delete "$SUITE" 2>/dev/null || true
    local hex
    hex="$(printf '%s' "$1" | xxd -p | tr -d '\n')"
    defaults write "$SUITE" voxa.settings -data "$hex"
}

launch() {
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.5
    rm -f "$WORK/audit.jsonl" "$WORK/report.txt"
    open -n --env "VOXA_ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT" --env VOXA_DEBUG_API_KEY=sk-ant-mock \
        --env VOXA_DEBUG_OPENAI_API_KEY=sk-mock --env "VOXA_DEBUG_DEFAULTS_SUITE=$SUITE" \
        --env "VOXA_DEBUG_COMMAND_FILE=$WORK/command.txt" --env "VOXA_DEBUG_REPORT_FILE=$WORK/report.txt" \
        --env "VOXA_DEBUG_AUDIT_PATH=$WORK/audit.jsonl" "$APP"
    wait_for 15 pgrep -x "$APP_NAME" || die "the app did not start"
    # A freshly built app can take a few seconds to start (macOS scans it first). It is ready once it answers a report request.
    wait_for 40 ready || die "the app started but never answered its debug hooks"
}

report() { rm -f "$WORK/report.txt"; notifyutil -p com.rohitsainier.voxa.debug.report; wait_for 3 test -s "$WORK/report.txt"; cat "$WORK/report.txt"; }
ready() { report | grep -q "status="; }
audit_has() { grep -q "$1" "$WORK/audit.jsonl" 2>/dev/null; }

run_command() { # run_command <text>
    printf '%s' "$1" >"$WORK/command.txt"
    notifyutil -p com.rohitsainier.voxa.debug.ask
}

exercise() { # exercise <provider-label> <settings-json> <expected mock dialect> <expected model>
    local label="$1" json="$2" dialect="$3" model="$4"
    log "$label"
    : >"$WORK/requests.jsonl"
    write_settings "$json"
    launch

    check "the app reports the chosen provider" "$(report | grep -q "provider=$5" && echo 0 || echo 1)"

    run_command "add numbers"
    wait_for 15 audit_has '"outcome":"confirm"' || true
    check "a state-changing action waits for confirmation" "$(audit_has confirm && echo 0 || echo 1)"
    # The card ignores presses for a moment after it appears, so a stray key can't approve it; wait that out.
    wait_for 10 grep -q 'awaiting=true' <(report) || true
    sleep 1
    notifyutil -p com.rohitsainier.voxa.debug.button.allow
    wait_for 15 audit_has '"kind":"reply"' || true
    check "approving lets it run and the command completes" "$(audit_has '"kind":"reply"' && echo 0 || echo 1)"
    check "the audit trail records the approval" "$(audit_has approved && echo 0 || echo 1)"

    local seen
    seen="$(python3 - "$WORK/requests.jsonl" "$dialect" "$model" <<'PY'
import json, sys
path, dialect, model = sys.argv[1:4]
rows = [json.loads(l) for l in open(path) if l.strip()]
ok = bool(rows) and all(r.get("dialect") == dialect and r.get("valid") and r.get("model") == model for r in rows)
print("ok" if ok else "bad: %s" % [(r.get("dialect"), r.get("valid"), r.get("problem"), r.get("model")) for r in rows])
PY
)"
    check "every request was a valid $dialect request for $model ($seen)" "$([[ "$seen" == ok ]] && echo 0 || echo 1)"
}

BASE="http://127.0.0.1:$PORT"
exercise "Claude" '{"localeIdentifier":"en_US"}' anthropic claude-sonnet-5-5 anthropic
exercise "OpenAI" "{\"localeIdentifier\":\"en_US\",\"provider\":\"openAI\",\"openAIBaseURL\":\"$BASE/v1\"}" openai gpt-6-luna openAI
exercise "Ollama" "{\"localeIdentifier\":\"en_US\",\"provider\":\"ollama\",\"ollamaModel\":\"qwen3:8b\",\"ollamaBaseURL\":\"$BASE\"}" ollama qwen3:8b ollama

echo
if [[ $FAILURES -eq 0 ]]; then log "All provider checks passed"; else die "$FAILURES check(s) failed"; fi
