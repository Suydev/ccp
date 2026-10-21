#!/data/data/com.termux/files/usr/bin/bash
# ccp e2e — the layers that need no Claude session. Runs anywhere (CI included).
#
#   3. stop gate        -> blocks in ask mode, silent in off/exit
#   4. session bookend  -> start/end records land in sessions.jsonl
#   5. dashboard API    -> state roundtrip, mode whitelist, 404, query strings
#   6. web terminal     -> ttyd serves and a websocket upgrades
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1${2:+ :: $2}"; }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1" "condition failed: $2"; fi; }

export CCP_HOME="$WORK"

echo "== stop gate =="
GATE="$ROOT/hooks/stop_gate.py"
printf 'ask' > "$WORK/stop-mode"
out=$(printf '{"stop_hook_active":false}' | python3 "$GATE" 2>/dev/null)
chk "ask mode blocks"          "printf '%s' \"\$out\" | command grep -q '\"continue\": false'"
chk "ask mode has stopReason" "printf '%s' \"\$out\" | command grep -q '\"stopReason\"'"
printf 'off' > "$WORK/stop-mode"
out=$(printf '{}' | python3 "$GATE" 2>/dev/null)
chk "off mode silent"         "[ -z \"\$out\" ]"
printf 'exit' > "$WORK/stop-mode"
out=$(printf '{}' | python3 "$GATE" 2>/dev/null)
chk "exit mode silent"        "[ -z \"\$out\" ]"
rm -f "$WORK/stop-mode"
out=$(printf '{}' | python3 "$GATE" 2>/dev/null)
chk "missing mode file -> off" "[ -z \"\$out\" ]"

echo "== session bookend =="
printf '{"session_id":"e2e-1","cwd":"/tmp"}' | bash "$ROOT/hooks/session_bookend.sh" start
printf '{"session_id":"e2e-1","cwd":"/tmp","reason":"other"}' | bash "$ROOT/hooks/session_bookend.sh" end
chk "start record written"     "command grep -q '\"event\":\"start\"' '$WORK/sessions.jsonl'"
chk "end record written"       "command grep -q '\"event\":\"end\"' '$WORK/sessions.jsonl'"
chk "records are valid json"   "jq -e . '$WORK/sessions.jsonl'"

echo "== dashboard API =="
printf 'ask' > "$WORK/stop-mode"; echo 3 > "$WORK/stop-count"
PORT=$((8790 + RANDOM % 40))
CCP_PORT=$PORT python3 "$ROOT/scripts/ccp-server.py" > "$WORK/srv.log" 2>&1 &
SRV=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sf "http://127.0.0.1:$PORT/api/state" >/dev/null 2>&1 && break
  sleep 1
done
chk "state reports mode"       "curl -sf http://127.0.0.1:$PORT/api/state | jq -e '.mode == \"ask\"'"
chk "state reports count"      "curl -sf http://127.0.0.1:$PORT/api/state | jq -e '.stop_count == 3'"
chk "mode change via POST"     "curl -sf -X POST -d '{\"mode\":\"exit\"}' http://127.0.0.1:$PORT/api/mode | jq -e '.mode == \"exit\"'"
chk "file reflects POST"       "[ \"\$(cat '$WORK/stop-mode')\" = exit ]"
chk "invalid mode rejected"    "curl -s -X POST -d '{\"mode\":\"<script>\"}' http://127.0.0.1:$PORT/api/mode | command grep -q error"
chk "unknown path 404s"        "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/nope)\" = 404 ]"
chk "query string served"      "curl -sf 'http://127.0.0.1:$PORT/?cb=1' | command grep -q 'ccp control plane'"
chk "page renders"             "curl -sf http://127.0.0.1:$PORT/ | command grep -q 'ccp control plane'"
kill $SRV 2>/dev/null

echo "== web terminal (ttyd) =="
if command -v ttyd >/dev/null 2>&1; then
  TPORT=$((8840 + RANDOM % 40))
  ttyd -p "$TPORT" -W bash -lc 'true' > "$WORK/ttyd.log" 2>&1 &
  TT=$!
  for _ in 1 2 3 4 5; do curl -sf -o /dev/null "http://127.0.0.1:$TPORT/" && break; sleep 1; done
  chk "ttyd serves http"       "curl -sf -o /dev/null http://127.0.0.1:$TPORT/"
  chk "websocket upgrades"      "curl -s -i -N -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' http://127.0.0.1:$TPORT/ws 2>/dev/null | command grep -q '101 Switching Protocols'"
  kill $TT 2>/dev/null
else
  echo "skip - ttyd not installed"
fi

echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
