import { isAbsolute, join, normalize, resolve } from 'node:path'
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

export interface WorkspaceProcessInput {
  commandArgv: string[]
  cwd?: string
  env?: Record<string, string>
  /** Operator-managed variables injected below the caller's `env`. */
  workerEnv?: Record<string, string>
  stdin?: string | Buffer
  signal?: AbortSignal
}

export interface WorkspaceProcessFinished {
  exitCode: number
  stdout: Buffer
  stderr: Buffer
}

/**
 * Runs one foreground command inside bubblewrap.
 */
export async function runWorkspaceCommand(
  input: CommandInput,
  agentHome: string,
  workspaceRoot: string
): Promise<CommandFinished> {
  const result = await runWorkspaceProcess(
    {
      commandArgv: commandArgvWithOptionalTimeout(input),
      cwd: input.cwd,
      env: input.env,
      workerEnv: input.workerEnv,
      signal: input.signal
    },
    agentHome,
    workspaceRoot
  )
  return finishedCommand(result.exitCode, result.stdout.toString('utf8'), result.stderr.toString('utf8'))
}

/**
 * Runs one argv inside the existing bubblewrap view and returns its exact bytes.
 */
export async function runWorkspaceProcess(
  input: WorkspaceProcessInput,
  agentHome: string,
  workspaceRoot: string
): Promise<WorkspaceProcessFinished> {
  if (input.signal?.aborted) {
    return { exitCode: 130, stdout: Buffer.alloc(0), stderr: Buffer.from('command aborted') }
  }

  const cwd = input.cwd ? workspacePath(agentHome, workspaceRoot, input.cwd) : workspaceRoot
  const env = commandEnv(input.env, { workerEnv: input.workerEnv, home: agentHome, ankoleAgentHome: agentHome })
  const argv = bubblewrapArgv({
    workspaceRoot: agentHome,
    cwd,
    env,
    commandArgv: input.commandArgv
  })

  return runCommandProcess({ argv, cwd: workspaceRoot, env, stdin: input.stdin, signal: input.signal })
}

export function commandArgvWithOptionalTimeout(input: CommandInput, defaultTimeoutMs?: number): string[] {
  const commandArgv = [input.cmd, ...(input.args ?? [])]
  const timeoutMs = input.timeoutMs ?? defaultTimeoutMs
  if (timeoutMs === undefined) return commandArgv
  return ['timeout', `${Math.max(1, Math.ceil(timeoutMs / 1000))}s`, ...commandArgv]
}

/**
 * Resolves command path syntax without deciding which paths bubblewrap permits.
 */
export function workspacePath(agentHome: string, cwd: string, path: string): string {
  const expanded = path === '~' ? agentHome : path.startsWith('~/') ? join(agentHome, path.slice(2)) : path
  return isAbsolute(expanded) ? resolve(normalize(expanded)) : resolve(cwd, normalize(expanded))
}

async function runCommandProcess(input: {
  argv: string[]
  cwd: string
  env: Record<string, string>
  stdin?: string | Buffer
  signal?: AbortSignal
}): Promise<WorkspaceProcessFinished> {
  const proc = Bun.spawn(input.argv, {
    cwd: input.cwd,
    env: input.env,
    stdin: input.stdin === undefined ? 'ignore' : 'pipe',
    stdout: 'pipe',
    stderr: 'pipe'
  })

  if (input.stdin !== undefined) {
    const stdin = proc.stdin
    if (!stdin) throw new Error('sandbox process stdin pipe is unavailable')
    stdin.write(input.stdin)
    stdin.end()
  }

  let aborted = false
  const abort = () => {
    aborted = true
    proc.kill()
  }

  input.signal?.addEventListener('abort', abort, { once: true })

  try {
    const [exitCode, stdout, stderr] = await Promise.all([
      proc.exited,
      readableToBuffer(proc.stdout),
      readableToBuffer(proc.stderr)
    ])

    return {
      exitCode: exitCode ?? 124,
      stdout,
      stderr: aborted && stderr.length === 0 ? Buffer.from('command aborted') : stderr
    }
  } finally {
    input.signal?.removeEventListener('abort', abort)
  }
}

/**
 * Reads a stream fully without changing its bytes.
 */
async function readableToBuffer(stream: ReadableStream<Uint8Array> | null): Promise<Buffer> {
  if (!stream) return Buffer.alloc(0)
  return Buffer.from(await new Response(stream).arrayBuffer())
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
