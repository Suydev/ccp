#!/data/data/com.termux/files/usr/bin/bash
# Unit tests for the ccp state helper (no claude needed).
set -u
PASS=0; FAIL=0
HELPER="$(cd "$(dirname "$0")/../mod/scripts" && pwd)/ccp_state.py"
S="$(mktemp -d)"; export CCP_HOME="$S"

chk() { # chk name expected-substr command...
  local name="$1" want="$2"; shift 2
  local out; out=$("$@" 2>&1)
  if printf '%s' "$out" | command grep -qF -- "$want"; then
    PASS=$((PASS+1)); echo "ok   - $name"
  else
    FAIL=$((FAIL+1)); echo "FAIL - $name: got [$out] want [$want]"
  fi
}

chk "card shows mode" "stop-mode: off" python3 "$HELPER" card
chk "bare ask sets mode" "off → ask" python3 "$HELPER" ask
[ "$(cat "$S/stop-mode")" = "ask" ] && { PASS=$((PASS+1)); echo "ok   - ask written to file"; } || { FAIL=$((FAIL+1)); echo "FAIL - ask not written"; }
chk "bare off sets mode" "ask → off" python3 "$HELPER" off
chk "set ask also works" "off → ask" python3 "$HELPER" set ask
chk "reset zeroes count" "reset to 0" python3 "$HELPER" reset
[ "$(cat "$S/stop-count" 2>/dev/null)" = "0" ] && { PASS=$((PASS+1)); echo "ok   - count file zeroed"; } || { FAIL=$((FAIL+1)); echo "FAIL - count not zeroed"; }
chk "status is json" '"mode"' python3 "$HELPER" status
out=$(python3 "$HELPER" bogus 2>&1); rc=$?
[ "$rc" = "2" ] && { PASS=$((PASS+1)); echo "ok   - unknown command exits 2"; } || { FAIL=$((FAIL+1)); echo "FAIL - unknown command rc=$rc"; }
out=$(python3 "$HELPER" card 2>&1); printf '%s' "$out" | command grep -q 'modes:' && { PASS=$((PASS+1)); echo "ok   - card lists modes"; } || { FAIL=$((FAIL+1)); echo "FAIL - card missing modes"; }

rm -rf "$S"
echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
