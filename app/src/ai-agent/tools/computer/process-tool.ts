import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { buildTool } from '../build-tool'
import type { ComputerToolContext } from './context'
import { truncateOutput } from './format'

const ProcessParams = z.object({
  action: z
    .enum(['list', 'poll', 'log', 'wait', 'kill'])
    .describe(
      "Action: 'list' (background sessions), 'poll' (status + recent output), 'log' (full output), 'wait' (block until exit), 'kill' (terminate)."
    ),
  session_id: z
    .string()
    .optional()
    .describe('Background session id from terminal(background=true). Required for every action except list.'),
  timeout: z
    .number()
    .int()
    .min(1)
    .max(1800)
    .optional()
    .describe('Max seconds to block for wait (default 60, max 1800).')
})

const KILL_GRACE_MS = 3000
const TERMINAL_STATUSES = new Set(['finished', 'killed', 'error'])

interface ProcessDetails {
  action: string
  sessionId?: string
  status?: string
  exitCode?: number | null
}

function jsonResult(value: unknown, details: ProcessDetails): AgentToolResult<ProcessDetails> {
  return { content: [{ type: 'text', text: JSON.stringify(value) }], details }
}

function waitSignal(
  signal: AbortSignal | undefined,
  timeoutSeconds: number | undefined
): { signal: AbortSignal; timeoutSignal: AbortSignal } {
  const timeout = AbortSignal.timeout((timeoutSeconds ?? 60) * 1000)
  return { signal: signal ? AbortSignal.any([signal, timeout]) : timeout, timeoutSignal: timeout }
}

export function createProcessTool(context: ComputerToolContext): AgentTool<typeof ProcessParams, ProcessDetails> {
  return buildTool({
    name: 'process',
    label: 'Process',
    description:
      'Manage background processes started with terminal(background=true). Use list for tracked sessions, poll for status and recent output, log for full output, wait to block until exit, and kill to terminate. Use this after starting servers, watchers, long builds, deploys, test suites, or CI pollers in the background. stdin write/submit/close are not supported in this computer version; use interactive_terminal for interactive programs.',
    schema: ProcessParams,
    executionMode: 'sequential',
    isDestructive: true,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<ProcessDetails>> {
      const computer = await context.getComputer(signal)

      if (params.action === 'list') {
        const commands = await computer.listCommands({ signal })
        const processes = commands
          .filter(command => command.detached || context.backgroundIds.has(command.id))
          .map(command => ({
            session_id: command.id,
            status: command.status,
            exit_code: command.exitCode ?? null
          }))
        return jsonResult({ processes }, { action: 'list' })
      }

      const sessionId = params.session_id
      if (!sessionId) throw new Error('session_id is required for this action')
      const command = computer.getCommand(sessionId)

      switch (params.action) {
        case 'poll': {
          const status = await command.status({ signal })
          const preview = truncateOutput(await command.output('both', { signal, follow: false }), 2000)
          return jsonResult(
            { session_id: sessionId, status: status.status, exit_code: status.exitCode, output_preview: preview },
            { action: 'poll', sessionId, status: status.status, exitCode: status.exitCode }
          )
        }
        case 'log': {
          const output = truncateOutput(await command.output('both', { signal, follow: false }))
          return jsonResult({ session_id: sessionId, output }, { action: 'log', sessionId })
        }
        case 'wait': {
          const waiter = waitSignal(signal, params.timeout)
          try {
            const finished = await command.wait({ signal: waiter.signal })
            context.backgroundIds.delete(sessionId)
            return jsonResult(
              {
                session_id: sessionId,
                status: 'exited',
                exit_code: finished.exitCode,
                output: truncateOutput(await finished.output('both', { signal }))
              },
              { action: 'wait', sessionId, status: 'exited', exitCode: finished.exitCode }
            )
          } catch (error) {
            if (!waiter.timeoutSignal.aborted) throw error
            return jsonResult(
              { session_id: sessionId, status: 'timeout' },
              { action: 'wait', sessionId, status: 'timeout' }
            )
          }
        }
        case 'kill': {
          await killGracefully(command, signal)
          context.backgroundIds.delete(sessionId)
          return jsonResult(
            { session_id: sessionId, status: 'killed' },
            { action: 'kill', sessionId, status: 'killed' }
          )
        }
        default:
          throw new Error(`unsupported process action: ${String(params.action)}`)
      }
    }
  })
}

async function killGracefully(
  command: {
    kill(signal?: string | number, opts?: { abortSignal?: AbortSignal }): Promise<void>
    status(opts?: { signal?: AbortSignal }): Promise<{ status: string }>
    wait(opts?: { signal?: AbortSignal }): Promise<unknown>
  },
  signal?: AbortSignal
): Promise<void> {
  await command.kill('SIGTERM', { abortSignal: signal })
  try {
    await command.wait({
      signal: signal
        ? AbortSignal.any([signal, AbortSignal.timeout(KILL_GRACE_MS)])
        : AbortSignal.timeout(KILL_GRACE_MS)
    })
  } catch {
    // Grace period expired or caller aborted; status check below decides whether force is needed.
  }
  const status = await command.status({ signal })
  if (!TERMINAL_STATUSES.has(status.status)) {
    await command.kill('SIGKILL', { abortSignal: signal })
  }
}
