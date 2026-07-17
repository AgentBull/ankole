import { BrowserDataError } from '../errors'

type Waiter = {
  resolve: (lease: ActiveBrowserLease) => void
  reject: (error: Error) => void
  deadline: number
  signal?: AbortSignal
  timer: ReturnType<typeof setTimeout>
  onAbort: () => void
}

type ActiveSlot = {
  released: boolean
  busy: boolean
  idleSince: number
  reclaim?: () => Promise<void>
  reclaiming: boolean
}

export type ActiveBrowserLease = {
  markBusy(): void
  markIdle(reclaim: () => Promise<void>): void
  release(): void
}

/** Bounds live physical browsers and reclaims warm idle sessions under pressure. */
export class ActiveBrowserLimiter {
  private closed = false
  private readonly slots = new Set<ActiveSlot>()
  private readonly waiters: Waiter[] = []

  constructor(readonly limit: number) {
    if (!Number.isInteger(limit) || limit < 1) throw new Error('active browser limit must be a positive integer')
  }

  acquire(deadline: number, signal?: AbortSignal): Promise<ActiveBrowserLease> {
    if (this.closed) return Promise.reject(new BrowserDataError('backend_unavailable', 'browser daemon is stopping'))
    if (signal?.aborted) return Promise.reject(cancelled())
    if (Date.now() >= deadline) return Promise.reject(timedOut())
    if (this.slots.size < this.limit) return Promise.resolve(this.createLease())

    return new Promise((resolve, reject) => {
      const waiter = {} as Waiter
      const remove = (error: Error): void => {
        const index = this.waiters.indexOf(waiter)
        if (index === -1) return
        this.waiters.splice(index, 1)
        clearTimeout(waiter.timer)
        signal?.removeEventListener('abort', waiter.onAbort)
        reject(error)
      }
      waiter.resolve = resolve
      waiter.reject = reject
      waiter.deadline = deadline
      waiter.signal = signal
      waiter.onAbort = () => remove(cancelled())
      waiter.timer = setTimeout(() => remove(timedOut()), Math.max(1, deadline - Date.now()))
      waiter.timer.unref()
      signal?.addEventListener('abort', waiter.onAbort, { once: true })
      this.waiters.push(waiter)
      this.reclaimOldestIdleSlot()
    })
  }

  close(): void {
    this.closed = true
    for (const waiter of this.waiters.splice(0)) {
      clearTimeout(waiter.timer)
      waiter.signal?.removeEventListener('abort', waiter.onAbort)
      waiter.reject(new BrowserDataError('backend_unavailable', 'browser daemon is stopping'))
    }
  }

  private createLease(): ActiveBrowserLease {
    const slot: ActiveSlot = {
      released: false,
      busy: true,
      idleSince: 0,
      reclaiming: false
    }
    this.slots.add(slot)
    return {
      markBusy: () => {
        if (slot.released) return
        slot.busy = true
        slot.reclaim = undefined
      },
      markIdle: reclaim => {
        if (slot.released) return
        slot.busy = false
        slot.idleSince = Date.now()
        slot.reclaim = reclaim
        this.reclaimOldestIdleSlot()
      },
      release: () => {
        if (slot.released) return
        slot.released = true
        slot.reclaim = undefined
        this.slots.delete(slot)
        this.drain()
      }
    }
  }

  private reclaimOldestIdleSlot(): void {
    if (this.closed || this.waiters.length === 0) return
    const candidate = [...this.slots]
      .filter(slot => !slot.busy && !slot.reclaiming && slot.reclaim)
      .sort((left, right) => left.idleSince - right.idleSince)[0]
    if (!candidate?.reclaim) return
    const reclaim = candidate.reclaim
    candidate.reclaiming = true
    void reclaim()
      .catch(() => undefined)
      .finally(() => {
        if (this.slots.has(candidate)) candidate.reclaiming = false
        this.drain(false)
      })
  }

  private drain(reclaimIdle = true): void {
    while (!this.closed && this.slots.size < this.limit && this.waiters.length > 0) {
      const waiter = this.waiters.shift()!
      clearTimeout(waiter.timer)
      waiter.signal?.removeEventListener('abort', waiter.onAbort)
      if (waiter.signal?.aborted) {
        waiter.reject(cancelled())
        continue
      }
      if (Date.now() >= waiter.deadline) {
        waiter.reject(timedOut())
        continue
      }
      waiter.resolve(this.createLease())
    }
    if (reclaimIdle && this.waiters.length > 0) this.reclaimOldestIdleSlot()
  }
}

function timedOut(): BrowserDataError {
  return new BrowserDataError('timeout', 'timed out waiting for an active browser slot', { retryable: true })
}

function cancelled(): BrowserDataError {
  return new BrowserDataError('cancelled', 'cancelled while waiting for an active browser slot', { retryable: true })
}
