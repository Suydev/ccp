# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`ccp` is a control plane for Claude Code sessions. It keeps a session alive
until you say exit, lets you redirect a running agent without interrupting it,
and survives API errors. The whole thing is designed for Android/Termux,
where the constraints are unusual (see below).

## Commands

```bash
./install.sh                     # wire hooks + /ccp command into ~/.claude (idempotent, backs up first)
bash tests/test_stop_gate.sh     # stop-gate unit tests
bash tests/test_state_helper.sh # /ccp helper unit tests
bash tests/test_failure_gate.sh # StopFailure handler unit tests
bash tests/test_steer.sh        # steering queue unit tests
bash tests/test_e2e_local.sh    # gate, bookend, dashboard API, ttyd
bash tests/test_e2e_full.sh     # the above + real claude sessions (needs a gateway; slow)
bash tests/test_interactive_probe.sh  # drives claude through a pty
```

CI (`.github/workflows/ci.yml`) runs the no-claude suites on every push. The
suites that invoke `claude` need a working gateway and are not in CI.

## Architecture

Four independent pieces. Each reads/writes the same state directory
(`$CCP_HOME`, default `~/.ccp`), so they never disagree:

- `hooks/stop_gate.py` — the Stop hook. In `ask` mode it returns
  `{"continue": false, "stopReason": ...}` so the model calls
  AskUserQuestion at every turn end. `continue:false` is the modern
  contract; the legacy `{"decision":"block"}` renders as a scary
  "blocking error" in the CLI.
- `hooks/failure_gate.py` — the StopFailure hook. Catches API errors,
  blocked egress, firewall refusals: logs them, notifies the phone, and
  lets the supervisor resume.
- `hooks/steer.py` — delivers an instruction to a **running** session
  (tmux bracketed paste, then `ctrl+x ctrl+s` to flush Claude Code's own
  message queue; ttyd websocket as the second path). Falls back to a
  queue that `hooks/steer_drain.py` injects at the next session start.
- `scripts/` — the supervisor loop, the web dashboard, the web terminal.

`bin/ccp.py` is the helper behind the `/ccp` slash command. It does the
work itself, so `/ccp` costs no model tokens. `commands/ccp.md` is the
slash command; `mod/` is the Claude Code plugin version of the same thing.

## Constraints specific to this box (do not "optimize" these away)

- `node` cold start is **1.8-8.2 s** here. `python3` is ~0.2 s, bash ~0.1 s.
  **Never write a hook in node.** Claude Code aborts *plugin* hooks about a
  second after they spawn, so a node plugin hook never survives.
- `/tmp` does not exist. `$TMPDIR` does. Never hardcode `/tmp`.
- `#!/usr/bin/env` does not exist either. Shebangs are absolute.
- A hook's `timeout` is in **seconds**; plugin hooks get far less grace
  than settings-file hooks.
- Claude Code's own Stop-block cap is `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`
  (default 8). `0` means unlimited. The installer sets it.
- The first decisive Stop-hook decision wins, so another plugin's Stop hook
  can veto ours. This is documented, not a bug to fix here.

## Conventions

- Bash scripts: `set -u`, no `set -e` where a non-zero exit is meaningful.
- Python: stdlib only, no pip installs, no third-party imports.
- State lives under `$CCP_HOME`; every path is overridable by env var.
- Tests use a temp `CCP_HOME` and must never touch the real one — an
  earlier version of the e2e suite did, and it flipped the live session
  into ask-mode.
