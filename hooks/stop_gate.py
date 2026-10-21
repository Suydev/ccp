#!/data/data/com.termux/files/usr/bin/python3
"""CCP Stop gate. Small, fast (python boots in ~0.2s here; node takes 1.8-8.2s).

Reads the Stop hook payload on stdin. Decides based on $HOME/.ccp/stop-mode:
  off   -> exit 0 silently (turn ends normally)
  ask   -> block once per stop-cap window, telling Claude to ask the user
  exit  -> exit 0 silently (user chose to leave; let the session end)

The ask path uses the standard Stop-hook block contract:
  {"decision": "block", "reason": "..."}
Claude Code caps consecutive Stop blocks at 8 (CLAUDE_CODE_STOP_HOOK_BLOCK_CAP
can raise it); we count our own blocks and yield before the cap so the cap
never truncates the loop in a confusing way.
"""
import json
import os
import sys

STATE = os.environ.get("CCP_HOME") or os.path.join(os.environ.get("HOME", "/"), ".ccp")
MODE_FILE = os.path.join(STATE, "stop-mode")
COUNTER = os.path.join(STATE, "stop-count")
MAX_BLOCKS = 7  # yield one before Claude Code's own cap of 8


def read_mode():
    try:
        with open(MODE_FILE) as f:
            m = f.read().strip()
    except OSError:
        return "off"
    return m if m in ("off", "ask", "exit") else "off"


def bump_count():
    try:
        n = int(open(COUNTER).read().strip() or 0)
    except (OSError, ValueError):
        n = 0
    n += 1
    with open(COUNTER, "w") as f:
        f.write(str(n))
    return n


def reset_count():
    try:
        with open(COUNTER, "w") as f:
            f.write("0")
    except OSError:
        pass


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}
    # stop_hook_active=True means this stop is itself the result of a
    # previous block; still counts toward our own limit.
    stop_hook_active = bool(payload.get("stop_hook_active"))

    mode = read_mode()
    if mode != "ask":
        reset_count()
        sys.exit(0)

    n = bump_count()
    if stop_hook_active and n > MAX_BLOCKS:
        # yield before Claude Code's own 8-block cap
        reset_count()
        sys.exit(0)

    sys.stdout.write(json.dumps({
        "decision": "block",
        "reason": (
            "CCP stop gate: the user wants the session to keep going. "
            "Ask the user what to do next with AskUserQuestion: "
            "'continue', 'new task', or 'exit'. "
            "If the user picks exit, tell them to run /ccp exit — that "
            "allows the next stop to end the session. "
            f"(ccp block {n}/{MAX_BLOCKS})"
        ),
    }))
    sys.exit(0)


if __name__ == "__main__":
    main()
