import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { buildTool } from '../build-tool'
import type { ComputerToolContext } from './context'
import { truncateOutput } from './format'

const CommandParams = z.object({
  command: z.string().min(1).describe('Shell command to execute as one stateless command in the computer.'),
  workdir: z
    .string()
    .optional()
    .describe('Working directory for this command. Absolute /workspace/... or relative to /workspace.'),
  timeout: z
    .number()
    .int()
    .min(1)
    .optional()
    .describe(
      'Max seconds to wait for the command (default 60). High values return immediately if the command is fast.'
    ),
  env: z.record(z.string(), z.string()).optional().describe('Environment variables for this command only.')
})

interface CommandDetails {
  exitCode: number
}

export function createCommandTool(context: ComputerToolContext): AgentTool<typeof CommandParams, CommandDetails> {
  return buildTool({
    name: 'command',
    label: 'Command',
    description:
      'Execute one stateless, non-interactive shell command in the computer. Use this for builds, installs, git, rg/find searches, package managers, scripts, network checks, and other one-shot commands that should not depend on persistent cd/export/alias state. Do not use cat/head/tail to read files; use read_file. Do not use sed/awk/perl/python scripts or heredocs to edit files; use patch. Use terminal when you intentionally need persistent shell state or a tracked background process. Use interactive_terminal for Codex, Claude, REPLs, installers, and other TTY/TUI programs.',
    schema: CommandParams,
    executionMode: 'sequential',
    isDestructive: true,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<CommandDetails>> {
      const computer = await context.getComputer(signal)
      const result = await computer.runCommand({
        cmd: 'bash',
        args: ['-lc', params.command],
        cwd: params.workdir,
        env: params.env,
        timeoutMs: (params.timeout ?? 60) * 1000,
        signal
      })
      const output = truncateOutput(await result.output('both', { signal }))
      return {
        content: [{ type: 'text', text: `exit_code=${result.exitCode}\n${output}` }],
        details: { exitCode: result.exitCode }
      }
    }
  })
}
