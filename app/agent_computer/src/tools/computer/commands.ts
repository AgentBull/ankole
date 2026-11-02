import { isAbsolute, join, normalize, resolve } from 'node:path'
import { scopedPath, visibleDrivePath } from '../../drive/paths'
import type { DriveView } from '../../drive/mounts'
import { commandEnv } from '../../core/execution/command-env'
import { agentProcessArgv, killProcessGroup } from '../../core/execution/process-group'
import commandProcess from './command-process.py' with { type: 'text' }

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
  outputCapture?: CommandOutputCapture
  output(mode?: CommandOutputMode, opts?: { signal?: AbortSignal }): Promise<string>
}

export interface CommandOutputCapture {
  observedBytes: number
  droppedBytes: number
  drained: boolean
}

interface WorkspaceCommandInput extends CommandInput {
  driveView?: DriveView
  /** Operator-managed variables injected below the caller's `env`. */
  workerEnv?: Record<string, string>
  /** Trusted turn variables injected above the caller's `env`. */
  runtimeEnv?: Record<string, string>
}

interface WorkspaceProcessInput {
  driveView?: DriveView
  commandArgv: string[]
  cwd?: string
  env?: Record<string, string>
  /** Operator-managed variables injected below the caller's `env`. */
  workerEnv?: Record<string, string>
  /** Trusted turn variables injected above the caller's `env`. */
  runtimeEnv?: Record<string, string>
  stdin?: string | Buffer
  signal?: AbortSignal
}

export interface WorkspaceProcessFinished {
  exitCode: number
  stdout: Buffer
  stderr: Buffer
  outputCapture?: CommandOutputCapture
}

export async function runWorkspaceCommand(
  input: WorkspaceCommandInput,
  agentHome: string,
  workspaceRoot: string
): Promise<CommandFinished> {
  if (input.signal?.aborted) return finishedCommand(130, '', 'command aborted')

  const startSeq = await input.driveView?.sequence()
  const result = await runForegroundProcess({
    driveView: input.driveView,
    hostCwd: agentHome,
    ...(await workspaceProcessContext(input, agentHome, workspaceRoot)),
    argv: [input.cmd, ...(input.args ?? [])],
    stdin: input.stdin,
    timeoutMs: input.timeoutMs,
    signal: input.signal
  })
  const driveSummary = startSeq
    ? await input.driveView!.flush(startSeq).catch(error => `Drive synchronization is still pending: ${String(error)}`)
    : ''
  return finishedCommand(
    result.exitCode,
    result.stdout.toString('utf8'),
    [result.stderr.toString('utf8'), driveSummary].filter(Boolean).join('\n'),
    result.outputCapture
  )
}

/**
 * Runs one argv in a working directory inside the Agent Home and returns its
 * exact bytes.
 *
 * The process runs as uid 1000, separate from the credential-holding Worker.
 * The container remains the Agent boundary. The process gets a fresh
 * environment and its own process group, which cancellation ends.
 */
export async function runWorkspaceProcess(
  input: WorkspaceProcessInput,
  agentHome: string,
  workspaceRoot: string
): Promise<WorkspaceProcessFinished> {
  if (input.signal?.aborted) {
    return { exitCode: 130, stdout: Buffer.alloc(0), stderr: Buffer.from('command aborted') }
  }

  const context = await workspaceProcessContext(input, agentHome, workspaceRoot)
  const proc = Bun.spawn(agentProcessArgv(input.commandArgv, input.driveView, context.cwd), {
    ...context,
    cwd: input.driveView ? agentHome : context.cwd,
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

export function workspacePath(agentHome: string, cwd: string, path: string): string {
  const expanded = path === '~' ? agentHome : path.startsWith('~/') ? join(agentHome, path.slice(2)) : path
  return isAbsolute(expanded) ? resolve(normalize(expanded)) : resolve(cwd, normalize(expanded))
}

async function workspaceProcessContext(
  input: Pick<WorkspaceProcessInput, 'cwd' | 'env' | 'workerEnv' | 'runtimeEnv' | 'driveView' | 'signal'>,
  agentHome: string,
  workspaceRoot: string
) {
  const requested = input.cwd ? workspacePath(agentHome, workspaceRoot, input.cwd) : workspaceRoot
  const target = await scopedPath(
    input.driveView,
    agentHome,
    requested,
    input.signal ? AbortSignal.any([input.signal, AbortSignal.timeout(15_000)]) : undefined
  )
  return {
    cwd: visibleDrivePath(input.driveView, target),
    env: commandEnv(input.env, { agentHome, workerEnv: input.workerEnv, runtimeEnv: input.runtimeEnv })
  }
}

async function runForegroundProcess(input: {
  driveView?: DriveView
  hostCwd: string
  argv: string[]
  cwd: string
  env: Record<string, string>
  stdin?: string | Buffer
  timeoutMs?: number
  signal?: AbortSignal
}): Promise<WorkspaceProcessFinished> {
  const python = Bun.which('python3')
  if (!python) throw new Error('Foreground commands require Python 3')
  const proc = Bun.spawn(
    agentProcessArgv(
      [python, '-I', '-S', '-c', commandProcess, String(input.timeoutMs ?? 0), ...input.argv],
      input.driveView,
      input.cwd
    ),
    {
      cwd: input.driveView ? input.hostCwd : input.cwd,
      env: input.env,
      stdin: input.stdin === undefined ? 'ignore' : 'pipe',
      stdout: 'pipe',
      stderr: 'pipe',
      detached: true
    }
  )
  const abort = () => proc.kill('SIGTERM')
  input.signal?.addEventListener('abort', abort, { once: true })
  const drain = new AbortController()
  const output = Promise.all([
    readableToBoundedBuffer(proc.stdout, drain.signal),
    readableToBoundedBuffer(proc.stderr, drain.signal)
  ])
  // A read failure must also end the command rather than leave it blocked on
  // a pipe. Attach this handler before waiting for the helper to exit.
  void output.catch(abort)
  let drainTimer: ReturnType<typeof setTimeout> | undefined
  try {
    if (input.stdin !== undefined) {
      const stdin = proc.stdin
      if (!stdin) throw new Error('command process stdin pipe is unavailable')
      try {
        stdin.write(input.stdin)
        await stdin.end()
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'EPIPE') throw error
      }
    }
    if (input.signal?.aborted) abort()
    const exitCode = await proc.exited
    // The helper has already ended its command group. A process that created
    // another session can still hold a pipe; stop reading it after one second.
    // Any capture cut short by this deadline reports incomplete output.
    drainTimer = setTimeout(() => drain.abort(), 1000)
    const [stdout, stderr] = await output
    return {
      exitCode: input.signal?.aborted ? 130 : exitCode,
      stdout: stdout.bytes,
      stderr: input.signal?.aborted && stderr.bytes.length === 0 ? Buffer.from('command aborted') : stderr.bytes,
      outputCapture: {
        observedBytes: stdout.observedBytes + stderr.observedBytes,
        droppedBytes: stdout.droppedBytes + stderr.droppedBytes,
        drained: stdout.drained && stderr.drained
      }
    }
  } catch (error) {
    abort()
    await proc.exited
    drain.abort()
    await output.catch(() => {})
    throw error
  } finally {
    if (drainTimer) clearTimeout(drainTimer)
    input.signal?.removeEventListener('abort', abort)
  }
}

async function readableToBuffer(stream: ReadableStream<Uint8Array> | null): Promise<Buffer> {
  if (!stream) return Buffer.alloc(0)
  return Buffer.from(await new Response(stream).arrayBuffer())
}

const BoundedOutputHeadBytes = 1024 * 1024
const BoundedOutputTailBytes = 1024 * 1024

async function readableToBoundedBuffer(
  stream: ReadableStream<Uint8Array>,
  signal: AbortSignal
): Promise<CommandOutputCapture & { bytes: Buffer }> {
  const reader = stream.getReader()
  let drained = false
  let observedBytes = 0
  const cancel = () => {
    void reader.cancel().catch(() => {})
  }
  signal.addEventListener('abort', cancel, { once: true })
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
  try {
    while (true) {
      const { value, done } = await reader.read()
      if (done) {
        drained = !signal.aborted
        break
      }
      const chunk = Buffer.from(value)
      observedBytes += chunk.length
      const take = Math.min(chunk.length, Math.max(0, BoundedOutputHeadBytes - headLength))
      if (take > 0) {
        head.push(chunk.subarray(0, take))
        headLength += take
      }
      if (take < chunk.length) pushTail(chunk.subarray(take))
    }
  } finally {
    signal.removeEventListener('abort', cancel)
    reader.releaseLock()
  }
  let tailBuffer = Buffer.concat(tail)
  if (tailBuffer.length > BoundedOutputTailBytes) {
    droppedBytes += tailBuffer.length - BoundedOutputTailBytes
    tailBuffer = tailBuffer.subarray(tailBuffer.length - BoundedOutputTailBytes)
  }
  const marker = Buffer.from(`\n... [${droppedBytes} bytes of output dropped here] ...\n`, 'utf8')
  return {
    bytes: Buffer.concat([...head, ...(droppedBytes > 0 ? [marker] : []), tailBuffer]),
    observedBytes,
    droppedBytes,
    drained
  }
}

function finishedCommand(
  exitCode: number,
  stdout: string,
  stderr: string,
  outputCapture?: CommandOutputCapture
): CommandFinished {
  return {
    exitCode,
    outputCapture,
    async output(mode = 'both') {
      if (mode === 'stdout') return stdout
      if (mode === 'stderr') return stderr
      return [stdout, stderr].filter(Boolean).join(stderr && stdout ? '\n' : '')
    }
  }
}
