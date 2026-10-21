#!/usr/bin/env python3
"""ccp-server: localhost web dashboard for the ccp control plane.

Stdlib only (no pip, no node). Reads/writes the same state files the hooks
use, so the dashboard and hooks never disagree:

  GET  /            HTML control panel (mobile-friendly, auto-refresh)
  GET  /api/state   JSON: mode, count, sessions tail, supervisor tail, alive
  POST /api/mode    body {"mode": "off|ask|exit"} -> writes stop-mode
  POST /api/reset   -> zeroes stop-count

Security: binds 127.0.0.1 by default (CCP_BIND to override), validates every
input against a whitelist, never shells out, never serves files outside
CCP_HOME.
"""
import json
import os
import signal
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = os.environ.get("CCP_HOME") or os.path.join(os.environ.get("HOME", "/"), ".ccp")
PORT = int(os.environ.get("CCP_PORT", "8799"))
BIND = os.environ.get("CCP_BIND", "127.0.0.1")
TAIL_LINES = int(os.environ.get("CCP_TAIL_LINES", "30"))
MODES = ("off", "ask", "exit")


def read_mode():
    try:
        with open(os.path.join(STATE, "stop-mode")) as f:
            m = f.read().strip()
        return m if m in MODES else "off"
    except OSError:
        return "off"


def read_count():
    try:
        return int(open(os.path.join(STATE, "stop-count")).read().strip() or 0)
    except (OSError, ValueError):
        return 0


def supervisor_alive():
    """Best-effort: is a ccp-supervisor process running?"""
    try:
        out = subprocess.run(
            ["pgrep", "-f", "ccp-supervisor"],
            capture_output=True, timeout=5,
        )
        # pgrep matches its own caller too on some systems; filter self
        pids = [p for p in out.stdout.decode().split() if p.strip()]
        return len(pids) > 1 or (len(pids) == 1 and not out.stderr)
    except Exception:
        return False


def tail_file(path, n=TAIL_LINES):
    try:
        with open(path, errors="replace") as f:
            return f.readlines()[-n:]
    except OSError:
        return []


def state():
    sessions = []
    for line in tail_file(os.path.join(STATE, "sessions.jsonl")):
        try:
            sessions.append(json.loads(line))
        except ValueError:
            sessions.append({"raw": line.strip()})
    sup = [l.rstrip("\n") for l in tail_file(os.path.join(STATE, "supervisor.log"), 15)]
    return {
        "mode": read_mode(),
        "stop_count": read_count(),
        "supervisor_alive": supervisor_alive(),
        "sessions": sessions[-TAIL_LINES:],
        "supervisor_log": sup,
        "ccp_home": STATE,
        "port": PORT,
    }


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ccp control plane</title>
<style>
:root {
  --bg: #0d1117; --panel: #161b22; --line: #30363d; --fg: #e6edf3;
  --muted: #8b949e; --off: #3fb950; --ask: #d29922; --exit: #f85149;
  --btn: #21262d; --btn-hi: #30363d;
}
@media (prefers-color-scheme: light) {
  :root { --bg: #f6f8fa; --panel: #ffffff; --line: #d0d7de; --fg: #1f2328;
          --muted: #656d76; --btn: #f6f8fa; --btn-hi: #eaeef2; }
}
* { box-sizing: border-box; }
body { background: var(--bg); color: var(--fg);
       font: 15px/1.5 system-ui, sans-serif; margin: 0; padding: 16px; }
.wrap { max-width: 720px; margin: 0 auto; }
h1 { font-size: 18px; margin: 0 0 4px; }
.sub { color: var(--muted); font-size: 13px; margin-bottom: 16px; }
.card { background: var(--panel); border: 1px solid var(--line);
        border-radius: 10px; padding: 14px; margin-bottom: 12px; }
.row { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
.badge { padding: 3px 10px; border-radius: 999px; font-weight: 600;
         font-size: 13px; border: 1px solid var(--line); }
.badge.off { background: var(--off); color: #000; }
.badge.ask { background: var(--ask); color: #000; }
.badge.exit { background: var(--exit); color: #fff; }
button { background: var(--btn); color: var(--fg); border: 1px solid var(--line);
         border-radius: 8px; padding: 9px 14px; font: inherit; cursor: pointer; }
button:hover { background: var(--btn-hi); }
button.active { outline: 2px solid var(--fg); }
button.danger { border-color: var(--exit); }
pre { background: var(--bg); border: 1px solid var(--line); border-radius: 8px;
      padding: 10px; overflow-x: auto; font-size: 12px; max-height: 260px;
      overflow-y: auto; margin: 8px 0 0; }
.alive { color: var(--off); } .dead { color: var(--muted); }
.label { color: var(--muted); font-size: 12px; text-transform: uppercase;
         letter-spacing: .05em; }
.toast { position: fixed; bottom: 16px; left: 50%; transform: translateX(-50%);
         background: var(--panel); border: 1px solid var(--line);
         padding: 8px 14px; border-radius: 8px; opacity: 0; transition: opacity .3s; }
.toast.show { opacity: 1; }
</style>
</head>
<body>
<div class="wrap">
  <h1>ccp control plane</h1>
  <div class="sub" id="home"></div>

  <div class="card">
    <div class="row">
      <span class="label">stop-mode</span>
      <span class="badge" id="mode">–</span>
      <span class="label" style="margin-left:auto">supervisor</span>
      <span id="sup" class="dead">?</span>
    </div>
    <div class="row" style="margin-top:12px">
      <button data-mode="off">off</button>
      <button data-mode="ask">ask</button>
      <button data-mode="exit">exit</button>
      <button id="reset" class="danger">reset count</button>
    </div>
    <div class="sub" style="margin-top:10px">
      stop-count: <b id="count">0</b> · blocks before yielding: 7
    </div>
  </div>

  <div class="card">
    <div class="label">sessions (tail)</div>
    <pre id="sessions">…</pre>
  </div>

  <div class="card">
    <div class="label">supervisor log (tail)</div>
    <pre id="suplog">…</pre>
  </div>
</div>
<div class="toast" id="toast"></div>
<script>
const $ = (id) => document.getElementById(id);
let toastTimer;
function toast(msg) {
  const t = $("toast"); t.textContent = msg; t.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove("show"), 1800);
}
async function refresh() {
  try {
    const s = await (await fetch("/api/state")).json();
    $("home").textContent = s.ccp_home + " · port " + s.port;
    $("mode").textContent = s.mode;
    $("mode").className = "badge " + s.mode;
    $("count").textContent = s.stop_count;
    $("sup").textContent = s.supervisor_alive ? "running" : "not running";
    $("sup").className = s.supervisor_alive ? "alive" : "dead";
    document.querySelectorAll("button[data-mode]").forEach(b =>
      b.classList.toggle("active", b.dataset.mode === s.mode));
    $("sessions").textContent =
      s.sessions.map(x => JSON.stringify(x)).join("\\n") || "(none)";
    $("suplog").textContent = s.supervisor_log.join("\\n") || "(empty)";
  } catch (e) { $("sup").textContent = "server error"; }
}
async function post(path, body) {
  try {
    const r = await fetch(path, { method: "POST",
      headers: {"Content-Type": "application/json"},
      body: body ? JSON.stringify(body) : "{}" });
    if (!r.ok) throw new Error(await r.text());
    toast("done"); refresh();
  } catch (e) { toast("error: " + e.message); }
}
document.querySelectorAll("button[data-mode]").forEach(b =>
  b.addEventListener("click", () => post("/api/mode", {mode: b.dataset.mode})));
$("reset").addEventListener("click", () => post("/api/reset"));
refresh();
setInterval(refresh, 3000);
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0].split("#", 1)[0]
        if path in ("/", "/index.html"):
            self._send(200, PAGE.encode(), "text/html; charset=utf-8")
        elif path == "/api/state":
            self._send(200, json.dumps(state()).encode(), "application/json")
        else:
            self._send(404, b"not found", "text/plain")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            body = {}
        path = self.path.split("?", 1)[0].split("#", 1)[0]
        if path == "/api/mode":
            mode = body.get("mode")
            if mode not in MODES:
                self._send(400, json.dumps({"error": "mode must be one of %s" % (MODES,)}).encode(), "application/json")
                return
            with open(os.path.join(STATE, "stop-mode"), "w") as f:
                f.write(mode)
            self._send(200, json.dumps({"mode": mode}).encode(), "application/json")
        elif path == "/api/reset":
            with open(os.path.join(STATE, "stop-count"), "w") as f:
                f.write("0")
            self._send(200, json.dumps({"ok": True}).encode(), "application/json")
        else:
            self._send(404, b"not found", "text/plain")

    def log_message(self, fmt, *args):  # silence request logging
        pass


def main():
    os.makedirs(STATE, exist_ok=True)
    srv = ThreadingHTTPServer((BIND, PORT), Handler)
    pidfile = os.path.join(STATE, "ui.pid")
    with open(pidfile, "w") as f:
        f.write(str(os.getpid()))
    print(f"ccp ui: http://{BIND}:{PORT}  (state: {STATE})", flush=True)
    try:
        srv.serve_forever()
    finally:
        try:
            os.remove(pidfile)
        except OSError:
            pass


if __name__ == "__main__":
    main()
