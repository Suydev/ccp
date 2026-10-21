#!/data/data/com.termux/files/usr/bin/python3
"""ccp — the Claude Code control plane helper behind the /ccp slash command.

One deterministic entry point. No model reasoning, no extra tokens: the slash
command runs this and prints whatever comes out.

Subcommands:
  (none) | status   mode, block count, supervisor state, recent sessions
  ask | off | exit  set the stop-gate mode
  reset             zero the stop-block counter
  steer <text>      deliver an instruction to a RUNNING session, without
                    stopping it
  steer --file PATH deliver a file's contents
  steer --list      show queued / already-sent steering messages
  steer --clear     drop the steering queue
  help              this text
"""
import json
import os
import subprocess
import sys
import time

STATE = os.environ.get("CCP_HOME") or os.path.join(os.environ.get("HOME", "/"), ".ccp")
MODES = ("off", "ask", "exit")
# The steer helper lives next to this script when deployed standalone
# (~/.claude/ccp/), and in ../hooks when run from a repo checkout.
def _find_helper(name):
    here = os.path.dirname(os.path.abspath(__file__))
    for cand in (os.path.join(here, name),
                 os.path.join(here, "..", "hooks", name)):
        if os.path.exists(cand):
            return cand
    return os.path.join(here, name)


def read(path, default=""):
    try:
        with open(path, errors="replace") as f:
            return f.read().strip()
    except OSError:
        return default


def mode():
    m = read(os.path.join(STATE, "stop-mode"), "off")
    return m if m in MODES else "off"


def count():
    try:
        return int(read(os.path.join(STATE, "stop-count"), "0") or 0)
    except ValueError:
        return 0


def sessions(n=5):
    out = []
    for line in read(os.path.join(STATE, "sessions.jsonl")).splitlines():
        if line.strip():
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out[-n:]


def supervisor_alive():
    try:
        out = subprocess.run(
            ["pgrep", "-f", "ccp-supervisor"], capture_output=True, timeout=5
        )
        pids = [p for p in out.stdout.decode().split() if p.strip()]
        # pgrep can match its own invocation; require more than the caller
        return len(pids) > 1
    except Exception:
        return False


def status():
    lines = [
        f"ccp — stop-mode: {mode()} · blocks: {count()}",
        f"supervisor: {'running' if supervisor_alive() else 'not running'}",
        f"state: {STATE}",
        "",
        "modes:  /ccp ask    (ask you at every turn end: continue / new task / exit)",
        "        /ccp off    (turns end normally)",
        "        /ccp exit   (allow the session to end)",
        "        /ccp reset  (zero the block counter)",
        "        /ccp steer \"text\"  (redirect a RUNNING session without stopping it)",
    ]
    sess = sessions()
    if sess:
        lines.append("")
        lines.append("recent sessions:")
        for s in sess:
            lines.append(
                f"  {s.get('ts', '?')} {s.get('event', '?'):9s} "
                f"{str(s.get('session_id', ''))[:8]} {s.get('cwd', '')}"
            )
    fails = read(os.path.join(STATE, "failures.jsonl"))
    if fails:
        n = len([l for l in fails.splitlines() if l.strip()])
        lines.append(f"failed turns recorded: {n}")
    return "\n".join(lines)


def run_helper(script, args):
    path = _find_helper(script)
    if not os.path.exists(path):
        return None
    proc = subprocess.run(
        [sys.executable, path] + args, capture_output=True, timeout=30
    )
    return proc


def main():
    args = [a for a in sys.argv[1:]]
    if not args:
        print(status())
        return 0

    cmd = args[0].lower()
    rest = args[1:]

    if cmd in ("help", "-h", "--help"):
        print(__doc__.strip())
        return 0

    if cmd in ("status", "show"):
        print(status())
        return 0

    if cmd in MODES:
        prev = mode()
        try:
            os.makedirs(STATE, exist_ok=True)
            with open(os.path.join(STATE, "stop-mode"), "w") as f:
                f.write(cmd)
        except OSError as e:
            print(f"ccp: cannot write stop-mode: {e}", file=sys.stderr)
            return 1
        if prev == cmd:
            print(f"already {cmd}")
        else:
            note = ""
            if cmd == "ask":
                note = " — at your next turn end you will be asked: continue / new task / exit."
            elif cmd == "exit":
                note = " — the next turn is allowed to end; the supervisor (if running) stops."
            print(f"stop-mode: {prev} → {cmd}{note}")
        return 0

    if cmd == "reset":
        try:
            with open(os.path.join(STATE, "stop-count"), "w") as f:
                f.write("0")
        except OSError as e:
            print(f"ccp: cannot write stop-count: {e}", file=sys.stderr)
            return 1
        print("stop-count reset to 0")
        return 0

    if cmd == "steer":
        proc = run_helper("steer.py", args[1:])
        if proc is None:
            print(f"ccp: steer helper not found at {_find_helper('steer.py')}",
                  file=sys.stderr)
            return 1
        sys.stdout.write(proc.stdout.decode(errors="replace"))
        sys.stderr.write(proc.stderr.decode(errors="replace"))
        return proc.returncode

    print(f"ccp: unknown argument '{cmd}'", file=sys.stderr)
    print(status(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
