#!/usr/bin/env python3
"""CCP failure gate — handles the StopFailure hook event.

Claude Code fires `StopFailure` when a turn ends because something went
wrong rather than because the model finished: an API error (400/429/5xx), a
blocked egress, a firewall/proxy refusal, a timeout, a crashed turn.

The Stop hook never sees those — a failed turn is not a "stop" — so without
this the session just dies with no record and no chance to recover.

What this does:
  * writes a failure record to $CCP_HOME/failures.jsonl (one line per event)
  * notifies the user (termux-notification when present) — a phone buzz is
    the difference between noticing a dead session now and an hour later
  * bumps $CCP_HOME/failure-count so the supervisor can decide to relaunch
  * prints a short line so the reason is visible in the transcript

It never blocks and never fails: an error handler that errors is worse than
no handler. Exit code is always 0.
"""
import json
import os
import subprocess
import sys
import time

STATE = os.environ.get("CCP_HOME") or os.path.join(os.environ.get("HOME", "/"), ".ccp")
FAILLOG = os.path.join(STATE, "failures.jsonl")
COUNT = os.path.join(STATE, "failure-count")


def read_text(path):
    try:
        with open(path, errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def summarize(payload):
    """Short, human-readable one-liner for the failure."""
    err = payload.get("error")
    details = payload.get("error_details")
    if isinstance(err, dict):
        # error is often {type, message} or {code, ...}
        parts = []
        for key in ("type", "code", "status", "statusCode", "origin", "api_error_origin"):
            if err.get(key):
                parts.append(str(err[key]))
        msg = err.get("message") or ""
        head = " ".join(parts)
        out = (head + " " + msg).strip() if head else msg
    else:
        out = str(err or "")
    if not out and isinstance(details, dict):
        out = json.dumps(details)[:300]
    elif not out and details:
        out = str(details)[:300]
    if not out:
        out = "unknown error"
    # collapse whitespace, keep it short
    out = " ".join(out.split())
    return out[:240]


def notify(summary):
    """Best-effort Android notification. Never raises."""
    if not os.environ.get("CCP_NOTIFY", "1"):
        return
    try:
        subprocess.run(
            [
                "termux-notification",
                "--id", "ccp.failure",
                "--title", "Claude session failed",
                "--content", summary[:140],
                "--priority", "high",
                "--vibrate", "400,150,400",
            ],
            timeout=8,
            capture_output=True,
        )
    except Exception:
        # Termux:API absent, or the app is not running. The session carries on.
        pass


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}

    summary = summarize(payload)
    session_id = payload.get("session_id") or ""
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    try:
        os.makedirs(STATE, exist_ok=True)
        with open(FAILLOG, "a") as f:
            f.write(json.dumps({
                "ts": ts,
                "event": "stop_failure",
                "session_id": session_id,
                "summary": summary,
                "error": payload.get("error"),
            }) + "\n")
    except OSError:
        pass

    try:
        n = int(read_text(COUNT) or 0) + 1
        with open(COUNT, "w") as f:
            f.write(str(n))
    except (OSError, ValueError):
        n = 1

    notify(summary)

    # Visible in the transcript, short enough not to look like an error.
    sys.stdout.write(f"ccp: turn failed ({summary}). Session can be resumed with: ccp start --resume\n")
    sys.exit(0)


if __name__ == "__main__":
    main()
