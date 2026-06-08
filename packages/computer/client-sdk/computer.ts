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
  /** Control-plane base URL. Defaults to env `BULLX_COMPUTER_CONTROL_URL` / `BULLX_AGENT_URL`. */
  baseUrl?: string
  /** Control-plane service token. Defaults to env `BULLX_COMPUTER_CONTROL_TOKEN` / `BULLX_COMPUTER_TOKEN`. */
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

async function resolveSession(
  params: ComputerConnectionConfig & { agentUid: string; signal?: AbortSignal }
): Promise<ResolveSessionResponse> {
  if (params.resolveWorker) return params.resolveWorker(params.agentUid, params.signal)
  const baseUrl = params.baseUrl ?? Bun.env.BULLX_COMPUTER_CONTROL_URL ?? Bun.env.BULLX_AGENT_URL
  if (!baseUrl) {
    throw new ApiError({
      status: 500,
      code: 'missing_control_url',
      message: 'no control-plane baseUrl (set BULLX_COMPUTER_CONTROL_URL / BULLX_AGENT_URL or pass baseUrl)',
      method: 'POST',
      url: ''
    })
  }
  const token = params.token ?? Bun.env.BULLX_COMPUTER_CONTROL_TOKEN ?? Bun.env.BULLX_COMPUTER_TOKEN
  const control = new ControlClient({ baseUrl, token, fetch: params.fetch, debug: params.debug })
  return withRetry(() => control.resolveSession(params.agentUid, params.signal), { signal: params.signal })
}

function workerFor(resolved: ResolveSessionResponse, params: ComputerConnectionConfig, agentUid: string): WorkerClient {
  return new WorkerClient(
    { baseUrl: resolved.worker.baseUrl, token: resolved.token, fetch: params.fetch, debug: params.debug },
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
    if (params.sudo) {
      throw new ApiError({
        status: 400,
        code: 'unsupported_sudo',
        message: 'sudo is not supported in this computer version',
        method: 'POST',
        url: ''
      })
    }
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

  async runShellCommand(command: string, opts: RunShellCommandOptions = {}): Promise<CommandFinished> {
    const response = await this.worker.openShell(
      { command, cwd: opts.cwd, env: opts.env, wait: true, timeout: opts.timeoutMs },
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

  stop(opts?: { signal?: AbortSignal }): Promise<SessionSnapshot> {
    return this.worker.stopSession(opts?.signal)
  }

  resetShell(opts?: { signal?: AbortSignal }): Promise<void> {
    return this.worker.resetShell(opts?.signal)
  }
}
