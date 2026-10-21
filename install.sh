#!/data/data/com.termux/files/usr/bin/bash
# ccp installer: merges the control-plane hooks into the user's Claude Code
# settings. Idempotent. Never overwrites unrelated settings.
#
# Uses node (shipped with Claude Code) for a safe JSON merge when available;
# falls back to a jq merge otherwise.
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$ROOT/hooks"
CCP_HOME="${CCP_HOME:-$HOME/.ccp}"

settings_file() {
  if [ -n "${CCP_SETTINGS:-}" ]; then
    printf '%s\n' "$CCP_SETTINGS"
  elif [ -f "$HOME/.claude/settings.json" ]; then
    printf '%s\n' "$HOME/.claude/settings.json"
  else
    printf '%s/.claude/settings.json\n' "$HOME"
  fi
}

SETTINGS="$(settings_file)"
[ -f "$SETTINGS" ] || { echo "no settings file at $SETTINGS; create one first (run claude once)." >&2; exit 1; }

cp "$SETTINGS" "$SETTINGS.bak-ccp-$(date +%Y%m%d-%H%M%S)"
echo "backed up: $SETTINGS.bak-ccp-*"

merge() {
  local tmp="$SETTINGS.tmp-ccp"
  if command -v node >/dev/null 2>&1; then
    node -e '
      const fs = require("fs");
      const [settingsPath, hooksDir, ccpHome] = process.argv.slice(1);
      const s = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
      s.hooks = s.hooks || {};
      // 0 = unlimited Stop blocks in Claude Code (`if (cap > 0 && count > cap)`)
      s.env = s.env || {};
      s.env.CLAUDE_CODE_STOP_HOOK_BLOCK_CAP = "0";
      const entry = (cmd) => [{ type: "command", command: `CCP_HOME=${ccpHome} ${cmd}`, timeout: 20 }];
      // idempotent: replace any entry that already points at these hooks
      const replace = (ev, obj) => {
        const keep = (s.hooks[ev] || []).filter(grp =>
          !JSON.stringify(grp).includes(hooksDir));
        s.hooks[ev] = keep.concat([{ hooks: entry(cmd(ev)) }]);
      };
      const cmd = (ev) => {
        if (ev === "Stop") return `python3 ${hooksDir}/stop_gate.py`;
        if (ev === "StopFailure") return `python3 ${hooksDir}/failure_gate.py`;
        return `bash ${hooksDir}/session_bookend.sh ${ev === "SessionStart" ? "start" : "end"}`;
      };
      replace("Stop"); replace("StopFailure"); replace("SessionStart"); replace("SessionEnd");
      // The steer drain is a SECOND SessionStart entry, so it must not replace
      // the bookend: both have to run. Append it separately, dropping any
      // previous copy of itself first.
      s.hooks.SessionStart = (s.hooks.SessionStart || [])
        .filter(grp => !JSON.stringify(grp).includes("steer_drain.sh"))
        .concat([{ hooks: entry(`bash ${hooksDir}/steer_drain.sh`) }]);
      fs.writeFileSync(settingsPath, JSON.stringify(s, null, 2));
    ' "$SETTINGS" "$HOOKS_DIR" "$CCP_HOME"
  elif command -v jq >/dev/null 2>&1; then
    jq --arg hd "$HOOKS_DIR" --arg ch "$CCP_HOME" '
      def entry(cmd): [{ type: "command", command: ("CCP_HOME=" + $ch + " " + cmd), timeout: 20 }];
      def env0: .env = ((.env // {}) + {CLAUDE_CODE_STOP_HOOK_BLOCK_CAP: "0"});
      def replace(ev; cmd):
        .hooks[ev] = ((.hooks[ev] // [])
          | map(select((tostring | contains($hd)) | not)))
          + [{ hooks: entry(cmd) }];
      env0
      | replace("Stop"; "python3 " + $hd + "/stop_gate.py")
      | replace("StopFailure"; "python3 " + $hd + "/failure_gate.py")
      | replace("SessionStart"; "bash " + $hd + "/session_bookend.sh start")
      | .hooks.SessionStart = ((.hooks.SessionStart // [])
          | map(select((tostring | contains("steer_drain.sh")) | not)))
          + [{ hooks: entry("bash " + $hd + "/steer_drain.sh") }]
      | replace("SessionEnd"; "bash " + $hd + "/session_bookend.sh end")
    ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  else
    echo "need node or jq to merge settings" >&2; exit 1
  fi
}

merge
# sanity: file still valid JSON
if command -v jq >/dev/null 2>&1; then
  jq -e . "$SETTINGS" >/dev/null || { echo "MERGE BROKE SETTINGS; restoring backup" >&2; ls -t "$SETTINGS".bak-ccp-* | head -1 | xargs cp -- "$SETTINGS"; exit 1; }
fi
echo "hooks merged into $SETTINGS"

# Also install the /ccp slash command into the user's commands dir, and the
# state helper next to the state files, so /ccp resolves without a plugin.
CMD_DIR="${CCP_COMMAND_DIR:-$HOME/.claude/commands}"
mkdir -p "$CMD_DIR" 2>/dev/null || true
if [ -f "$ROOT/commands/ccp.md" ]; then
  cp "$ROOT/commands/ccp.md" "$CMD_DIR/ccp.md"
  echo "slash command: $CMD_DIR/ccp.md"
fi
if [ -f "$ROOT/mod/scripts/ccp_state.py" ]; then
  mkdir -p "$CCP_HOME" 2>/dev/null || true
  cp "$ROOT/mod/scripts/ccp_state.py" "$CCP_HOME/ccp_state.py"
  chmod +x "$CCP_HOME/ccp_state.py" 2>/dev/null || true
  echo "state helper:  $CCP_HOME/ccp_state.py"
fi

mkdir -p "$CCP_HOME"
[ -f "$CCP_HOME/stop-mode" ] || printf 'off' > "$CCP_HOME/stop-mode"
echo "state dir ready: $CCP_HOME (stop-mode=off)"
echo
echo "next:  ccp start    (or: ccp stop-mode ask, then ccp start)"
