import type { Engine, Register } from 'claude-code'

/**
 * ccp — Claude Code control plane, inside the GUI.
 *
 * Everything the terminal `ccp` tool does, as slash commands typed right into
 * the Claude Code prompt:
 *
 *   /ccp                 — status card: mode, block count, recent sessions
 *   /ccp ask|off|exit    — switch stop-mode (hooks pick it up on the next stop)
 *   /ccp reset           — zero the stop-block counter
 *
 * No shell for state changes: mode and count are single fixed-string file
 * writes, done with fs, so an argument can never become shell syntax. The
 * optional `ccp statusline` helper and the web dashboard remain available for
 * outside-the-TUI use, but nothing here requires them.
 *
 * State lives in $CCP_HOME (default ~/.ccp) — the same files the Stop hook
 * and session bookends read, so every surface agrees.
 */

const MODES = ['off', 'ask', 'exit'] as const
type Mode = (typeof MODES)[number]

const MAX_BLOCKS = 7

function ccpHome($: Engine): string {
  // The env var the hooks were installed with wins; HOME is the fallback.
  const envHome = $.process.env?.CCP_HOME
  return (typeof envHome === 'string' && envHome) || `${$.process.env.HOME ?? ''}/.ccp`
}

function readText($: Engine, path: string): string {
  try {
    return $.fs.readFileSync(path, 'utf8').trim()
  } catch {
    return ''
  }
}

function readMode($: Engine): Mode {
  const m = readText($, `${ccpHome($)}/stop-mode`)
  return (MODES as readonly string[]).includes(m) ? (m as Mode) : 'off'
}

function readCount($: Engine): number {
  const n = Number.parseInt(readText($, `${ccpHome($)}/stop-count`) || '0', 10)
  return Number.isFinite(n) ? n : 0
}

function writeText($: Engine, path: string, text: string): void {
  $.fs.mkdirSync(ccpHome($), { recursive: true })
  $.fs.writeFileSync(path, text)
}

function tailSessions($: Engine, n: number): string[] {
  try {
    const raw = $.fs.readFileSync(`${ccpHome($)}/sessions.jsonl`, 'utf8')
    return raw.split('\n').filter(Boolean).slice(-n)
  } catch {
    return []
  }
}

function statusCard($: Engine): string {
  const mode = readMode($)
  const count = readCount($)
  const sessions = tailSessions($, 5)
  const lines = [
    `ccp — stop-mode: ${mode} · stop-count: ${count}/${MAX_BLOCKS}`,
    '',
    'modes:  /ccp off   (turns end normally)',
    '        /ccp ask   (Claude must ask: continue / new task / exit)',
    '        /ccp exit  (allow the session to end)',
    '        /ccp reset (zero the block counter)',
    '',
  ]
  if (sessions.length) {
    lines.push('recent sessions:')
    for (const s of sessions) lines.push(`  ${s}`)
  } else {
    lines.push('no sessions recorded yet')
  }
  return lines.join('\n')
}

export const register: Register = (on, options) => {
  if (options?.userConfig?.enabled === false) return

  on('session.start', async ($: Engine, _e, next) => {
    await next()
    await $.command.register({
      name: 'ccp',
      description: 'Control-plane status and stop-mode switch (/ccp [off|ask|exit|reset])',
    })
    // Context injection on session start: one line, only when the gate is
    // doing something (ask-mode), so it costs nothing when off.
    if (readMode($) !== 'ask') return
    await $.context.add(
      'ccp: stop-mode is ASK — at each turn end, ask the user via AskUserQuestion: continue / new task / exit. If they pick exit, tell them to run /ccp exit, which allows the stop.',
    )
  }).catch(($: Engine, e, next) => next(e))

  on('command.run', async ($: Engine, e, next) => {
    if (e.name !== 'ccp') return next(e)

    const arg = String(e.args ?? '').trim().toLowerCase()

    if (!arg) return { text: statusCard($) }

    if ((MODES as readonly string[]).includes(arg)) {
      const prev = readMode($)
      writeText($, `${ccpHome($)}/stop-mode`, arg)
      return {
        text:
          arg === prev
            ? `already ${arg}`
            : `stop-mode: ${prev} → ${arg}${
                arg === 'ask'
                  ? ' — at your next turn end, Claude will ask: continue / new task / exit.'
                  : arg === 'exit'
                    ? ' — the next turn is allowed to end; the supervisor loop (if running) will stop.'
                    : ''
              }`,
      }
    }

    if (arg === 'reset') {
      writeText($, `${ccpHome($)}/stop-count`, '0')
      return { text: 'stop-count reset to 0' }
    }

    return {
      text: `unknown /ccp argument: ${arg}\n\n${statusCard($)}`,
    }
  }).catch(($: Engine, e, next) => next(e))

