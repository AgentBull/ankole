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
    .max(1800)
    .optional()
    .describe(
      'Max seconds to wait for the command (default 60, max 1800). High values return immediately if the command is fast.'
    ),
  env: z.record(z.string(), z.string()).optional().describe('Environment variables for this command only.')
})

interface CommandDetails {
  exitCode: number
}

/**
 * The model's tool for one-shot, stateless shell commands (builds, installs, git, searches).
 *
 * Each call runs through the worker's isolated `runCommand`, not the persistent shell, so nothing
 * a command does to cwd/env/aliases leaks into the next one. That isolation is the whole point of
 * having `command` separate from `interactive_terminal`: callers who explicitly want
 * carried-over interactive state reach for `interactive_terminal` instead. The long `description` is what the model reads, and it deliberately
 * steers the model away from cat/sed/heredoc tricks toward the dedicated read_file/patch tools.
 */
export function createCommandTool(context: ComputerToolContext): AgentTool<typeof CommandParams, CommandDetails> {
  return buildTool({
    name: 'command',
    label: 'Command',
    description:
      'Execute one stateless, non-interactive shell command in the computer. Use this for builds, installs, git, rg/find searches, package managers, scripts, network checks, and other one-shot commands that should not depend on persistent cd/export/alias state. Do not use cat/head/tail to read files; use read_file. Do not use sed/awk/perl/python scripts or heredocs to edit files; use patch. Use interactive_terminal for direct TTY/TUI programs, REPLs, installers, and troubleshooting interactive CLIs.',
    schema: CommandParams,
    executionMode: 'sequential',
    isDestructive: true,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<CommandDetails>> {
      const computer = await context.getComputer(signal)
      // `-lc` runs a login shell so PATH and profile-provided tooling are present, matching what a
      // user typing the command would get. `timeout` is the worker-side execution budget in
      // seconds (default 60), passed as ms; the worker kills the process when it elapses.
      const result = await computer.runCommand({
        cmd: 'bash',
        args: ['-lc', params.command],
        cwd: params.workdir,
        env: params.env,
        timeoutMs: (params.timeout ?? 60) * 1000,
        signal
      })
      // stdout and stderr are merged and truncated before going back to the model, so a runaway
      // command cannot blow the context window. The `exit_code=` prefix gives the model the result
      // up front even when the tail of the output was dropped.
      const output = truncateOutput(await result.output('both', { signal }))
      return {
        content: [{ type: 'text', text: `exit_code=${result.exitCode}\n${output}` }],
        details: { exitCode: result.exitCode }
      }
    }
  })
}
