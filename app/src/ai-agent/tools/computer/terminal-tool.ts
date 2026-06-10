import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { buildTool } from '../build-tool'
import type { ComputerToolContext } from './context'
import { truncateOutput } from './format'

const TerminalParams = z.object({
  command: z
    .string()
    .min(1)
    .describe('Shell command to execute in the computer. The persistent shell retains cd/export/alias across calls.'),
  background: z
    .boolean()
    .optional()
    .describe('Run detached and return a session_id to manage with the process tool. Default false.'),
  workdir: z
    .string()
    .optional()
    .describe('Working directory (absolute /workspace/... or relative to the current shell cwd).'),
  timeout: z.number().int().min(1).optional().describe('Max seconds to wait for a foreground command (default 60).')
})

interface TerminalDetails {
  background: boolean
  exitCode: number | null
  sessionId?: string
}

export function createTerminalTool(context: ComputerToolContext): AgentTool<typeof TerminalParams, TerminalDetails> {
  return buildTool({
    name: 'terminal',
    label: 'Terminal',
    description:
      'Execute non-interactive shell commands in the computer. Foreground (default) runs in the persistent shell and returns output + exit code, retaining cd/export/alias. Set background=true for long-running non-TTY processes (servers, builds) and manage them with the process tool. Use interactive_terminal for Codex, Claude, REPLs, installers, and other TTY/TUI programs.',
    schema: TerminalParams,
    executionMode: 'sequential',
    isDestructive: true,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<TerminalDetails>> {
      const computer = await context.getComputer(signal)
      const timeoutMs = (params.timeout ?? 60) * 1000

      if (params.background) {
        const command = await computer.runCommand({
          cmd: 'bash',
          args: ['-lc', params.command],
          cwd: params.workdir,
          detached: true,
          timeoutMs,
          signal
        })
        context.backgroundIds.add(command.cmdId)
        return {
          content: [
            {
              type: 'text',
              text: `Background process started. session_id=${command.cmdId}. Use process(action='poll'|'wait'|'log'|'kill', session_id) to manage it.`
            }
          ],
          details: { background: true, exitCode: null, sessionId: command.cmdId }
        }
      }

      const result = await computer.runShellCommand(params.command, {
        cwd: params.workdir,
        shellScope: context.executionScopeId,
        timeoutMs,
        signal
      })
      const output = truncateOutput(await result.output('both', { signal }))
      return {
        content: [{ type: 'text', text: `exit_code=${result.exitCode}\n${output}` }],
        details: { background: false, exitCode: result.exitCode }
      }
    }
  })
}
