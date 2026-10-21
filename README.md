# ccp — control plane inside Claude Code

[![ci](https://github.com/Suydev/ccp/actions/workflows/ci.yml/badge.svg)](https://github.com/Suydev/ccp/actions/workflows/ci.yml)

A Claude Code mod that keeps sessions alive under your control — **everything
happens inside the Claude Code GUI**. Sessions keep running until *you* say
exit; every turn-end can ask what to do next; crashes auto-recover. No
separate terminal tools required for daily use.

## Use it (in the Claude Code prompt)

| Command | What it does |
|---|---|
| `/ccp` | status card: mode, block count, recent sessions |
| `/ccp ask` | Claude must ask you at every turn end: continue / new task / exit |
| `/ccp off` | normal behavior — turns end freely (default) |
| `/ccp exit` | allow the session to end |
| `/ccp reset` | zero the block counter |

You reply to the continue/new-task/exit question **in the AskUserQuestion
popup inside Claude Code** — same place you type everything else.

## Install

The mod is a plain Claude Code plugin:

```
mod/
  .claude-plugin/plugin.json   # name, version, description
  hooks/hooks.json             # { "modules": ["./register.ts"] }
  hooks/register.ts            # registers /ccp + ask-mode context injection
```

Load it your plugin dir of choice:

```bash
claude --plugin-dir /path/to/ccp/mod
```

The mod reads and writes `$CCP_HOME` (default `~/.ccp`) — the same state
files the hooks use, so everything agrees.

## The hooks (installed once by `install.sh`)

| Hook | Event | What it does |
|---|---|---|
| `hooks/stop_gate.py` | Stop | In `ask` mode, blocks turn-end and tells Claude to ask via AskUserQuestion. Yields before Claude Code's 8-block cap. |
| `hooks/session_bookend.sh` | SessionStart/End | One JSON line per session lifecycle into `$CCP_HOME/sessions.jsonl` — the crash-recovery record. |

```bash
./install.sh    # idempotent merge into ~/.claude/settings.json (backs up first)
```

## Optional, not required

- `ccp ui` — localhost web dashboard (http://127.0.0.1:8799) with the same
  buttons; handy on a phone screen while a session runs in another window.
- `scripts/ccp-supervisor.sh` — launch/relaunch loop for terminal sessions
  with `--resume` crash recovery. Interactive sessions only.
- `bin/ccp` — the same commands from any shell.

Everything reads/writes the same `$CCP_HOME`, so the GUI, dashboard, and
hooks never disagree.

## Why bash/python (measured on Android/Termux aarch64)

`node` cold start: **1.8–8.2 s**; `python3` ~0.2 s; bash+jq 0.3–0.6 s.
Claude Code aborts *plugin* hooks ~1 s after spawn on SessionEnd
(`Hook cancelled`). Control-plane hooks that run on SessionEnd are bash;
the decision hook is python. The mod itself is TypeScript loaded by Claude
Code's own engine, so node's cold start never enters its path.

## Block limits

In `ask` mode the Stop gate blocks **unlimited** times. Claude Code's own
limit is `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` (default 8); the installer sets it
to `0`, which Claude Code reads as "no cap" (`if (cap > 0 && count > cap)`).

`hooks/stop_gate.py` has its own optional `MAX_BLOCKS` ceiling — `0` (the
default) means unlimited. Set it to a number to impose your own limit.

The reason text is short on purpose: a long reason makes Claude Code render
it as "Stop hook blocking error", which reads like a crash rather than a
prompt.

## Known limitations (measured, not assumed)

- **Headless ask-mode parks the session.** In `-p` mode nothing can answer
  AskUserQuestion, so an ask-block waits forever. Ask-mode is for
  interactive sessions.
- **Other Stop-hook plugins can veto the gate.** Claude Code takes the
  first decisive Stop-hook decision; a plugin that emits
  `{"decision":"approve"}` moots the block. Disable competing Stop-hook
  plugins for reliable ask-mode.
- **supervisor is interactive-only** — it refuses without a tty rather than
  crash-looping.

## Tests

```bash
tests/test_stop_gate.sh     # unit: decisions, cap, malformed input
tests/test_e2e.sh           # headless claude run, asserts hooks fired cleanly
```

CI runs the units, bookend degradation ladder (jq → python → silent),
installer idempotency, and the web-dashboard API on every push.

## License

MIT — see [LICENSE](LICENSE).

## Steering a running session

Change the agent's mind **while it is working** — the turn is not stopped,
the instruction is queued and picked up on the next step.

```bash
ccp steer "also handle the failing test"     # deliver now
ccp steer --file notes.md                    # send a file's contents
ccp steer --list                             # what is queued / already sent
ccp steer --clear                            # drop the queue
```

Delivery paths, tried in order:

1. **tmux** — bracketed paste into the pane, then Enter. Claude Code reads a
   pasted message as a queued user message; the current turn finishes and the
   instruction is picked up next.
2. **ttyd** — the same paste over the ttyd websocket, so a browser session
   can be steered too (`CCP_TTYD_PORT`, default 7681).
3. **Queue** — if no live session is found, the message waits in
   `$CCP_HOME/steer-queue/` and the `SessionStart` drain injects it into the
   next session. Nothing is lost.

The queue is drained exactly once: drained messages move to
`$CCP_HOME/steer-sent/`, so a later session start does not repeat them.
