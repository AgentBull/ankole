import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { TEXT_TURN_TIMEOUT_MS } from '../../core/turns/turn_config'
import type { BackgroundCommandSnapshot, ComputerToolContext } from './context'
import { truncateOutput } from './format'

const TOOL_TIMEOUT_MARGIN_MS = 15_000
const ForegroundCommandTimeoutMaxSeconds = Math.max(
  1,
  Math.floor((TEXT_TURN_TIMEOUT_MS - TOOL_TIMEOUT_MARGIN_MS) / 1000)
)
const BackgroundCommandTimeoutMaxSeconds = 1800
const SYSTEM_ROOT_TRAVERSAL_COMMANDS = new Set(['du', 'find', 'tree'])
const RECURSIVE_LIST_COMMANDS = new Set(['ls'])
const RECURSIVE_SEARCH_COMMANDS = new Set(['grep', 'egrep', 'fgrep', 'ag'])
const RECURSIVE_BY_DEFAULT_SEARCH_COMMANDS = new Set(['rg'])

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
      .max(BackgroundCommandTimeoutMaxSeconds)
      .optional()
      .describe(
        `Max seconds to wait for the command. Foreground runs must fit the current text-turn budget (${ForegroundCommandTimeoutMaxSeconds}s max); use background=true for longer commands up to ${BackgroundCommandTimeoutMaxSeconds}s.`
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
    if (
      action === 'run' &&
      params.background !== true &&
      params.timeout !== undefined &&
      params.timeout > ForegroundCommandTimeoutMaxSeconds
    ) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['timeout'],
        message: `foreground timeout must be <= ${ForegroundCommandTimeoutMaxSeconds}s; use background=true for longer commands`
      })
    }
  })

interface CommandDetails {
  durationMs?: number
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
  return {
    name: 'command',
    description:
      'Execute one stateless, non-interactive shell command in the computer. Use this for builds, installs, git, rg/find searches, package managers, scripts, network checks, and one-shot commands that should not depend on persistent cd/export/alias state. Set background=true for long-running non-interactive commands such as dev servers, then poll with action=status, list all with action=list, and stop with action=kill using the returned backgroundId. Do not use cat/head/tail to read files; use read_file. Do not use sed/awk/perl/python scripts or heredocs to edit files; use patch. Use interactive_terminal for direct TTY/TUI programs, REPLs, installers, and troubleshooting interactive CLIs.',
    schema: CommandParams,
    executionMode: 'sequential',
    isReadOnly: false,
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

        return backgroundResult(snapshot, { incremental: action === 'status' })
      }

      const rootTraversalRefusal = systemRootTraversalRefusal(params.command!)
      if (rootTraversalRefusal) {
        return {
          content: [{ type: 'text', text: rootTraversalRefusal }],
          details: { exitCode: 2 }
        }
      }

      // `-lc` runs a login shell so any profile sourced inside the sandbox is applied. The sandbox
      // starts from bubblewrap `--clearenv`: only a fixed set of vars (PATH/HOME/LANG/TERM/
      // ANKOLE_WORKSPACE_ROOT, plus validated caller env) is injected, so this is the sandbox
      // environment, not the host user's. `timeout` is the worker-side execution budget in seconds
      // (default 60), passed as ms; the worker kills the process when it elapses.
      const timeoutSeconds = params.timeout ?? (params.background ? BackgroundCommandTimeoutMaxSeconds : 60)
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

      const startedAt = Date.now()
      const result = await computer.runCommand({
        ...runInput,
        timeoutMs: timeoutSeconds * 1000
      })
      const durationMs = Date.now() - startedAt
      // stdout and stderr are merged and truncated before going back to the model, so a runaway
      // command cannot blow the context window. The `exit_code=` prefix gives the model the result
      // up front even when the tail of the output was dropped.
      const output = truncateOutput(await result.output('both', { signal }))
      const text = formatForegroundCommandResult({
        command: params.command!,
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
 * Rejects obvious filesystem-wide scans before they reach the sandbox.
 *
 * This is deliberately conservative: it is not a full shell parser and only
 * blocks commands that plainly point common recursive walkers/searchers at `/`.
 * Workspace scans (`/workspace`, `.`, relative paths) still run through the
 * normal command path and keep the existing timeout/output truncation behavior.
 */
function systemRootTraversalRefusal(command: string): string | undefined {
  for (const segment of shellCommandSegments(command)) {
    const words = unwrapCommandWords(shellWords(segment))
    const commandName = commandBasename(words[0])
    if (!commandName) continue

    const args = words.slice(1)
    if (!hasSystemRootPathArg(args)) continue

    if (SYSTEM_ROOT_TRAVERSAL_COMMANDS.has(commandName)) {
      return formatSystemRootTraversalRefusal(commandName)
    }
    if (RECURSIVE_LIST_COMMANDS.has(commandName) && hasRecursiveFlag(args)) {
      return formatSystemRootTraversalRefusal(commandName)
    }
    if (RECURSIVE_SEARCH_COMMANDS.has(commandName) && hasRecursiveFlag(args) && hasPatternBeforeRoot(args)) {
      return formatSystemRootTraversalRefusal(commandName)
    }
    if (RECURSIVE_BY_DEFAULT_SEARCH_COMMANDS.has(commandName) && hasSearchTargetBeforeRoot(args)) {
      return formatSystemRootTraversalRefusal(commandName)
    }
  }

  return undefined
}

function formatSystemRootTraversalRefusal(commandName: string): string {
  return [
    `Refused command: ${commandName} over the system root "/" is not allowed.`,
    'Narrow the command to /workspace, a relative path, or a specific known subdirectory.'
  ].join('\n')
}

function shellCommandSegments(command: string): string[] {
  return command.split(/\n|&&|\|\||;|\|/g).map(segment => segment.trim())
}

function shellWords(segment: string): string[] {
  const words: string[] = []
  let current = ''
  let quote: '"' | "'" | undefined
  let escaped = false

  for (const char of segment) {
    if (escaped) {
      current += char
      escaped = false
      continue
    }
    if (char === '\\' && quote !== "'") {
      escaped = true
      continue
    }
    if (quote) {
      if (char === quote) quote = undefined
      else current += char
      continue
    }
    if (char === '"' || char === "'") {
      quote = char
      continue
    }
    if (/\s/.test(char)) {
      if (current.length > 0) {
        words.push(current)
        current = ''
      }
      continue
    }
    current += char
  }

  if (current.length > 0) words.push(current)
  return words
}

function unwrapCommandWords(words: string[]): string[] {
  let remaining = skipEnvAssignments(words)
  while (remaining.length > 0) {
    const commandName = commandBasename(remaining[0])
    if (commandName === 'env') {
      remaining = skipEnvAssignments(remaining.slice(1))
      continue
    }
    if (commandName === 'sudo' || commandName === 'command' || commandName === 'time' || commandName === 'nohup') {
      remaining = remaining.slice(1)
      continue
    }
    if (commandName === 'timeout') {
      remaining = remaining.slice(2)
      continue
    }
    break
  }
  return remaining
}

function skipEnvAssignments(words: string[]): string[] {
  let index = 0
  while (index < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[index]!)) index += 1
  return words.slice(index)
}

function commandBasename(word: string | undefined): string | undefined {
  if (!word) return undefined
  return word.replace(/^.*\//, '')
}

function hasSystemRootPathArg(args: string[]): boolean {
  return args.some(isSystemRootPathArg)
}

function isSystemRootPathArg(arg: string): boolean {
  return arg === '/' || arg === '/*'
}

function hasRecursiveFlag(args: string[]): boolean {
  return args.some(arg => arg === '--recursive' || /^-[A-Za-z]*[Rr][A-Za-z]*$/.test(arg))
}

function hasPatternBeforeRoot(args: string[]): boolean {
  const rootIndex = args.findIndex(isSystemRootPathArg)
  return rootIndex > 0 && args.slice(0, rootIndex).some(arg => arg !== '--' && !arg.startsWith('-'))
}

function hasSearchTargetBeforeRoot(args: string[]): boolean {
  if (args.includes('--files')) return true
  return hasPatternBeforeRoot(args)
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
      `command timed out after ${input.timeoutSeconds}s (foreground budget). Recovery: rerun with background=true then poll with action=status, or narrow the command (shorter probe, smaller input) and split the work.`
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

/**
 * Formats a background command snapshot for status/list/kill responses.
 */
async function backgroundResult(
  snapshot: BackgroundCommandSnapshot,
  options: { incremental?: boolean } = {}
): Promise<AgentToolResult<CommandDetails>> {
  const output = truncateOutput(await snapshot.output('both', { incremental: options.incremental }))
  const outputLines =
    options.incremental && output.length === 0
      ? ['[no new output]']
      : options.incremental
        ? [`new_output_chars=${output.length}`, output]
        : [output]
  return {
    content: [
      {
        type: 'text',
        text: [
          `background_id=${snapshot.id}`,
          `status=${snapshot.status}`,
          snapshot.exitCode === undefined ? undefined : `exit_code=${snapshot.exitCode}`,
          ...outputLines
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
