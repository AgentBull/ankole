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

function unscopedTmuxName(context: ComputerToolContext, name: string): string {
  const suffix = `${SCOPE_SEPARATOR}${executionScopeTag(context)}`
  return name.endsWith(suffix) ? name.slice(0, -suffix.length) : name
}

const InteractiveTerminalParams = z.object({
  action: z
    .enum(['list', 'start', 'send', 'capture', 'kill'])
    .describe("Action: 'start' a recoverable tmux session, 'send' input/keys, 'capture' screen, 'kill', or 'list'."),
  session: z
    .string()
    .optional()
    .describe('tmux session name. Required for every action except list. Use letters, numbers, _, ., or -.'),
  command: z
    .string()
    .optional()
    .describe("Command used by start. Defaults to 'bash'. Use this for TUI programs such as codex or claude."),
  input: z.string().optional().describe('Text to send for action=send.'),
  keys: z
    .array(z.string())
    .optional()
    .describe('Additional tmux key names for action=send, such as Enter, Down, C-c, or Space.'),
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

function requireSession(session: string | undefined): string {
  if (!session) throw new Error('session is required for this action')
  if (!SESSION_NAME.test(session)) throw new Error('session must match /^[A-Za-z0-9_.-]{1,64}$/')
  return session
}

export function createInteractiveTerminalTool(
  context: ComputerToolContext
): AgentTool<typeof InteractiveTerminalParams, InteractiveTerminalDetails> {
  return buildTool({
    name: 'interactive_terminal',
    label: 'Interactive Terminal',
    description:
      'Manage recoverable tmux sessions in the computer for TTY/TUI programs such as Codex, Claude, REPLs, and installers. Use start to launch, send to provide input/keys, capture to inspect the screen, and kill when done.',
    schema: InteractiveTerminalParams,
    executionMode: 'sequential',
    isDestructive: true,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<InteractiveTerminalDetails>> {
      const computer = await context.getComputer(signal)
      switch (params.action) {
        case 'list': {
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
