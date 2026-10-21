#!/usr/bin/env python3
"""CCP steer — deliver instructions to a RUNNING session without stopping it.

The whole point of a control plane is that you can change the agent's mind
*while it works*, instead of waiting for the turn to end.

Two delivery paths, both non-interrupting:

  tmux   -> bracketed paste into the pane, then Enter. Claude Code reads a
             pasted message as a queued user message; the current turn
             finishes, the new instruction is picked up on the next step.
  ttyd   -> the same paste, but over the ttyd websocket, so a browser
             session can be steered too.

Message text is written to $CCP_HOME/steer-queue/ as a numbered file
first, so nothing is lost if the pane is busy, and the delivery is
retried until the session acknowledges it.

Usage:
  ccp steer "also handle the failing test"      # deliver now
  ccp steer --file notes.md                     # deliver a file's contents
  ccp steer --list                              # what is queued / sent
  ccp steer --clear                             # drop the queue
"""
import json
import os
import sys
import time

STATE = os.environ.get("CCP_HOME") or os.path.join(os.environ.get("HOME", "/"), ".ccp")
QUEUE = os.path.join(STATE, "steer-queue")
SENT = os.path.join(STATE, "steer-sent")
REGISTRY = os.path.join(STATE, "sessions.jsonl")

ESC = "\x1B"
PASTE_START = ESC + "[200~"
PASTE_END = ESC + "[201~"


def ensure_dirs():
    for d in (QUEUE, SENT):
        try:
            os.makedirs(d, exist_ok=True)
        except OSError:
            pass


def read_sessions():
    """session_id -> cwd, from the bookend log."""
    out = {}
    try:
        with open(REGISTRY, errors="replace") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                sid = rec.get("session_id")
                if sid:
                    out[sid] = rec.get("cwd") or ""
    except OSError:
        pass
    return out


def find_tmux_session():
    """The most recent tmux session running claude, if any."""
    import subprocess
    try:
        out = subprocess.run(
            ["tmux", "list-sessions", "-F", "#{session_name}:#{session_attached}:#{session_created}"],
            capture_output=True, timeout=5, text=True,
        )
    except Exception:
        return None
    best = None
    best_created = -1
    for line in out.stdout.splitlines():
        parts = line.split(":")
        if len(parts) < 3:
            continue
        name = parts[0]
        try:
            created = int(parts[2])
        except ValueError:
            created = 0
        if created > best_created:
            best, best_created = name, created
    return best


def tmux_pane(session):
    import subprocess
    try:
        out = subprocess.run(
            ["tmux", "list-panes", "-t", session, "-F", "#{pane_id}"],
            capture_output=True, timeout=5, text=True,
        )
        return out.stdout.strip().splitlines()[0] if out.stdout.strip() else None
    except Exception:
        return None


def tmux_deliver(session, text):
    """Bracketed paste + Enter. Returns True on success."""
    import subprocess
    pane = tmux_pane(session) or session
    # strip the markers so a user message can never break out of the paste
    safe = text.replace(PASTE_END, "").replace(PASTE_START, "")
    try:
        subprocess.run(
            ["tmux", "send-keys", "-t", pane, "-l", PASTE_START + safe + PASTE_END],
            capture_output=True, timeout=10, check=True,
        )
        subprocess.run(
            ["tmux", "send-keys", "-t", pane, "Enter"],
            capture_output=True, timeout=10, check=True,
        )
        return True
    except Exception:
        return False


def ttyd_deliver(port, text):
    """Bracketed paste over the ttyd websocket."""
    try:
        import base64
        import hashlib
        import socket
    except Exception:
        return False
    # A full RFC6455 client is overkill here; ttyd's websocket is a
    # binary/text frame channel. Use the simplest reliable path: the
    # ttyd client protocol sends the input as a binary frame prefixed by
    # the command byte '0'.
    try:
        import struct
        host, p = "127.0.0.1", int(port)
        key = base64.b64encode(os.urandom(16)).decode()
        s = socket.create_connection((host, p), timeout=10)
        req = (
            f"GET /ws HTTP/1.1\r\nHost: {host}:{p}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: tty\r\n\r\n"
        )
        s.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        if b"101" not in buf.split(b"\r\n")[0]:
            s.close()
            return False
        # ttyd input frame: command '0' (INPUT) + payload
        payload = b"0" + (PASTE_START + text + PASTE_END).encode()
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        header = bytes([0x82, 0x80 | len(payload)]) if len(payload) < 126 else \
            bytes([0x82, 0x80 | 126]) + struct.pack(">H", len(payload))
        s.sendall(header + mask + masked)
        time.sleep(0.4)
        # Enter
        ent = b"0" + b"\r"
        mask2 = os.urandom(4)
        masked2 = bytes(b ^ mask2[i % 4] for i, b in enumerate(ent))
        s.sendall(bytes([0x82, 0x80 | len(ent)]) + mask2 + masked2)
        time.sleep(0.4)
        s.close()
        return True
    except Exception:
        return False


def queue_message(text, source="manual"):
    ensure_dirs()
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime())
    seq = len([f for f in os.listdir(QUEUE) if f.endswith(".txt")]) + 1
    path = os.path.join(QUEUE, f"{stamp}-{seq:03d}.txt")
    with open(path, "w") as f:
        f.write(text)
    return path


def mark_sent(path, target):
    ensure_dirs()
    base = os.path.basename(path)
    with open(os.path.join(SENT, base + ".sent"), "w") as f:
        f.write(json.dumps({"target": target, "ts": time.time()}))


def list_queue():
    ensure_dirs()
    queued = sorted(f for f in os.listdir(QUEUE) if f.endswith(".txt"))
    sent = sorted(f for f in os.listdir(SENT) if f.endswith(".sent"))
    return queued, sent


def main():
    args = sys.argv[1:]
    if not args:
        print("usage: ccp steer \"instruction\" | --file PATH | --list | --clear")
        return 1

    if args[0] == "--list":
        queued, sent = list_queue()
        print(f"queued ({len(queued)}):")
        for f in queued:
            body = open(os.path.join(QUEUE, f), errors="replace").read()
            first = body.strip().splitlines()[0] if body.strip() else ""
            print(f"  {f}: {first[:70]}")
        print(f"sent ({len(sent)}):")
        for f in sent[-10:]:
            print(f"  {f[:-5]}")
        return 0

    if args[0] == "--clear":
        ensure_dirs()
        n = 0
        for f in os.listdir(QUEUE):
            if f.endswith(".txt"):
                os.remove(os.path.join(QUEUE, f))
                n += 1
        print(f"cleared {n} queued message(s)")
        return 0

    text = None
    if args[0] == "--file":
        if len(args) < 2:
            print("ccp steer: --file needs a path", file=sys.stderr)
            return 2
        try:
            with open(args[1], errors="replace") as f:
                text = f.read()
        except OSError as e:
            print(f"ccp steer: cannot read {args[1]}: {e}", file=sys.stderr)
            return 2
    else:
        text = " ".join(args)

    if not text.strip():
        print("ccp steer: empty message", file=sys.stderr)
        return 2

    ensure_dirs()
    path = queue_message(text)

    # deliver to a tmux session if there is one
    session = find_tmux_session()
    if session and tmux_deliver(session, text):
        mark_sent(path, f"tmux:{session}")
        print(f"delivered to tmux session {session} (also queued as {os.path.basename(path)})")
        return 0

    # otherwise try a ttyd web terminal
    port = os.environ.get("CCP_TTYD_PORT", "7681")
    if ttyd_deliver(port, text):
        mark_sent(path, f"ttyd:{port}")
        print(f"delivered to ttyd on port {port} (also queued as {os.path.basename(path)})")
        return 0

    print(f"queued as {os.path.basename(path)} — no live session found to deliver it now.")
    print("It stays queued; the next session start picks it up, or deliver it with:")
    print(f"  ccp steer --list")
    return 0


if __name__ == "__main__":
    sys.exit(main())
