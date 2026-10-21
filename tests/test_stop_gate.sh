#!/data/data/com.termux/files/usr/bin/bash
# Unit tests for stop_gate.py. Runs without claude.
set -u
PASS=0; FAIL=0
HOOKS_DIR="$(cd "$(dirname "$0")/../hooks" && pwd)"
TMP="$(mktemp -d)" || TMP="${TMPDIR:-/tmp}/ccp-test-$$"
export CCP_HOME="$TMP"

t() { # t <name> <expected-substring> <payload>
  local name="$1" want="$2" payload="$3" out
  out=$(printf '%s' "$payload" | python3 "$HOOKS_DIR/stop_gate.py" 2>/dev/null)
  if [ -z "$want" ]; then
    if [ -z "$out" ]; then PASS=$((PASS+1)); echo "ok   - $name"
    else FAIL=$((FAIL+1)); echo "FAIL - $name: expected silence, got [$out]"; fi
  elif printf '%s' "$out" | command grep -q "$want"; then
    PASS=$((PASS+1)); echo "ok   - $name"
  else
    FAIL=$((FAIL+1)); echo "FAIL - $name: got [$out] want substring [$want]"
  fi
}

# mode off: no output
printf 'off' > "$TMP/stop-mode"
t "mode off -> silent" "" '{}'

# mode exit: no output
printf 'exit' > "$TMP/stop-mode"
t "mode exit -> silent" "" '{}'

# mode ask: blocks with reason
printf 'ask' > "$TMP/stop-mode"
rm -f "$TMP/stop-count"
t "mode ask -> blocks" '"continue": false' '{}'
t "mode ask -> has stopReason" '"stopReason"' '{}'
t "mode ask -> has reason" 'AskUserQuestion' '{}'
t "mode ask -> reason says ask every time" 'EVERY turn end' '{}'

# unlimited: every consecutive stop must still block (no self-truncation)
n_blocked=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  o=$(printf '%s' '{"stop_hook_active": true}' | python3 "$HOOKS_DIR/stop_gate.py" 2>/dev/null)
  case "$o" in *'"continue": false'*) n_blocked=$((n_blocked + 1));; esac
done
if [ "$n_blocked" = "20" ]; then
  PASS=$((PASS+1)); echo "ok   - 20 consecutive blocks all block (unlimited)"
else
  FAIL=$((FAIL+1)); echo "FAIL - 20 consecutive blocks all block (unlimited): only $n_blocked blocked"
fi

# invalid json -> treated as empty payload: mode ask still applies, no crash
printf 'ask' > "$TMP/stop-mode"
rm -f "$TMP/stop-count"
t "invalid json -> mode ask still blocks" '"continue": false' 'not-json{{'
printf 'off' > "$TMP/stop-mode"

echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
