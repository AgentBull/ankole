import { isRecord, Result, type JsonObject as JSONObject } from '@agentbull/active-support'
import { errorMessage, toError } from '../../common/errors'

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
  end?: () => unknown
}

type CodexAppServerProcess = {
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

// Hermes uses 10s for initialize, 15s for thread/start, and 30s for generic
// app-server requests. Ankole keeps the same request classes but gives slower
// cold-start and background Job paths a wider budget.
const DEFAULT_REQUEST_TIMEOUT_MS = 60_000
const INITIALIZE_REQUEST_TIMEOUT_MS = 15_000
const THREAD_START_REQUEST_TIMEOUT_MS = 30_000
const parseJSONLine = (line: string): Result<unknown, unknown> =>
  Result.try({
    try: () => JSON.parse(line) as unknown,
    catch: error => error
  })

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
          const error = new Error(`codex app-server exited with code ${code ?? 'unknown'}`)
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
        this.pending.delete(id)
        reject(new Error(`codex app-server request timed out: ${method}`))
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

  private closeProcess(): void {
    try {
      this.stdin?.end?.()
    } catch {
      // ignore close races; the process may already have exited.
    }

    try {
      this.proc.kill()
    } catch {
      // ignore close races; the process may already have exited.
    }
  }

  private async write(message: JSONRPCMessage) {
    if (this.closeReason) throw this.closeReason
    try {
      await Promise.resolve(this.stdin?.write(this.encoder.encode(`${JSON.stringify(message)}\n`)))
    } catch (error) {
      this.failTransport(toError(error))
      throw this.closeReason
    }
  }

  private async readStdout(): Promise<void> {
    try {
      await readJSONLines(this.proc.stdout ?? null, line => this.handleLine(line))
      if (!this.closed) this.failTransport(new Error('codex app-server stdout closed'))
    } catch (error) {
      this.failTransport(toError(error))
    }
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
    this.opts.onExit?.(error)
  }
}

function defaultRequestTimeoutMs(method: string): number {
  if (method === 'thread/start') return THREAD_START_REQUEST_TIMEOUT_MS
  return DEFAULT_REQUEST_TIMEOUT_MS
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
