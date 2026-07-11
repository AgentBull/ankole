import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { DEFAULT_BROWSER_COMMAND_TIMEOUT_MS, DEFAULT_CDP_CONNECT_TIMEOUT_MS } from './constants'

/**
 * Minimal Chrome DevTools Protocol client over one WebSocket.
 *
 * The worker uses only a small CDP subset, so keeping this local avoids pulling
 * in a full browser automation framework while still preserving request ids,
 * session ids, events, and command timeouts.
 */
export class CDPClient {
  private nextID = 1
  readonly closed: Promise<void>
  private resolveClosed!: () => void
  private eventListeners = new Map<string, Set<(params: JSONObject) => void>>()
  private pending = new Map<
    number,
    {
      resolve: (value: unknown) => void
      reject: (reason: Error) => void
      timeout: ReturnType<typeof setTimeout>
    }
  >()

  private constructor(private readonly socket: WebSocket) {
    this.closed = new Promise(resolve => {
      this.resolveClosed = resolve
    })
    socket.addEventListener('message', event => {
      try {
        this.handleMessage(event.data)
      } catch (error) {
        debugCDP(`message handler failed: ${error instanceof Error ? error.stack || error.message : String(error)}`)
      }
    })
    socket.addEventListener('close', event => {
      debugCDP(`socket closed code=${event.code} reason=${event.reason || ''}`)
      this.rejectAll(new Error('CDP socket closed'))
      this.resolveClosed()
    })
    socket.addEventListener('error', () => {
      debugCDP('socket error')
      this.rejectAll(new Error('CDP socket error'))
    })
  }

  /**
   * Connects to a CDP WebSocket and resolves only after the socket is open.
   */
  static connect(url: string, opts: { headers?: Record<string, string>; timeoutMs?: number } = {}): Promise<CDPClient> {
    return new Promise((resolveConnect, rejectConnect) => {
      const socket = opts.headers ? new WebSocket(url, { headers: opts.headers } as never) : new WebSocket(url)
      const timeout = setTimeout(() => {
        socket.close()
        rejectConnect(new Error('Timed out connecting to browser CDP'))
      }, opts.timeoutMs ?? DEFAULT_CDP_CONNECT_TIMEOUT_MS)

      socket.addEventListener(
        'open',
        () => {
          clearTimeout(timeout)
          resolveConnect(new CDPClient(socket))
        },
        { once: true }
      )
      socket.addEventListener(
        'error',
        () => {
          clearTimeout(timeout)
          rejectConnect(new Error('Failed to connect to browser CDP'))
        },
        { once: true }
      )
    })
  }

  /**
   * Sends one CDP command and waits for the matching response id.
   */
  send<T>(
    method: string,
    params: JSONObject = {},
    sessionID?: string,
    timeoutMs = DEFAULT_BROWSER_COMMAND_TIMEOUT_MS
  ): Promise<T> {
    if (this.socket.readyState !== WebSocket.OPEN) throw new Error('CDP socket is not open')

    const id = this.nextID++
    const message: JSONObject = { id, method, params }
    if (sessionID) message['sessionId'] = sessionID
    debugCDP(`send id=${id} method=${method} session=${sessionID ?? '-'}`)

    const promise = new Promise<T>((resolveSend, rejectSend) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id)
        rejectSend(new Error(`CDP command timed out: ${method}`))
      }, timeoutMs)
      this.pending.set(id, {
        resolve: value => resolveSend(value as T),
        reject: rejectSend,
        timeout
      })
    })

    this.socket.send(JSON.stringify(message))
    return promise
  }

  /**
   * Closes the underlying WebSocket if it is still open or connecting.
   */
  close(): void {
    if (this.socket.readyState === WebSocket.OPEN || this.socket.readyState === WebSocket.CONNECTING) {
      this.socket.close()
    }
  }

  /**
   * Reports whether the WebSocket is currently open.
   */
  isOpen(): boolean {
    return this.socket.readyState === WebSocket.OPEN
  }

  /**
   * Subscribes to CDP events, optionally scoped to an attached target session.
   */
  on(method: string, sessionID: string | undefined, listener: (params: JSONObject) => void): () => void {
    const key = eventListenerKey(method, sessionID)
    let listeners = this.eventListeners.get(key)
    if (!listeners) {
      listeners = new Set()
      this.eventListeners.set(key, listeners)
    }
    listeners.add(listener)
    return () => {
      const current = this.eventListeners.get(key)
      if (!current) return
      current.delete(listener)
      if (current.size === 0) this.eventListeners.delete(key)
    }
  }

  /**
   * Routes an incoming CDP message to either a pending command or event
   * listeners.
   */
  private handleMessage(data: unknown): void {
    const text = typeof data === 'string' ? data : Buffer.from(data as ArrayBuffer).toString('utf8')
    const message = JSON.parse(text) as {
      id?: number
      method?: string
      params?: JSONObject
      sessionID?: string
      result?: unknown
      error?: { message?: string; data?: string }
    }
    if (message.id === undefined) {
      if (message.method) this.emitEvent(message.method, message.sessionID, message.params ?? {})
      return
    }

    const pending = this.pending.get(message.id)
    if (!pending) return
    this.pending.delete(message.id)
    clearTimeout(pending.timeout)

    if (message.error) {
      pending.reject(new Error([message.error.message, message.error.data].filter(Boolean).join(': ')))
    } else {
      debugCDP(`recv id=${message.id}`)
      pending.resolve(message.result)
    }
  }

  /**
   * Rejects all pending commands after the socket closes or errors.
   */
  private rejectAll(error: Error): void {
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timeout)
      pending.reject(error)
      this.pending.delete(id)
    }
  }

  /**
   * Emits an event to both session-specific listeners and wildcard listeners.
   */
  private emitEvent(method: string, sessionID: string | undefined, params: JSONObject): void {
    for (const key of [eventListenerKey(method, sessionID), eventListenerKey(method, undefined)]) {
      const listeners = this.eventListeners.get(key)
      if (!listeners) continue
      for (const listener of listeners) {
        try {
          listener(params)
        } catch {
          // Event listeners update local CDP bookkeeping only.
        }
      }
    }
  }
}

/**
 * Builds the listener map key for a CDP event and optional target session.
 */
function eventListenerKey(method: string, sessionID: string | undefined): string {
  return `${sessionID ?? '*'}:${method}`
}

/**
 * Writes CDP debug logs only when explicitly enabled.
 */
function debugCDP(message: string): void {
  if (process.env.ANKOLE_BROWSER_CDP_DEBUG !== '1') return
  process.stderr.write(`[browser-cdp] ${message}\n`)
}
