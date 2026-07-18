import { rm } from 'node:fs/promises'
import { join } from 'node:path'
import type { BrowserContext } from 'playwright-core'
import { BrowserDataError, browserError } from '../errors'
import type { BrowserCommand, BrowserMaterial, BrowserPageCommand, BrowserRequest } from '../protocol'
import { BrowserSession } from '../browser/browser-session'
import { PhysicalBrowser } from '../browser/backend'
import type { ActiveBrowserLease, ActiveBrowserLimiter } from './active-browser-limiter'

type BrowserCommandOf<Name extends BrowserCommand['name']> = Extract<BrowserCommand, { name: Name }>

const LeaseCompatibleCommands: ReadonlySet<BrowserCommand['name']> = new Set([
  'status',
  'lease.delegate',
  'lease.release'
])

export type ActorResult = {
  data?: unknown
  warnings?: string[]
}

type Lease = {
  token: string
  runId: string
  phase: 'preparing' | 'delegated'
  expiresAt: number
  baseline: ReadonlySet<BrowserContext>
  timer: ReturnType<typeof setTimeout>
}

export class SessionActor {
  private mailbox: Promise<void> = Promise.resolve()
  private material?: BrowserMaterial
  private materialJSON?: string
  private browserSession?: BrowserSession
  private lease?: Lease
  private lastReleasedToken?: string
  private idleTimer?: ReturnType<typeof setTimeout>
  private remoteLost = false
  private activeBrowserLease?: ActiveBrowserLease
  private pendingDispatches = 0
  private purged = false

  constructor(
    readonly route: string,
    readonly session: string,
    private readonly activeBrowsers: ActiveBrowserLimiter,
    private readonly onDisposable?: (actor: SessionActor) => void
  ) {}

  dispatch(request: BrowserRequest, signal?: AbortSignal): Promise<ActorResult> {
    this.pendingDispatches += 1
    this.clearIdleTimer()
    this.activeBrowserLease?.markBusy()
    const result = this.enqueue(async () => {
      signal?.throwIfAborted()
      this.assertBeforeDeadline(request.deadline_unix_ms)
      await this.acceptMaterial(request.material)
      const result = await this.handle(request.command, request.deadline_unix_ms, signal)
      return result
    })
    return result.finally(() => {
      this.pendingDispatches -= 1
      if (this.pendingDispatches === 0) {
        const lease = this.activeBrowserLease
        if (lease && this.browserSession && !this.lease) {
          lease.markIdle(() => this.reclaimIdleBrowser(lease))
        }
        this.scheduleIdleClose()
        if (this.purged) this.onDisposable?.(this)
      }
    })
  }

  close(): Promise<void> {
    this.activeBrowserLease?.markBusy()
    return this.enqueue(async () => {
      this.clearIdleTimer()
      await this.releaseLease('daemon_shutdown')
      await this.closeLive(false)
      return undefined
    })
  }

  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.mailbox.then(operation)
    this.mailbox = result.then(
      () => undefined,
      () => undefined
    )
    return result
  }

  private async handle(command: BrowserCommand, deadline: number, signal?: AbortSignal): Promise<ActorResult> {
    if (this.lease && !LeaseCompatibleCommands.has(command.name)) {
      throw new BrowserDataError('session_busy', 'browser session has an active code lease', {
        retryable: true,
        details: { state: this.state(), expires_at: this.lease.expiresAt }
      })
    }

    switch (command.name) {
      case 'status':
        return { data: this.status() }
      case 'close':
        await this.closeLive(false)
        this.remoteLost = false
        return { data: { closed: true, data_retained: true } }
      case 'lifecycle':
        return await this.lifecycle(command)
      case 'batch':
        return await this.batch(command, deadline, signal)
      case 'lease.acquire':
        return await this.acquireLease(command, deadline)
      case 'lease.delegate':
        return await this.delegateLease(command)
      case 'lease.release':
        return await this.releaseLeaseCommand(command)
      default: {
        const browserSession = await this.attached(deadline, signal)
        signal?.throwIfAborted()
        this.assertBeforeDeadline(deadline)
        try {
          const data = await this.executeWithinDeadline(browserSession, command, deadline, signal)
          return { data, warnings: browserSession.warnings() }
        } catch (error) {
          if (error instanceof BrowserDataError && error.code === 'session_lost') {
            this.remoteLost = this.material?.backend.kind !== 'local_chromium'
            await this.closeLive(false)
          }
          throw error
        }
      }
    }
  }

  private async batch(
    command: BrowserCommandOf<'batch'>,
    deadline: number,
    signal?: AbortSignal
  ): Promise<ActorResult> {
    const bail = command.args.bail === true
    const browserSession = await this.attached(deadline, signal)
    const results: Array<Record<string, unknown>> = []
    const warnings: string[] = []

    for (const item of command.args.commands) {
      signal?.throwIfAborted()
      this.assertBeforeDeadline(deadline)
      try {
        const data =
          item.name === 'status'
            ? this.status()
            : await this.executeWithinDeadline(browserSession, item, deadline, signal)
        results.push({ ok: true, data })
        warnings.push(...browserSession.warnings())
      } catch (error) {
        results.push({ ok: false, error: browserError(error) })
        warnings.push(...browserSession.warnings())
        if (error instanceof BrowserDataError && error.code === 'session_lost') {
          this.remoteLost = this.material?.backend.kind !== 'local_chromium'
          await this.closeLive(false)
          break
        }
        if (
          bail ||
          (error instanceof BrowserDataError && ['timeout', 'cancelled'].includes(error.code)) ||
          (error instanceof DOMException && error.name === 'AbortError')
        ) {
          break
        }
      }
    }
    return { data: { results }, warnings }
  }

  private async acquireLease(command: BrowserCommandOf<'lease.acquire'>, deadline: number): Promise<ActorResult> {
    if (this.lease) throw new BrowserDataError('session_busy', 'browser session already has a code lease')
    const runId = command.args.run_id
    const browserSession = await this.attached(deadline)
    if (browserSession.guard.hasPending()) {
      throw new BrowserDataError('dialog_blocked', 'cannot start browser code while a dialog is pending', {
        details: browserSession.guard.status()
      })
    }
    const baseline = new Set(browserSession.contexts())
    const contextOrdinal = browserSession.defaultContextOrdinal()
    const pageOrdinal = browserSession.activePageOrdinal()
    if (contextOrdinal < 0 || pageOrdinal < 0) {
      throw new BrowserDataError('session_lost', 'persistent browser context or active page is unavailable')
    }
    const endpoint = await browserSession.bind(`ankole-browser-${runId}`)
    const token = `lease_${crypto.randomUUID()}`
    const expiresAt = Math.max(Date.now() + 1_000, deadline + 2_000)
    const timer = setTimeout(
      () => {
        void this.enqueue(async () => {
          if (this.lease?.token === token) await this.releaseLease('expired')
        }).catch(() => undefined)
      },
      Math.max(1, expiresAt - Date.now())
    )
    timer.unref()
    this.lease = { token, runId, phase: 'preparing', expiresAt, baseline, timer }
    this.clearIdleTimer()
    return {
      data: {
        lease_token: token,
        endpoint,
        context_ordinal: contextOrdinal,
        page_ordinal: pageOrdinal,
        expires_at: expiresAt
      }
    }
  }

  private async delegateLease(command: BrowserCommandOf<'lease.delegate'>): Promise<ActorResult> {
    const token = command.args.lease_token
    const lease = this.requireLease(token)
    if (lease.phase !== 'preparing') {
      throw new BrowserDataError('session_busy', 'browser code lease is not waiting for delegation')
    }
    const browserSession = this.browserSession
    if (!browserSession) throw new BrowserDataError('session_lost', 'browser session disconnected before delegation')
    browserSession.delegateDialogs()
    lease.phase = 'delegated'
    return { data: { delegated: true, expires_at: lease.expiresAt } }
  }

  private async releaseLeaseCommand(command: BrowserCommandOf<'lease.release'>): Promise<ActorResult> {
    const token = command.args.lease_token
    if (!this.lease && token === this.lastReleasedToken) return { data: { released: true, already_released: true } }
    this.requireLease(token)
    await this.releaseLease(command.args.outcome ?? 'unknown')
    return { data: { released: true, already_released: false } }
  }

  private async releaseLease(_outcome: string): Promise<void> {
    const lease = this.lease
    if (!lease) return
    clearTimeout(lease.timer)
    this.lease = undefined
    this.lastReleasedToken = lease.token
    if (!this.browserSession) return
    try {
      await this.browserSession.reconcileAfterLease(lease.baseline)
    } catch (error) {
      this.remoteLost = this.material?.backend.kind !== 'local_chromium'
      await this.closeLive(false)
      if (error instanceof BrowserDataError && error.code === 'session_lost') return
      throw error
    }
  }

  private requireLease(token: string): Lease {
    const lease = this.lease
    if (!lease || lease.token !== token) {
      throw new BrowserDataError('session_busy', 'browser code lease token or state does not match')
    }
    return lease
  }

  private async lifecycle(command: BrowserCommandOf<'lifecycle'>): Promise<ActorResult> {
    if (this.lease) throw new BrowserDataError('session_busy', 'cannot change lifecycle during a code lease')
    const material = this.requireMaterial()
    if (command.args.verb === 'reset') {
      await this.closeLive(true)
      await rm(join(material.data_root, 'sessions', this.session), { recursive: true, force: true })
      this.remoteLost = false
      return { data: { reset: true } }
    }
    await this.closeLive(true)
    await rm(material.data_root, { recursive: true, force: true })
    this.material = undefined
    this.materialJSON = undefined
    this.remoteLost = false
    this.purged = true
    return { data: { purged: true } }
  }

  private async acceptMaterial(incoming: BrowserMaterial): Promise<void> {
    if (incoming.route_id !== this.route) {
      throw new BrowserDataError('invalid_material', 'request route does not match material route_id')
    }
    if (!this.material) {
      this.material = incoming
      this.materialJSON = JSON.stringify(incoming)
      this.purged = false
      return
    }
    if (
      incoming.immutable_fingerprint !== this.material.immutable_fingerprint ||
      incoming.data_root !== this.material.data_root
    ) {
      throw new BrowserDataError('session_spec_conflict', 'route immutable browser material changed')
    }
    if (incoming.material_generation < this.material.material_generation) {
      throw new BrowserDataError('invalid_material', 'browser material generation moved backwards')
    }
    if (incoming.material_generation === this.material.material_generation) {
      if (JSON.stringify(incoming) !== this.materialJSON) {
        throw new BrowserDataError('invalid_material', 'browser material changed without a generation increase')
      }
      return
    }
    if (this.lease) {
      throw new BrowserDataError('session_busy', 'cannot refresh browser material during a code lease', {
        retryable: true
      })
    }
    await this.closeLive(false)
    this.material = incoming
    this.materialJSON = JSON.stringify(incoming)
    this.remoteLost = false
  }

  private async attached(deadline: number, signal?: AbortSignal): Promise<BrowserSession> {
    if (this.remoteLost) {
      throw new BrowserDataError('session_lost', 'remote browser session was lost; reset or refresh material')
    }
    if (this.browserSession?.physical.isConnected()) return this.browserSession
    if (this.browserSession) {
      this.remoteLost = this.material?.backend.kind !== 'local_chromium'
      await this.closeLive(false)
      if (this.remoteLost) throw new BrowserDataError('session_lost', 'remote browser session disconnected')
    }
    const release = await this.activeBrowsers.acquire(deadline, signal)
    this.activeBrowserLease = release
    try {
      this.browserSession = await BrowserSession.create(this.requireMaterial(), this.session)
      return this.browserSession
    } catch (error) {
      this.activeBrowserLease = undefined
      release.release()
      if (this.material?.backend.kind !== 'local_chromium') this.remoteLost = true
      throw error
    }
  }

  private async executeWithinDeadline(
    browserSession: BrowserSession,
    command: BrowserPageCommand,
    deadline: number,
    signal?: AbortSignal
  ): Promise<unknown> {
    signal?.throwIfAborted()
    this.assertBeforeDeadline(deadline)
    const operation = browserSession.execute(command, deadline)
    let timer: ReturnType<typeof setTimeout> | undefined
    let onAbort: (() => void) | undefined
    try {
      return await Promise.race([
        operation,
        new Promise<never>((_, reject) => {
          timer = setTimeout(
            () => reject(new BrowserDataError('timeout', 'browser command deadline expired', { retryable: true })),
            Math.max(1, deadline - Date.now())
          )
          timer.unref()
          if (signal) {
            onAbort = () => reject(signal.reason ?? new DOMException('cancelled', 'AbortError'))
            signal.addEventListener('abort', onAbort, { once: true })
          }
        })
      ])
    } catch (error) {
      if (
        (error instanceof BrowserDataError && error.code === 'timeout') ||
        (error instanceof DOMException && error.name === 'AbortError')
      ) {
        operation.catch(() => undefined)
        await this.closeLive(false)
      }
      throw error
    } finally {
      if (timer) clearTimeout(timer)
      if (signal && onAbort) signal.removeEventListener('abort', onAbort)
    }
  }

  private async closeLive(purge: boolean): Promise<void> {
    this.clearIdleTimer()
    const browserSession = this.browserSession
    this.browserSession = undefined
    const lease = this.activeBrowserLease
    this.activeBrowserLease = undefined
    try {
      if (browserSession) {
        if (purge) await browserSession.purge()
        else await browserSession.close()
      } else if (purge && this.material) {
        await PhysicalBrowser.purgeDetached(this.material, this.session)
      }
    } finally {
      lease?.release()
    }
  }

  private async reclaimIdleBrowser(lease: ActiveBrowserLease): Promise<void> {
    await this.enqueue(async () => {
      if (this.pendingDispatches > 0 || this.lease || this.activeBrowserLease !== lease) {
        this.activeBrowserLease?.markBusy()
        return
      }
      await this.closeLive(false)
    })
  }

  private status(): Record<string, unknown> {
    return {
      state: this.state(),
      material_generation: this.material?.material_generation,
      lease: this.lease
        ? { phase: this.lease.phase, run_id: this.lease.runId, expires_at: this.lease.expiresAt }
        : undefined,
      browser: this.browserSession?.status()
    }
  }

  private state(): string {
    if (this.lease) return this.lease.phase === 'preparing' ? 'lease_preparing' : 'lease_delegated'
    if (this.remoteLost) return 'session_lost'
    if (!this.browserSession?.physical.isConnected()) return 'detached'
    if (this.browserSession.guard.hasPending()) return 'dialog_pending'
    return 'ready'
  }

  private scheduleIdleClose(): void {
    this.clearIdleTimer()
    if (this.lease || !this.browserSession) return
    const timer = setTimeout(() => {
      void this.enqueue(async () => {
        if (this.pendingDispatches === 0 && !this.lease) await this.closeLive(false)
      }).catch(() => undefined)
    }, this.requireMaterial().idle_ttl_ms)
    timer.unref()
    this.idleTimer = timer
  }

  private clearIdleTimer(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer)
    this.idleTimer = undefined
  }

  private assertBeforeDeadline(deadline: number): void {
    if (Date.now() >= deadline) {
      throw new BrowserDataError('timeout', 'browser request deadline expired', { retryable: true })
    }
  }

  private requireMaterial(): BrowserMaterial {
    if (!this.material) throw new BrowserDataError('invalid_material', 'browser material is unavailable')
    return this.material
  }
}
