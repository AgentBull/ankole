import { Result, isRecord, ms, type JsonObject as JSONObject } from '@agentbull/active-support'
import { errorMessage, toError } from '../../../common/errors'

export type JSONRPCMessage = JSONObject & {
  id?: string | number
  method?: string
  params?: unknown
  result?: unknown
  error?: unknown
}

export type CodexServerRequestHandler = (message: JSONRPCMessage, client: CodexAppServerClient) => Promise<void>
export type CodexNotificationHandler = (message: JSONRPCMessage) => void

type PendingRequest = {
  resolve: (value: unknown) => void
  reject: (error: Error) => void
  timeout: ReturnType<typeof setTimeout>
}

type JSONRPCLineError = {
  line: string
  message: string
}

type WritableFileSink = {
  write: (chunk: string | Uint8Array) => unknown
  flush?: () => unknown
  end?: () => unknown
}

type CodexAppServerProcess = {
  pid?: number
  stdin?: WritableFileSink | null
  stdout?: ReadableStream<Uint8Array> | null
  stderr?: ReadableStream<Uint8Array> | null
  exited: Promise<number | null>
  kill: () => unknown
}

type CodexAppServerSpawner = (
  commandArgv: string[],
  options: {
    cwd: string
    env: Record<string, string>
    stdin: 'pipe'
    stdout: 'pipe'
    stderr: 'pipe'
  }
) => CodexAppServerProcess

/** Typed Bun process adapter and deterministic spawn seam for tests. */
const spawnCodexAppServer: CodexAppServerSpawner = (commandArgv, options) =>
  Bun.spawn(commandArgv, options) as unknown as CodexAppServerProcess

export type CodexAppServerClientOptions = {
  command?: string
  commandArgv?: string[]
  args?: string[]
  cwd: string
  env: Record<string, string>
  onExit?: (error: Error) => void
  onNotification?: CodexNotificationHandler
  onServerRequest?: CodexServerRequestHandler
}

export class CodexAppServerRPCError extends Error {
  readonly details: JSONObject

  constructor(readonly rpcError: unknown) {
    super(jsonErrorMessage(rpcError))
    this.name = 'CodexAppServerRPCError'

    const payload = isRecord(rpcError) ? rpcError : {}
    const data = isRecord(payload.data) ? payload.data : {}
    this.details = {
      ...data,
      ...payload,
      message: typeof payload.message === 'string' ? payload.message : this.message
    }
  }
}

/** Default bound for app-server requests that have no larger operation budget. */
const DEFAULT_REQUEST_TIMEOUT_MS = ms('1m')
// Codex can maintain large shared state before initialize returns. Give this
// operation its own budget instead of consuming the ordinary RPC budget.
const INITIALIZE_REQUEST_TIMEOUT_MS = ms('5m')
/** Thread creation budget; Plugin and Skill discovery can run before return. */
const THREAD_START_REQUEST_TIMEOUT_MS = ms('2m')
/** Thread restore budget; Codex can load and validate retained history. */
const THREAD_RESUME_REQUEST_TIMEOUT_MS = ms('2m')
/** Short read-only probe used after a state-changing request times out. */
const HEALTH_PROBE_TIMEOUT_MS = ms('5s')
/** Allows the process exit code to arrive before reporting a closed stdout. */
const STDOUT_EXIT_GRACE_MS = 50
/** Grace period after stdin closes before Agent Computer kills the process. */
const PROCESS_GRACEFUL_CLOSE_MS = ms('1s')
// JSON line parsing stays non-throwing so one bad line becomes a protocol
// failure with the original line attached.
const parseJSONLine = (line: string): Result<unknown, unknown> =>
  Result.try({
    try: () => JSON.parse(line) as unknown,
    catch: error => error
  })

// The recorder persists completed semantic items. Suppress intermediate
// notifications that would duplicate durable content.
export const CODEX_OPT_OUT_NOTIFICATION_METHODS = [
  'item/agentMessage/delta',
  'item/plan/delta',
  'item/reasoning/summaryPartAdded',
  'item/reasoning/summaryTextDelta',
  'item/reasoning/textDelta',
  'item/commandExecution/outputDelta',
  'item/commandExecution/terminalInteraction',
  'item/fileChange/outputDelta',
  'item/fileChange/patchUpdated',
  'item/mcpToolCall/progress'
] as const

/**
 * Owns the JSON-RPC transport to one Codex app-server process.
 * Job lifecycle, thread ownership, and durable state stay outside this client.
 */
export class CodexAppServerClient {
  private nextID = 1
  private pending = new Map<string | number, PendingRequest>()
  private stdin?: WritableFileSink
  private closed = false
  private closeReason?: Error
  private readonly proc: CodexAppServerProcess
  private readonly encoder = new TextEncoder()

  constructor(
    private readonly opts: CodexAppServerClientOptions,
    spawn: CodexAppServerSpawner = spawnCodexAppServer
  ) {
    const commandArgv = opts.commandArgv ?? [
      opts.command ?? process.env.ANKOLE_CODEX_BINARY ?? 'codex',
      'app-server',
      '--stdio',
      ...(opts.args ?? [])
    ]
    this.proc = spawn(commandArgv, {
      cwd: opts.cwd,
      env: opts.env,
      stdin: 'pipe',
      stdout: 'pipe',
      stderr: 'pipe'
    })
    this.stdin = this.proc.stdin ?? undefined
    void this.readStdout()
    void this.readStderr()
    void this.proc.exited.then(
      code => {
        if (!this.closed) {
          const error = new CodexAppServerExitError(code)
          this.failTransport(error)
        }
      },
      error => {
        if (!this.closed) {
          this.failTransport(toError(error))
        }
      }
    )
  }

  get processID(): number | undefined {
    return this.proc.pid
  }

  async initialize(): Promise<JSONObject> {
    const response =
      (await this.request(
        'initialize',
        {
          clientInfo: {
            name: 'ankole_agent_computer',
            title: 'Ankole Agent Computer',
            version: '0.1.0'
          },
          capabilities: {
            ['experimentalApi']: true,
            ['optOutNotificationMethods']: [...CODEX_OPT_OUT_NOTIFICATION_METHODS]
          }
        },
        INITIALIZE_REQUEST_TIMEOUT_MS
      )) ?? {}
    await this.notify('initialized', {})
    return isRecord(response) ? (response as JSONObject) : {}
  }

  async request(method: string, params: unknown, timeoutMs = defaultRequestTimeoutMs(method)): Promise<unknown> {
    if (this.closeReason) throw this.closeReason
    const id = this.nextID++
    const message = { method, id, params }
    const promise = new Promise<unknown>((resolve, reject) => {
      const timeout = setTimeout(() => {
        const error = new CodexAppServerRequestTimeoutError(method)
        if (transportFatalTimeoutMethod(method)) {
          this.failTransport(error)
        } else if (uncertainResultMethod(method)) {
          void this.failTransportUnlessResponsive(error, id, reject)
        } else {
          this.pending.delete(id)
          reject(error)
        }
      }, timeoutMs)
      this.pending.set(id, { resolve, reject, timeout })
    })

    try {
      await this.write(message)
    } catch {
      return promise
    }
    return promise
  }

  async notify(method: string, params: unknown): Promise<void> {
    await this.write({ method, params })
  }

  async respond(id: string | number, result: unknown): Promise<void> {
    await this.write({ id, result })
  }

  async respondError(id: string | number, code: number, message: string): Promise<void> {
    await this.write({ id, error: { code, message } })
  }

  async close(): Promise<void> {
    if (this.closed) return
    this.closed = true
    this.closeReason = new Error('codex app-server client is closed')
    this.rejectPending(this.closeReason)
    this.closeProcess()
  }

  async closeAndWait(): Promise<void> {
    if (!this.closed) {
      this.closed = true
      this.closeReason = new Error('codex app-server client is closed')
      this.rejectPending(this.closeReason)
      this.closeInput()
      if (!(await this.processExitedWithin(PROCESS_GRACEFUL_CLOSE_MS))) this.killProcess()
    }
    try {
      await this.proc.exited
    } catch {
      // Process-exit rejection is already reflected by the closed transport.
    }
  }

  private closeProcess(): void {
    this.closeInput()
    this.killProcess()
  }

  private closeInput(): void {
    try {
      this.stdin?.end?.()
    } catch {
      // The process can exit before this cleanup call.
    }
  }

  private killProcess(): void {
    try {
      this.proc.kill()
    } catch {
      // The process can exit before this cleanup call.
    }
  }

  private async processExitedWithin(timeoutMs: number): Promise<boolean> {
    return Promise.race([
      this.proc.exited.then(
        () => true,
        () => true
      ),
      delay(timeoutMs).then(() => false)
    ])
  }

  private async write(message: JSONRPCMessage) {
    if (this.closeReason) throw this.closeReason
    try {
      await Promise.resolve(this.stdin?.write(this.encoder.encode(`${JSON.stringify(message)}\n`)))
      await Promise.resolve(this.stdin?.flush?.())
    } catch (error) {
      this.failTransport(toError(error))
      throw this.closeReason
    }
  }

  private async readStdout(): Promise<void> {
    try {
      await readJSONLines(this.proc.stdout ?? null, line => this.handleLine(line))
      if (!this.closed) await this.failAfterStdoutClosed()
    } catch (error) {
      this.failTransport(toError(error))
    }
  }

  private async failAfterStdoutClosed(): Promise<void> {
    await Promise.race([
      this.proc.exited.then(
        () => undefined,
        () => undefined
      ),
      delay(STDOUT_EXIT_GRACE_MS)
    ])
    if (!this.closed) this.failTransport(new Error('codex app-server stdout closed'))
  }

  private async readStderr(): Promise<void> {
    try {
      await readTextChunks(this.proc.stderr ?? null, chunk => {
        this.opts.onNotification?.({
          method: '$stderr',
          params: { text: chunk }
        })
      })
    } catch (error) {
      this.opts.onNotification?.({
        method: '$stderr_error',
        params: { error: errorMessage(error) }
      })
    }
  }

  private handleLine(line: string): void {
    const parsed = parseJSONRPCLine(line)
    if (parsed.isErr()) {
      this.opts.onNotification?.({
        method: '$parse_error',
        params: { line: parsed.error.line, error: parsed.error.message }
      })
      return
    }

    const rpc = parsed.value
    if (!rpc) return

    if (rpc.id !== undefined && (Object.hasOwn(rpc, 'result') || Object.hasOwn(rpc, 'error'))) {
      this.resolveResponse(rpc)
      return
    }

    if (typeof rpc.method === 'string' && rpc.id !== undefined) {
      const handler = this.opts.onServerRequest
      if (!handler) {
        void this.respondError(rpc.id, -32601, `Codex server request is not implemented: ${rpc.method}`).catch(
          error => {
            this.opts.onNotification?.({
              method: '$server_request_error',
              params: { error: errorMessage(error) }
            })
          }
        )
        return
      }

      void handler(rpc, this).catch(error => {
        this.opts.onNotification?.({
          method: '$server_request_error',
          params: { error: errorMessage(error) }
        })
      })
      return
    }

    this.opts.onNotification?.(rpc)
  }

  private resolveResponse(message: JSONRPCMessage): void {
    const id = message.id
    if (id === undefined) return
    const pending = this.pending.get(id)
    if (!pending) return

    clearTimeout(pending.timeout)
    this.pending.delete(id)

    if (message.error) {
      pending.reject(new CodexAppServerRPCError(message.error))
      return
    }

    pending.resolve(message.result)
  }

  private rejectPending(error: Error): void {
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timeout)
      pending.reject(error)
      this.pending.delete(id)
    }
  }

  private failTransport(error: Error): void {
    if (this.closed) return
    this.closed = true
    this.closeReason = error
    this.rejectPending(error)
    this.closeProcess()
    void this.notifyExitAfterReap(error)
  }

  /**
   * A timed-out state-changing request has an unknown result.
   * Keep the shared runtime only if a separate read-only probe proves that
   * stdio still responds.
   */
  private async failTransportUnlessResponsive(
    error: CodexAppServerRequestTimeoutError,
    id: number,
    reject: (error: Error) => void
  ): Promise<void> {
    if (await this.probeResponsive()) {
      this.pending.delete(id)
      reject(error)
      return
    }
    this.failTransport(error)
  }

  /**
   * Codex 0.147 rejects an unknown method before request scheduling or config
   * handling. Its JSON-RPC error proves that the stdio request path is alive.
   */
  private async probeResponsive(): Promise<boolean> {
    if (this.closed) return false
    try {
      await this.request('ankole/health_probe', {}, HEALTH_PROBE_TIMEOUT_MS)
      return true
    } catch (probeError) {
      return probeError instanceof CodexAppServerRPCError
    }
  }

  private async notifyExitAfterReap(error: Error): Promise<void> {
    try {
      await this.proc.exited
    } catch {
      // Rejected exit promises still mean that the child can no longer run.
    }
    this.opts.onExit?.(error)
  }
}

function defaultRequestTimeoutMs(method: string): number {
  if (method === 'thread/start') return THREAD_START_REQUEST_TIMEOUT_MS
  if (method === 'thread/resume') return THREAD_RESUME_REQUEST_TIMEOUT_MS
  return DEFAULT_REQUEST_TIMEOUT_MS
}

export class CodexAppServerRequestTimeoutError extends Error {
  readonly code = 'codex_app_server_request_timeout'

  constructor(readonly method: string) {
    super(`codex app-server request timed out: ${method}`)
    this.name = 'CodexAppServerRequestTimeoutError'
  }
}

export class CodexAppServerExitError extends Error {
  constructor(readonly exitCode: number | null) {
    super(`codex app-server exited with code ${exitCode ?? 'unknown'}`)
    this.name = 'CodexAppServerExitError'
  }
}

// A late `turn/start` result is unsafe because a ghost Codex turn can continue
// without its caller. It and a failed initialize close the transport directly.
function transportFatalTimeoutMethod(method: string): boolean {
  return method === 'initialize' || method === 'turn/start'
}

// These requests can change shared runtime state. Do not retry one after a
// timeout because its result is unknown.
function uncertainResultMethod(method: string): boolean {
  return (
    method === 'thread/start' ||
    method === 'thread/resume' ||
    method === 'thread/fork' ||
    method === 'turn/steer' ||
    method === 'turn/interrupt' ||
    method === 'thread/unsubscribe' ||
    method === 'thread/backgroundTerminals/terminate' ||
    method === 'thread/backgroundTerminals/clean' ||
    method.startsWith('plugin/') ||
    method.startsWith('skills/config/') ||
    method.startsWith('config/')
  )
}

function parseJSONRPCLine(line: string): Result<JSONRPCMessage | undefined, JSONRPCLineError> {
  const parsed = parseJSONLine(line).mapError(error => ({ line, message: errorText(error) }))
  if (parsed.isErr()) {
    return Result.err(parsed.error)
  }

  const message = parsed.value
  return Result.ok(isRecord(message) ? (message as JSONRPCMessage) : undefined)
}

async function readJSONLines(stream: ReadableStream<Uint8Array> | null, onLine: (line: string) => void): Promise<void> {
  if (!stream) return
  const reader = stream.getReader()
  const decoder = new TextDecoder()
  let buffer = ''

  try {
    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      let newlineIndex = buffer.indexOf('\n')
      while (newlineIndex >= 0) {
        const line = buffer.slice(0, newlineIndex).trim()
        buffer = buffer.slice(newlineIndex + 1)
        if (line) onLine(line)
        newlineIndex = buffer.indexOf('\n')
      }
    }
    const tail = buffer.trim()
    if (tail) onLine(tail)
  } finally {
    reader.releaseLock()
  }
}

async function readTextChunks(
  stream: ReadableStream<Uint8Array> | null,
  onChunk: (chunk: string) => void
): Promise<void> {
  if (!stream) return
  const reader = stream.getReader()
  const decoder = new TextDecoder()

  try {
    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      if (value) onChunk(decoder.decode(value))
    }
  } finally {
    reader.releaseLock()
  }
}

function jsonErrorMessage(error: unknown): string {
  if (isRecord(error) && typeof error.message === 'string') return error.message
  return JSON.stringify(error)
}

function errorText(error: unknown): string {
  return errorMessage(error)
}

function delay(durationMs: number): Promise<void> {
  return new Promise(resolve => {
    const timer = setTimeout(resolve, durationMs)
    timer.unref?.()
  })
}
