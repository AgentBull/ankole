import { randomUUID } from 'node:crypto'
import { copyFile, mkdir, open, rm, stat } from 'node:fs/promises'
import { basename, extname, isAbsolute, join, relative, resolve } from 'node:path'
import type { Browser, CDPSession, ConsoleMessage, Download, Page, Request, Response } from 'playwright-core'
import { BrowserDataError } from '../errors'
import { compileQueryFilter } from './query-filter'

const MaxConsoleEntries = 100
const MaxNetworkEntries = 120
const MaxDownloadEntries = 40
const MaxDiagnosticTextChars = 2_000
const MaxDiagnosticURLChars = 1_024

const ConsoleErrorTypes = new Set(['pageerror', 'error', 'warning', 'assert'])
const StaticResourceTypes = new Set(['image', 'media', 'font', 'stylesheet'])

const SensitiveParamPattern =
  /(?:^|[_.-])(?:token|access_token|refresh_token|id_token|api_key|apikey|key|secret|client_secret|password|passwd|pwd|auth|authorization|sig|signature|x-amz-signature|x-goog-signature|session|session_id|jwt|code)$/i

const URLInTextPattern = /(?:https?|wss?):\/\/[^\s"'<>]+/gi

export type DiagnosticConsoleEntry = {
  type: string
  text: string
  url: string
  ts: string
}

export type DiagnosticNetworkEntry = {
  method: string
  url: string
  resource_type: string
  status: number | null
  failed: boolean
  failure_text?: string
  ts: string
}

export type DiagnosticDownloadEntry = {
  filename: string
  path?: string
  url: string
  size_bytes?: number
  error?: string
  ts: string
}

export type RecordedDownload = DiagnosticDownloadEntry

export type DiagnosticsQuery = {
  all?: boolean
  include_static?: boolean
  url?: string
  clear?: boolean
}

class RingBuffer<T> {
  private readonly items: T[] = []

  constructor(private readonly capacity: number) {}

  push(item: T): void {
    if (this.items.length >= this.capacity) this.items.shift()
    this.items.push(item)
  }

  values(): T[] {
    return [...this.items]
  }

  clear(): void {
    this.items.length = 0
  }
}

export class DiagnosticsStore {
  private readonly consoleBuffer = new RingBuffer<DiagnosticConsoleEntry>(MaxConsoleEntries)
  private readonly networkBuffer = new RingBuffer<DiagnosticNetworkEntry>(MaxNetworkEntries)
  private readonly downloadBuffer = new RingBuffer<DiagnosticDownloadEntry>(MaxDownloadEntries)
  private readonly installedPages = new WeakSet<Page>()
  private readonly inflightDownloads = new Set<Promise<DiagnosticDownloadEntry>>()
  private readonly pendingCDPDownloads = new Map<string, (outcome: { error?: string }) => void>()
  private browserCDP?: CDPSession
  private actionDownloads: Promise<DiagnosticDownloadEntry>[] | undefined
  private resolveClosed!: () => void
  private readonly closed = new Promise<string>(resolveDone => {
    this.resolveClosed = () => resolveDone('browser session closed before download completed')
  })

  constructor(private readonly artifactRoot: string) {}

  async attachBrowser(browser: Browser, localStagingDir?: string): Promise<void> {
    if (!localStagingDir || typeof browser.newBrowserCDPSession !== 'function') return
    try {
      await mkdir(localStagingDir, { recursive: true })
      const cdp = await browser.newBrowserCDPSession()
      const emitter = cdp as unknown as {
        on(event: string, listener: (payload: Record<string, unknown>) => void): void
      }
      emitter.on('Browser.downloadWillBegin', payload => {
        const guid = typeof payload.guid === 'string' ? payload.guid : ''
        if (!guid) return
        const url = typeof payload.url === 'string' ? payload.url : ''
        const suggestedFilename = typeof payload.suggestedFilename === 'string' ? payload.suggestedFilename : 'download'
        const completed = new Promise<{ error?: string }>(resolveDone => {
          this.pendingCDPDownloads.set(guid, resolveDone)
        })
        const stagedPath = join(localStagingDir, guid)
        const task = this.archiveDownload({
          rawURL: url,
          suggestedFilename,
          awaitFailure: async () => (await completed).error,
          writeTo: targetPath => copyFile(stagedPath, targetPath),
          cleanup: () => rm(stagedPath, { force: true })
        })
        this.registerDownloadTask(task)
      })
      emitter.on('Browser.downloadProgress', payload => {
        const guid = typeof payload.guid === 'string' ? payload.guid : ''
        const state = typeof payload.state === 'string' ? payload.state : ''
        if (!guid || (state !== 'completed' && state !== 'canceled')) return
        const finish = this.pendingCDPDownloads.get(guid)
        if (!finish) return
        this.pendingCDPDownloads.delete(guid)
        finish(state === 'completed' ? {} : { error: 'download canceled' })
      })
      await cdp.send('Browser.setDownloadBehavior', {
        behavior: 'allowAndName',
        downloadPath: localStagingDir,
        eventsEnabled: true
      })
      this.browserCDP = cdp
    } catch {
      // Fall back to Playwright's page.on('download') when browser-level CDP download events are unavailable.
    }
  }

  async close(): Promise<void> {
    this.resolveClosed()
    for (const finish of this.pendingCDPDownloads.values()) {
      finish({ error: 'browser session closed before download completed' })
    }
    this.pendingCDPDownloads.clear()
    const cdp = this.browserCDP
    this.browserCDP = undefined
    if (cdp) await cdp.detach().catch(() => undefined)
    if (this.inflightDownloads.size > 0) {
      await Promise.allSettled(this.inflightDownloads)
    }
  }

  installPage(page: Page): void {
    if (this.installedPages.has(page)) return
    this.installedPages.add(page)

    page.on('pageerror', (error: Error) => {
      const message = error?.stack || error?.message || String(error)
      this.consoleBuffer.push({
        type: 'pageerror',
        text: truncateText(redactURLsInText(message), MaxDiagnosticTextChars),
        url: redactDiagnosticURL(safePageURL(page)),
        ts: new Date().toISOString()
      })
    })

    page.on('console', (message: ConsoleMessage) => {
      const rawText = message.text()
      // Chromium mirrors HTTP 4xx/5xx and blocked subresources into console errors ("Failed to load resource: ...");
      // networkBuffer already records those with structured status codes and static-asset filtering.
      if (/^Failed to load resource:/i.test(rawText)) return
      const locationURL = safeConsoleLocationURL(message) || safePageURL(page)
      this.consoleBuffer.push({
        type: message.type(),
        text: truncateText(redactURLsInText(rawText), MaxDiagnosticTextChars),
        url: redactDiagnosticURL(locationURL),
        ts: new Date().toISOString()
      })
    })

    page.on('response', (response: Response) => {
      const request = response.request()
      this.networkBuffer.push({
        method: request.method(),
        url: redactDiagnosticURL(response.url()),
        resource_type: request.resourceType(),
        status: response.status(),
        failed: false,
        ts: new Date().toISOString()
      })
    })

    page.on('requestfailed', (request: Request) => {
      const failureText = request.failure()?.errorText ?? 'request_failed'
      const resourceType = request.resourceType()
      // Ignore intentional subresource aborts produced by no-media / rendered_fallback routing.
      if (StaticResourceTypes.has(resourceType) && /ERR_BLOCKED_BY_CLIENT|aborted/i.test(failureText)) {
        return
      }
      this.networkBuffer.push({
        method: request.method(),
        url: redactDiagnosticURL(request.url()),
        resource_type: resourceType,
        status: null,
        failed: true,
        failure_text: truncateText(failureText, 300),
        ts: new Date().toISOString()
      })
    })

    page.on('download', (download: Download) => {
      // On local Chromium, Browser.downloadWillBegin handles GUID staging directly over CDP.
      if (this.browserCDP) return
      const task = this.archiveDownload({
        rawURL: download.url(),
        suggestedFilename: download.suggestedFilename(),
        awaitFailure: () => Promise.race([download.failure(), this.closed]),
        writeTo: targetPath => download.saveAs(targetPath)
      })
      this.registerDownloadTask(task)
    })
  }

  private registerDownloadTask(task: Promise<DiagnosticDownloadEntry>): void {
    this.inflightDownloads.add(task)
    this.actionDownloads?.push(task)
    void task.finally(() => {
      this.inflightDownloads.delete(task)
    })
  }

  async captureDownloadsDuring<T>(
    deadline: number,
    settleGraceMs: number,
    fn: () => Promise<T>
  ): Promise<{ result: T; downloads: RecordedDownload[] }> {
    const captured: Promise<DiagnosticDownloadEntry>[] = []
    this.actionDownloads = captured
    let result: T
    try {
      result = await fn()
      if (settleGraceMs > 0 && captured.length === 0) {
        // Give Chromium a brief window to receive attachment response headers triggered by click/submit.
        await Bun.sleep(Math.min(settleGraceMs, Math.max(0, deadline - Date.now())))
      }
    } finally {
      if (this.actionDownloads === captured) {
        this.actionDownloads = undefined
      }
    }

    if (captured.length === 0) {
      return { result, downloads: [] }
    }

    const waitBudget = Math.max(50, Math.min(2_500, deadline - Date.now()))
    const settled = await Promise.race([Promise.all(captured), Bun.sleep(waitBudget).then(() => null)])
    return { result, downloads: settled ?? [] }
  }

  async read(options: DiagnosticsQuery = {}, deadline = Date.now() + 5_000): Promise<Record<string, unknown>> {
    if (this.inflightDownloads.size > 0) {
      const waitBudget = Math.max(25, Math.min(1_000, deadline - Date.now()))
      await Promise.race([Promise.all(this.inflightDownloads), Bun.sleep(waitBudget)])
    }

    const all = options.all === true
    const includeStatic = options.include_static === true
    const urlMatcher = options.url ? compileQueryFilter(options.url) : undefined

    const consoleEntries = this.consoleBuffer.values().filter(entry => {
      if (!all && !ConsoleErrorTypes.has(entry.type)) return false
      if (urlMatcher && !urlMatcher(entry.url) && !urlMatcher(entry.text)) return false
      return true
    })

    const allDownloadURLs = new Set(this.downloadBuffer.values().map(entry => entry.url))
    const networkEntries = this.networkBuffer.values().filter(entry => {
      if (!includeStatic && StaticResourceTypes.has(entry.resource_type)) return false
      if (!all && entry.failed && /ERR_ABORTED/i.test(entry.failure_text ?? '') && allDownloadURLs.has(entry.url)) {
        return false
      }
      if (!all && !entry.failed && (entry.status === null || entry.status < 400)) return false
      if (urlMatcher && !urlMatcher(entry.url)) return false
      return true
    })

    const downloads = this.downloadBuffer.values().filter(entry => {
      if (urlMatcher && !urlMatcher(entry.url) && !urlMatcher(entry.filename)) return false
      return true
    })

    if (options.clear === true) {
      this.consoleBuffer.clear()
      this.networkBuffer.clear()
      this.downloadBuffer.clear()
    }

    return {
      mode: all ? 'all' : 'errors',
      console: consoleEntries,
      network: networkEntries,
      downloads,
      ...(options.clear === true ? { cleared: true } : {})
    }
  }

  private async archiveDownload(options: {
    rawURL: string
    suggestedFilename: string
    awaitFailure: () => Promise<string | null | undefined>
    writeTo: (targetPath: string) => Promise<void>
    cleanup?: () => Promise<void>
  }): Promise<DiagnosticDownloadEntry> {
    const ts = new Date().toISOString()
    const redactedURL = redactDiagnosticURL(options.rawURL)
    const filename = sanitizeDownloadFilename(options.suggestedFilename)
    const downloadsDir = resolve(this.artifactRoot, 'downloads')
    let reservedPath: string | undefined
    try {
      const failure = await options.awaitFailure()
      if (failure) {
        const failedEntry: DiagnosticDownloadEntry = { filename, url: redactedURL, error: failure, ts }
        this.downloadBuffer.push(failedEntry)
        return failedEntry
      }
      await mkdir(downloadsDir, { recursive: true })
      const targetPath = await reserveUniqueDownloadPath(this.artifactRoot, downloadsDir, filename)
      reservedPath = targetPath
      await options.writeTo(targetPath)
      const info = await stat(targetPath)
      const savedEntry: DiagnosticDownloadEntry = {
        filename: basename(targetPath),
        path: targetPath,
        url: redactedURL,
        size_bytes: info.size,
        ts
      }
      this.downloadBuffer.push(savedEntry)
      return savedEntry
    } catch (error) {
      if (reservedPath) await rm(reservedPath, { force: true }).catch(() => undefined)
      const failedEntry: DiagnosticDownloadEntry = {
        filename,
        url: redactedURL,
        error: error instanceof Error ? error.message : String(error),
        ts
      }
      this.downloadBuffer.push(failedEntry)
      return failedEntry
    } finally {
      await options.cleanup?.().catch(() => undefined)
    }
  }
}

export function redactDiagnosticURL(raw: string): string {
  if (!raw) return ''
  const trimmed = raw.trim()
  if (/^(?:data|blob|javascript):/i.test(trimmed)) {
    const prefix = trimmed.slice(0, trimmed.indexOf(':') + 1).toLowerCase()
    return `${prefix}[redacted]`
  }
  try {
    const parsed = new URL(trimmed)
    parsed.username = ''
    parsed.password = ''
    const sensitiveKeys: string[] = []
    for (const key of parsed.searchParams.keys()) {
      if (isSensitiveParamKey(key)) sensitiveKeys.push(key)
    }
    for (const key of sensitiveKeys) {
      parsed.searchParams.set(key, '[REDACTED]')
    }
    if (
      parsed.hash &&
      /(?:token|key|secret|password|passwd|pwd|code|session|session_id|sig|signature|jwt)=/i.test(
        splitCamelCaseKey(parsed.hash)
      )
    ) {
      parsed.hash = '#[REDACTED]'
    }
    // Keep readable `[REDACTED]` instead of `%5BREDACTED%5D` for operator/model clarity.
    const formatted = parsed.toString().replaceAll('%5BREDACTED%5D', '[REDACTED]')
    return truncateText(formatted, MaxDiagnosticURLChars)
  } catch {
    return truncateText(trimmed, MaxDiagnosticURLChars)
  }
}

function splitCamelCaseKey(key: string): string {
  return key.replace(/([a-z0-9])([A-Z])/g, '$1_$2').replace(/([A-Z]+)([A-Z][a-z])/g, '$1_$2')
}

function isSensitiveParamKey(key: string): boolean {
  return SensitiveParamPattern.test(splitCamelCaseKey(key))
}

function redactURLsInText(text: string): string {
  return text.replace(URLInTextPattern, match => redactDiagnosticURL(match))
}

function truncateText(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text
  return `${text.slice(0, maxChars)}…`
}

function safePageURL(page: Page): string {
  try {
    return page.url()
  } catch {
    return ''
  }
}

function safeConsoleLocationURL(message: ConsoleMessage): string {
  try {
    return message.location()?.url ?? ''
  } catch {
    return ''
  }
}

function sanitizeDownloadFilename(raw: string): string {
  const sanitized = Array.from(basename(raw || 'download'), ch => {
    const code = ch.charCodeAt(0)
    return code <= 0x1f || code === 0x7f || ch === '/' || ch === '\\' ? '_' : ch
  })
    .join('')
    .replace(/_+/g, '_')
    .replace(/^\.+/, '')
    .trim()
  return sanitized.slice(0, 180) || 'download'
}

export async function reserveUniqueDownloadPath(
  artifactRoot: string,
  downloadsDir: string,
  filename: string
): Promise<string> {
  const ext = extname(filename)
  const stem = ext ? filename.slice(0, -ext.length) : filename
  for (let suffix = 1; suffix <= 1_000; suffix++) {
    const candidateName = suffix === 1 ? filename : `${stem}-${suffix}${ext}`
    const candidatePath = join(downloadsDir, candidateName)
    assertInsideRoot(artifactRoot, candidatePath)
    try {
      const handle = await open(candidatePath, 'wx')
      await handle.close()
      return candidatePath
    } catch (error) {
      if ((error as NodeJS.ErrnoException)?.code === 'EEXIST') continue
      throw error
    }
  }
  const fallbackPath = join(downloadsDir, `${stem}-${randomUUID().slice(0, 8)}${ext}`)
  assertInsideRoot(artifactRoot, fallbackPath)
  const handle = await open(fallbackPath, 'wx')
  await handle.close()
  return fallbackPath
}

function assertInsideRoot(root: string, target: string): void {
  const child = relative(resolve(root), resolve(target))
  if (child === '..' || child.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`) || isAbsolute(child)) {
    throw new BrowserDataError('invalid_command', 'download path must stay inside browser artifact root')
  }
}
