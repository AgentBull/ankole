import { ApiError } from './api-client/api-error'
import type { WorkerClient } from './api-client/worker-client'
import type { CommandLog, CommandState, CommandStatus, CommandStream } from './types'
import { readNdjson } from './utils/ndjson'
import { delay } from './utils/resolve-signal'

const POLL_INTERVAL_MS = 250
// The statuses past which a command will not change again. Anything else means
// the command is still running.
const TERMINAL_STATUSES: ReadonlySet<CommandStatus> = new Set(['finished', 'killed', 'error'])

// A command killed by a signal often has no exit code on the wire. Defaulting to 1
// (failure) rather than 0 is deliberate: a signal-killed or errored command must
// never be reported as success. Covered by the "signal-killed ... exitCode missing"
// test.
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

  /**
   * Streams the command's interleaved stdout/stderr as it is produced. Each NDJSON
   * line is tagged with its stream, which is how the two are multiplexed over a
   * single connection. With `follow` the stream stays open and tails a still-running
   * command; otherwise it ends once the recorded output is drained. An `error` frame
   * mid-stream is surfaced as a thrown {@link ApiError} rather than a log line.
   */
  async *logs(opts: { signal?: AbortSignal; follow?: boolean } = {}): AsyncIterable<CommandLog> {
    const response = await this.client.openLogs(this.cmdId, { signal: opts.signal, follow: opts.follow })
    if (!response.body) return
    for await (const line of readNdjson<LogLine>(response.body, opts.signal)) {
      // The worker can inject a synthetic `error` frame into the log stream (e.g. the
      // command record vanished). Turn it into a typed throw so callers do not treat
      // the error payload as ordinary output.
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

  /**
   * Blocks until the command reaches a terminal status, then returns it as a
   * {@link CommandFinished} carrying the exit code.
   *
   * Polls the command state instead of holding the log stream open. A detached
   * command may outlive the call that started it (or a reconnect), so re-querying
   * state is the reliable way to learn the outcome; a long-held stream would be
   * fragile across worker reconnects.
   */
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

  /** Collects the full output as a string, optionally filtered to one stream. Convenience over {@link logs}. */
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

  /**
   * Asks the worker to signal the command. `signal` is the kill signal (name or
   * number) for the process; `opts.abortSignal` aborts the kill *request* itself —
   * two different signals that are easy to confuse, hence the separate names.
   */
  async kill(signal?: string | number, opts: { abortSignal?: AbortSignal } = {}): Promise<void> {
    await this.client.killCommand(this.cmdId, signal, opts.abortSignal)
  }

  /** Builds the {@link CommandFinished} view once a terminal exit code is known. */
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

/**
 * Pipes a command's live logs to caller-provided writable streams until the
 * command completes. Each log line is routed to stdout or stderr by its tag. The
 * `finally` releases the writer locks even if the loop throws or is aborted, so
 * the caller's streams are never left locked.
 */
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
  // Drive the NDJSON stream by hand (not `for await`) because the first line is
  // special — it carries the command id needed to build the Command — and because
  // the detached path must stop reading early without consuming the rest.
  const iterator = readNdjson<CommandStreamLine>(response.body, options.signal)[Symbol.asyncIterator]()

  // The worker's first frame is either a fatal `error` or the initial `running`
  // command state. A stream that closes before this means the worker died early.
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

  // Detached: we have the command id from the first line, so release the stream and
  // return a handle the caller can poll/kill later. Closing the iterator and
  // cancelling the body frees the worker connection instead of holding it open for a
  // command we are not waiting on. The cancel error is swallowed — there is nothing
  // useful to do if tearing down an abandoned stream fails.
  if (options.detached) {
    await iterator.return?.(undefined)
    await response.body.cancel().catch(() => {})
    const command = new Command(context)
    if (typeof initial.exitCode === 'number') command.exitCode = initial.exitCode
    return command
  }

  // Foreground with caller streams: tee live logs on a second connection while this
  // one walks the command-state frames for the exit code. The two run concurrently
  // because the state stream and the log stream are separate worker endpoints.
  const streaming = options.stdout || options.stderr ? pumpLogs(new Command(context), options) : null

  // If the command already finished by the first frame, take its code; otherwise read
  // forward until a terminal command-state line appears. A clean stream close without
  // a terminal line leaves the default 0 — the worker closed the stream normally.
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

  // Make sure the log pump has fully drained before returning, so no writes land on
  // the caller's streams after this resolves.
  if (streaming) await streaming

  const finished = new CommandFinished(context)
  finished.exitCode = exitCode
  return finished
}
