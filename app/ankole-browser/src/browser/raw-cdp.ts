type CDPResponse = {
  id?: number
  result?: Record<string, unknown>
  error?: { message?: string }
}

type PendingCall = {
  resolve: (value: Record<string, unknown>) => void
  reject: (error: Error) => void
  timer: ReturnType<typeof setTimeout>
}

/**
 * Clears native dialogs before Playwright attaches to a recovered local Chrome.
 * Playwright connection setup can itself wait on a pre-existing dialog, so this
 * probe deliberately uses only the browser's raw CDP WebSocket.
 */
export async function dismissOrphanDialogsBeforeAttach(endpoint: string): Promise<void> {
  const probe = new RawCDPProbe(endpoint)
  try {
    await probe.open()
    const targets = await probe.call('Target.getTargets')
    const targetInfos = Array.isArray(targets.targetInfos) ? targets.targetInfos : []
    for (const candidate of targetInfos) {
      if (!candidate || typeof candidate !== 'object') continue
      const target = candidate as Record<string, unknown>
      if (target.type !== 'page' || typeof target.targetId !== 'string') continue
      let sessionId: string | undefined
      let responsive = false
      try {
        const attached = await probe.call('Target.attachToTarget', { targetId: target.targetId, flatten: true })
        sessionId = typeof attached.sessionId === 'string' ? attached.sessionId : undefined
        if (!sessionId) continue
        await probe.call('Page.handleJavaScriptDialog', { accept: false }, sessionId).catch(() => undefined)
        await probe.call('Input.dispatchMouseEvent', mouseRelease(), sessionId).catch(() => undefined)
        await probe.call('Page.getFrameTree', {}, sessionId)
        responsive = true
      } catch {
        // A Playwright action interrupted by daemon death can leave its page
        // target unable to answer Page/Runtime initialization commands even
        // after the native dialog is gone. Playwright would hang while
        // attaching to that target, so repair only the poisoned tab below.
      } finally {
        if (sessionId) {
          await probe.call('Target.detachFromTarget', { sessionId }).catch(() => undefined)
        }
      }
      if (!responsive) await probe.replaceUnresponsivePage(target)
    }
  } finally {
    probe.close()
  }
}

function mouseRelease(): Record<string, unknown> {
  return { type: 'mouseReleased', x: 0, y: 0, button: 'left', clickCount: 1 }
}

class RawCDPProbe {
  private socket?: WebSocket
  private nextID = 1
  private readonly pending = new Map<number, PendingCall>()

  constructor(readonly endpoint: string) {}

  async open(): Promise<void> {
    const socket = new WebSocket(this.endpoint)
    this.socket = socket
    socket.addEventListener('message', event => this.handleMessage(event.data))
    socket.addEventListener('close', () => this.rejectAll(new Error('raw CDP probe closed')))
    socket.addEventListener('error', () => this.rejectAll(new Error('raw CDP probe failed')))
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        socket.close()
        reject(new Error('raw CDP probe connection timed out'))
      }, 2_000)
      socket.addEventListener(
        'open',
        () => {
          clearTimeout(timer)
          resolve()
        },
        { once: true }
      )
      socket.addEventListener(
        'error',
        () => {
          clearTimeout(timer)
          reject(new Error('raw CDP probe connection failed'))
        },
        { once: true }
      )
    })
  }

  call(method: string, params: Record<string, unknown> = {}, sessionId?: string): Promise<Record<string, unknown>> {
    const socket = this.socket
    if (!socket || socket.readyState !== WebSocket.OPEN) return Promise.reject(new Error('raw CDP probe is not open'))
    const id = this.nextID++
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`raw CDP ${method} timed out`))
      }, 1_000)
      this.pending.set(id, { resolve, reject, timer })
      socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }))
    })
  }

  async replaceUnresponsivePage(target: Record<string, unknown>): Promise<void> {
    const targetId = target.targetId
    if (typeof targetId !== 'string') return
    const url = typeof target.url === 'string' && target.url.length > 0 ? target.url : 'about:blank'
    await this.call('Target.createTarget', { url })
    const closed = await this.call('Target.closeTarget', { targetId })
    if (closed.success !== true) throw new Error('failed to close unresponsive browser page')
    const deadline = Date.now() + 1_000
    while (Date.now() < deadline) {
      const current = await this.call('Target.getTargets')
      const targetInfos = Array.isArray(current.targetInfos) ? current.targetInfos : []
      if (!targetInfos.some(candidate => isTarget(candidate, targetId))) return
      await new Promise(resolve => setTimeout(resolve, 25))
    }
    throw new Error('unresponsive browser page did not close')
  }

  close(): void {
    this.socket?.close()
    this.socket = undefined
    this.rejectAll(new Error('raw CDP probe closed'))
  }

  private handleMessage(value: unknown): void {
    const text =
      typeof value === 'string' ? value : value instanceof ArrayBuffer ? Buffer.from(value).toString('utf8') : ''
    if (!text) return
    let response: CDPResponse
    try {
      response = JSON.parse(text) as CDPResponse
    } catch {
      return
    }
    if (typeof response.id !== 'number') return
    const pending = this.pending.get(response.id)
    if (!pending) return
    this.pending.delete(response.id)
    clearTimeout(pending.timer)
    if (response.error) pending.reject(new Error(response.error.message ?? 'raw CDP command failed'))
    else pending.resolve(response.result ?? {})
  }

  private rejectAll(error: Error): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer)
      pending.reject(error)
    }
    this.pending.clear()
  }
}

function isTarget(candidate: unknown, targetId: string): boolean {
  return Boolean(
    candidate && typeof candidate === 'object' && (candidate as Record<string, unknown>).targetId === targetId
  )
}
