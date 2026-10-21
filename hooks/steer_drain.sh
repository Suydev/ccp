#!/data/data/com.termux/files/usr/bin/bash
# CCP steer drain — thin wrapper so the SessionStart hook can call it.
set -u
exec python3 "$(dirname "$0")/steer_drain.py"
