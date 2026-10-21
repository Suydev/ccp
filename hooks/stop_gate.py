#!/usr/bin/env python3
"""CCP stop gate — the Stop hook that keeps a session alive.

Behaviour is driven by $CCP_HOME/stop-mode:
  off   -> exit 0 silently; turns end normally (default)
  ask   -> block the turn end and tell the model to ask the user
  exit  -> exit 0 silently; the session may end

In `ask` mode the gate blocks **unlimited** times. Claude Code's own limit is
`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` (default 8); the installer sets that env var
to 0, which Claude Code reads as "no cap" (`if (cap > 0 && count > cap)`).
This module's own MAX_BLOCKS is a secondary, optional ceiling: 0 means
unlimited, which is the default.

The block reason is deliberately short. Claude Code renders a long reason as a
"Stop hook blocking error", which looks like a failure rather than a prompt.
"""
import json
import os
import sys

STATE = os.environ.get("CCP_HOME") or os.path.join(os.environ.get("HOME", "/"), ".ccp")
MODE_FILE = os.path.join(STATE, "stop-mode")
COUNTER = os.path.join(STATE, "stop-count")

# 0 = unlimited. Set a number to impose a ceiling of your own.
MAX_BLOCKS = 0

REASON = (
    "ccp: the user wants this session to keep going. Do NOT end your turn "
    "and do NOT just continue the work silently. You MUST call the "
    "AskUserQuestion tool right now (if it is not in your tool list, use "
    "ToolSearch with query 'select:AskUserQuestion' to load it first), "
    "asking the user to choose 'continue', 'new task', or 'exit'. Ask this "
    "question on EVERY turn end (every time you see this reason, ask again) "
    "until the user picks exit; when they pick exit, tell them to run "
    "/ccp exit so the session can end."
)


def read_mode():
    try:
        with open(MODE_FILE) as f:
            m = f.read().strip()
    except OSError:
        return "off"
    return m if m in ("off", "ask", "exit") else "off"


def read_count():
    try:
        return int(open(COUNTER).read().strip() or 0)
    except (OSError, ValueError):
        return 0


def bump_count():
    n = read_count() + 1
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(COUNTER, "w") as f:
            f.write(str(n))
    except OSError:
        pass
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
    if not isinstance(payload, dict):
        payload = {}
    # stop_hook_active=True means this stop is the result of a previous
    # block, so it counts toward any ceiling we impose.
    stop_hook_active = bool(payload.get("stop_hook_active"))

    if read_mode() != "ask":
        reset_count()
        sys.exit(0)

    n = bump_count()
    if MAX_BLOCKS and stop_hook_active and n > MAX_BLOCKS:
        # Only reached when a finite ceiling is configured. With the default
        # (0 = unlimited) this never fires: the loop must not truncate
        # itself just because the user is taking a while.
        reset_count()
        sys.exit(0)

    counter = f"(block {n})" if not MAX_BLOCKS else f"(block {n}/{MAX_BLOCKS})"
    # `continue: false` + `stopReason` is the current contract. The legacy
    # `{"decision": "block"}` shape is still honoured by the CLI, but it is
    # rendered as "Stop hook blocking error", which reads like a crash. The
    # modern shape renders as "Stop hook feedback" — a normal-looking note.
    sys.stdout.write(json.dumps({
        "continue": False,
        "stopReason": f"{REASON} {counter}",
        "systemMessage": f"ccp: waiting for you — {counter}",
        "suppressOutput": True,
    }))
    sys.exit(0)


if __name__ == "__main__":
    main()
