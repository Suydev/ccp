#!/data/data/com.termux/files/usr/bin/bash
# Unit tests for the /ccp helper (bin/ccp.py) — what the slash command runs.
set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/bin/ccp.py"
S="$(mktemp -d)"; export CCP_HOME="$S"

ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1${2:+ :: $2}"; }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1" "condition failed: $2"; fi; }

out=$(python3 "$HELPER" 2>&1)
chk "status shows mode"   "printf '%s' \"\$out\" | command grep -q 'stop-mode: off'"
chk "status lists modes"  "printf '%s' \"\$out\" | command grep -q '/ccp ask'"
chk "status mentions steer" "printf '%s' \"\$out\" | command grep -q '/ccp steer'"

out=$(python3 "$HELPER" ask 2>&1)
chk "ask sets the mode"   "[ \"\$(cat '$S/stop-mode')\" = ask ]"
chk "ask reports the change" "printf '%s' \"\$out\" | command grep -q 'off → ask'"

out=$(python3 "$HELPER" off 2>&1)
chk "off sets the mode"   "[ \"\$(cat '$S/stop-mode')\" = off ]"
out=$(python3 "$HELPER" exit 2>&1)
chk "exit sets the mode"  "[ \"\$(cat '$S/stop-mode')\" = exit ]"

printf '7' > "$S/stop-count"
out=$(python3 "$HELPER" reset 2>&1)
chk "reset zeroes the count" "[ \"\$(cat '$S/stop-count')\" = 0 ]"
chk "reset says so"         "printf '%s' \"\$out\" | command grep -q 'reset to 0'"

out=$(python3 "$HELPER" frobnicate 2>&1); rc=$?
[ "$rc" = "2" ] && ok "unknown argument exits 2" || bad "unknown argument exits 2" "rc=$rc"

out=$(python3 "$HELPER" steer --list 2>&1)
chk "steer --list works" "printf '%s' \"\$out\" | command grep -q 'queued'"

# the helper must not print a vvp anywhere
out=$(python3 "$HELPER" 2>&1)
case "$out" in *vvp*) bad "no vvp leftovers";; *) ok "no vvp leftovers";; esac

rm -rf "$S"
echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
