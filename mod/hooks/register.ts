import type { Engine, Register } from 'claude-code'

/**
 * ccp — Claude Code control plane, inside the GUI.
 *
 * Everything the control plane does, as slash commands typed right into the
 * Claude Code prompt:
 *
 *   /ccp                 — status card: mode, block count, recent sessions
 *   /ccp ask|off|exit    — switch stop-mode (hooks pick it up on the next stop)
 *   /ccp reset           — zero the stop-block counter
 *
 * All state operations go through one python3 helper (`scripts/ccp_state.py`
 * beside this file) invoked with $.process.run — argv, never a shell string,
 * so arguments can never become shell syntax. python3 boots in ~0.2 s here;
 * the mod's calls stay well inside any timeout.
 *
 * State lives in $CCP_HOME (default ~/.ccp) — the same files the Stop hook
 * and session bookends read, so every surface agrees.
 */

const MODES = ['off', 'ask', 'exit'] as const

/** The state helper, relative to this plugin's directory. */
const HELPER = '../scripts/ccp_state.py'

interface CcpState {
  mode: string
  count: number
  sessions: string[]
}

async function runState($: Engine, args: string[], timeoutMs = 5000): Promise<string> {
  const home = $.plugin.root
  const root = typeof home === 'string' ? home : '.'
  const { stdout, stderr, exitCode } = await $.process.run(
    ['python3', `${root}/${HELPER}`, ...args],
    { timeoutMs },
  )
  if (exitCode !== 0) throw new Error(stderr.trim() || `ccp_state exited ${exitCode}`)
  return stdout
}

export const register: Register = (on, options) => {
  if (options?.userConfig?.enabled === false) return

  on('session.start', async ($: Engine, _e, next) => {
    await next()
    await $.command.register({
      name: 'ccp',
      description: 'Control-plane status and stop-mode switch (/ccp [off|ask|exit|reset])',
    })
    // One context line, only when the gate is doing something (ask-mode), so
    // it costs nothing in the default off mode.
    try {
      const state: CcpState = JSON.parse(await runState($, ['status']))
      if (state.mode === 'ask') {
        await $.context.add(
          'ccp: stop-mode is ASK. On EVERY turn end you must call the ' +
            'AskUserQuestion tool with options "continue", "new task", "exit" ' +
            '— ask again every time, not just the first time. Never end a turn ' +
            'silently while in ask mode. If the user picks exit, tell them to ' +
            'run /ccp exit, which allows the session to end.',
        )
      }
    } catch {
      // State files missing or unreadable: the /ccp command reports it when used.
    }
  }).catch(($: Engine, e, next) => next(e))

  on('command.run', async ($: Engine, e, next) => {
    if (e.name !== 'ccp') return next(e)

    const arg = String(e.args ?? '').trim().toLowerCase()

    try {
      if (!arg) return { text: await runState($, ['card']) }
      if ((MODES as readonly string[]).includes(arg)) {
        return { text: await runState($, ['set', arg]) }
      }
      if (arg === 'reset') {
        return { text: await runState($, ['reset']) }
      }
      return { text: `unknown /ccp argument: ${arg}\n\n${await runState($, ['card'])}` }
    } catch (err) {
      return {
        text: `ccp state error: ${err instanceof Error ? err.message : String(err)}`,
      }
    }
  }).catch(($: Engine, e, next) => next(e))
}
