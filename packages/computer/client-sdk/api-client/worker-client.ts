import type {
  CommandState,
  DirEntry,
  FileStat,
  SendTerminalParams,
  SessionResponse,
  SessionSnapshot,
  StartTerminalParams,
  TerminalCapture,
  TerminalInfo,
  TerminalStatus,
  WorkerInfo
} from '../types'
import { BaseClient, type BaseClientConfig, toApiError } from './base-client'
import { expectOctetStream } from './validators'

const NDJSON = 'application/x-ndjson'
const JSON_CT = 'application/json'

// Fallback command budget when the caller omits `timeout` (mirrors the worker's
// own DEFAULT_TIMEOUT_MS), and the grace added on top before the client gives up
// on a silent stream: the worker still has to detect its server-side timeout,
// SIGTERM, wait the kill grace, SIGKILL, and flush the terminal frame.
const DEFAULT_COMMAND_TIMEOUT_MS = 60_000
const COMMAND_IDLE_GRACE_MS = 30_000

/** A `wait:true` stream is silent until the worker's own timeout fires; bound the client at timeout + grace. */
function commandIdleTimeoutMs(body: { wait: boolean; timeout?: number }): number | undefined {
  if (!body.wait) return undefined
  return (body.timeout ?? DEFAULT_COMMAND_TIMEOUT_MS) + COMMAND_IDLE_GRACE_MS
}

export interface CommandRequest {
  command: string
  args?: string[]
  cwd?: string
  env?: Record<string, string>
  sudo?: boolean
  wait: boolean
  timeout?: number
}

export interface ShellRequest {
  command: string
  cwd?: string
  env?: Record<string, string>
  /** Execution scope (conversation) owning the persistent shell; omit for the agent-shared shell. */
  scope?: string
  wait: boolean
  timeout?: number
}

/**
 * Typed client for a resolved worker daemon (`bullx-computerd`), the Rust process
 * that actually runs commands and holds the filesystem for one agent.
 *
 * The agent identity is not a header but part of the path: every session route is
 * `/v1/sessions/{agentUid}/…` (see {@link sessionPath}), so one worker can host
 * many agents and each call is scoped to exactly one. Filesystem and command
 * working directories travel differently — as a JSON `cwd` field, except bulk
 * uploads which use the `x-cwd` header (see {@link writeFiles}).
 *
 * Methods come in two shapes: `json()`-based calls that decode a typed body, and
 * `request()`-based calls that hand back the raw streaming {@link Response} (command/
 * shell/log NDJSON and file octet-streams), which the caller consumes itself.
 */
export class WorkerClient extends BaseClient {
  readonly agentUid: string

  constructor(config: BaseClientConfig, agentUid: string) {
    super(config)
    this.agentUid = agentUid
  }

  private sessionPath(suffix = ''): string {
    return `/v1/sessions/${encodeURIComponent(this.agentUid)}${suffix}`
  }

  private cmdPath(cmdId: string, suffix = ''): string {
    return this.sessionPath(`/cmd/${encodeURIComponent(cmdId)}${suffix}`)
  }

  private terminalPath(name: string, suffix = ''): string {
    return this.sessionPath(`/terminals/${encodeURIComponent(name)}${suffix}`)
  }

  getWorker(signal?: AbortSignal): Promise<WorkerInfo> {
    return this.json<WorkerInfo>({ method: 'GET', path: '/v1/worker', signal })
  }

  putSession(signal?: AbortSignal): Promise<SessionResponse> {
    return this.json<SessionResponse>({ method: 'PUT', path: this.sessionPath(), signal })
  }

  getSession(signal?: AbortSignal): Promise<SessionResponse> {
    return this.json<SessionResponse>({ method: 'GET', path: this.sessionPath(), signal })
  }

  stopSession(signal?: AbortSignal): Promise<SessionSnapshot> {
    return this.json<SessionSnapshot>({ method: 'POST', path: this.sessionPath('/stop'), signal })
  }

  async resetShell(signal?: AbortSignal): Promise<void> {
    await this.request({ method: 'POST', path: this.sessionPath('/reset-shell'), signal })
  }

  /**
   * Starts a one-off command and returns the raw NDJSON {@link Response} stream
   * (decoded by `consumeCommandResponse`), not a parsed result. The idle timeout is
   * derived from the command's own budget for `wait:true` calls — see
   * {@link commandIdleTimeoutMs} for why a fixed value would be wrong.
   */
  openCommand(body: CommandRequest, signal?: AbortSignal): Promise<Response> {
    return this.request({
      method: 'POST',
      path: this.sessionPath('/cmd'),
      accept: NDJSON,
      contentType: JSON_CT,
      body: JSON.stringify(body),
      idleTimeoutMs: commandIdleTimeoutMs(body),
      signal
    })
  }

  /** Like {@link openCommand} but targets the agent's persistent shell (`scope` picks a per-conversation one). */
  openShell(body: ShellRequest, signal?: AbortSignal): Promise<Response> {
    return this.request({
      method: 'POST',
      path: this.sessionPath('/shell'),
      accept: NDJSON,
      contentType: JSON_CT,
      body: JSON.stringify(body),
      idleTimeoutMs: commandIdleTimeoutMs(body),
      signal
    })
  }

  getCommand(cmdId: string, signal?: AbortSignal): Promise<CommandState> {
    return this.json<CommandState>({ method: 'GET', path: this.cmdPath(cmdId), signal })
  }

  async listCommands(signal?: AbortSignal): Promise<CommandState[]> {
    const result = await this.json<{ commands: CommandState[] }>({
      method: 'GET',
      path: this.sessionPath('/cmd'),
      signal
    })
    return result.commands
  }

  /**
   * Opens the command's log stream (NDJSON {@link Response}). The worker tails a
   * live command by default; `follow:false` is sent only to opt out, so that the
   * stream ends once recorded output is drained. Other values are left implicit to
   * keep the worker's default.
   */
  openLogs(cmdId: string, opts: { signal?: AbortSignal; follow?: boolean } = {}): Promise<Response> {
    return this.request({
      method: 'GET',
      path: this.cmdPath(cmdId, '/logs'),
      accept: NDJSON,
      query: opts.follow === false ? { follow: false } : undefined,
      signal: opts.signal
    })
  }

  /**
   * Signals a running command. `signal` is the process kill signal (name/number,
   * null = worker default); `abortSignal` aborts the kill *request* — two unrelated
   * "signal" notions kept as distinct params. Sent as JSON `null` when unspecified
   * so the worker picks its default.
   */
  async killCommand(cmdId: string, signal?: string | number, abortSignal?: AbortSignal): Promise<void> {
    await this.request({
      method: 'POST',
      path: this.cmdPath(cmdId, '/kill'),
      contentType: JSON_CT,
      body: JSON.stringify({ signal: signal ?? null }),
      signal: abortSignal
    })
  }

  async listTerminals(signal?: AbortSignal): Promise<TerminalInfo[]> {
    const result = await this.json<{ terminals: TerminalInfo[] }>({
      method: 'GET',
      path: this.sessionPath('/terminals'),
      signal
    })
    return result.terminals
  }

  startTerminal(name: string, body: StartTerminalParams, signal?: AbortSignal): Promise<TerminalStatus> {
    return this.json<TerminalStatus>({
      method: 'POST',
      path: this.terminalPath(name, '/start'),
      contentType: JSON_CT,
      body: JSON.stringify(body),
      signal
    })
  }

  sendTerminal(name: string, body: SendTerminalParams, signal?: AbortSignal): Promise<TerminalStatus> {
    return this.json<TerminalStatus>({
      method: 'POST',
      path: this.terminalPath(name, '/send'),
      contentType: JSON_CT,
      body: JSON.stringify(body),
      signal
    })
  }

  captureTerminal(name: string, lines?: number, signal?: AbortSignal): Promise<TerminalCapture> {
    return this.json<TerminalCapture>({
      method: 'GET',
      path: this.terminalPath(name, '/capture'),
      query: { lines },
      signal
    })
  }

  killTerminal(name: string, signal?: AbortSignal): Promise<TerminalStatus> {
    return this.json<TerminalStatus>({
      method: 'DELETE',
      path: this.terminalPath(name),
      signal
    })
  }

  async mkdir(path: string, cwd: string | undefined, recursive: boolean, signal?: AbortSignal): Promise<void> {
    await this.request({
      method: 'POST',
      path: this.sessionPath('/fs/mkdir'),
      contentType: JSON_CT,
      body: JSON.stringify({ path, cwd, recursive }),
      signal
    })
  }

  /**
   * Uploads a batch of files as a single gzipped tar (built by {@link FileWriter}).
   * The destination directory rides as the `x-cwd` header rather than in the body,
   * because the body is the opaque archive; the worker unpacks the tar relative to
   * that cwd. One archive per call keeps it to a single request instead of N writes.
   */
  async writeFiles(tarGz: Uint8Array, cwd: string, signal?: AbortSignal): Promise<void> {
    await this.request({
      method: 'POST',
      path: this.sessionPath('/fs/write'),
      contentType: 'application/gzip',
      headers: { 'x-cwd': cwd },
      body: tarGz,
      signal
    })
  }

  /**
   * Reads a file, returning the streaming octet-stream {@link Response} so large
   * files are not buffered here. A missing file is a normal outcome (`null`), not an
   * error, so `noThrow` lets the 404 through and the body is cancelled to free the
   * connection. {@link expectOctetStream} then rejects the case where a non-404
   * error came back as a JSON body instead of file content.
   */
  async readFile(path: string, cwd: string | undefined, signal?: AbortSignal): Promise<Response | null> {
    const route = this.sessionPath('/fs/read')
    const response = await this.request({
      method: 'POST',
      path: route,
      contentType: JSON_CT,
      accept: 'application/octet-stream',
      body: JSON.stringify({ path, cwd }),
      signal,
      noThrow: true
    })
    if (response.status === 404) {
      await response.body?.cancel()
      return null
    }
    if (!response.ok) throw await toApiError(response, 'POST', this.buildUrl(route))
    expectOctetStream(response, 'POST', this.buildUrl(route))
    return response
  }

  stat(path: string, cwd: string | undefined, signal?: AbortSignal): Promise<FileStat> {
    return this.json<FileStat>({
      method: 'POST',
      path: this.sessionPath('/fs/stat'),
      contentType: JSON_CT,
      body: JSON.stringify({ path, cwd }),
      signal
    })
  }

  async readdir(path: string, cwd: string | undefined, signal?: AbortSignal): Promise<DirEntry[]> {
    const result = await this.json<{ entries: DirEntry[] }>({
      method: 'POST',
      path: this.sessionPath('/fs/readdir'),
      contentType: JSON_CT,
      body: JSON.stringify({ path, cwd }),
      signal
    })
    return result.entries
  }
}
