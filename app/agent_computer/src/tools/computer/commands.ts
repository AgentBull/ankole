import { resolveWorkspacePath } from '../../core/workspace-paths'
import { bubblewrapArgv } from './bubblewrap'
import { commandEnv } from './env'

export type CommandOutputMode = 'stdout' | 'stderr' | 'both'

export interface CommandInput {
  cmd: string
  args?: string[]
  cwd?: string
  env?: Record<string, string>
  /** Operator-managed variables injected below the caller's `env`. */
  workerEnv?: Record<string, string>
  timeoutMs?: number
  signal?: AbortSignal
}

export interface CommandFinished {
  exitCode: number
  output(mode?: CommandOutputMode, opts?: { signal?: AbortSignal }): Promise<string>
}

/**
 * Runs one foreground command inside bubblewrap.
 */
export async function runWorkspaceCommand(input: CommandInput, workspaceRoot: string): Promise<CommandFinished> {
  if (input.signal?.aborted) return finishedCommand(130, '', 'command aborted')

  const cwd = input.cwd ? workspacePath(workspaceRoot, input.cwd) : workspaceRoot
  const env = commandEnv(input.env, { workerEnv: input.workerEnv })
  const argv = bubblewrapArgv({
    workspaceRoot,
    cwd,
    env,
    commandArgv: commandArgvWithOptionalTimeout(input)
  })

  return runCommandProcess({ argv, cwd: workspaceRoot, env, signal: input.signal })
}

/**
 * Runs Agent Computer control processes that must share container runtime state.
 *
 * This is intentionally not exposed through the model-facing `command` tool.
 * `interactive_terminal` is backed by a tmux server, and wrapping every tmux
 * control command in a fresh bubblewrap `/tmp` would make the session socket
 * disappear between `start`, `send`, `capture`, and `kill`.
 *
 * Operator worker env deliberately stays out of this path: the tmux server may
 * be shared by several agents on one worker, so per-agent variables enter a
 * session via `new-session -e`, never via the server process environment.
 */
export async function runControlCommand(input: CommandInput, workspaceRoot: string): Promise<CommandFinished> {
  if (input.signal?.aborted) return finishedCommand(130, '', 'command aborted')

  const cwd = input.cwd ? workspacePath(workspaceRoot, input.cwd) : workspaceRoot
  const env = commandEnv(input.env)
  const argv = commandArgvWithOptionalTimeout(input, 60_000)

  return runCommandProcess({ argv, cwd, env, signal: input.signal })
}

export function commandArgvWithOptionalTimeout(input: CommandInput, defaultTimeoutMs?: number): string[] {
  const commandArgv = [input.cmd, ...(input.args ?? [])]
  const timeoutMs = input.timeoutMs ?? defaultTimeoutMs
  if (timeoutMs === undefined) return commandArgv
  return ['timeout', `${Math.max(1, Math.ceil(timeoutMs / 1000))}s`, ...commandArgv]
}

/**
 * Resolves a path against the workspace root.
 */
export function workspacePath(root: string, path: string): string {
  return resolveWorkspacePath(root, path)
}

async function runCommandProcess(input: {
  argv: string[]
  cwd: string
  env: Record<string, string>
  signal?: AbortSignal
}): Promise<CommandFinished> {
  const proc = Bun.spawn(input.argv, {
    cwd: input.cwd,
    env: input.env,
    stdout: 'pipe',
    stderr: 'pipe'
  })

  let aborted = false
  const abort = () => {
    aborted = true
    proc.kill()
  }

  input.signal?.addEventListener('abort', abort, { once: true })

  try {
    const [exitCode, stdout, stderr] = await Promise.all([
      proc.exited,
      readableToUTF8(proc.stdout),
      readableToUTF8(proc.stderr)
    ])

    return finishedCommand(exitCode ?? 124, stdout, aborted && stderr.length === 0 ? 'command aborted' : stderr)
  } finally {
    input.signal?.removeEventListener('abort', abort)
  }
}

/**
 * Reads a stream fully as UTF-8 text.
 */
async function readableToUTF8(stream: ReadableStream<Uint8Array> | null): Promise<string> {
  if (!stream) return ''
  return Buffer.from(await new Response(stream).arrayBuffer()).toString('utf8')
}

/**
 * Builds the completed-command facade returned by command execution.
 */
function finishedCommand(exitCode: number, stdout: string, stderr: string): CommandFinished {
  return {
    exitCode,
    async output(mode = 'both') {
      if (mode === 'stdout') return stdout
      if (mode === 'stderr') return stderr
      return [stdout, stderr].filter(Boolean).join(stderr && stdout ? '\n' : '')
    }
  }
}
