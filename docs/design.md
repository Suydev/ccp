# CCP — Claude Code Control Plane (Termux)

Design: 2026-10-21. Built from `~/idea.md`, adapted to what this device can
actually do (measured, not assumed).

## What idea.md wanted

A persistent agent session: Claude never silently stops; every turn end asks
the user "continue / new task / exit"; an `exit` choice ends the loop; crash
or phone-kill lets the supervisor re-launch and resume. CCR stays the model
gateway and logs usage.

## What this device can and cannot do (measured)

| Fact | Value | Consequence |
|---|---|---|
| node cold start | 1.8–8.2s | hooks must not be node unless unavoidable |
| python3 boot | ~0.2s | fine for hooks |
| bash+jq hook | 0.27–0.6s | fine, needs timeout ≥ 20s |
| SessionEnd plugin-hook abort | ~1s after spawn | plugin SessionEnd hooks must be bash |
| settings hooks | wait for full timeout | control-plane hooks live in settings |
| /tmp | absent; $TMPDIR exists | all state under $HOME |
| Stop-block cap | 8 consecutive blocks | supervisor must handle the cap |
| AskUserQuestion | interactive-only | in `-p` mode it cannot work; use input-box flow |

## Architecture

Four pieces, each independently testable:

1. **`hooks/stop_gate.py`** — the Stop hook. Reads payload, checks
   `$HOME/.ccp/stop-mode`:
   - `off` (default): exit 0, agent ends turn normally.
   - `ask`: prints `{"decision":"block","reason":"Ask the user what's next via AskUserQuestion: continue / new task / exit."}`
   - `exit`: exit 0.
   Written in python for 0.2s boot; timeout 20.

2. **`hooks/session_bookend.sh`** — SessionStart + SessionEnd hook that
   stamps `$HOME/.ccp/sessions.jsonl` (event, session id, ts, cwd). Gives the
   supervisor crash-recovery data without any node.

3. **`bin/ccp-supervisor.sh`** — the loop. Runs interactive `claude` via the
   existing wrapper (which brings up CCR). Between launches:
   - re-asserts `stop-mode` state from `$HOME/.ccp/supervisor-state.json`
   - records each session end with ts + reason
   - loops until user chose exit (state file) or `--once`
   Supports `--resume` to pass `claude --resume <id>` after a crash.

4. **`bin/ccp`** — user commands: `start`, `stop-mode ask|off|exit`, `status`,
   `notify-test`. Notifies via `termux-notification` on stop events when
   `stop-mode` is `ask`.

## State machine

Idle → Running (supervisor launches claude) → user works → Stop hook fires →
- stop-mode off: session may end; supervisor relaunches (fresh session, or
  `--resume` the id recorded by SessionEnd) unless user's last choice was exit.
- stop-mode ask: hook blocks, Claude asks via AskUserQuestion; user picks;
  `ccp` writes stop-mode accordingly.
- 8-block cap hit: hook yields; session ends; supervisor relaunches and
  resets counter.

## Files

```
$HOME/cc-control-plane/
  hooks/stop_gate.py
  hooks/session_bookend.sh
  bin/ccp
  bin/ccp-supervisor.sh
  tests/*.sh        headless e2e runs (settings-only, no plugins)
$HOME/.ccp/
  stop-mode         off | ask | exit
  supervisor-state.json
  sessions.jsonl
```

## Testing

- `tests/test_stop_gate.sh` — unit: feeds payloads, checks decisions.
- `tests/test_e2e.sh` — headless `claude -p` with a settings file that has
  stop-mode ask + SessionEnd bookend; asserts hook output lands and no
  "Hook cancelled" appears.

## Deliberately not built (YAGNI)

- PTY JSON-stream parsing of AskUserQuestion (idea.md's approach) — the
  Stop-hook block + reason path gets the same behavior without parsing
  streams.
- Cost parsing from CCR logs — CCR UI already shows it.
- SQLite state — one small JSON + one JSONL is enough; jq/python read both.

## Integration finding (2026-10-21)

Stop-hook precedence: the first decisive Stop-hook decision wins. The
`claude-judge` plugin (double-shot-latte) emits `{"decision":"approve"}`
when its own evaluation times out — an approve moots CCP's ask-block.
Observed live: stop_gate incremented its counter (ran, blocked) but the
session transcript shows `preventedContinuation:false` because another Stop
hook approved first.

Consequences:
- In ask-mode with Stop-hook plugins enabled (double-shot-latte, homunculus
  on_stop), CCP's gate can be vetoed. For reliable ask-mode, disable
  competing Stop-hook plugins for the supervised session (run with
  `--strict-mcp-config` is unrelated; use `claude --settings ... ` with
  plugins off, or uninstall/disable the judge plugin).
- In off/exit modes CCP is inert, so no interference.
