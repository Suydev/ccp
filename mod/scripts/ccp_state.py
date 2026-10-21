#!/usr/bin/env python3
"""ccp state helper for the Claude Code mod.

One process, one subcommand; prints text for the mod to show verbatim.
Reads/writes the same $CCP_HOME files the hooks use. Never shells out.

  status                JSON {mode, count, sessions:[last 5]}
  card                  human status card (the /ccp default view)
  set <mode>            write stop-mode; prints the transition line
  reset                 zero stop-count
"""
import json
import os
import sys

STATE = os.environ.get("CCP_HOME") or os.path.join(os.environ.get("HOME", "/"), ".ccp")
MODES = ("off", "ask", "exit")
MAX_BLOCKS = 7


def read_mode():
    try:
        with open(os.path.join(STATE, "stop-mode")) as f:
            m = f.read().strip()
        return m if m in MODES else "off"
    except OSError:
        return "off"


def read_count():
    try:
        return int(open(os.path.join(STATE, "stop-count")).read().strip() or 0)
    except (OSError, ValueError):
        return 0


def write_text(name, text):
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, name), "w") as f:
        f.write(text)


def tail_sessions(n=5):
    try:
        with open(os.path.join(STATE, "sessions.jsonl")) as f:
            return [l for l in f.read().splitlines() if l.strip()][-n:]
    except OSError:
        return []


def card():
    mode = read_mode()
    count = read_count()
    lines = [
        f"ccp — stop-mode: {mode} · stop-count: {count}/{MAX_BLOCKS}",
        "",
        "modes:  /ccp off   (turns end normally)",
        "        /ccp ask   (Claude must ask: continue / new task / exit)",
        "        /ccp exit  (allow the session to end)",
        "        /ccp reset (zero the block counter)",
        "",
    ]
    sessions = tail_sessions()
    if sessions:
        lines.append("recent sessions:")
        lines.extend(f"  {s}" for s in sessions)
    else:
        lines.append("no sessions recorded yet")
    return "\n".join(lines)


def set_mode(mode):
    prev = read_mode()
    write_text("stop-mode", mode)
    if mode == prev:
        return f"already {mode}"
    note = ""
    if mode == "ask":
        note = " — at your next turn end, Claude will ask: continue / new task / exit."
    elif mode == "exit":
        note = " — the next turn is allowed to end; the supervisor loop (if running) will stop."
    return f"stop-mode: {prev} → {mode}{note}"


def main():
    args = sys.argv[1:]
    if not args:
        print(card())
        return
    cmd, rest = args[0], args[1:]
    if cmd == "status":
        print(json.dumps({
            "mode": read_mode(),
            "count": read_count(),
            "sessions": tail_sessions(),
        }))
    elif cmd == "card":
        print(card())
    elif cmd == "set" and rest and rest[0] in MODES:
        print(set_mode(rest[0]))
    elif cmd == "reset":
        write_text("stop-count", "0")
        print("stop-count reset to 0")
    else:
        print(f"ccp_state: unknown command {cmd!r}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
