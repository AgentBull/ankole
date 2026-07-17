#!/usr/bin/env node
import { appendFile, mkdir, open, rename } from 'node:fs/promises'
import { dirname, isAbsolute, relative, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { chromium, type Browser, type BrowserContext, type Dialog, type Page } from 'playwright-core'

type ScriptInput = {
  page: Page
  context: BrowserContext
  browser: Browser
  args: string[]
  runDir: string
  log: (value: unknown) => Promise<void>
  screenshot: (name?: string, options?: { fullPage?: boolean }) => Promise<string>
  signal: AbortSignal
}

type ScriptModule = {
  default?: (input: ScriptInput) => unknown | Promise<unknown>
  dialogPolicy?: (dialog: Dialog) => unknown | Promise<unknown>
}

const endpoint = requiredEnv('ANKOLE_BROWSER_BOUND_ENDPOINT')
const runId = requiredEnv('ANKOLE_BROWSER_RUN_ID')
const runDir = requiredEnv('ANKOLE_BROWSER_RUN_DIR')
const scriptPath = requiredEnv('ANKOLE_BROWSER_SCRIPT')
const contextOrdinal = integerEnv('ANKOLE_BROWSER_CONTEXT_ORDINAL')
const pageOrdinal = integerEnv('ANKOLE_BROWSER_PAGE_ORDINAL')
const args = JSON.parse(process.env.ANKOLE_BROWSER_SCRIPT_ARGS ?? '[]') as string[]
const controller = new AbortController()
const startedAt = new Date().toISOString()
let browser: Browser | undefined
let baseline: ReadonlySet<BrowserContext> = new Set()
let status: 'ok' | 'error' | 'cancelled' = 'error'
let value: unknown = null
let failure: Record<string, unknown> | null = null

process.on('disconnect', () => controller.abort(new DOMException('runner parent disconnected', 'AbortError')))
process.on('message', message => {
  if (message && typeof message === 'object' && (message as { type?: unknown }).type === 'runner.abort') {
    controller.abort(new DOMException(String((message as { reason?: unknown }).reason ?? 'cancelled'), 'AbortError'))
  }
})

try {
  const module = (await import(`${pathToFileURL(scriptPath).href}?run=${encodeURIComponent(runId)}`)) as ScriptModule
  if (typeof module.default !== 'function') throw new Error('browser script must export a default function')
  browser = await chromium.connect(endpoint)
  baseline = new Set(browser.contexts())
  const context = browser.contexts()[contextOrdinal]
  if (!context) throw new Error(`browser context ordinal ${contextOrdinal} is unavailable`)
  let page = context.pages()[pageOrdinal]
  if (!page) page = await context.newPage()
  const dialogs = installDialogPolicy(context, module.dialogPolicy, controller)
  process.send?.({ type: 'runner.ready' })
  await waitForStart(controller.signal)
  value = await module.default({
    page,
    context,
    browser,
    args,
    runDir,
    log: async entry => appendFile(resolve(runDir, 'actions.jsonl'), `${safeJSONString(entry)}\n`, { mode: 0o600 }),
    screenshot: async (name = `screenshot-${Date.now()}.png`, options = {}) => {
      const path = insideRunDir(runDir, name)
      await mkdir(dirname(path), { recursive: true })
      await page.screenshot({ path, fullPage: options.fullPage })
      return path
    },
    signal: controller.signal
  })
  await dialogs.settle()
  controller.signal.throwIfAborted()
  value = normalizeJSON(value)
  status = 'ok'
} catch (error) {
  status = controller.signal.aborted ? 'cancelled' : 'error'
  failure = serializeError(error, endpoint)
} finally {
  if (browser) {
    for (const context of browser.contexts()) {
      if (!baseline.has(context)) await context.close().catch(() => undefined)
    }
    await browser.close().catch(() => undefined)
  }
  await atomicJSON(resolve(runDir, 'result.json'), {
    run_id: runId,
    status,
    value: status === 'ok' ? value : null,
    error: failure,
    started_at: startedAt,
    completed_at: new Date().toISOString()
  }).catch(() => undefined)
  process.send?.({ type: 'runner.done' })
  process.disconnect?.()
}

function installDialogPolicy(
  context: BrowserContext,
  customPolicy: ScriptModule['dialogPolicy'],
  controller: AbortController
): { settle: () => Promise<void> } {
  const installed = new WeakSet<Page>()
  const pending = new Set<Promise<void>>()
  const install = (page: Page): void => {
    if (installed.has(page)) return
    installed.add(page)
    page.on('dialog', dialog => {
      const operation = handleDialog(dialog, customPolicy).catch(async error => {
        await dialog.dismiss().catch(() => undefined)
        controller.abort(error)
      })
      pending.add(operation)
      void operation.finally(() => pending.delete(operation))
    })
  }
  for (const page of context.pages()) install(page)
  context.on('page', install)
  return {
    settle: async () => {
      await Promise.allSettled([...pending])
      controller.signal.throwIfAborted()
    }
  }
}

async function handleDialog(dialog: Dialog, customPolicy: ScriptModule['dialogPolicy']): Promise<void> {
  if (!customPolicy) {
    if (dialog.type() === 'alert' || dialog.type() === 'beforeunload') await dialog.accept()
    else await dialog.dismiss()
    return
  }
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    await Promise.race([
      Promise.resolve(customPolicy(dialog)),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error('dialogPolicy timed out')), 2_000)
      })
    ])
    // A custom policy that resolves without handling the dialog must not leave
    // the renderer blocked. Dismiss is a no-op error after a successful accept
    // or dismiss, and is the bounded fallback otherwise.
    await dialog.dismiss().catch(() => undefined)
  } finally {
    if (timer) clearTimeout(timer)
  }
}

async function waitForStart(signal: AbortSignal): Promise<void> {
  signal.throwIfAborted()
  await new Promise<void>((resolveStart, reject) => {
    const onMessage = (message: unknown): void => {
      if (message && typeof message === 'object' && (message as { type?: unknown }).type === 'runner.start')
        finish(resolveStart)
    }
    const onAbort = (): void => finish(() => reject(signal.reason))
    const onDisconnect = (): void => finish(() => reject(new Error('runner parent disconnected before start')))
    const finish = (callback: () => void): void => {
      process.removeListener('message', onMessage)
      process.removeListener('disconnect', onDisconnect)
      signal.removeEventListener('abort', onAbort)
      callback()
    }
    process.on('message', onMessage)
    process.once('disconnect', onDisconnect)
    signal.addEventListener('abort', onAbort, { once: true })
  })
}

function normalizeJSON(value: unknown): unknown {
  if (value === undefined) return null
  const encoded = JSON.stringify(value)
  if (encoded === undefined) throw new Error('browser script result is not JSON serializable')
  return JSON.parse(encoded) as unknown
}

function safeJSONString(value: unknown): string {
  try {
    return JSON.stringify(normalizeJSON(value))
  } catch {
    return JSON.stringify({ value: String(value) })
  }
}

function insideRunDir(root: string, value: string): string {
  const path = isAbsolute(value) ? resolve(value) : resolve(root, value)
  const child = relative(resolve(root), path)
  if (child === '..' || child.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`) || isAbsolute(child)) {
    throw new Error('artifact path must stay inside runDir')
  }
  return path
}

async function atomicJSON(path: string, value: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true })
  const temporary = `${path}.${crypto.randomUUID()}.tmp`
  const file = await open(temporary, 'w', 0o600)
  try {
    await file.writeFile(`${JSON.stringify(value, null, 2)}\n`)
  } finally {
    await file.close()
  }
  await rename(temporary, path)
}

function serializeError(error: unknown, boundEndpoint: string): Record<string, unknown> {
  const message = (error instanceof Error ? error.message : String(error)).replaceAll(boundEndpoint, '[bound-endpoint]')
  return { code: 'internal', message, details: {} }
}

function requiredEnv(key: string): string {
  const value = process.env[key]
  if (!value) throw new Error(`${key} is required`)
  return value
}

function integerEnv(key: string): number {
  const parsed = Number(requiredEnv(key))
  if (!Number.isInteger(parsed) || parsed < 0) throw new Error(`${key} must be a non-negative integer`)
  return parsed
}
