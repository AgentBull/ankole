import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { buildTool } from '../build-tool'
import { executionScopeTag, type ComputerToolContext } from './context'
import { truncateOutput } from './format'

const SESSION_NAME = /^[A-Za-z0-9_.-]{1,64}$/
const SCOPE_SEPARATOR = '--s-'

/**
 * tmux names are namespaced per execution scope (conversation) on the worker,
 * so two conversations of one agent can both run a session called `main`.
 * The model keeps seeing the plain name.
 */
function scopedTmuxName(context: ComputerToolContext, name: string): string {
  return `${name}${SCOPE_SEPARATOR}${executionScopeTag(context)}`
}

/**
 * Strips the scope suffix back off so every name returned to the model is the plain one it passed
 * in. The scoping is an internal detail; the model should never see or have to reproduce the hash.
 */
function unscopedTmuxName(context: ComputerToolContext, name: string): string {
  const suffix = `${SCOPE_SEPARATOR}${executionScopeTag(context)}`
  return name.endsWith(suffix) ? name.slice(0, -suffix.length) : name
}

const InteractiveTerminalParams = z.object({
  action: z
    .enum(['list', 'start', 'send', 'capture', 'kill'])
    .describe(
      "Action: 'start' a recoverable interactive terminal session, 'send' input/keys, 'capture' screen, 'kill', or 'list'."
    ),
  session: z
    .string()
    .optional()
    .describe(
      'Interactive terminal session name. Required for every action except list. Use letters, numbers, _, ., or -.'
    ),
  command: z
    .string()
    .optional()
    .describe("Command used by action=start. Defaults to 'bash'. Use this for TTY/TUI programs such as claude."),
  input: z.string().optional().describe('Text to send for action=send.'),
  keys: z
    .array(z.string())
    .optional()
    .describe('Additional terminal key names for action=send, such as Enter, Down, C-c, or Space.'),
  enter: z
    .boolean()
    .optional()
    .describe('For action=send, append Enter after input. Default true when input is present.'),
  workdir: z.string().optional().describe('Start directory for action=start. Default /workspace.'),
  lines: z.number().int().min(1).max(2000).optional().describe('Lines to capture for action=capture. Default 80.'),
  cols: z.number().int().min(40).max(300).optional().describe('Terminal columns for action=start. Default 140.'),
  rows: z.number().int().min(10).max(100).optional().describe('Terminal rows for action=start. Default 40.')
})

interface InteractiveTerminalDetails {
  action: string
  session?: string
  status?: string
}

function jsonResult(value: unknown, details: InteractiveTerminalDetails): AgentToolResult<InteractiveTerminalDetails> {
  return { content: [{ type: 'text', text: JSON.stringify(value) }], details }
}

/**
 * Validates a model-supplied session name before it becomes part of a worker-side tmux name.
 * The character/length whitelist keeps the name shell-safe and prevents it from colliding with or
 * injecting the scope separator.
 */
function requireSession(session: string | undefined): string {
  if (!session) throw new Error('session is required for this action')
  if (!SESSION_NAME.test(session)) throw new Error('session must match /^[A-Za-z0-9_.-]{1,64}$/')
  return session
}

/**
 * The model's tool for *interactive* TTY/TUI programs — Claude, REPLs, full-screen CLIs,
 * interactive installers — as opposed to the one-shot `command`/`terminal` tools.
 *
 * The difference that justifies a separate tool: these programs need a real terminal you can type
 * keystrokes into and read a rendered screen back from, and they outlive a single call. They are
 * backed by tmux on the worker so a session can be captured and resumed across turns; the model
 * drives them through start/send/capture/kill/list rather than ever touching tmux directly. Every
 * action maps to a tmux session whose name is scope-namespaced (see `scopedTmuxName`) and then
 * un-namespaced on the way out, so the model works in plain names while conversations stay isolated.
 */
export function createInteractiveTerminalTool(
  context: ComputerToolContext
): AgentTool<typeof InteractiveTerminalParams, InteractiveTerminalDetails> {
  return buildTool({
    name: 'interactive_terminal',
    label: 'Interactive Terminal',
    description:
      'Manage recoverable interactive terminal sessions in the computer for TTY/TUI programs such as Claude, REPLs, full-screen CLIs, and interactive installers. These sessions are backed internally by tmux so they can be captured and resumed through this tool; use this tool rather than calling tmux directly. Use start to launch a session, send to provide text or terminal keys, capture to inspect the screen, and kill when done. Use command or terminal for non-interactive shell commands. Do not use this for simple file reads or edits; use read_file and patch.',
    schema: InteractiveTerminalParams,
    executionMode: 'sequential',
    isDestructive: true,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<InteractiveTerminalDetails>> {
      const computer = await context.getComputer(signal)
      switch (params.action) {
        case 'list': {
          // The worker lists every tmux session it holds across all conversations of this agent;
          // filter down to the ones tagged for the current scope so a conversation only ever sees
          // its own terminals.
          const suffix = `${SCOPE_SEPARATOR}${executionScopeTag(context)}`
          const terminals = await computer.terminals.list({ signal })
          return jsonResult(
            {
              sessions: terminals
                .filter(terminal => terminal.name.endsWith(suffix))
                .map(terminal => ({
                  session: unscopedTmuxName(context, terminal.name),
                  windows: terminal.windows,
                  attached: terminal.attached
                }))
            },
            { action: 'list' }
          )
        }
        case 'start': {
          const session = requireSession(params.session)
          const command = params.command?.trim() || 'bash'
          const workdir = params.workdir?.trim() || '/workspace'
          const cols = params.cols ?? 140
          const rows = params.rows ?? 40
          const terminal = await computer.terminals.start(
            scopedTmuxName(context, session),
            { command, cwd: workdir, cols, rows },
            { signal }
          )
          const name = unscopedTmuxName(context, terminal.name)
          return jsonResult(
            { session: name, status: terminal.status },
            { action: 'start', session: name, status: terminal.status }
          )
        }
        case 'send': {
          const session = requireSession(params.session)
          const keys = [...(params.keys ?? [])]
          if (params.input === undefined && keys.length === 0) throw new Error('input or keys is required for send')
          const terminal = await computer.terminals.send(
            scopedTmuxName(context, session),
            { input: params.input, keys, enter: params.enter },
            { signal }
          )
          const name = unscopedTmuxName(context, terminal.name)
          return jsonResult(
            { session: name, status: terminal.status },
            { action: 'send', session: name, status: terminal.status }
          )
        }
        case 'capture': {
          const session = requireSession(params.session)
          const lines = params.lines ?? 80
          const capture = await computer.terminals.capture(scopedTmuxName(context, session), { lines }, { signal })
          const name = unscopedTmuxName(context, capture.name)
          return jsonResult(
            { session: name, screen: truncateOutput(capture.screen) },
            { action: 'capture', session: name, status: 'captured' }
          )
        }
        case 'kill': {
          const session = requireSession(params.session)
          const terminal = await computer.terminals.kill(scopedTmuxName(context, session), { signal })
          const name = unscopedTmuxName(context, terminal.name)
          return jsonResult(
            { session: name, status: terminal.status },
            { action: 'kill', session: name, status: terminal.status }
          )
        }
        default:
          throw new Error(`unsupported interactive_terminal action: ${String(params.action)}`)
      }
    }
  })
}
