#!/data/data/com.termux/files/usr/bin/bash
# CCP session bookend: stamps session lifecycle into $CCP_HOME/sessions.jsonl.
# Used for both SessionStart and SessionEnd via an event-type argument.
# Degrades gracefully: if jq is missing, python3 builds the JSON line; if
# python3 is missing too, the line is skipped but the hook still exits 0.
# flock guards concurrent appends when available.
set -u
EV="${1:-unknown}"
STATE="${CCP_HOME:-$HOME/.ccp}"
SFILE="$STATE/sessions.jsonl"
[ -d "$STATE" ] || mkdir -p "$STATE" 2>/dev/null

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
payload=$(cat 2>/dev/null) || payload=""

line() {
  # $1 = payload; prints one JSON line or nothing
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r --arg ev "$EV" --arg ts "$TS" '
      {ts: $ts, event: $ev,
       session_id: (.session_id // null),
       cwd: (if ((.cwd // "") == "") then null else .cwd end),
       reason: (if ((.reason // "") == "") then null else .reason end)}
      | tostring'
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | CCP_EVENT="$EV" CCP_TS="$TS" python3 -c '
import json, os, sys
try:
    p = json.load(sys.stdin)
except Exception:
    p = {}
rec = {
    "ts": os.environ.get("CCP_TS", ""),
    "event": os.environ.get("CCP_EVENT", "unknown"),
    "session_id": p.get("session_id"),
    "cwd": p.get("cwd") or None,
    "reason": p.get("reason") or None,
}
sys.stdout.write(json.dumps(rec))
sys.stdout.write("\n")
'
  fi
}

w=$(line "$payload")
[ -n "$w" ] || exit 0

if command -v flock >/dev/null 2>&1; then
  : >> "$SFILE" 2>/dev/null  # flock needs the file to exist
  printf '%s\n' "$w" | flock "$SFILE" cat >> "$SFILE" 2>/dev/null || printf '%s\n' "$w" >> "$SFILE" 2>/dev/null
else
  printf '%s\n' "$w" >> "$SFILE" 2>/dev/null
fi
exit 0
