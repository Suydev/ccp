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

echo "== 3. stop gate behaviour =="
GATE="$ROOT/hooks/stop_gate.py"
printf 'ask' > "$WORK/mode"; export CCP_HOME="$WORK"
out=$(printf '{"stop_hook_active":false}' | python3 "$GATE" 2>/dev/null)
chk "ask mode blocks"            "printf '%s' \"\$out\" | command grep -q '\"decision\": \"block\"'"
printf 'off' > "$WORK/mode"
out=$(printf '{}' | python3 "$GATE" 2>/dev/null)
chk "off mode silent"            "[ -z \"\$out\" ]"
printf 'exit' > "$WORK/mode"
out=$(printf '{}' | python3 "$GATE" 2>/dev/null)
chk "exit mode silent"           "[ -z \"\$out\" ]"
unset CCP_HOME

echo "== 4. session bookend =="
export CCP_HOME="$WORK"
printf '{"session_id":"e2e-1","cwd":"/tmp"}' | bash "$ROOT/hooks/session_bookend.sh" start
printf '{"session_id":"e2e-1","cwd":"/tmp","reason":"other"}' | bash "$ROOT/hooks/session_bookend.sh" end
chk "start record written"        "command grep -q '\"event\":\"start\"' '$WORK/sessions.jsonl'"
chk "end record written"          "command grep -q '\"event\":\"end\"' '$WORK/sessions.jsonl'"
chk "records are valid json"      "jq -e . '$WORK/sessions.jsonl'"
unset CCP_HOME

echo "== 5. dashboard API =="
export CCP_HOME="$WORK"
printf 'ask' > "$WORK/mode"; echo 3 > "$WORK/stop-count"
CCP_PORT=8791 python3 "$ROOT/scripts/ccp-server.py" > "$WORK/srv.log" 2>&1 &
SRV=$!
for i in 1 2 3 4 5 6 7 8 9 10; do
  curl -sf http://127.0.0.1:8791/api/state >/dev/null 2>&1 && break
  sleep 1
done
chk "state reports mode"          "curl -sf http://127.0.0.1:8791/api/state | jq -e '.mode == \"ask\"'"
chk "state reports count"         "curl -sf http://127.0.0.1:8791/api/state | jq -e '.stop_count == 3'"
chk "mode change via POST"        "curl -sf -X POST -d '{\"mode\":\"exit\"}' http://127.0.0.1:8791/api/mode | jq -e '.mode == \"exit\"'"
chk "file reflects POST"          "[ \"\$(cat '$WORK/mode')\" = exit ]"
chk "invalid mode rejected"       "curl -s -X POST -d '{\"mode\":\"<script>\"}' http://127.0.0.1:8791/api/mode | command grep -q error"
chk "unknown path 404s"           "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8791/nope)\" = 404 ]"
chk "query string served"         "curl -sf 'http://127.0.0.1:8791/?cb=1' | command grep -q 'ccp control plane'"
chk "page renders"                "curl -sf http://127.0.0.1:8791/ | command grep -q 'ccp control plane'"
kill $SRV 2>/dev/null
unset CCP_HOME

echo "== 6. web terminal (ttyd) =="
if command -v ttyd >/dev/null 2>&1; then
  ttyd -p 8792 -W bash -lc 'true' > "$WORK/ttyd.log" 2>&1 &
  TT=$!
  for i in 1 2 3 4 5; do curl -sf -o /dev/null http://127.0.0.1:8792/ && break; sleep 1; done
  chk "ttyd serves http"          "curl -sf -o /dev/null http://127.0.0.1:8792/"
  chk "websocket upgrades"         "curl -s -i -N -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' http://127.0.0.1:8792/ws 2>/dev/null | command grep -q '101 Switching Protocols'"
  kill $TT 2>/dev/null
else
  echo "skip - ttyd not installed"
fi

export CCP_HOME="$REAL_CCP_HOME"
echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
