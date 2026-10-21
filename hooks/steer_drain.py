#!/usr/bin/env python3
"""CCP steer drain — deliver queued instructions when a session starts.

Messages queued while no session was live (or that could not be delivered)
are injected at the start of the next session, so an instruction is never
lost just because the agent was busy.

Runs on the SessionStart hook, before the first prompt.
"""
import json
import os
import sys
import time

STATE = os.environ.get("CCP_HOME") or os.path.join(os.environ.get("HOME", "/"), ".ccp")
QUEUE = os.path.join(STATE, "steer-queue")
SENT = os.path.join(STATE, "steer-sent")


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}

    try:
        names = sorted(f for f in os.listdir(QUEUE) if f.endswith(".txt"))
    except OSError:
        names = []

    if not names:
        sys.exit(0)

    # Surface the queued instructions as context for the model, and mark them
    # delivered so they are not injected twice.
    lines = []
    for name in names:
        path = os.path.join(QUEUE, name)
        try:
            with open(path, errors="replace") as f:
                body = f.read().strip()
        except OSError:
            continue
        if not body:
            continue
        lines.append(f"- {body}")
        # Mark it delivered AND take it out of the queue, so a later session
        # start does not inject the same instruction a second time.
        try:
            with open(os.path.join(SENT, name + ".sent"), "w") as f:
                json.dump({"target": "session_start", "ts": time.time()}, f)
        except OSError:
            pass
        try:
            os.remove(path)
        except OSError:
            pass

    if not lines:
        sys.exit(0)

    sys.stdout.write(
        "ccp: queued instructions from before this session started — "
        "follow them now:\n" + "\n".join(lines) + "\n"
    )
    sys.exit(0)


if __name__ == "__main__":
    main()
