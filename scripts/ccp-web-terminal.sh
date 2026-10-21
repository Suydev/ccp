#!/usr/bin/env bash
# ccp-web-terminal: serve the REAL Claude Code TUI in a browser over LAN.
#
#   ccp-web-terminal [port] [bind]
#
# Uses ttyd (pkg install ttyd). The Claude Code TUI needs a real terminal,
# so a plain web server cannot host it — ttyd gives it a pty.
#
# Phone-friendly: open http://<phone-ip>:<port>/ on any device on the same
# network. Termux needs the Android app for LAN access to be permitted.
set -u

PORT="${1:-${CCP_WEB_PORT:-7681}}"
BIND="${2:-${CCP_WEB_BIND:-0.0.0.0}}"
WORKDIR="${CCP_WORKDIR:-$HOME}"

command -v ttyd >/dev/null 2>&1 || {
  echo "ccp-web-terminal: ttyd not installed — run: pkg install ttyd" >&2
  exit 1
}

# Best-effort LAN IP so the user knows where to point a phone.
ip=""
if command -v ip >/dev/null 2>&1; then
  ip=$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 \
       | grep -v '^127\.' | head -1)
fi

echo "ccp web terminal:"
echo "  local:   http://127.0.0.1:${PORT}/"
[ -n "$ip" ] && echo "  network: http://${ip}:${PORT}/   (same Wi-Fi)"
echo "  press Ctrl-C to stop"

exec ttyd -p "$PORT" -i "$BIND" -W bash -lc "cd '$WORKDIR' && exec claude"
