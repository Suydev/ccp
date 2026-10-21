#!/data/data/com.termux/files/usr/bin/bash
# End-to-end test: headless claude run with the CCP hooks wired through a
# settings file. Asserts:
#   - run exits 0
#   - no "Hook cancelled" / hook timeout lines
#   - sessions.jsonl got a start and an end record for the run
#   - stop-mode=off lets the turn end normally
# Requires: claude on PATH (a configured gateway or real API).
set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CCP_T="$(mktemp -d)" || CCP_T="${TMPDIR:-/tmp}/ccp-e2e-$$"
export CCP_HOME="$CCP_T"
printf 'off' > "$CCP_T/stop-mode"

SET_JSON="$CCP_T/settings.json"
cat > "$SET_JSON" <<EOF
{
  "hooks": {
    "SessionStart": [ { "hooks": [ { "type": "command", "command": "CCP_HOME=$CCP_T bash $ROOT/hooks/session_bookend.sh start", "timeout": 20 } ] } ],
    "SessionEnd":   [ { "hooks": [ { "type": "command", "command": "CCP_HOME=$CCP_T bash $ROOT/hooks/session_bookend.sh end", "timeout": 20 } ] } ],
    "Stop":         [ { "hooks": [ { "type": "command", "command": "CCP_HOME=$CCP_T python3 $ROOT/hooks/stop_gate.py", "timeout": 20 } ] } ]
  }
}
EOF

OUT="$CCP_T/run.out"
timeout 500 claude --settings "$SET_JSON" -p "Reply with exactly: DONE" > "$OUT" 2>&1
rc=$?

check() {
  if eval "$2"; then PASS=$((PASS+1)); echo "ok   - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1: $3"; fi
}

check "claude exits 0" "[ $rc -eq 0 ]" "rc=$rc, output: $(tail -5 "$OUT")"
check "DONE in output" "command grep -q DONE '$OUT'" "$(cat "$OUT")"
check "no hook cancelled" "! command grep -qi 'hook cancelled\|timed out after' '$OUT'" "$(command grep -i 'hook\|timeout' "$OUT" | head -3)"
check "session start recorded" "command grep -q '\"event\":\"start\"' '$CCP_T/sessions.jsonl'" "sessions.jsonl: $(cat "$CCP_T/sessions.jsonl" 2>/dev/null)"
check "session end recorded" "command grep -q '\"event\":\"end\"' '$CCP_T/sessions.jsonl'" "sessions.jsonl: $(cat "$CCP_T/sessions.jsonl" 2>/dev/null)"

echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
