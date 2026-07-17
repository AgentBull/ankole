import type { BrowserContext, Dialog, Page } from 'playwright-core'
import { BrowserDataError } from '../errors'

type PendingDialog = {
  dialog: Dialog
  page: Page
  action?: Promise<unknown>
}

type DialogWaiter = (pending: PendingDialog) => void

export class DialogGuard {
  private mode: 'active' | 'delegated' = 'active'
  private pending?: PendingDialog
  private automaticDepth = 0
  private readonly installed = new WeakSet<Page>()
  private readonly waiters = new Set<DialogWaiter>()
  private warnings: string[] = []

  install(page: Page): void {
    if (this.installed.has(page)) return
    this.installed.add(page)
    page.on('dialog', dialog => void this.onDialog(page, dialog))
    page.on('close', () => {
      if (this.pending?.page === page) this.pending = undefined
    })
  }

  hasPending(): boolean {
    return Boolean(this.pending)
  }

  status(): Record<string, unknown> {
    if (!this.pending) return { has_dialog: false, mode: this.mode }
    return {
      has_dialog: true,
      mode: this.mode,
      type: this.pending.dialog.type(),
      message: this.pending.dialog.message(),
      default_value: this.pending.dialog.defaultValue()
    }
  }

  takeWarnings(): string[] {
    const warnings = this.warnings
    this.warnings = []
    return warnings
  }

  assertRendererAvailable(command: string): void {
    if (!this.pending) return
    throw new BrowserDataError(
      'dialog_blocked',
      `${this.pending.dialog.type()} dialog is waiting for accept or dismiss`,
      {
        retryable: true,
        details: { command, ...this.status() }
      }
    )
  }

  async runPotentialDialogAction<T>(page: Page, action: () => Promise<T>): Promise<T> {
    this.assertRendererAvailable('action')
    let resolveDialog!: DialogWaiter
    const dialogOpened = new Promise<PendingDialog>(resolve => {
      resolveDialog = resolve
      this.waiters.add(resolveDialog)
    })
    const actionPromise = action()
    const outcome = await Promise.race([
      actionPromise.then(
        value => ({ kind: 'value' as const, value }),
        error => ({ kind: 'error' as const, error })
      ),
      dialogOpened.then(pending => ({ kind: 'dialog' as const, pending }))
    ])
    this.waiters.delete(resolveDialog)
    if (outcome.kind === 'value') return outcome.value
    if (outcome.kind === 'error') throw outcome.error
    if (outcome.pending.page !== page) {
      throw new BrowserDataError('dialog_blocked', 'a dialog opened in another page during the action', {
        retryable: true,
        details: this.status()
      })
    }
    outcome.pending.action = actionPromise
    throw new BrowserDataError(
      'dialog_blocked',
      `${outcome.pending.dialog.type()} dialog is waiting for accept or dismiss`,
      {
        retryable: true,
        details: this.status()
      }
    )
  }

  async handle(action: 'accept' | 'dismiss', text?: string): Promise<Record<string, unknown>> {
    const pending = this.pending
    if (!pending) return { handled: false }
    this.pending = undefined
    if (action === 'accept') await pending.dialog.accept(text)
    else await pending.dialog.dismiss()
    if (pending.action) {
      let completed = await settlesWithin(pending.action, 2_000)
      if (!completed) {
        await pending.page.mouse.up().catch(() => undefined)
        completed = await settlesWithin(pending.action, 500)
      }
      if (!completed) {
        throw new BrowserDataError('session_lost', 'browser action did not settle after the dialog was handled', {
          retryable: true
        })
      }
    }
    return { handled: true, accepted: action === 'accept' }
  }

  delegate(): void {
    if (this.pending) {
      throw new BrowserDataError('dialog_blocked', 'cannot delegate while a dialog is pending', {
        details: this.status()
      })
    }
    this.mode = 'delegated'
  }

  async resume(context: BrowserContext): Promise<void> {
    this.mode = 'active'
    this.pending = undefined
    await this.cleanupOrphans(context)
  }

  async cleanupOrphans(context: BrowserContext): Promise<void> {
    for (const page of context.pages()) {
      if (page.isClosed()) continue
      const session = await within(context.newCDPSession(page), 2_000).catch(() => undefined)
      if (!session) continue
      try {
        await within(session.send('Page.handleJavaScriptDialog', { accept: false }), 2_000)
      } catch {
        // Chrome reports an error when no dialog exists; that is the common path.
      } finally {
        await within(session.detach(), 1_000).catch(() => undefined)
      }
    }
  }

  async withAutomaticDialogs<T>(operation: () => Promise<T>): Promise<T> {
    this.automaticDepth += 1
    try {
      return await operation()
    } finally {
      this.automaticDepth -= 1
    }
  }

  private async onDialog(page: Page, dialog: Dialog): Promise<void> {
    if (this.mode === 'delegated') return
    const type = dialog.type()
    if (this.automaticDepth > 0) {
      if (type === 'alert' || type === 'beforeunload') await dialog.accept().catch(() => undefined)
      else await dialog.dismiss().catch(() => undefined)
      return
    }
    if (type === 'alert' || type === 'beforeunload') {
      await dialog.accept().catch(() => undefined)
      this.warnings.push(`auto-accepted ${type} dialog: ${dialog.message()}`)
      return
    }
    if (this.pending) {
      await dialog.dismiss().catch(() => undefined)
      this.warnings.push(`dismissed additional ${type} dialog while another dialog was pending`)
      return
    }
    const pending = { dialog, page }
    this.pending = pending
    for (const waiter of this.waiters) waiter(pending)
  }
}

async function settlesWithin(operation: Promise<unknown>, timeoutMs: number): Promise<boolean> {
  return await Promise.race([
    operation.then(
      () => true,
      () => true
    ),
    new Promise<false>(resolve => setTimeout(() => resolve(false), timeoutMs))
  ])
}

async function within<T>(operation: Promise<T>, timeoutMs: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      operation,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error('dialog cleanup timed out')), timeoutMs)
        timer.unref()
      })
    ])
  } finally {
    if (timer) clearTimeout(timer)
  }
}
