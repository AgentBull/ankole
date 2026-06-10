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

/** Client for a resolved worker daemon (`bullx-computerd`). All paths are agent-scoped. */
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

  openCommand(body: CommandRequest, signal?: AbortSignal): Promise<Response> {
    return this.request({
      method: 'POST',
      path: this.sessionPath('/cmd'),
      accept: NDJSON,
      contentType: JSON_CT,
      body: JSON.stringify(body),
      signal
    })
  }

  openShell(body: ShellRequest, signal?: AbortSignal): Promise<Response> {
    return this.request({
      method: 'POST',
      path: this.sessionPath('/shell'),
      accept: NDJSON,
      contentType: JSON_CT,
      body: JSON.stringify(body),
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

  openLogs(cmdId: string, opts: { signal?: AbortSignal; follow?: boolean } = {}): Promise<Response> {
    return this.request({
      method: 'GET',
      path: this.cmdPath(cmdId, '/logs'),
      accept: NDJSON,
      query: opts.follow === false ? { follow: false } : undefined,
      signal: opts.signal
    })
  }

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

  /** Returns the octet-stream Response on success, or `null` on 404 (file missing). */
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
