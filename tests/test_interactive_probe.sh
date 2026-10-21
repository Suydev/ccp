#!/data/data/com.termux/files/usr/bin/bash
# Interactive-mode probe. Needs a real terminal: drives claude through a pty
# and checks that the ask-gate blocks and the reason reaches the model.
#
# Not part of CI (no pty, no human). Run it on the device:
#   bash tests/test_interactive_probe.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1${2:+ :: $2}"; }

TMP="$(mktemp -d)"; export CCP_HOME="$TMP"
printf 'ask' > "$TMP/stop-mode"

python3 - "$ROOT" "$TMP" <<'PY'
import os, pty, select, subprocess, sys, time
root, tmp = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(os.path.expanduser("~"))
    os.environ["CCP_HOME"] = tmp
    os.execvp("claude", ["claude", "-p", "Say PROBE-HELLO only."])
out = b""
t0 = time.time()
while time.time() - t0 < 180:
    r, _, _ = select.select([fd], [], [], 1)
    if r:
        try:
            d = os.read(fd, 65536)
        except OSError:
            break
        if not d:
            break
        out += d
    if b"AskUserQuestion" in out or b"ccp:" in out:
        break
text = out.decode("utf-8", "replace")
if "AskUserQuestion" in text:
    print("ok   - model reached AskUserQuestion")
    open(os.path.join(tmp, "PASS"), "w").write("1")
else:
    print("FAIL - model never reached AskUserQuestion")
    open(os.path.join(tmp, "PASS"), "w").write("0")
PY

[ "$(cat "$TMP/PASS" 2>/dev/null)" = "1" ] && ok "ask-gate reaches the model" || bad "ask-gate reaches the model"
count=$(cat "$TMP/stop-count" 2>/dev/null || echo 0)
[ "$count" -ge 1 ] && ok "stop gate blocked ($count)" || bad "stop gate blocked" "count=$count"
rm -rf "$TMP"
echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
