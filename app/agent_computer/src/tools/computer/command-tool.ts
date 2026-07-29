import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { commandActivityLabel } from '../activity-summary'
import type { ComputerToolContext } from './context'
import { truncateOutput } from './format'

const ForegroundCommandDefaultTimeoutSeconds = 180

const CommandParams = z
  .object({
    command: z.string().min(1).describe('Shell command to execute.'),
    workdir: z
      .string()
      .optional()
      .describe(
        'Working directory for this command. Use a real absolute Agent Home path or a workspace-relative path.'
      ),
    timeout: z
      .number()
      .int()
      .min(1)
      .optional()
      .describe(`Max seconds to wait for the command. Defaults to ${ForegroundCommandDefaultTimeoutSeconds}.`),
    env: z.record(z.string(), z.string()).optional().describe('Environment variables for this command only.')
  })
  .strict()

interface CommandDetails {
  durationMs?: number
  exitCode?: number
}

/**
 * The model's tool for one-shot, stateless shell commands (builds, installs, git, searches).
 *
 * Each call runs through the worker's isolated `runCommand`, so nothing a command does to
 * cwd/env/aliases leaks into the next one. The long `description` is what the model reads, and it
 * deliberately steers the model away from persistent processes and cat/sed/heredoc tricks.
 */
export function createCommandTool(context: ComputerToolContext): AgentTool<typeof CommandParams, CommandDetails> {
  return {
    name: 'command',
    description:
      'Execute one foreground, stateless, non-interactive shell command in the computer. Use this for quick builds, tests, installs, git, rg/find searches, package managers, scripts, network checks, and one-shot commands that do not depend on persistent cd/export/alias or process state. If a required workflow says to run, build, test, or verify with a shell command, call this tool before saying that step ran or passed; future-tense text does not execute a command. The command must finish within this call; use create_background_job for work that needs a persistent process, interactive session, or more than the active exchange. Do not use cat/head/tail to read files; use read_file. Do not use sed/awk or heredocs to edit files; use apply_patch.',
    schema: CommandParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    describeActivity: params => commandActivityLabel(params.command),
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<CommandDetails>> {
      const computer = await context.getComputer(signal)

      // `-lc` runs a login shell so any profile sourced inside the sandbox is applied. The sandbox
      // starts from bubblewrap `--clearenv`: only a fixed set of vars (PATH/HOME/LANG/TERM/
      // ANKOLE_AGENT_HOME, plus validated caller env) is injected, so this is the sandbox
      // environment, not the host user's. `timeout`, when provided, is the
      // command execution budget in seconds, passed as ms; the worker kills
      // the process when it elapses.
      const timeoutSeconds = params.timeout ?? ForegroundCommandDefaultTimeoutSeconds
      const runInput = {
        cmd: 'bash',
        args: ['-lc', params.command],
        cwd: params.workdir,
        env: params.env,
        timeoutMs: timeoutSeconds * 1000,
        signal
      }
      const startedAt = Date.now()
      const result = await computer.runCommand(runInput)
      const durationMs = Date.now() - startedAt
      // stdout and stderr are merged and truncated before going back to the model, so a runaway
      // command cannot blow the context window. The `exit_code=` prefix gives the model the result
      // up front even when the tail of the output was dropped.
      const output = truncateOutput(await result.output('both', { signal }))
      const text = formatForegroundCommandResult({
        command: params.command,
        durationMs,
        exitCode: result.exitCode,
        output,
        timeoutSeconds
      })
      return {
        content: [{ type: 'text', text }],
        details: { durationMs, exitCode: result.exitCode }
      }
    }
  }
}

/**
 * Formats foreground command output with exit code, duration, and timeout hints.
 */
function formatForegroundCommandResult(input: {
  command: string
  durationMs: number
  exitCode: number
  output: string
  timeoutSeconds: number
}): string {
  const lines = [`exit_code=${input.exitCode}`, `duration=${formatDuration(input.durationMs)}`]
  const note = exitCodeNote(input.command, input.exitCode)
  if (note) lines.push(`exit_code_note: ${note}`)
  if (isLikelyForegroundTimeout(input.exitCode, input.durationMs, input.timeoutSeconds)) {
    lines.push(
      `command timed out after ${input.timeoutSeconds}s (foreground budget). Narrow the command (shorter probe or smaller input) and split the work, or use create_background_job when it cannot finish in the active exchange.`
    )
  }
  if (input.output.length > 0) lines.push(input.output)
  return lines.join('\n')
}

/**
 * Formats command duration for model-visible output.
 */
function formatDuration(durationMs: number): string {
  if (durationMs < 1000) return `${durationMs}ms`
  return `${(durationMs / 1000).toFixed(1)}s`
}

/**
 * Detects the common `timeout` exit-code path for foreground commands.
 */
function isLikelyForegroundTimeout(exitCode: number, durationMs: number, timeoutSeconds: number): boolean {
  if (exitCode !== 124) return false
  const timeoutMs = timeoutSeconds * 1000
  return durationMs >= Math.max(0, timeoutMs - 1000)
}

/**
 * Adds known non-error meanings for common command exit code 1 cases.
 */
function exitCodeNote(command: string, exitCode: number): string | undefined {
  const name = lastCommandName(command)
  if (!name) return undefined
  if ((name === 'grep' || name === 'rg' || name === 'ag') && exitCode === 1) {
    return `${name} exit 1 = no matches found (not an error)`
  }
  if ((name === 'test' || name === '[') && exitCode === 1) {
    return `${name} exit 1 = condition is false (not an execution error)`
  }
  if ((name === 'diff' || name === 'cmp') && exitCode === 1) {
    return `${name} exit 1 = inputs differ (not an execution error)`
  }
  return undefined
}

/**
 * Extracts the last command name from a simple shell command string.
 */
function lastCommandName(command: string): string | undefined {
  const segments = command.split(/\|\||&&|;|\|/g)
  const segment = segments.at(-1)?.trim()
  if (!segment) return undefined
  const token = segment.match(/^(?:env\s+)?(?:(?:[A-Za-z_][A-Za-z0-9_]*)=[^\s]+\s+)*([^\s]+)/)?.[1]
  return token?.replace(/^.*\//, '')
}
