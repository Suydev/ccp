#!/data/data/com.termux/files/usr/bin/bash
# ccp-supervisor: keeps a Claude Code session alive until the user says exit.
# No hardcoded paths, no hardcoded models, no hardcoded ports — it calls the
# `claude` on PATH and reads/writes only under $CCP_HOME (default $HOME/.ccp).
#
# Loop:
#   launch claude (interactive, using the claude on PATH)
#   on exit: check $CCP_HOME/stop-mode
#     exit -> break
#     off  -> relaunch (resume the last session if resumable)
#     ask  -> relaunch; the Stop hook inside Claude handles the ask-loop
#
# Usage: ccp-supervisor.sh [--resume] [--workdir DIR] [-- CLAUDE ARGS...]
set -u

CCP_HOME="${CCP_HOME:-$HOME/.ccp}"
mkdir -p "$CCP_HOME"

mode() {
  [ -f "$CCP_HOME/stop-mode" ] && cat "$CCP_HOME/stop-mode" 2>/dev/null || echo off
}

set_mode() {
  printf '%s' "$1" > "$CCP_HOME/stop-mode"
}

# How many failed turns the StopFailure hook has recorded.
failure_count() {
  [ -f "$CCP_HOME/failure-count" ] && cat "$CCP_HOME/failure-count" 2>/dev/null || echo 0
}

last_session_id() {
  jq -r 'select(.event == "end") | .session_id // empty' \
    "$CCP_HOME/sessions.jsonl" 2>/dev/null | tail -1
}

note() { printf '[ccp-supervisor] %s\n' "$*" >&2; }

RESUME=0
WORKDIR="$PWD"
extra_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --resume) RESUME=1; shift ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --) shift; extra_args=("$@"); break ;;
    *) extra_args+=("$1"); shift ;;
  esac
done

command -v claude >/dev/null 2>&1 || {
  echo "ccp-supervisor: 'claude' not found on PATH" >&2
  exit 1
}

# claude is interactive by design here; refuse to run without a terminal
# (headless -p runs have nothing to ask, so a loop makes no sense and would
# crash-relaunch forever).
if [ -t 0 ] && [ -t 1 ]; then
  :
else
  echo "ccp-supervisor: no tty — the supervisor runs interactive sessions only." >&2
  echo "For headless use, call claude -p directly (CCP hooks still apply)." >&2
  exit 1
fi

cycle=0
: > "$CCP_HOME/supervisor.log"
while :; do
  cycle=$((cycle + 1))
  m=$(mode)
  if [ "$m" = "exit" ]; then
    note "stop-mode=exit; stopping supervisor."
    break
  fi

  args=()
  if [ "$RESUME" = "1" ] && [ "$cycle" -gt 1 ]; then
    if sid=$(last_session_id) && [ -n "$sid" ]; then
      note "cycle $cycle: resuming session $sid"
      args+=(--resume "$sid")
    else
      note "cycle $cycle: no resumable session id, starting fresh"
    fi
  fi
  # first cycle of a --resume run resumes immediately
  if [ "$RESUME" = "1" ] && [ "$cycle" -eq 1 ]; then
    if sid=$(last_session_id) && [ -n "$sid" ]; then
      note "cycle 1: resuming session $sid"
      args+=(--resume "$sid")
    fi
  fi

  fails_before=$(failure_count)
  note "cycle $cycle: launching claude in $WORKDIR"
  (
    cd "$WORKDIR" || exit 127
    claude "${args[@]}" "${extra_args[@]:-}"
  ) >> "$CCP_HOME/supervisor.log" 2>&1
  rc=$?
  note "cycle $cycle: claude exited rc=$rc stop-mode=$(mode)"
  printf '{"ts":"%s","event":"supervisor_cycle","cycle":%d,"rc":%d,"mode":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$cycle" "$rc" "$(mode)" >> "$CCP_HOME/supervisor.log"

  # A failed turn (API error, blocked egress, firewall) is recorded by the
  # StopFailure hook in $CCP_HOME/failures.jsonl. When the count grew
  # during this cycle, the session died for a reason the model could not
  # fix — back off further before relaunching, and resume the session so
  # the conversation is not lost.
  fails_now=$(failure_count)
  if [ "$fails_now" != "$fails_before" ]; then
    note "turn failed during this cycle (failures: $fails_before -> $fails_now); backoff 20s then resume"
    sleep 20
    continue
  fi

  # claude exits 0 on normal end, 130 on ctrl-c, 143 on TERM. treat fatal
  # non-zero as a crash-restart with backoff.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 130 ]; then
    note "non-zero exit; backoff 10s before relaunch"
    sleep 10
  fi
done
