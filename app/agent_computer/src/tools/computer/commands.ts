import { isAbsolute, join, normalize, resolve } from 'node:path'
import { assertPathInsideAgentHome } from '../../core/agent-home-paths'
import { commandEnv } from '../../core/execution/command-env'
import { agentProcessArgv, killProcessGroup } from '../../core/execution/process-group'

export type CommandOutputMode = 'stdout' | 'stderr' | 'both'

export interface CommandInput {
  cmd: string
  args?: string[]
  cwd?: string
  env?: Record<string, string>
  stdin?: string | Buffer
  timeoutMs?: number
  signal?: AbortSignal
}

export interface CommandFinished {
  exitCode: number
  output(mode?: CommandOutputMode, opts?: { signal?: AbortSignal }): Promise<string>
}

interface WorkspaceCommandInput extends CommandInput {
  /** Operator-managed variables injected below the caller's `env`. */
  workerEnv?: Record<string, string>
  /** Trusted turn variables injected above the caller's `env`. */
  runtimeEnv?: Record<string, string>
}

interface WorkspaceProcessInput {
  commandArgv: string[]
  cwd?: string
  env?: Record<string, string>
  /** Operator-managed variables injected below the caller's `env`. */
  workerEnv?: Record<string, string>
  /** Trusted turn variables injected above the caller's `env`. */
  runtimeEnv?: Record<string, string>
  stdin?: string | Buffer
  /**
   * Collect stdout/stderr with the bounded head/tail collector instead of the
   * exact full bytes. Only the model-facing command path sets this; file
   * transfer paths need every byte.
   */
  boundedOutput?: boolean
  signal?: AbortSignal
}

export interface WorkspaceProcessFinished {
  exitCode: number
  stdout: Buffer
  stderr: Buffer
}

export async function runWorkspaceCommand(
  input: WorkspaceCommandInput,
  agentHome: string,
  workspaceRoot: string
): Promise<CommandFinished> {
  const result = await runWorkspaceProcess(
    {
      commandArgv: commandArgvWithOptionalTimeout(input),
      cwd: input.cwd,
      env: input.env,
      workerEnv: input.workerEnv,
      runtimeEnv: input.runtimeEnv,
      stdin: input.stdin,
      boundedOutput: true,
      signal: input.signal
    },
    agentHome,
    workspaceRoot
  )
  return finishedCommand(result.exitCode, result.stdout.toString('utf8'), result.stderr.toString('utf8'))
}

/**
 * Runs one argv in a working directory inside the Agent Home and returns its
 * exact bytes.
 *
 * The process runs as uid 1000, separate from the credential-holding Worker.
 * The container remains the Agent boundary. The process gets a fresh
 * environment and its own process group, so a cancellation ends every process
 * that the command started.
 */
export async function runWorkspaceProcess(
  input: WorkspaceProcessInput,
  agentHome: string,
  workspaceRoot: string
): Promise<WorkspaceProcessFinished> {
  if (input.signal?.aborted) {
    return { exitCode: 130, stdout: Buffer.alloc(0), stderr: Buffer.from('command aborted') }
  }

  const cwd = assertPathInsideAgentHome(
    agentHome,
    input.cwd ? workspacePath(agentHome, workspaceRoot, input.cwd) : workspaceRoot,
    'command cwd escapes Agent Home'
  )
  const env = commandEnv(input.env, { agentHome, workerEnv: input.workerEnv, runtimeEnv: input.runtimeEnv })

  return runCommandProcess({
    argv: input.commandArgv,
    cwd,
    env,
    stdin: input.stdin,
    boundedOutput: input.boundedOutput,
    signal: input.signal
  })
}

export function commandArgvWithOptionalTimeout(input: CommandInput, defaultTimeoutMs?: number): string[] {
  const commandArgv = [input.cmd, ...(input.args ?? [])]
  const timeoutMs = input.timeoutMs ?? defaultTimeoutMs
  if (timeoutMs === undefined) return commandArgv
  // `-k 5s` escalates to KILL when the command ignores the initial TERM, so a
  // signal-immune command cannot outlive its budget. KILL makes `timeout` exit
  // with 137 instead of 124.
  return ['timeout', '-k', '5s', `${Math.max(1, Math.ceil(timeoutMs / 1000))}s`, ...commandArgv]
}

export function workspacePath(agentHome: string, cwd: string, path: string): string {
  const expanded = path === '~' ? agentHome : path.startsWith('~/') ? join(agentHome, path.slice(2)) : path
  return isAbsolute(expanded) ? resolve(normalize(expanded)) : resolve(cwd, normalize(expanded))
}

async function runCommandProcess(input: {
  argv: string[]
  cwd: string
  env: Record<string, string>
  stdin?: string | Buffer
  boundedOutput?: boolean
  signal?: AbortSignal
}): Promise<WorkspaceProcessFinished> {
  const proc = Bun.spawn(agentProcessArgv(input.argv), {
    cwd: input.cwd,
    env: input.env,
    stdin: input.stdin === undefined ? 'ignore' : 'pipe',
    stdout: 'pipe',
    stderr: 'pipe',
    detached: true
  })

  if (input.stdin !== undefined) {
    const stdin = proc.stdin
    if (!stdin) throw new Error('command process stdin pipe is unavailable')
    stdin.write(input.stdin)
    stdin.end()
  }

  let aborted = false
  const abort = () => {
    aborted = true
    killProcessGroup(proc.pid)
  }

  input.signal?.addEventListener('abort', abort, { once: true })

  try {
    const collect = input.boundedOutput ? readableToBoundedBuffer : readableToBuffer
    const [exitCode, stdout, stderr] = await Promise.all([proc.exited, collect(proc.stdout), collect(proc.stderr)])

    return {
      exitCode: exitCode ?? 124,
      stdout,
      stderr: aborted && stderr.length === 0 ? Buffer.from('command aborted') : stderr
    }
  } finally {
    input.signal?.removeEventListener('abort', abort)
  }
}

async function readableToBuffer(stream: ReadableStream<Uint8Array> | null): Promise<Buffer> {
  if (!stream) return Buffer.alloc(0)
  return Buffer.from(await new Response(stream).arrayBuffer())
}

const BoundedOutputHeadBytes = 1024 * 1024
const BoundedOutputTailBytes = 1024 * 1024

/**
 * When this collector drops bytes, `truncateOutputDetailed` undercounts the
 * true output: it reports omitted characters against this bounded text, and
 * the marker usually falls inside the range it cuts. Below the 2 MB bound the
 * bytes are exact.
 */
async function readableToBoundedBuffer(stream: ReadableStream<Uint8Array> | null): Promise<Buffer> {
  if (!stream) return Buffer.alloc(0)
  const head: Buffer[] = []
  let headLength = 0
  const tail: Buffer[] = []
  let tailLength = 0
  let droppedBytes = 0
  const pushTail = (part: Buffer): void => {
    tail.push(part)
    tailLength += part.length
    while (tail.length > 0 && tailLength - tail[0]!.length >= BoundedOutputTailBytes) {
      tailLength -= tail[0]!.length
      droppedBytes += tail[0]!.length
      tail.shift()
    }
  }
  for await (const part of stream) {
    const chunk = Buffer.from(part)
    const take = Math.min(chunk.length, Math.max(0, BoundedOutputHeadBytes - headLength))
    if (take > 0) {
      head.push(chunk.subarray(0, take))
      headLength += take
    }
    if (take < chunk.length) pushTail(chunk.subarray(take))
  }
  let tailBuffer = Buffer.concat(tail)
  if (tailBuffer.length > BoundedOutputTailBytes) {
    droppedBytes += tailBuffer.length - BoundedOutputTailBytes
    tailBuffer = tailBuffer.subarray(tailBuffer.length - BoundedOutputTailBytes)
  }
  if (droppedBytes === 0) return Buffer.concat([...head, tailBuffer])
  const marker = Buffer.from(`\n... [${droppedBytes} bytes of output dropped here] ...\n`, 'utf8')
  return Buffer.concat([...head, marker, tailBuffer])
}

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
