import { ApiError } from './api-client/api-error'
import type { WorkerClient } from './api-client/worker-client'
import type { CommandLog, CommandState, CommandStatus, CommandStream } from './types'
import { readNdjson } from './utils/ndjson'
import { delay } from './utils/resolve-signal'

const POLL_INTERVAL_MS = 250
const TERMINAL_STATUSES: ReadonlySet<CommandStatus> = new Set(['finished', 'killed', 'error'])

function terminalExitCode(state: CommandState): number {
  return state.exitCode ?? 1
}

export interface CommandContext {
  client: WorkerClient
  cmdId: string
  cwd?: string
}

interface LogLine {
  stream: CommandStream | 'error'
  data: unknown
}

/**
 * A running (possibly detached) command. Mirrors the Vercel SDK `Command`: you can
 * stream `logs()`, `wait()` for completion, collect `stdout()/stderr()/output()`,
 * or `kill()` it. A finished command is a {@link CommandFinished}.
 */
export class Command {
  readonly cmdId: string
  readonly cwd: string | undefined
  exitCode: number | null = null
  protected readonly client: WorkerClient

  constructor(context: CommandContext) {
    this.client = context.client
    this.cmdId = context.cmdId
    this.cwd = context.cwd
  }

  async *logs(opts: { signal?: AbortSignal; follow?: boolean } = {}): AsyncIterable<CommandLog> {
    const response = await this.client.openLogs(this.cmdId, { signal: opts.signal, follow: opts.follow })
    if (!response.body) return
    for await (const line of readNdjson<LogLine>(response.body, opts.signal)) {
      if (line.stream === 'error') {
        const detail = (line.data ?? {}) as { code?: string; message?: string }
        throw new ApiError({
          status: 500,
          code: detail.code ?? 'command_error',
          message: detail.message ?? 'command stream error',
          method: 'GET',
          url: this.cmdId
        })
      }
      yield { stream: line.stream, data: String(line.data) }
    }
  }

  async wait(opts: { signal?: AbortSignal } = {}): Promise<CommandFinished> {
    for (;;) {
      const state = await this.client.getCommand(this.cmdId, opts.signal)
      if (TERMINAL_STATUSES.has(state.status)) return this.finish(terminalExitCode(state))
      await delay(POLL_INTERVAL_MS, opts.signal)
    }
  }

  /** Current worker-reported status without blocking (used by the `process` tool's poll). */
  async status(opts: { signal?: AbortSignal } = {}): Promise<{ status: CommandStatus; exitCode: number | null }> {
    const state = await this.client.getCommand(this.cmdId, opts.signal)
    return { status: state.status, exitCode: state.exitCode ?? null }
  }

  async output(
    stream: CommandStream | 'both' = 'both',
    opts: { signal?: AbortSignal; follow?: boolean } = {}
  ): Promise<string> {
    let collected = ''
    for await (const log of this.logs(opts)) {
      if (stream === 'both' || log.stream === stream) collected += log.data
    }
    return collected
  }

  stdout(opts: { signal?: AbortSignal; follow?: boolean } = {}): Promise<string> {
    return this.output('stdout', opts)
  }

  stderr(opts: { signal?: AbortSignal; follow?: boolean } = {}): Promise<string> {
    return this.output('stderr', opts)
  }

  async kill(signal?: string | number, opts: { abortSignal?: AbortSignal } = {}): Promise<void> {
    await this.client.killCommand(this.cmdId, signal, opts.abortSignal)
  }

  protected finish(exitCode: number): CommandFinished {
    const finished = new CommandFinished({ client: this.client, cmdId: this.cmdId, cwd: this.cwd })
    finished.exitCode = exitCode
    return finished
  }
}

/** A command that has completed. `exitCode` is always present; `wait()` is a no-op. */
export class CommandFinished extends Command {
  declare exitCode: number

  override async wait(): Promise<CommandFinished> {
    return this
  }
}

export interface CommandFlowOptions {
  detached?: boolean
  stdout?: WritableStream<Uint8Array>
  stderr?: WritableStream<Uint8Array>
  signal?: AbortSignal
}

interface CommandStreamLine {
  command?: CommandState
  error?: { code?: string; message?: string }
}

/** Pipe a command's live logs to caller-provided writable streams until completion. */
async function pumpLogs(command: Command, options: CommandFlowOptions): Promise<void> {
  const encoder = new TextEncoder()
  const out = options.stdout?.getWriter()
  const err = options.stderr?.getWriter()
  try {
    for await (const log of command.logs({ signal: options.signal })) {
      if (log.stream === 'stdout' && out) await out.write(encoder.encode(log.data))
      if (log.stream === 'stderr' && err) await err.write(encoder.encode(log.data))
    }
  } finally {
    out?.releaseLock()
    err?.releaseLock()
  }
}

/**
 * Drive the NDJSON command/shell response: read the initial `running` line to learn
 * the command id, then either return immediately (detached) or read until the
 * `finished` line for the exit code (optionally streaming live logs meanwhile).
 */
export async function consumeCommandResponse(
  client: WorkerClient,
  response: Response,
  options: CommandFlowOptions
): Promise<Command | CommandFinished> {
  if (!response.body) {
    throw new ApiError({
      status: 502,
      code: 'empty_response',
      message: 'worker returned no command stream',
      method: 'POST',
      url: ''
    })
  }
  const iterator = readNdjson<CommandStreamLine>(response.body, options.signal)[Symbol.asyncIterator]()

  const first = await iterator.next()
  if (first.done) {
    throw new ApiError({
      status: 502,
      code: 'empty_response',
      message: 'command stream closed before status',
      method: 'POST',
      url: ''
    })
  }
  if (first.value.error) {
    throw new ApiError({
      status: 500,
      code: first.value.error.code ?? 'command_error',
      message: first.value.error.message ?? 'command error',
      method: 'POST',
      url: ''
    })
  }
  const initial = first.value.command
  if (!initial) {
    throw new ApiError({
      status: 502,
      code: 'invalid_response',
      message: 'command stream missing command field',
      method: 'POST',
      url: ''
    })
  }

  const context: CommandContext = { client, cmdId: initial.id, cwd: initial.cwd }

  if (options.detached) {
    await iterator.return?.(undefined)
    await response.body.cancel().catch(() => {})
    const command = new Command(context)
    if (typeof initial.exitCode === 'number') command.exitCode = initial.exitCode
    return command
  }

  const streaming = options.stdout || options.stderr ? pumpLogs(new Command(context), options) : null

  let exitCode = TERMINAL_STATUSES.has(initial.status) ? terminalExitCode(initial) : 0
  if (!TERMINAL_STATUSES.has(initial.status)) {
    for (;;) {
      const next = await iterator.next()
      if (next.done) break
      const state = next.value.command
      if (state && TERMINAL_STATUSES.has(state.status)) {
        exitCode = terminalExitCode(state)
        break
      }
    }
  }

  if (streaming) await streaming

  const finished = new CommandFinished(context)
  finished.exitCode = exitCode
  return finished
}
