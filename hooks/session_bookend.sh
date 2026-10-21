#!/data/data/com.termux/files/usr/bin/bash
# CCP session bookend: stamps session lifecycle into $HOME/.ccp/sessions.jsonl.
# Used for both SessionStart and SessionEnd via an event-type argument.
# bash (not python) so it also works as a plugin-style fast hook if ever needed.
set -u
EV="$1"
SFILE="${CCP_HOME:-$HOME/.ccp}/sessions.jsonl"
mkdir -p "$(dirname "$SFILE")"
payload=$(cat 2>/dev/null) || payload=""
sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
reason=$(printf '%s' "$payload" | jq -r '.reason // empty' 2>/dev/null)
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq -nc \
  --arg ev "$EV" --arg sid "$sid" --arg cwd "$cwd" --arg ts "$ts" --arg reason "$reason" \
  '{ts: $ts, event: $ev, session_id: $sid, cwd: (if $cwd == "" then null else $cwd end),
    reason: (if $reason == "" then null else $reason end)}' >> "$SFILE" 2>/dev/null
exit 0
