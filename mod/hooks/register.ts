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

const ASK_INSTRUCTION =
  'ccp: stop-mode is ASK. On EVERY turn end you must call the ' +
  'AskUserQuestion tool with options "continue", "new task", "exit" ' +
  '— ask again every time, not just the first time. Never end a turn ' +
  'silently while in ask mode. If the user picks exit, tell them to ' +
  'run /ccp exit, which allows the session to end. If AskUserQuestion is ' +
  'not in your tool list, load it with ToolSearch first: ' +
  'query "select:AskUserQuestion".'

/**
 * The stop-mode, read straight from the state file.
 *
 * Reading the file here (rather than shelling out to the helper) keeps the
 * mod free of a helper-path dependency, and the mode file is the same file
 * the Stop hook and the /ccp command read, so all three always agree.
 */
async function readMode($: EngineInterface): Promise<string> {
  try {
    // `$.env.get` is the sanctioned accessor in a plugin's environment;
    // `process` is not available there.
    const ccpHome = await $.env.get('CCP_HOME')
    const home = await $.env.get('HOME')
    const state = ccpHome || `${home ?? ''}/.ccp`
    const { stdout, exitCode } = await $.process.run(
      ['cat', `${state}/stop-mode`],
      { timeoutMs: 3000 },
    )
    if (exitCode !== 0) return 'off'
    const m = stdout.trim()
    return m === 'ask' || m === 'exit' ? m : 'off'
  } catch {
    return 'off'
  }
}

export const register: Register = (on, options) => {
  const enabled = options?.userConfig as Record<string, unknown> | undefined
  if (enabled && enabled.enabled === false) return

  // Re-assert ask-mode on every prompt. Switching to ask-mode mid-session
  // would otherwise leave the model with no instruction to keep asking, and
  // the Stop gate would block turns without ever showing the question.
  on('prompt.submit', async ($, e, next) => {
    const context = e.context ?? []
    if ((await readMode($)) === 'ask') {
      return next({ ...e, context: [...context, ASK_INSTRUCTION] })
    }
    return next({ ...e, context })
  }).catch(($, e, next) => next(e))


}
