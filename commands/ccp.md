---
name: ccp
description: Control plane for this Claude Code session — stop-mode, block counter, and steering. /ccp [status|ask|off|exit|reset|steer <text>|help]
argument-hint: [status|ask|off|exit|reset|steer <text>]
---

# /ccp — Claude Code control plane

`/ccp` is dedicated to Claude Code. It controls this session's stop-gate
(when to ask you), the block counter, and steering (redirecting a running
agent without stopping it).

It runs one local helper directly — no model reasoning, no extra tokens.

**Run exactly this, then print the helper's output verbatim. Nothing else.**

```bash
CCP_HOME="${CCP_HOME:-$HOME/.ccp}" python3 "$HOME/.claude/ccp/ccp.py" $ARGUMENTS
```

Rules:
- Run the command once. If `$ARGUMENTS` is empty, pass no extra argument.
- Print the helper's stdout exactly as it is — no summary, no commentary
  before or after, no markdown fence.
- If the helper exits non-zero, print its stderr exactly and stop.
- If the helper cannot be found, print this one line and stop:
  `ccp: helper not found at $HOME/.claude/ccp/ccp.py`
- Never explore the filesystem to find the helper. Never substitute another
  command. This one command does everything.
