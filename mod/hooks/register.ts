import type { EngineInterface, Register } from 'claude-code'

/**
 * ccp — Claude Code control plane, inside the GUI.
 *
 * Registers the `/ccp` slash command and keeps the model honest about
 * ask-mode: on every prompt, if stop-mode is `ask`, the model is told to
 * call AskUserQuestion at every turn end until the user picks exit.
 *
 * API notes (verified against the shipped `claude-code` type definitions,
 * not guessed):
 *   - `command.run` carries `e.command` (the name without the slash) and
 *     `e.args` (everything after it). There is no `e.name`.
 *   - Context for the model is attached by returning
 *     `next({ ...e, context: [...(e.context ?? []), hunk] })` from a
 *     `prompt.submit` hook — not by a separate `$.context.add` call.
 *   - `next(e)` takes the event object; `next()` with no argument is a
 *     type error.
 *   - A hook must return its event's result type, so the handlers below
 *     return whatever `next` resolved with.
 */

const MODES = ['off', 'ask', 'exit'] as const

/** The state helper, relative to this plugin's directory. */
const HELPER = '../scripts/ccp_state.py'

const ASK_INSTRUCTION =
  'ccp: stop-mode is ASK. On EVERY turn end you must call the ' +
  'AskUserQuestion tool with options "continue", "new task", "exit" ' +
  '— ask again every time, not just the first time. Never end a turn ' +
  'silently while in ask mode. If the user picks exit, tell them to ' +
  'run /ccp exit, which allows the session to end. If AskUserQuestion is ' +
  'not in your tool list, load it with ToolSearch first: ' +
  'query "select:AskUserQuestion".'

interface CcpState {
  mode: string
  count: number
  sessions: string[]
}

async function runState($: EngineInterface, args: string[], timeoutMs = 5000): Promise<string> {
  const root = $.plugin.root
  const { stdout, stderr, exitCode } = await $.process.run(
    ['python3', `${typeof root === 'string' ? root : '.'}/${HELPER}`, ...args],
    { timeoutMs },
  )
  if (exitCode !== 0) throw new Error(stderr.trim() || `ccp_state exited ${exitCode}`)
  return stdout
}

export const register: Register = (on, options) => {
  const enabled = options?.userConfig as Record<string, unknown> | undefined
  if (enabled && enabled.enabled === false) return

  on('session.start', async ($, _e, next) => {
    const result = await next(_e)
    await $.command.register({
      name: 'ccp',
      description: 'Control-plane status and stop-mode switch (/ccp [off|ask|exit|reset])',
    })
    return result
  }).catch(($, e, next) => next(e))

  // Re-assert ask-mode on every prompt. Switching to ask-mode mid-session
  // would otherwise leave the model with no instruction to keep asking, and
  // the Stop gate would block turns without ever showing the question.
  on('prompt.submit', async ($, e, next) => {
    let context = e.context ?? []
    try {
      const state: CcpState = JSON.parse(await runState($, ['status']))
      if (state.mode === 'ask') context = [...context, ASK_INSTRUCTION]
    } catch {
      // State files missing or unreadable: /ccp reports it when used.
    }
    return next({ ...e, context })
  }).catch(($, e, next) => next(e))

  on('command.run', async ($, e, next) => {
    if (e.command !== 'ccp') return next(e)

    const arg = String(e.args ?? '').trim().toLowerCase()
    try {
      if (!arg) return { ...(await next(e)), text: await runState($, ['card']) }
      if ((MODES as readonly string[]).includes(arg)) {
        return { ...(await next(e)), text: await runState($, [arg]) }
      }
      if (arg === 'reset') {
        return { ...(await next(e)), text: await runState($, ['reset']) }
      }
      return {
        ...(await next(e)),
        text: `unknown /ccp argument: ${arg}\n\n${await runState($, ['card'])}`,
      }
    } catch (err) {
      return {
        ...(await next(e)),
        text: `ccp state error: ${err instanceof Error ? err.message : String(err)}`,
      }
    }
  }).catch(($, e, next) => next(e))
}
