---
name: ccp
description: Control-plane status and stop-mode switch. /ccp [off|ask|exit|reset]
argument-hint: [off|ask|exit|reset]
---

# ccp — Claude Code control plane

Run the state helper and report its output verbatim. Do not explore the
filesystem, do not shell out to anything else, do not summarise.

Resolve the helper in this order and use the first one that exists:

1. `$CCP_HOME/ccp_state.py`
2. `~/.ccp/ccp_state.py`
3. `~/.claude/plugins/cache/local/ccp/*/scripts/ccp_state.py`
4. `~/cc-control-plane/mod/scripts/ccp_state.py`

Then run:

```bash
CCP_HOME="${CCP_HOME:-$HOME/.ccp}" python3 <resolved-helper> "$ARGUMENTS"
```

Rules:
- `$ARGUMENTS` empty → run the helper with no arguments, print its output
  exactly.
- `$ARGUMENTS` is `off`, `ask`, `exit`, or `reset` → run the helper with
  that single argument, print its output exactly.
- `$ARGUMENTS` is anything else → run the helper with no arguments (the
  status card lists the valid values), print that output exactly.
- If no helper is found, print one line:
  `ccp: helper not found` and nothing else.

Never add commentary before or after the helper's output.
