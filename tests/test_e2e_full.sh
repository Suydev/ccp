#!/data/data/com.termux/files/usr/bin/bash
# ccp end-to-end suite. Exercises every layer against a REAL claude session.
#
#   1. /ccp slash command  -> card, mode switch, reset (in a real session)
#   2. Stop gate           -> blocks in ask mode, silent in off mode
#   3. Session bookend     -> start/end records land in sessions.jsonl
#   4. Plugin hooks        -> no "Hook cancelled" / timeouts in the output
#   5. Dashboard API       -> state roundtrip, mode whitelist, 404
#   6. Web terminal        -> ttyd serves and a websocket upgrades
#
# Env: CCP_E2E_TIMEOUT (default 300) seconds per claude invocation.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMO="${CCP_E2E_TIMEOUT:-300}"
PASS=0; FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# NEVER touch the user's live state: the state file the slash command reads
# is $CCP_HOME/stop-mode, so point the whole suite at a sandbox and restore
# the real CCP_HOME afterwards.
REAL_CCP_HOME="${CCP_HOME:-$HOME/.ccp}"
export CCP_HOME="$WORK/live"
mkdir -p "$CCP_HOME"
printf 'off' > "$CCP_HOME/stop-mode"

ok()   { PASS=$((PASS+1)); echo "ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL - $1${2:+ :: $2}"; }
chk()  { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1" "condition failed: $2"; fi; }

# Run claude headless with a given prompt, capture output.
run_claude() { # run_claude <outfile> <prompt> [extra args...]
  local out="$1" prompt="$2"; shift 2
  timeout "$TMO" claude -p "$prompt" "$@" > "$out" 2>&1
  echo $?
}

echo "== 1. slash command in a real session =="
rc=$(run_claude "$WORK/ccp_card.out" "/ccp")
chk "session exits 0"            "[ '$rc' = 0 ]"
chk "card rendered"               "command grep -q 'stop-mode:' '$WORK/ccp_card.out'"
chk "card lists modes"            "command grep -q '/ccp ask' '$WORK/ccp_card.out'"
chk "no hook errors"              "! command grep -qi 'hook cancelled\|timed out after' '$WORK/ccp_card.out'"

echo "== 2. mode switch through /ccp =="
printf 'off' > "$CCP_HOME/stop-mode"
rc=$(run_claude "$WORK/ccp_ask.out" "/ccp ask")
chk "session exits 0"            "[ '$rc' = 0 ]"
chk "mode file is now ask"       "[ \"\$(cat '$CCP_HOME/stop-mode')\" = ask ]"
rc=$(run_claude "$WORK/ccp_off.out" "/ccp off")
chk "mode file back to off"      "[ \"\$(cat '$CCP_HOME/stop-mode')\" = off ]"
rc=$(run_claude "$WORK/ccp_reset.out" "/ccp reset")
chk "reset reports 0"            "command grep -q 'reset to 0' '$WORK/ccp_reset.out'"

echo "== 3-6. gate, bookend, dashboard, ttyd (shared with the local suite) =="
if bash "$ROOT/tests/test_e2e_local.sh"; then
  ok "local e2e layers"
else
  bad "local e2e layers"
fi

export CCP_HOME="$REAL_CCP_HOME"
echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
