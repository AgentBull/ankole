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
  timeout: z
    .number()
    .int()
    .min(1)
    .max(1800)
    .optional()
    .describe(
      'Max seconds to wait for a foreground command (default 60, max 1800). High values return immediately if fast.'
    )
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
      "Execute non-interactive shell commands in the computer when persistent shell state matters. The foreground path returns output and exit code while retaining cd/export/alias across calls. Set background=true for long-lived or long-running non-TTY processes such as servers, watchers, builds, deploys, and test suites, then use process(action='poll'|'wait'|'log'|'kill') to manage them. Do not use shell-level background wrappers such as nohup, disown, setsid, or trailing '&' when BullX should track lifecycle. Do not use cat/head/tail to read files; use read_file. Do not use sed/awk/perl/python scripts or heredocs to edit files; use patch. Use command for stateless one-shot shell commands. Use interactive_terminal for direct TTY/TUI programs, REPLs, installers, and troubleshooting interactive CLIs.",
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
