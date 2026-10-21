#!/data/data/com.termux/files/usr/bin/bash
# Unit tests for steering: queueing, listing, clearing, and the drain.
set -u
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$(mktemp -d)"; export CCP_HOME="$S"
STEER="$ROOT/hooks/steer.py"
DRAIN="$ROOT/hooks/steer_drain.py"

ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1${2:+ :: $2}"; }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1" "condition failed: $2"; fi; }

# 1. queueing without a live session
out=$(python3 "$STEER" "do the other thing" 2>&1)
chk "message queued" "ls '$S/steer-queue' | command grep -q '\\.txt$'"
chk "queued file has the text" "command grep -q 'do the other thing' '$S'/steer-queue/*.txt"

# 2. listing shows the queue
out=$(python3 "$STEER" --list 2>&1)
chk "list shows the message" "printf '%s' \"\$out\" | command grep -q 'do the other thing'"

# 3. drain injects it and marks it sent
out=$(printf '{"session_id":"s1"}' | python3 "$DRAIN" 2>&1)
chk "drain injects the message" "printf '%s' \"\$out\" | command grep -q 'do the other thing'"
chk "drain marks it sent" "[ -f \"\$S/steer-sent/\"*.sent ]"

# 4. drain is idempotent: a second drain does not repeat it
out=$(printf '{"session_id":"s1"}' | python3 "$DRAIN" 2>&1)
chk "drain does not repeat" "[ -z \"\$out\" ]"

# 5. clear empties the queue
python3 "$STEER" "another one" >/dev/null 2>&1
out=$(python3 "$STEER" --clear 2>&1)
chk "clear empties the queue" "[ -z \"\$(ls '$S/steer-queue'/*.txt 2>/dev/null)\" ]"

# 6. empty message rejected
out=$(python3 "$STEER" "   " 2>&1); rc=$?
[ "$rc" = "2" ] && ok "empty message rejected" || bad "empty message rejected" "rc=$rc"

# 7. --file reads a file
printf 'instructions from a file\n' > "$S/note.md"
python3 "$STEER" --file "$S/note.md" >/dev/null 2>&1
chk "file message queued" "command grep -q 'instructions from a file' '$S'/steer-queue/*.txt 2>/dev/null || command grep -rq 'instructions from a file' '$S/steer-queue'"

# 8. missing file is an error, not a crash
out=$(python3 "$STEER" --file "$S/nope.md" 2>&1); rc=$?
[ "$rc" = "2" ] && ok "missing file exits 2" || bad "missing file exits 2" "rc=$rc"

rm -rf "$S"
echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
