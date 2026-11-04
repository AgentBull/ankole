import { createRuntime, type Runtime } from 'mcporter'

type Options = { server: string; skill?: string; connection?: string; account?: string }

/** Holds the two signed execution identities in the trusted host for one invocation. */
export class InvocationMCP {
  private readonly clients = new Map<string, Promise<Runtime>>()

  constructor(
    private readonly origin: string,
    private readonly callerToken: string,
    private readonly adminToken: string,
    private readonly deadline: number
  ) {}

  async call(operation: string, args: unknown[]): Promise<unknown> {
    const [tool, input, options] = args as [string, Record<string, unknown>, Options]
    if (typeof tool !== 'string' || !input || typeof input !== 'object' || Array.isArray(input) || !options?.server) {
      throw { code: 'invalid_request', message: 'MCP calls require a tool, arguments, and server', status: 400 }
    }
    const token = operation === 'admin.mcp.call' ? this.adminToken : this.callerToken
    const path = options.skill
      ? `/api/internal/mcp/skills/${encodeURIComponent(options.skill)}/${encodeURIComponent(options.server)}`
      : `/api/internal/mcp/toolkits/${encodeURIComponent(options.server)}`
    const url = new URL(path, this.origin)
    if (options.connection) url.searchParams.set('connection', options.connection)
    if (options.account) url.searchParams.set('account', options.account)
    const key = `${operation}:${url}`
    let client = this.clients.get(key)
    if (!client) {
      client = createRuntime({
        servers: [
          {
            name: 'gateway',
            protocolVersion: '2026-07-28',
            command: {
              kind: 'http',
              url,
              headers: { authorization: `Bearer ${token}` }
            }
          }
        ]
      })
      this.clients.set(key, client)
    }
    const timeoutMs = this.deadline - Date.now()
    if (timeoutMs <= 0) throw { code: 'handler_timeout', message: 'Applet invocation timed out', status: 504 }
    const result = (await (await client).callTool('gateway', tool, { args: input, timeoutMs, disableOAuth: true })) as {
      isError?: boolean
      structuredContent?: { error?: Record<string, unknown> }
      content?: unknown
    }
    if (result.isError) {
      const error = result.structuredContent?.error
      throw {
        code: 'connector_call_failed',
        message: 'Connector call failed',
        ...error,
        status: typeof error?.status === 'number' && error.status >= 400 && error.status <= 599 ? error.status : 502,
        details: error
      }
    }
    return result.structuredContent ?? result
  }

  async close() {
    await Promise.allSettled([...this.clients.values()].map(async client => (await client).close()))
    this.clients.clear()
  }
}

/** Relays the existing capability WebSocket and consumes MCP calls in the host. */
export function bridgeAppletSockets(outer: WebSocket, inner: WebSocket, mcp: InvocationMCP) {
  const queued: string[] = []
  const sendInner = (data: string) => (inner.readyState === WebSocket.OPEN ? inner.send(data) : queued.push(data))
  inner.addEventListener('open', () => {
    for (const data of queued.splice(0)) inner.send(data)
  })
  outer.addEventListener('message', event => sendInner(String(event.data)))
  inner.addEventListener('message', event => {
    const frame = JSON.parse(String(event.data))
    if (frame.type === 'call' && ['mcp.call', 'admin.mcp.call'].includes(frame.operation)) {
      void mcp.call(frame.operation, frame.args).then(
        value => sendInner(JSON.stringify({ type: 'reply', call_id: frame.call_id, value })),
        error => {
          const details = typeof error?.data?.code === 'string' ? error.data : error?.details
          const code = details?.code ?? error?.code
          const status = details?.status ?? error?.status
          sendInner(
            JSON.stringify({
              type: 'reply',
              call_id: frame.call_id,
              error: {
                status: Number.isInteger(status) && status >= 400 && status <= 599 ? status : 502,
                code: typeof code === 'string' ? code : 'connector_call_failed',
                message: String(details?.message ?? error?.message ?? 'Connector call failed'),
                details,
                retryable: details?.retryable ?? error?.retryable,
                request_sent: details?.request_sent ?? error?.request_sent
              }
            })
          )
        }
      )
    } else if (outer.readyState === WebSocket.OPEN) outer.send(event.data)
  })
  const close = () => {
    if (inner.readyState < WebSocket.CLOSING) inner.close()
    if (outer.readyState < WebSocket.CLOSING) outer.close()
    void mcp.close()
  }
  for (const socket of [outer, inner]) {
    socket.addEventListener('close', close, { once: true })
    socket.addEventListener('error', close, { once: true })
  }
}
