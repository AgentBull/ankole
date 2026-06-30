import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { buildTool } from '../build-tool'
import type { BackgroundCommandSnapshot, ComputerToolContext } from './context'
import { truncateOutput } from './format'

const CommandParams = z
  .object({
    action: z
      .enum(['run', 'status', 'kill', 'list'])
      .optional()
      .describe(
        'Action to perform. Omit or use run to execute a command; use status/kill with backgroundId; use list to show all background commands.'
      ),
    command: z.string().min(1).optional().describe('Shell command to execute. Required for action=run.'),
    background: z
      .boolean()
      .optional()
      .describe('When true, start the command in the background and return a backgroundId immediately.'),
    backgroundId: z.string().min(1).optional().describe('Background command id returned by a prior background run.'),
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
        'Max seconds to wait for the command. Defaults to 60 for foreground runs and 1800 for background runs.'
      ),
    env: z.record(z.string(), z.string()).optional().describe('Environment variables for this command only.')
  })
  .superRefine((params, ctx) => {
    const action = params.action ?? 'run'
    if (action === 'run' && !params.command) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['command'], message: 'command is required for run' })
    }
    if ((action === 'status' || action === 'kill') && !params.backgroundId) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['backgroundId'],
        message: 'backgroundId is required for status/kill'
      })
    }
  })

interface CommandDetails {
  exitCode?: number
  backgroundId?: string
  status?: 'running' | 'exited' | 'killed' | 'not_found'
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
      'Execute one stateless, non-interactive shell command in the computer. Use this for builds, installs, git, rg/find searches, package managers, scripts, network checks, and one-shot commands that should not depend on persistent cd/export/alias state. Set background=true for long-running non-interactive commands such as dev servers, then poll with action=status, list all with action=list, and stop with action=kill using the returned backgroundId. Do not use cat/head/tail to read files; use read_file. Do not use sed/awk/perl/python scripts or heredocs to edit files; use patch. Use interactive_terminal for direct TTY/TUI programs, REPLs, installers, and troubleshooting interactive CLIs.',
    schema: CommandParams,
    executionMode: 'sequential',
    isDestructive: true,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<CommandDetails>> {
      const computer = await context.getComputer(signal)
      const action = params.action ?? 'run'

      if (action === 'list') {
        const snapshots = await computer.backgroundCommands.list({ signal })
        if (snapshots.length === 0) {
          return { content: [{ type: 'text', text: 'no background commands' }], details: {} }
        }
        const lines = snapshots.map(snapshot => {
          const parts = [`background_id=${snapshot.id}`, `status=${snapshot.status}`]
          if (snapshot.exitCode !== undefined) parts.push(`exit_code=${snapshot.exitCode}`)
          parts.push(`command=${snapshot.command}`)
          return parts.join(' ')
        })
        return { content: [{ type: 'text', text: lines.join('\n') }], details: {} }
      }

      if (action === 'status' || action === 'kill') {
        const backgroundId = params.backgroundId!
        const snapshot =
          action === 'status'
            ? await computer.backgroundCommands.status(backgroundId, { signal })
            : await computer.backgroundCommands.kill(backgroundId, { signal })

        if (!snapshot) {
          return {
            content: [{ type: 'text', text: `background_id=${backgroundId}\nstatus=not_found` }],
            details: { backgroundId, status: 'not_found' }
          }
        }

        return backgroundResult(snapshot)
      }

      // `-lc` runs a login shell so any profile sourced inside the sandbox is applied. The sandbox
      // starts from bubblewrap `--clearenv`: only a fixed set of vars (PATH/HOME/LANG/TERM/
      // ANKOLE_WORKSPACE_ROOT, plus validated caller env) is injected, so this is the sandbox
      // environment, not the host user's. `timeout` is the worker-side execution budget in seconds
      // (default 60), passed as ms; the worker kills the process when it elapses.
      const timeoutSeconds = params.timeout ?? (params.background ? 1800 : 60)
      const runInput = {
        cmd: 'bash',
        args: ['-lc', params.command!],
        cwd: params.workdir,
        env: params.env,
        timeoutMs: timeoutSeconds * 1000,
        signal
      }

      if (params.background) {
        const snapshot = await computer.backgroundCommands.start(runInput)
        return backgroundResult(snapshot)
      }

      const result = await computer.runCommand({
        ...runInput,
        timeoutMs: timeoutSeconds * 1000
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

async function backgroundResult(snapshot: BackgroundCommandSnapshot): Promise<AgentToolResult<CommandDetails>> {
  const output = truncateOutput(await snapshot.output('both'))
  return {
    content: [
      {
        type: 'text',
        text: [
          `background_id=${snapshot.id}`,
          `status=${snapshot.status}`,
          snapshot.exitCode === undefined ? undefined : `exit_code=${snapshot.exitCode}`,
          output
        ]
          .filter((line): line is string => line !== undefined && line.length > 0)
          .join('\n')
      }
    ],
    details: {
      backgroundId: snapshot.id,
      status: snapshot.status,
      ...(snapshot.exitCode === undefined ? {} : { exitCode: snapshot.exitCode })
    }
  }
}
