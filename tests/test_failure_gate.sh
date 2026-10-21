#!/data/data/com.termux/files/usr/bin/bash
# Unit tests for the StopFailure handler. No claude needed.
set -u
PASS=0; FAIL=0
HOOKS_DIR="$(cd "$(dirname "$0")/../hooks" && pwd)"
GATE="$HOOKS_DIR/failure_gate.py"
S="$(mktemp -d)"; export CCP_HOME="$S"
export CCP_NOTIFY=0   # no phone buzz in tests

t() { # t name expect-substr payload
  local name="$1" want="$2" payload="$3"
  local out; out=$(printf '%s' "$payload" | python3 "$GATE" 2>/dev/null)
  if printf '%s' "$out" | command grep -qF -- "$want"; then
    PASS=$((PASS+1)); echo "ok   - $name"
  else
    FAIL=$((FAIL+1)); echo "FAIL - $name: got [$out] want [$want]"
  fi
}

t "api 400 error"      "400 Bad Request"  '{"hook_event_name":"StopFailure","error":{"type":"api_error","message":"400 Bad Request: invalid model"}}'
t "429 rate limit"     "429"              '{"hook_event_name":"StopFailure","error":{"status":429,"message":"rate limited"}}'
t "blocked egress"     "blocked egress"   '{"hook_event_name":"StopFailure","error":"connection refused: blocked egress"}'
t "firewall refusal"   "firewall"         '{"hook_event_name":"StopFailure","error":"firewall denied the request"}'
t "timeout"            "timeout"          '{"hook_event_name":"StopFailure","error":{"type":"timeout","message":"request timeout"}}'
t "error_details only" "429"              '{"hook_event_name":"StopFailure","error_details":{"status":429}}'
t "unknown error"      "unknown error"    '{}'
t "garbage stdin"      "unknown error"    'not-json-at-all'
t "mentions resume"    "ccp start --resume" '{"error":"boom"}'

# every call must exit 0 — a failure handler that fails is worse than none
printf '{"error":"x"}' | python3 "$GATE" >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && { PASS=$((PASS+1)); echo "ok   - always exits 0"; } || { FAIL=$((FAIL+1)); echo "FAIL - exit code $rc"; }

# records
chk() { if eval "$2" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi; }
chk "failures.jsonl written"   "[ -s '$S/failures.jsonl' ]"
chk "failure record is json"   "jq -e . '$S/failures.jsonl'"
chk "failure-count incremented" "[ \"\$(cat '$S/failure-count')\" -ge 1 ]"
chk "summary stored"           "jq -e '.summary | length > 0' '$S/failures.jsonl'"

rm -rf "$S"
echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
