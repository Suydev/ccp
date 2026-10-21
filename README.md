[![ci](https://github.com/Suydev/ccp/actions/workflows/ci.yml/badge.svg)](https://github.com/Suydev/ccp/actions/workflows/ci.yml)

# ccp — Claude Code control plane for Termux

A small, dependency-light supervisor + hook layer that keeps Claude Code
sessions alive under your control: sessions keep running until *you* say
exit, every turn-end can ask what to do next, and crashes auto-recover.

Works with any provider behind Claude Code — it never touches model config,
API keys, or ports. Everything lives in `$CCP_HOME` (default `$HOME/.ccp`).

```
┌──────────────┐  launches        ┌─────────────┐
│ ccp start    │ ─────────▶       │ claude CLI  │
│ (supervisor) │                  └──────┬──────┘
│              │ Stop hook        │ every turn  │
│ loops until  │ ◀────────        ┤ stop_gate   │
│ stop-mode=   │ blocks turn end  │ ask→block   │
│ exit         │                  │ off → end   │
└──────────────┘                  └─────────────┘
```

## Install

```bash
git clone <this-repo> ccp
cd ccp
./install.sh        # wires hooks into ~/.claude/settings.json (idempotent)
ccp help
```

Requirements: bash, python3, jq, `claude` on PATH. On Termux:
`pkg install bash python3 jq` and your usual Claude Code install.

## Use

```bash
ccp start                  # session stays alive; each stop relaunches
ccp stop-mode ask          # every turn end, Claude must ask: continue / new task / exit
ccp stop-mode off          # turn ends normally (default)
ccp stop-mode exit         # allow the session to end; supervisor exits
ccp status                 # mode, counter, recent session records
ccp reset                  # clear the stop-block counter
ccp start --resume         # after a crash, resume the last session
ccp notify-test            # send a Termux notification (optional)
```

## How it works

Three hooks, wired into your `claude` settings:

| Hook | Event | What it does |
|---|---|---|
| `hooks/stop_gate.py` | Stop | In `ask` mode, blocks turn-end with a reason telling Claude to ask the user via AskUserQuestion. Counts blocks and yields before Claude Code's own 8-block cap. |
| `hooks/session_bookend.sh` | SessionStart / SessionEnd | Appends one JSON line per session start/end to `$CCP_HOME/sessions.jsonl` — the crash-recovery record the supervisor reads. |
| `scripts/ccp-supervisor.sh` | (not a hook) | Launches `claude`, waits, checks `stop-mode`, relaunches (optionally `--resume`-ing the last session) until you pick exit. |

State files:

```
$CCP_HOME/stop-mode          off | ask | exit
$CCP_HOME/stop-count         consecutive blocks this window
$CCP_HOME/sessions.jsonl     one line per session start/end
$CCP_HOME/supervisor.log     supervisor cycle log
```

## Why bash/python and not node

On Android/Termux (aarch64) we measured:

- `node` cold start: **1.8–8.2 s**
- `python3` boot: ~0.2 s
- bash+jq hook: 0.3–0.6 s

Claude Code also aborts *plugin* hooks ~1 s after spawn on SessionEnd
(`Hook cancelled`). So control-plane hooks that must run on SessionEnd are
bash, and the decision hook is python. If your machine has a fast node, you
can rewrite them in node — the contract is the standard hook JSON.

## Tests

```bash
tests/test_stop_gate.sh     # unit: decisions, cap, malformed input
tests/test_e2e.sh           # headless claude run, asserts hooks fired cleanly
```

## Open-source notes

- No hardcoded paths, models, ports, or API keys anywhere in the scripts.
- Everything configurable lives in env vars: `CCP_HOME`, `CCP_HOOKS_DIR`,
  `CCP_SCRIPTS_DIR`.
- Hooks are plain files; the installer merges them into whatever settings
  file Claude Code already reads for you.

## License

MIT — see [LICENSE](LICENSE).

## Known limitations (measured, not assumed)

- **Headless ask-mode parks the session.** In `-p` mode nothing can answer
  AskUserQuestion, so an ask-block waits forever. Ask-mode is for interactive
  sessions; in headless runs keep `stop-mode off`.
- **Other Stop-hook plugins can veto the gate.** Claude Code takes the first
  decisive Stop-hook decision; a plugin that emits
  `{"decision":"approve"}` (e.g. a judge/latte plugin) moots the block.
  For reliable ask-mode, disable competing Stop-hook plugins.
- **Plugin cache fixes are not durable.** The bash shims for vercel /
  claude-session-driver / homunculus live in Claude Code's plugin cache and
  are overwritten when those plugins update. Originals are kept next to them
  as `hooks.json.orig-ccpp`; re-apply or re-derive from the pattern in
  `docs/design.md` after upgrading those plugins.

## Web dashboard + statusline

```bash
ccp ui                # control panel at http://127.0.0.1:8799 (Ctrl-C to stop)
ccp ui --port 9000    # custom port
ccp statusline        # one-line summary for a Claude Code statusline command
```

The dashboard reads/writes the same `$CCP_HOME` state the hooks use: mode
switch buttons (off/ask/exit), stop-count with reset, live session and
supervisor-log tails, auto-refresh every 3 s. Python stdlib only — no pip,
no node. It binds 127.0.0.1 by default (`CCP_BIND` to change).

Inside Claude Code, add to your statusline settings:

```json
{ "statusLine": { "type": "command", "command": "<path-to>/ccp/bin/ccp statusline" } }
```

## The Claude Code mod (`mod/`)

Everything above is also available **inside the Claude Code GUI** as a mod:

- `/ccp` — status card: mode, block count, recent sessions
- `/ccp ask|off|exit` — switch stop-mode without leaving the prompt
- `/ccp reset` — zero the block counter

State is the same `$CCP_HOME` files the hooks use, so the TUI commands,
web dashboard, and hooks never disagree.

Install (your dev-mods path is machine-specific — see the plugin docs):

```bash
cp -r mod/ <your-plugin-dir>/ccp
claude --plugin-dir <your-plugin-dir>/ccp
```

It is a plain Claude Code plugin: `.claude-plugin/plugin.json` +
`hooks/hooks.json` (`modules: ["./register.ts"]`) + `hooks/register.ts`.
No build step, no dependencies beyond the `claude-code` types.
