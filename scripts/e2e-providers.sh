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
source "$(dirname "${BASH_SOURCE[0]}")/lib/e2e.sh"

exercise() { # exercise <label> <settings-json> <expected mock dialect> <expected model> <expected provider in the report>
    local label="$1" json="$2" dialect="$3" model="$4" provider="$5"
    log "$label"
    : >"$WORK/requests.jsonl"
    write_settings "$json"
    launch

    check "the app reports the chosen provider" "$(report_has "provider=$provider" && echo 0 || echo 1)"

    ask "add numbers"
    check "a state-changing action waits for confirmation" "$(audit_has "$MARK" policyDecision run_applescript confirm && echo 0 || echo 1)"
    answer allow
    check "approving lets it run and the command completes" "$(audit_has "$MARK" reply && echo 0 || echo 1)"
    check "the audit trail records the approval" "$(audit_has "$MARK" confirmation run_applescript approved && echo 0 || echo 1)"

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

e2e_init
BASE="http://127.0.0.1:$PORT"
exercise "Claude" '{"localeIdentifier":"en_US","onboardingCompleted":true}' anthropic claude-sonnet-5-5 anthropic
exercise "OpenAI" "{\"localeIdentifier\":\"en_US\",\"onboardingCompleted\":true,\"provider\":\"openAI\",\"openAIBaseURL\":\"$BASE/v1\"}" openai gpt-6-luna openAI
exercise "Ollama" "{\"localeIdentifier\":\"en_US\",\"onboardingCompleted\":true,\"provider\":\"ollama\",\"ollamaModel\":\"qwen3:8b\",\"ollamaBaseURL\":\"$BASE\"}" ollama qwen3:8b ollama
e2e_finish
