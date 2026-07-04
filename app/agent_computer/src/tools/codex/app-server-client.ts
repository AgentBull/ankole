import { type JsonObject, isRecord } from '../../fabric/fabric'

export type JsonRpcMessage = JsonObject & {
  id?: string | number
  method?: string
  params?: unknown
  result?: unknown
  error?: unknown
}

export type CodexServerRequestHandler = (message: JsonRpcMessage, client: CodexAppServerClient) => Promise<void>
export type CodexNotificationHandler = (message: JsonRpcMessage) => void
export type CodexAuditHandler = (
  direction: 'client_to_server' | 'server_to_client' | 'client_response',
  message: JsonRpcMessage
) => void

type PendingRequest = {
  resolve: (value: unknown) => void
  reject: (error: Error) => void
  timeout: ReturnType<typeof setTimeout>
}

type WritableFileSink = {
  write: (chunk: string | Uint8Array) => unknown
  end?: () => unknown
}

export type CodexAppServerClientOptions = {
  command?: string
  args?: string[]
  cwd: string
  env: Record<string, string>
  audit?: CodexAuditHandler
  onExit?: (error: Error) => void
  onNotification?: CodexNotificationHandler
  onServerRequest?: CodexServerRequestHandler
}

const requestTimeoutMs = 60_000

export class CodexAppServerClient {
  private nextId = 1
  private pending = new Map<string | number, PendingRequest>()
  private stdin?: WritableFileSink
  private closed = false
  private readonly proc: ReturnType<typeof Bun.spawn>
  private readonly encoder = new TextEncoder()

  constructor(private readonly opts: CodexAppServerClientOptions) {
    this.proc = Bun.spawn(
      [opts.command ?? process.env.ANKOLE_CODEX_BINARY ?? 'codex', 'app-server', '--stdio', ...(opts.args ?? [])],
      {
        cwd: opts.cwd,
        env: opts.env,
        stdin: 'pipe',
        stdout: 'pipe',
        stderr: 'pipe'
      }
    )
    this.stdin =
      this.proc.stdin && typeof this.proc.stdin === 'object' ? (this.proc.stdin as WritableFileSink) : undefined
    void this.readStdout()
    void this.readStderr()
    void this.proc.exited.then(
      code => {
        if (!this.closed) {
          const error = new Error(`codex app-server exited with code ${code ?? 'unknown'}`)
          this.rejectPending(error)
          this.opts.onExit?.(error)
        }
      },
      error => {
        if (!this.closed) {
          const normalized = error instanceof Error ? error : new Error(String(error))
          this.rejectPending(normalized)
          this.opts.onExit?.(normalized)
        }
      }
    )
  }

  async initialize(): Promise<void> {
    await this.request('initialize', {
      clientInfo: {
        name: 'ankole_agent_computer',
        title: 'Ankole Agent Computer',
        version: '0.1.0'
      },
      capabilities: {
        experimentalApi: true
      }
    })
    await this.notify('initialized', {})
  }

  async request(method: string, params: unknown): Promise<unknown> {
    const id = this.nextId++
    const message = { method, id, params }
    const promise = new Promise<unknown>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`codex app-server request timed out: ${method}`))
      }, requestTimeoutMs)
      this.pending.set(id, { resolve, reject, timeout })
    })

    await this.write(message)
    return promise
  }

  async notify(method: string, params: unknown): Promise<void> {
    await this.write({ method, params })
  }

  async respond(id: string | number, result: unknown): Promise<void> {
    await this.write({ id, result }, 'client_response')
  }

  async respondError(id: string | number, code: number, message: string): Promise<void> {
    await this.write({ id, error: { code, message } }, 'client_response')
  }

  async close(): Promise<void> {
    if (this.closed) return
    this.closed = true

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

  private async write(message: JsonRpcMessage, direction: 'client_to_server' | 'client_response' = 'client_to_server') {
    if (this.closed) throw new Error('codex app-server client is closed')
    this.opts.audit?.(direction, message)
    await Promise.resolve(this.stdin?.write(this.encoder.encode(`${JSON.stringify(message)}\n`)))
  }

  private async readStdout(): Promise<void> {
    await readJsonLines(this.proc.stdout && typeof this.proc.stdout === 'object' ? this.proc.stdout : null, line =>
      this.handleLine(line)
    )
  }

  private async readStderr(): Promise<void> {
    await readTextChunks(this.proc.stderr && typeof this.proc.stderr === 'object' ? this.proc.stderr : null, chunk => {
      this.opts.onNotification?.({
        method: '$stderr',
        params: { text: chunk }
      })
    })
  }

  private handleLine(line: string): void {
    let message: unknown

    try {
      message = JSON.parse(line)
    } catch (error) {
      this.opts.onNotification?.({
        method: '$parse_error',
        params: { line, error: error instanceof Error ? error.message : String(error) }
      })
      return
    }

    if (!isRecord(message)) return
    const rpc = message as JsonRpcMessage
    this.opts.audit?.('server_to_client', rpc)

    if (rpc.id !== undefined && (Object.hasOwn(rpc, 'result') || Object.hasOwn(rpc, 'error'))) {
      this.resolveResponse(rpc)
      return
    }

    if (typeof rpc.method === 'string' && rpc.id !== undefined) {
      const handler = this.opts.onServerRequest
      if (!handler) {
        void this.respondError(rpc.id, -32601, `Codex server request is not implemented: ${rpc.method}`).catch(error => {
          this.opts.onNotification?.({
            method: '$server_request_error',
            params: { error: error instanceof Error ? error.message : String(error) }
          })
        })
        return
      }

      void handler(rpc, this).catch(error => {
        this.opts.onNotification?.({
          method: '$server_request_error',
          params: { error: error instanceof Error ? error.message : String(error) }
        })
      })
      return
    }

    this.opts.onNotification?.(rpc)
  }

  private resolveResponse(message: JsonRpcMessage): void {
    const id = message.id
    if (id === undefined) return
    const pending = this.pending.get(id)
    if (!pending) return

    clearTimeout(pending.timeout)
    this.pending.delete(id)

    if (message.error) {
      pending.reject(new Error(jsonErrorMessage(message.error)))
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
}

async function readJsonLines(stream: ReadableStream<Uint8Array> | null, onLine: (line: string) => void): Promise<void> {
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
