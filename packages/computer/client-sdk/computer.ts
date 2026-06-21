import { ApiError } from './api-client/api-error'
import { ControlClient } from './api-client/control-client'
import { WorkerClient } from './api-client/worker-client'
import { withRetry } from './api-client/with-retry'
import { Command, type CommandFinished, consumeCommandResponse } from './command'
import { FileSystem, type DownloadTarget, type ReadFileRef } from './filesystem'
import { TerminalManager } from './terminal'
import type {
  DirEntry,
  FetchLike,
  FileStat,
  ResolveSessionResponse,
  RunCommandParams,
  RunShellCommandOptions,
  ComputerFile,
  SessionSnapshot
} from './types'

export interface ComputerConnectionConfig {
  /** Control-plane base URL. Defaults to env `BULLX_AGENT_URL`. */
  baseUrl?: string
  /** Control-plane service token. Defaults to env  `BULLX_COMPUTER_TOKEN`. */
  token?: string
  fetch?: FetchLike
  debug?: boolean
  /**
   * In-process resolver. When provided, the control-plane HTTP call is skipped and
   * this function returns the worker + session token directly. The BullX app uses
   * this to resolve bindings without a self-HTTP round-trip.
   */
  resolveWorker?: (agentUid: string, signal?: AbortSignal) => Promise<ResolveSessionResponse>
}

/**
 * Parameters for {@link Computer.getOrCreate}. `onCreate` runs only when this
 * call freshly created the session; `onResume` runs when an existing session was
 * reattached. They let callers seed a brand-new workspace once without re-running
 * that setup on every reconnect.
 */
export interface GetOrCreateComputerParams extends ComputerConnectionConfig {
  agentUid: string
  signal?: AbortSignal
  onCreate?: (computer: Computer) => Promise<void>
  onResume?: (computer: Computer) => Promise<void>
}

export interface GetComputerParams extends ComputerConnectionConfig {
  agentUid: string
  signal?: AbortSignal
}

interface ComputerInit {
  agentUid: string
  sessionId: string
  workerId: string
  worker: WorkerClient
}

/**
 * Resolves which worker hosts this agent, plus the mTLS material to reach it.
 *
 * When an in-process `resolveWorker` is supplied (the BullX app binding itself),
 * the control-plane HTTP call is skipped entirely. Otherwise the call goes
 * through {@link withRetry} because worker resolution is a transient control-plane
 * operation that may briefly fail during deploys or rebinding.
 */
async function resolveSession(
  params: ComputerConnectionConfig & { agentUid: string; signal?: AbortSignal }
): Promise<ResolveSessionResponse> {
  if (params.resolveWorker) return params.resolveWorker(params.agentUid, params.signal)
  const baseUrl = params.baseUrl ?? Bun.env.BULLX_AGENT_URL
  if (!baseUrl) {
    throw new ApiError({
      status: 500,
      code: 'missing_control_url',
      message: 'no control-plane baseUrl (set BULLX_AGENT_URL or pass baseUrl)',
      method: 'POST',
      url: ''
    })
  }
  const token = params.token ?? Bun.env.BULLX_COMPUTER_TOKEN
  const control = new ControlClient({ baseUrl, token, fetch: params.fetch, debug: params.debug })
  return withRetry(() => control.resolveSession(params.agentUid, params.signal), { signal: params.signal })
}

/** Builds the worker client from a resolved binding, carrying its mTLS config across. */
function workerFor(resolved: ResolveSessionResponse, params: ComputerConnectionConfig, agentUid: string): WorkerClient {
  return new WorkerClient(
    { baseUrl: resolved.worker.baseUrl, tls: resolved.tls, fetch: params.fetch, debug: params.debug },
    agentUid
  )
}

/**
 * Agent-scoped computer session. Created via `Computer.getOrCreate({ agentUid })`
 * (resolve-or-create persistent session) rather than `create()` — the BullX
 * semantic is a sticky agent worker, not a short-lived VM.
 */
export class Computer {
  readonly agentUid: string
  readonly sessionId: string
  readonly workerId: string
  readonly fs: FileSystem
  readonly terminals: TerminalManager
  private readonly worker: WorkerClient

  private constructor(init: ComputerInit) {
    this.agentUid = init.agentUid
    this.sessionId = init.sessionId
    this.workerId = init.workerId
    this.worker = init.worker
    this.fs = new FileSystem(init.worker)
    this.terminals = new TerminalManager(init.worker)
  }

  /**
   * Resolves the agent's worker and ensures a live session, creating one if none
   * exists. `PUT` is idempotent: a second caller for the same agent reattaches to
   * the running session rather than starting a second one. The worker's `created`
   * flag (not anything client-side) decides whether `onCreate` or `onResume` fires,
   * so first-run setup happens exactly once even across reconnects.
   */
  static async getOrCreate(params: GetOrCreateComputerParams): Promise<Computer> {
    const resolved = await resolveSession(params)
    const worker = workerFor(resolved, params, params.agentUid)
    const session = await worker.putSession(params.signal)
    const computer = new Computer({
      agentUid: params.agentUid,
      sessionId: session.sessionId,
      workerId: session.workerId,
      worker
    })
    if (session.created) await params.onCreate?.(computer)
    else await params.onResume?.(computer)
    return computer
  }

  /**
   * Attaches to an agent's already-running session. Unlike {@link getOrCreate},
   * this never starts a worker — it `GET`s the existing session and fails if there
   * is none. Used when the caller expects the session to already exist.
   */
  static async get(params: GetComputerParams): Promise<Computer> {
    const resolved = await resolveSession(params)
    const worker = workerFor(resolved, params, params.agentUid)
    const session = await worker.getSession(params.signal)
    return new Computer({
      agentUid: params.agentUid,
      sessionId: session.sessionId,
      workerId: session.workerId,
      worker
    })
  }

  /**
   * Runs a one-off process on the worker (not the persistent shell — see
   * {@link runShellCommand}). The overloads encode the return contract: a
   * `detached: true` call yields a live {@link Command} you poll or kill later,
   * while every other call blocks and yields a {@link CommandFinished} with the
   * exit code. The convenience `(command, args, opts)` form is sugar for the
   * common foreground case.
   *
   * `timeoutMs` is a worker-side execution budget (the worker kills the process and
   * reports a non-zero exit), not a client fetch abort — pass `signal` to abort
   * from the client side.
   */
  runCommand(
    command: string,
    args?: string[],
    opts?: { signal?: AbortSignal; timeoutMs?: number }
  ): Promise<CommandFinished>
  runCommand(params: RunCommandParams & { detached: true }): Promise<Command>
  runCommand(params: RunCommandParams): Promise<CommandFinished>
  async runCommand(
    commandOrParams: string | RunCommandParams,
    args?: string[],
    opts?: { signal?: AbortSignal; timeoutMs?: number }
  ): Promise<Command | CommandFinished> {
    const params: RunCommandParams =
      typeof commandOrParams === 'string'
        ? { cmd: commandOrParams, args, signal: opts?.signal, timeoutMs: opts?.timeoutMs }
        : commandOrParams
    // This computer build runs commands as a single unprivileged user, so sudo can
    // never succeed. Reject up front with a clear code instead of letting the
    // worker fail it opaquely.
    if (params.sudo) {
      throw new ApiError({
        status: 400,
        code: 'unsupported_sudo',
        message: 'sudo is not supported in this computer version',
        method: 'POST',
        url: ''
      })
    }
    // `wait: !detached` tells the worker whether to hold the NDJSON stream open
    // until the command finishes; the response shape is consumed accordingly below.
    const response = await this.worker.openCommand(
      {
        command: params.cmd,
        args: params.args,
        cwd: params.cwd,
        env: params.env,
        sudo: params.sudo ?? false,
        wait: !params.detached,
        timeout: params.timeoutMs
      },
      params.signal
    )
    return consumeCommandResponse(this.worker, response, {
      detached: params.detached,
      stdout: params.stdout,
      stderr: params.stderr,
      signal: params.signal
    })
  }

  /**
   * Runs a command inside the agent's *persistent* shell, so state set by earlier
   * calls (working directory, exported env, shell variables) carries over. This is
   * the BullX-specific counterpart to {@link runCommand}, which spawns an isolated
   * process each time. Always foreground (`wait: true`); the returned
   * {@link CommandFinished} reports the shell-observed cwd after the command ran.
   * `shellScope` picks a per-conversation shell; omit it for the agent-shared one.
   */
  async runShellCommand(command: string, opts: RunShellCommandOptions = {}): Promise<CommandFinished> {
    const response = await this.worker.openShell(
      { command, cwd: opts.cwd, env: opts.env, scope: opts.shellScope, wait: true, timeout: opts.timeoutMs },
      opts.signal
    )
    const result = await consumeCommandResponse(this.worker, response, {
      detached: false,
      stdout: opts.stdout,
      stderr: opts.stderr,
      signal: opts.signal
    })
    return result as CommandFinished
  }

  mkDir(path: string, opts?: { signal?: AbortSignal }): Promise<void> {
    return this.fs.mkdir(path, opts)
  }

  writeFiles(files: ComputerFile[], opts?: { signal?: AbortSignal }): Promise<void> {
    return this.fs.writeFiles(files, opts)
  }

  readFile(file: ReadFileRef, opts?: { signal?: AbortSignal }): Promise<ReadableStream<Uint8Array> | null> {
    return this.fs.readFile(file, opts)
  }

  readFileToBuffer(file: ReadFileRef, opts?: { signal?: AbortSignal }): Promise<Buffer | null> {
    return this.fs.readFileToBuffer(file, opts)
  }

  downloadFile(
    src: ReadFileRef,
    dst: DownloadTarget,
    opts?: { mkdirRecursive?: boolean; signal?: AbortSignal }
  ): Promise<string | null> {
    return this.fs.downloadFile(src, dst, opts)
  }

  stat(file: ReadFileRef, opts?: { signal?: AbortSignal }): Promise<FileStat> {
    return this.fs.stat(file, opts)
  }

  readdir(dir: ReadFileRef, opts?: { signal?: AbortSignal }): Promise<DirEntry[]> {
    return this.fs.readdir(dir, opts)
  }

  /** Reattach to a previously-started (e.g. detached) command by id. */
  getCommand(cmdId: string): Command {
    return new Command({ client: this.worker, cmdId })
  }

  async listCommands(opts: { signal?: AbortSignal } = {}) {
    return this.worker.listCommands(opts.signal)
  }

  /** Tears down the session on the worker and returns a final snapshot of it. */
  stop(opts?: { signal?: AbortSignal }): Promise<SessionSnapshot> {
    return this.worker.stopSession(opts?.signal)
  }

  /**
   * Restarts the persistent shell, discarding accumulated state (cwd, env, shell
   * variables). Used to recover when {@link runShellCommand} state has drifted into
   * a bad shape, without tearing down the whole session.
   */
  resetShell(opts?: { signal?: AbortSignal }): Promise<void> {
    return this.worker.resetShell(opts?.signal)
  }
}
