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

/**
 * The model's tool for shell commands that need to remember state, plus tracked background jobs.
 *
 * Two paths. Foreground runs through the worker's *persistent* shell (`runShellCommand`), so a `cd`
 * or `export` in one call is still in effect on the next — the opposite of the stateless `command`
 * tool. Background (`background: true`) starts a detached process and hands back a `session_id`
 * instead of waiting, for servers, watchers, and other long-runners; the id is recorded in
 * `context.backgroundIds` so the `process` tool can later poll, tail, wait on, or kill it. The
 * description steers the model to let BullX own the lifecycle rather than reaching for nohup/`&`.
 */
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
        // Background work runs through `runCommand` (detached), not the persistent shell: a
        // long-lived job should be a tracked process the `process` tool can manage, not something
        // tied to the shared shell's lifecycle. `timeoutMs` here caps how long the worker lets the
        // detached process live overall.
        const command = await computer.runCommand({
          cmd: 'bash',
          args: ['-lc', params.command],
          cwd: params.workdir,
          detached: true,
          timeoutMs,
          signal
        })
        // Record the id so `process(action='list')` shows it and the other process actions accept
        // it; this is the handoff point between the two tools.
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

      // Foreground: run in the persistent shell scoped to this conversation. `shellScope` keeps
      // each conversation on its own shell, so concurrent conversations of one agent do not stomp
      // on each other's cwd/env.
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
