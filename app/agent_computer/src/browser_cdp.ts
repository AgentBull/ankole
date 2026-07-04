import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { isIP } from 'node:net'
import { createServer } from 'node:net'
import { dirname, normalize, resolve } from 'node:path'

type JsonObject = Record<string, unknown>

type BrowserBackend = 'chromium' | 'remote_cdp'
type BrowserAdapterKind = 'chromium' | 'cdp_endpoint' | 'cdp_session_request'
type RemoteSessionResponse = { type: 'text' } | { type: 'json'; path: string[] }

export interface BrowserSessionMeta {
  version: 1
  session: string
  backend: BrowserBackend
  adapter: BrowserAdapterKind
  local_sidecar_key?: string
  pid: number | null
  connect_url?: string
  connect_url_redacted?: string
  connect_url_source?: 'session' | 'config'
  browser_context_id?: string
  target_id?: string
  profile_dir?: string
  started_at_unix_ms: number
}

type RemoteBrowserCdpConfig =
  | {
      adapter: 'cdp_endpoint'
      endpoint_url: string
      headers?: Record<string, string>
      connect_timeout_ms?: number
    }
  | {
      adapter: 'cdp_session_request'
      request: {
        url: string
        method?: 'GET' | 'POST'
        headers?: Record<string, string>
        body?: JsonObject
        response?: RemoteSessionResponse
      }
      headers?: Record<string, string>
      connect_timeout_ms?: number
    }

export interface BrowserRuntimeOptions {
  remoteCdpConfig?: Record<string, unknown> | RemoteBrowserCdpConfig | null
  localBrowserIdleTtlMs?: number
}

interface BrowserConnection {
  backend: BrowserBackend
  adapter: BrowserAdapterKind
  connectUrl: string
  redactedConnectUrl: string
  headers?: Record<string, string>
}

interface BrowserRef {
  ref: string
  selector: string
  tag: string
  role: string
  name: string
  disabled: boolean
}

interface BrowserSnapshot {
  url: string
  title: string
  text: string
  elements: BrowserRef[]
}

interface BrowserFindMatch {
  line: number
  text: string
  before: string[]
  after: string[]
}

interface PageSession {
  targetId: string
  sessionId: string
  mainFrameId?: string
  mainContextId?: number
  domContentEventAtUnixMs?: number
  loadEventAtUnixMs?: number
  mainFrameStoppedLoadingAtUnixMs?: number
}

interface ActiveBrowserSession {
  cdp: CdpClient
  page: PageSession
  connectUrl: string
  headersKey: string
}

interface TargetInfo {
  targetId: string
  type: string
  url: string
  title?: string
  attached?: boolean
  browserContextId?: string
}

interface RuntimeEvaluateResult {
  result: {
    type: string
    value?: unknown
    description?: string
  }
  exceptionDetails?: {
    text?: string
    exception?: { description?: string }
  }
}

interface PageNavigateResult {
  frameId: string
  loaderId?: string
  errorText?: string
}

interface PageFrameTree {
  frameTree: {
    frame: { id: string }
    childFrames?: PageFrameTree['frameTree'][]
  }
}

interface RuntimeExecutionContextCreatedEvent {
  context: {
    id: number
    auxData?: {
      isDefault?: boolean
      type?: string
      frameId?: string
    }
  }
}

interface PageFrameNavigatedEvent {
  frame: { id: string }
}

const workspaceRoot = process.env.ANKOLE_WORKSPACE_ROOT || '/workspace'
const SNAPSHOT_TEXT_MAX = 6_000
const SNAPSHOT_ELEMENT_MAX = 200
const DEFAULT_WAIT_MS = 15_000
const DEFAULT_CDP_CONNECT_TIMEOUT_MS = 30_000
const REMOTE_CONFIG_ENV = 'ANKOLE_REMOTE_BROWSER_CDP_CONFIG_JSON'
const DEFAULT_LOCAL_BROWSER_IDLE_TTL_MS = 30 * 60_000
const LOCAL_BROWSER_READY_STABLE_MS = 750
const BROWSER_NAVIGATION_ATTEMPTS = 2
const LOCAL_CHROMIUM_SIDECAR_KEY = 'browser.chromium'
const LOCAL_CHROMIUM_USER_AGENT =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/150.0.4078.48'

interface LocalChromiumSidecar {
  key: string
  port: number
  proc: Bun.Subprocess<'ignore', 'pipe', 'pipe'>
  connectUrl: string
  cdpHttpUrl: string
  profileDir: string
  startedAtUnixMs: number
  lastUsedAtUnixMs: number
  idleTtlMs: number
  idleTimer?: ReturnType<typeof setTimeout>
}

const localChromiumSidecars = new Map<string, LocalChromiumSidecar>()
const activeBrowserSessions = new Map<string, ActiveBrowserSession>()
let localChromiumShutdownHooksInstalled = false

export function findChromium(): string | null {
  const candidates = [
    process.env.ANKOLE_CHROMIUM_PATH,
    'chromium',
    'chromium-browser',
    'google-chrome',
    'google-chrome-stable'
  ].filter((candidate): candidate is string => typeof candidate === 'string' && candidate.length > 0)

  for (const candidate of candidates) {
    const result = Bun.spawnSync(['bash', '-lc', `command -v ${JSON.stringify(candidate)}`], {
      stdout: 'pipe',
      stderr: 'pipe'
    })
    const stdout = Buffer.from(result.stdout).toString('utf8').trim()
    if (result.exitCode === 0 && stdout) return stdout
  }

  return null
}

export function remoteBrowserCdpConfigFromEnv(
  env: Record<string, string | undefined> = process.env
): RemoteBrowserCdpConfig | null {
  const raw = env[REMOTE_CONFIG_ENV]
  if (!raw || raw.trim() === '' || raw.trim() === 'null') return null

  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch (error) {
    throw new Error(`invalid ${REMOTE_CONFIG_ENV}: ${error instanceof Error ? error.message : String(error)}`)
  }

  return normalizeRemoteBrowserCdpConfig(parsed)
}

function remoteBrowserCdpConfigFromOptions(options?: BrowserRuntimeOptions): RemoteBrowserCdpConfig | null {
  if (options && 'remoteCdpConfig' in options) {
    const value = options.remoteCdpConfig
    if (value === null || value === undefined) return null
    return normalizeRemoteBrowserCdpConfig(value)
  }

  return remoteBrowserCdpConfigFromEnv()
}

export function browserDoctor(options?: BrowserRuntimeOptions): JsonObject {
  const remoteConfig = remoteBrowserCdpConfigFromOptions(options)
  if (remoteConfig) {
    return {
      ok: true,
      backend: 'remote_cdp',
      adapter: remoteConfig.adapter,
      remote_cdp_configured: true,
      remote_cdp_config: redactRemoteBrowserConfig(remoteConfig),
      local_browser_idle_ttl_ms: localBrowserIdleTtlMs(options)
    }
  }

  const chromium = findChromium()
  return {
    ok: Boolean(chromium),
    backend: 'chromium',
    adapter: 'chromium',
    chromium_path: chromium,
    remote_cdp_configured: false,
    local_browser_idle_ttl_ms: localBrowserIdleTtlMs(options)
  }
}

export async function launchBrowserSession(
  args: {
    session: string | undefined
    headless?: boolean
  },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  const session = sanitizeId(args.session || 'default')
  const ready = await startBrowserSession(session, options)
  process.stdout.write(`${JSON.stringify(ready)}\n`)
  await waitForTermination()
  await releaseBrowserSession({ session }, options)
  return { ...ready, ok: false, exit_code: 0 }
}

export async function ensureBrowserSession(
  args: { session: string | undefined },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  const session = sanitizeId(args.session || 'default')
  const status = await browserStatus({ session }, options)
  if (status.ok === true) return status
  return await startBrowserSession(session, options)
}

export async function releaseBrowserSession(
  args: { session: string | undefined },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  const session = sanitizeId(args.session || 'default')
  forgetActiveBrowserSession(session)

  const meta = readSessionMeta(session)
  let browserContextDisposed = false
  let browserContextDisposeError: string | undefined
  if (meta?.browser_context_id) {
    try {
      const connection = await resolveConnectionForSession(session, meta, options)
      const cdp = await CdpClient.connect(connection.connectUrl, {
        headers: connection.headers,
        timeoutMs: 5_000
      })
      try {
        await cdp.send('Target.disposeBrowserContext', { browserContextId: meta.browser_context_id }, undefined, 5_000)
        browserContextDisposed = true
      } finally {
        cdp.close()
      }
    } catch (error) {
      browserContextDisposeError = error instanceof Error ? error.message : String(error)
    }

    const { browser_context_id: _browserContextId, target_id: _targetId, ...updated } = readSessionMeta(session) ?? meta
    writeSessionMeta(session, updated)
  }

  return {
    ok: true,
    session,
    released: true,
    browser_context_disposed: browserContextDisposed,
    ...(browserContextDisposeError ? { browser_context_dispose_error: browserContextDisposeError } : {})
  }
}

async function startBrowserSession(session: string, options?: BrowserRuntimeOptions): Promise<JsonObject> {
  const remoteConfig = remoteBrowserCdpConfigFromOptions(options)

  const root = browserRoot(session)
  const profileDir = resolve(root, 'profile')
  mkdirSync(profileDir, { recursive: true })

  if (remoteConfig) {
    const connection = await resolveRemoteConnection(remoteConfig)
    const meta: BrowserSessionMeta = {
      version: 1,
      session,
      backend: 'remote_cdp',
      adapter: remoteConfig.adapter,
      pid: null,
      connect_url_redacted: connection.redactedConnectUrl,
      ...(remoteConfig.adapter === 'cdp_session_request' ? { connect_url: connection.connectUrl } : {}),
      connect_url_source: remoteConfig.adapter === 'cdp_session_request' ? 'session' : 'config',
      started_at_unix_ms: Date.now()
    }
    writeSessionMeta(session, meta)

    return {
      ok: true,
      backend: 'remote_cdp',
      adapter: remoteConfig.adapter,
      session,
      pid: null,
      connect_url: connection.redactedConnectUrl
    }
  }

  const sidecar = await ensureLocalChromiumSidecar(localSidecarKey(), localBrowserIdleTtlMs(options))
  const connectUrl = sidecar.connectUrl
  const context = await createLocalBrowserContext(connectUrl)

  const meta: BrowserSessionMeta = {
    version: 1,
    session,
    backend: 'chromium',
    adapter: 'chromium',
    local_sidecar_key: sidecar.key,
    pid: sidecar.proc.pid,
    connect_url: connectUrl,
    connect_url_redacted: redactUrl(connectUrl),
    connect_url_source: 'session',
    browser_context_id: context.browserContextId,
    target_id: context.targetId,
    profile_dir: toWorkspacePath(profileDir),
    started_at_unix_ms: Date.now()
  }
  writeSessionMeta(session, meta)

  const ready = {
    ok: true,
    backend: 'chromium',
    adapter: 'chromium',
    session,
    pid: sidecar.proc.pid,
    connect_url: redactUrl(connectUrl),
    browser_context_id: context.browserContextId,
    target_id: context.targetId,
    profile_dir: toWorkspacePath(profileDir)
  }

  return ready
}

async function createLocalBrowserContext(connectUrl: string): Promise<{
  browserContextId: string
  targetId: string
}> {
  const cdp = await CdpClient.connect(connectUrl, { timeoutMs: 5_000 })
  let browserContextId: string | undefined
  try {
    const context = await cdp.send<{ browserContextId: string }>('Target.createBrowserContext', {})
    browserContextId = context.browserContextId
    const target = await cdp.send<{ targetId: string }>('Target.createTarget', {
      url: 'about:blank',
      browserContextId
    })
    return { browserContextId, targetId: target.targetId }
  } catch (error) {
    if (browserContextId) {
      try {
        await cdp.send('Target.disposeBrowserContext', { browserContextId }, undefined, 5_000)
      } catch {
        // Best-effort cleanup for a partially created local context.
      }
    }
    throw error
  } finally {
    cdp.close()
  }
}

export async function browserStatus(
  args: { session: string | undefined },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  const session = sanitizeId(args.session || 'default')

  const meta = readSessionMeta(session)
  if (!meta) {
    const remoteConfig = remoteBrowserCdpConfigFromOptions(options)
    return {
      ok: false,
      backend: remoteConfig ? 'remote_cdp' : 'chromium',
      adapter: remoteConfig?.adapter ?? 'chromium',
      session,
      reason: 'no session'
    }
  }

  try {
    const connection = await resolveConnectionForSession(session, meta, options)
    const cdp = await CdpClient.connect(connection.connectUrl, {
      headers: connection.headers,
      timeoutMs: 5_000
    })
    let body: JsonObject
    try {
      body = await cdp.send<JsonObject>('Browser.getVersion', {}, undefined, 5_000)
    } finally {
      cdp.close()
    }
    return {
      ok: true,
      backend: connection.backend,
      adapter: connection.adapter,
      session,
      pid: meta.pid,
      connect_url: connection.redactedConnectUrl,
      profile_dir: meta.profile_dir,
      browser: body['product'] ?? body['Browser'] ?? null
    }
  } catch (error) {
    return {
      ok: false,
      backend: meta.backend,
      adapter: meta.adapter,
      session,
      pid: meta.pid,
      connect_url: meta.connect_url_redacted ?? (meta.connect_url ? redactUrl(meta.connect_url) : null),
      reason: error instanceof Error ? error.message : String(error)
    }
  }
}

export async function browserNavigate(
  args: {
    session: string | undefined
    url: string
    taskId?: string
    screenshot?: boolean
  },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  assertSafeBrowserUrl(args.url)

  return withPage(
    args.session,
    options,
    async (cdp, page, session, connection) => {
      let snapshot: BrowserSnapshot | undefined
      let navigationFailure: string | undefined
      for (let attempt = 1; attempt <= BROWSER_NAVIGATION_ATTEMPTS; attempt += 1) {
        resetPageNavigationState(page)
        const navigation = await cdp.send<PageNavigateResult>('Page.navigate', { url: args.url }, page.sessionId)
        await waitForReadyState(cdp, page, DEFAULT_WAIT_MS)
        snapshot = await captureSnapshot(cdp, page, session)
        navigationFailure = navigation.errorText || browserNavigationFailureReason(snapshot)
        if (!navigationFailure) break
        if (attempt < BROWSER_NAVIGATION_ATTEMPTS) await sleep(500)
      }

      if (!snapshot) throw new Error('browser navigation did not produce a page snapshot')
      if (navigationFailure) throw new Error(`browser navigation failed for ${args.url}: ${navigationFailure}`)

      const result: JsonObject = {
        ok: true,
        backend: connection.backend,
        adapter: connection.adapter,
        session,
        url: snapshot.url,
        title: snapshot.title,
        snapshot: formatSnapshot(snapshot)
      }
      if (args.screenshot) {
        Object.assign(result, await captureScreenshot(cdp, page, session, args.taskId))
      }
      return result
    },
    { retryLocalDisconnect: true }
  )
}

export async function browserSnapshot(
  args: { session: string | undefined; full?: boolean },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  return withPage(
    args.session,
    options,
    async (cdp, page, session, connection) => {
      const snapshot = await captureSnapshot(cdp, page, session)
      return {
        ok: true,
        backend: connection.backend,
        adapter: connection.adapter,
        session,
        url: snapshot.url,
        title: snapshot.title,
        snapshot: formatSnapshot(snapshot, { full: args.full })
      }
    },
    { retryLocalDisconnect: true }
  )
}

export async function browserFindInSession(
  args: {
    session: string | undefined
    query: string
    contextLines?: number
    matchLimit?: number
    caseSensitive?: boolean
  },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  const query = args.query.trim()
  if (!query) throw new Error('find requires a non-empty query')

  return withPage(
    args.session,
    options,
    async (cdp, page, session, connection) => {
      const text = await evaluate<string>(
        cdp,
        page,
        `document.body?.innerText || document.documentElement?.innerText || ''`
      )
      const matches = findTextMatches(text, {
        query,
        contextLines: args.contextLines,
        matchLimit: args.matchLimit,
        caseSensitive: args.caseSensitive
      })
      return {
        ok: true,
        backend: connection.backend,
        adapter: connection.adapter,
        session,
        query,
        match_count: matches.length,
        matches: redactBrowserJson(matches),
        text: truncate(redactText(formatFindMatches(matches)))
      }
    },
    { retryLocalDisconnect: true }
  )
}

export async function browserClick(
  args: { session: string | undefined; ref: string },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  return actOnRef(args.session, args.ref, options, async (cdp, page, ref, session, connection) => {
    const clicked = await evaluate<JsonObject & { beforeUrl: string; href?: string; x: number; y: number }>(
      cdp,
      page,
      `(() => {
        const el = document.querySelector(${JSON.stringify(ref.selector)});
        if (!el) throw new Error('Element is detached from the DOM; take a new browser_snapshot and use the new ref.');
        el.scrollIntoView({ block: 'center', inline: 'center' });
        if ('disabled' in el && el.disabled) throw new Error('Element is disabled.');
        const rect = el.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) throw new Error('Element is not visible enough to click.');
        const text = (() => {
          try {
            return el instanceof HTMLElement ? el.innerText || el.textContent || '' : el.textContent || '';
          } catch {
            return el.textContent || '';
          }
        })();
        const link = el.closest?.('a[href]');
        return {
          tag: el.tagName.toLowerCase(),
          text: text.trim().slice(0, 200),
          beforeUrl: location.href,
          href: link instanceof HTMLAnchorElement ? link.href : undefined,
          x: rect.left + rect.width / 2,
          y: rect.top + rect.height / 2
        };
      })()`
    )
    await cdp.send(
      'Input.dispatchMouseEvent',
      { type: 'mouseMoved', x: clicked.x, y: clicked.y, button: 'none' },
      page.sessionId
    )
    await cdp.send(
      'Input.dispatchMouseEvent',
      { type: 'mousePressed', x: clicked.x, y: clicked.y, button: 'left', clickCount: 1 },
      page.sessionId
    )
    await cdp.send(
      'Input.dispatchMouseEvent',
      { type: 'mouseReleased', x: clicked.x, y: clicked.y, button: 'left', clickCount: 1 },
      page.sessionId
    )
    await waitBriefly()
    let snapshot = await captureSnapshot(cdp, page, session)
    let usedHrefFallback = false
    if (
      typeof clicked.href === 'string' &&
      clicked.href.length > 0 &&
      !sameBrowserUrl(clicked.href, clicked.beforeUrl) &&
      sameBrowserUrl(snapshot.url, clicked.beforeUrl)
    ) {
      resetPageNavigationState(page)
      const navigation = await cdp.send<PageNavigateResult>('Page.navigate', { url: clicked.href }, page.sessionId)
      await waitForReadyState(cdp, page, DEFAULT_WAIT_MS)
      snapshot = await captureSnapshot(cdp, page, session)
      const fallbackFailure = navigation.errorText || browserNavigationFailureReason(snapshot)
      if (fallbackFailure) throw new Error(`browser click navigation failed: ${fallbackFailure}`)
      usedHrefFallback = true
    }
    const navigationFailure = browserNavigationFailureReason(snapshot)
    if (navigationFailure) throw new Error(`browser click navigation failed: ${navigationFailure}`)

    return {
      ok: true,
      backend: connection.backend,
      adapter: connection.adapter,
      session,
      action: 'click',
      clicked,
      href_fallback_used: usedHrefFallback,
      snapshot: formatSnapshot(snapshot)
    }
  })
}

export async function browserType(
  args: {
    session: string | undefined
    ref: string
    text: string
  },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  return actOnRef(args.session, args.ref, options, async (cdp, page, ref, session, connection) => {
    await evaluate(
      cdp,
      page,
      `(() => {
        const el = document.querySelector(${JSON.stringify(ref.selector)});
        if (!el) throw new Error('Element is detached from the DOM; take a new browser_snapshot and use the new ref.');
        el.scrollIntoView({ block: 'center', inline: 'center' });
        el.focus();
        const text = ${JSON.stringify(args.text)};
        if (el.isContentEditable) {
          el.textContent = text;
          el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return;
        }
        if (!('value' in el)) throw new Error('Element does not accept text input.');
        const proto =
          el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype :
          el instanceof HTMLInputElement ? HTMLInputElement.prototype :
          Object.getPrototypeOf(el);
        const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
        if (setter) setter.call(el, text);
        else el.value = text;
        el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      })()`
    )
    await waitBriefly()
    const snapshot = await captureSnapshot(cdp, page, session)
    return {
      ok: true,
      backend: connection.backend,
      adapter: connection.adapter,
      session,
      action: 'type',
      ref: args.ref,
      snapshot: formatSnapshot(snapshot)
    }
  })
}

export async function browserPress(
  args: { session: string | undefined; key: string },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  return withPage(args.session, options, async (cdp, page, session, connection) => {
    const key = keyDefinition(args.key)
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', ...key }, page.sessionId)
    if (key.text) await cdp.send('Input.dispatchKeyEvent', { type: 'char', ...key }, page.sessionId)
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', ...key }, page.sessionId)
    await waitBriefly()
    const snapshot = await captureSnapshot(cdp, page, session)
    return {
      ok: true,
      backend: connection.backend,
      adapter: connection.adapter,
      session,
      action: 'press',
      key: args.key,
      snapshot: formatSnapshot(snapshot)
    }
  })
}

export async function browserScroll(
  args: {
    session: string | undefined
    ref?: string
    direction?: string
    pixels?: number
  },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  const pixels = Math.max(1, Math.min(args.pixels ?? 700, 10_000))
  const direction = args.direction === 'up' || args.direction === 'left' ? -1 : 1

  if (args.ref) {
    return actOnRef(args.session, args.ref, options, async (cdp, page, ref, session, connection) => {
      await evaluate(
        cdp,
        page,
        `(() => {
          const el = document.querySelector(${JSON.stringify(ref.selector)});
          if (!el) throw new Error('Element is detached from the DOM; take a new browser_snapshot and use the new ref.');
          el.scrollBy({ top: ${direction * pixels}, behavior: 'instant' });
        })()`
      )
      await waitBriefly()
      const snapshot = await captureSnapshot(cdp, page, session)
      return {
        ok: true,
        backend: connection.backend,
        adapter: connection.adapter,
        session,
        action: 'scroll',
        snapshot: formatSnapshot(snapshot)
      }
    })
  }

  return withPage(args.session, options, async (cdp, page, session, connection) => {
    await evaluate(cdp, page, `window.scrollBy({ top: ${direction * pixels}, behavior: 'instant' })`)
    await waitBriefly()
    const snapshot = await captureSnapshot(cdp, page, session)
    return {
      ok: true,
      backend: connection.backend,
      adapter: connection.adapter,
      session,
      action: 'scroll',
      snapshot: formatSnapshot(snapshot)
    }
  })
}

export async function browserSelect(
  args: {
    session: string | undefined
    ref: string
    value: string
  },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  return actOnRef(args.session, args.ref, options, async (cdp, page, ref, session, connection) => {
    await evaluate(
      cdp,
      page,
      `(() => {
        const el = document.querySelector(${JSON.stringify(ref.selector)});
        if (!el) throw new Error('Element is detached from the DOM; take a new browser_snapshot and use the new ref.');
        if (!(el instanceof HTMLSelectElement)) throw new Error('Element is not a select.');
        const wanted = ${JSON.stringify(args.value)};
        const option = Array.from(el.options).find(o => o.value === wanted || o.textContent?.trim() === wanted);
        if (!option) throw new Error('No matching option for ' + wanted);
        el.value = option.value;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      })()`
    )
    await waitBriefly()
    const snapshot = await captureSnapshot(cdp, page, session)
    return {
      ok: true,
      backend: connection.backend,
      adapter: connection.adapter,
      session,
      action: 'select',
      snapshot: formatSnapshot(snapshot)
    }
  })
}

export async function browserWait(
  args: {
    session: string | undefined
    kind?: string
    text?: string
    selector?: string
    timeoutMs?: number
  },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  return withPage(
    args.session,
    options,
    async (cdp, page, session, connection) => {
      const timeoutMs = Math.max(1_000, Math.min(args.timeoutMs ?? DEFAULT_WAIT_MS, 120_000))
      const started = Date.now()
      let nextFallbackProbeAt = started + 2_000
      while (Date.now() - started < timeoutMs) {
        const allowReadyProbe = Date.now() >= nextFallbackProbeAt
        if (allowReadyProbe) nextFallbackProbeAt = Date.now() + 1_000
        const ok = await waitPredicate(cdp, page, args, { allowReadyProbe })
        if (ok) {
          const snapshot = await captureSnapshot(cdp, page, session)
          return {
            ok: true,
            backend: connection.backend,
            adapter: connection.adapter,
            session,
            waited: args.kind ?? 'load',
            snapshot: formatSnapshot(snapshot)
          }
        }
        await sleep(250)
      }
      throw new Error(`browser_wait timed out after ${timeoutMs}ms`)
    },
    { retryLocalDisconnect: true }
  )
}

export async function browserBack(
  args: { session: string | undefined },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  return withPage(
    args.session,
    options,
    async (cdp, page, session, connection) => {
      const history = await cdp.send<{ currentIndex: number; entries: Array<{ id: number }> }>(
        'Page.getNavigationHistory',
        {},
        page.sessionId
      )
      if (history.currentIndex <= 0) throw new Error('No previous browser history entry.')
      const entry = history.entries[history.currentIndex - 1]
      resetPageNavigationState(page)
      await cdp.send('Page.navigateToHistoryEntry', { entryId: entry.id }, page.sessionId)
      await waitForReadyState(cdp, page, DEFAULT_WAIT_MS)
      const snapshot = await captureSnapshot(cdp, page, session)
      return {
        ok: true,
        backend: connection.backend,
        adapter: connection.adapter,
        session,
        action: 'back',
        snapshot: formatSnapshot(snapshot)
      }
    },
    { retryLocalDisconnect: true }
  )
}

function resetPageNavigationState(page: PageSession): void {
  page.mainContextId = undefined
  page.domContentEventAtUnixMs = undefined
  page.loadEventAtUnixMs = undefined
  page.mainFrameStoppedLoadingAtUnixMs = undefined
}

export async function browserScreenshot(
  args: {
    session: string | undefined
    taskId?: string
    path?: string
  },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  return withPage(
    args.session,
    options,
    async (cdp, page, session, connection) => {
      const screenshot = await captureScreenshot(cdp, page, session, args.taskId, args.path)
      if (screenshot.screenshot_unsupported === true) {
        return {
          ok: false,
          backend: connection.backend,
          adapter: connection.adapter,
          session,
          ...screenshot
        }
      }
      return {
        ok: true,
        backend: connection.backend,
        adapter: connection.adapter,
        session,
        ...screenshot
      }
    },
    { retryLocalDisconnect: true }
  )
}

export async function browserExtractFromSession(
  args: {
    session: string | undefined
    url?: string
    taskId?: string
    pattern?: string
  },
  options?: BrowserRuntimeOptions
): Promise<JsonObject | undefined> {
  if (args.url) assertSafeBrowserUrl(args.url)

  const status = await browserStatus({ session: args.session }, options)
  if (status.ok !== true) throw new Error('No active browser session; run browser_navigate first.')

  if (args.url) await browserNavigate({ session: args.session, url: args.url, taskId: args.taskId }, options)

  return withPage(args.session, options, async (cdp, page, session, connection) => {
    const text = await evaluate<string>(
      cdp,
      page,
      `document.body?.innerText || document.documentElement?.innerText || ''`
    )
    const extracted = args.pattern
      ? text
          .split(/\r?\n/)
          .filter(line => line.toLowerCase().includes(args.pattern!.toLowerCase()))
          .join('\n')
      : text
    return {
      ok: true,
      backend: connection.backend,
      adapter: connection.adapter,
      session,
      pattern: args.pattern || null,
      text: truncate(redactText(extracted))
    }
  })
}

export function redactBrowserJson<T>(value: T): T {
  if (typeof value === 'string') return redactText(value) as T
  if (Array.isArray(value)) return value.map(item => redactBrowserJson(item)) as T
  if (value && typeof value === 'object') {
    const output: JsonObject = {}
    for (const [key, item] of Object.entries(value)) {
      output[key] = /password|secret|token|api[_-]?key|authorization/i.test(key)
        ? '[redacted]'
        : redactBrowserJson(item)
    }
    return output as T
  }
  return value
}

function redactRemoteBrowserConfig(config: RemoteBrowserCdpConfig): JsonObject {
  const redacted = redactBrowserJson(config) as JsonObject
  redactUrlFields(redacted)
  return redacted
}

function redactUrlFields(value: unknown): void {
  if (!value || typeof value !== 'object') return
  if (Array.isArray(value)) {
    for (const item of value) redactUrlFields(item)
    return
  }

  for (const [key, item] of Object.entries(value as JsonObject)) {
    if (typeof item === 'string' && /(^url$|_url$|endpoint_url)/i.test(key)) {
      const record = value as JsonObject
      record[key] = redactUrl(item)
    } else {
      redactUrlFields(item)
    }
  }
}

export function assertSafeBrowserUrl(rawUrl: string): void {
  const url = new URL(rawUrl)
  if (url.protocol === 'data:' || url.protocol === 'about:') return
  if (!['http:', 'https:'].includes(url.protocol)) {
    throw new Error(`unsupported browser URL protocol: ${url.protocol}`)
  }

  const host = url.hostname.replace(/^\[|\]$/g, '').toLowerCase()
  if (isBlockedMetadataHost(host)) {
    throw new Error('blocked browser navigation to cloud metadata endpoint')
  }
}

function isBlockedMetadataHost(host: string): boolean {
  if (host === 'metadata.google.internal' || host === 'metadata') return true
  if (host === '169.254.169.254' || host === '169.254.169.250' || host === '169.254.169.251') return true
  if (host === 'fd00:ec2::254') return true
  if (isIP(host) === 6 && host.startsWith('fe80:')) return true
  return false
}

async function withPage<T>(
  rawSession: string | undefined,
  options: BrowserRuntimeOptions | undefined,
  fn: (cdp: CdpClient, page: PageSession, session: string, connection: BrowserConnection) => Promise<T>,
  opts: { retryLocalDisconnect?: boolean } = {}
): Promise<T> {
  const session = sanitizeId(rawSession || 'default')
  const meta = readSessionMeta(session)
  if (!meta) throw new Error('No active browser session; run browser_navigate first.')

  const connection = await resolveConnectionForSession(session, meta, options)
  const active = await activePageForSession(session, connection, meta)
  try {
    return await fn(active.cdp, active.page, session, connection)
  } catch (error) {
    forgetActiveBrowserSession(session)
    if (!opts.retryLocalDisconnect || connection.backend !== 'chromium' || !isRecoverableCdpConnectionError(error)) {
      throw error
    }

    const currentMeta = readSessionMeta(session) ?? meta
    const recoveredConnection = await recoverLocalChromiumConnection(session, currentMeta, options)
    const recoveredActive = await activePageForSession(
      session,
      recoveredConnection,
      readSessionMeta(session) ?? currentMeta
    )
    return await fn(recoveredActive.cdp, recoveredActive.page, session, recoveredConnection)
  }
}

function forgetActiveBrowserSession(session: string): void {
  const active = activeBrowserSessions.get(session)
  if (!active) return
  activeBrowserSessions.delete(session)
  active.cdp.close()
}

async function recoverLocalChromiumConnection(
  session: string,
  meta: BrowserSessionMeta,
  options?: BrowserRuntimeOptions
): Promise<BrowserConnection> {
  const sidecarKey = meta.local_sidecar_key ?? localSidecarKey()
  const sidecar = localChromiumSidecars.get(sidecarKey)
  if (sidecar) await stopLocalSidecar(sidecar)

  const idleTtlMs = localBrowserIdleTtlMs(options)
  const recovered = await ensureLocalChromiumSidecar(sidecarKey, idleTtlMs)
  const context = await createLocalBrowserContext(recovered.connectUrl)
  writeSessionMeta(session, {
    ...meta,
    local_sidecar_key: recovered.key,
    pid: recovered.proc.pid,
    connect_url: recovered.connectUrl,
    connect_url_redacted: redactUrl(recovered.connectUrl),
    connect_url_source: 'session',
    browser_context_id: context.browserContextId,
    target_id: context.targetId
  })
  return {
    backend: 'chromium',
    adapter: 'chromium',
    connectUrl: recovered.connectUrl,
    redactedConnectUrl: redactUrl(recovered.connectUrl)
  }
}

async function activePageForSession(
  session: string,
  connection: BrowserConnection,
  meta: BrowserSessionMeta
): Promise<ActiveBrowserSession> {
  const headersKey = stableHeadersKey(connection.headers)
  const existing = activeBrowserSessions.get(session)
  if (
    existing &&
    existing.cdp.isOpen() &&
    existing.connectUrl === connection.connectUrl &&
    existing.headersKey === headersKey
  ) {
    return existing
  }

  existing?.cdp.close()

  const cdp = await CdpClient.connect(connection.connectUrl, { headers: connection.headers })
  const page = await attachPage(cdp, meta.target_id, meta.browser_context_id)
  if (meta.target_id !== page.targetId) {
    writeSessionMeta(session, { ...(readSessionMeta(session) ?? meta), target_id: page.targetId })
  }

  const active: ActiveBrowserSession = {
    cdp,
    page,
    connectUrl: connection.connectUrl,
    headersKey
  }
  activeBrowserSessions.set(session, active)
  cdp.closed.then(() => {
    if (activeBrowserSessions.get(session) === active) activeBrowserSessions.delete(session)
  })
  return active
}

async function actOnRef<T>(
  rawSession: string | undefined,
  refName: string,
  options: BrowserRuntimeOptions | undefined,
  fn: (cdp: CdpClient, page: PageSession, ref: BrowserRef, session: string, connection: BrowserConnection) => Promise<T>
): Promise<T> {
  return withPage(rawSession, options, async (cdp, page, session, connection) => {
    const ref = readRefs(session).find(item => item.ref === refName)
    if (!ref) throw new Error('Unknown or stale browser ref; take a new browser_snapshot and use the new ref.')
    return await fn(cdp, page, ref, session, connection)
  })
}

async function attachPage(cdp: CdpClient, preferredTargetId?: string, browserContextId?: string): Promise<PageSession> {
  const targets = await cdp.send<{ targetInfos: TargetInfo[] }>('Target.getTargets')
  let target = preferredTargetId
    ? targets.targetInfos.find(info => info.targetId === preferredTargetId && info.type === 'page')
    : undefined
  if (!target && browserContextId) {
    target = targets.targetInfos.find(info => info.type === 'page' && info.browserContextId === browserContextId)
  }
  if (!browserContextId) {
    target ??= targets.targetInfos.find(
      info => info.type === 'page' && !info.url.startsWith('devtools://') && info.url !== 'about:blank'
    )
    target ??= targets.targetInfos.find(info => info.type === 'page' && !info.url.startsWith('devtools://'))
  }
  if (!target) {
    const created = await cdp.send<{ targetId: string }>('Target.createTarget', {
      url: 'about:blank',
      ...(browserContextId ? { browserContextId } : {})
    })
    target = { targetId: created.targetId, type: 'page', url: 'about:blank' }
  }

  const attached = await cdp.send<{ sessionId: string }>('Target.attachToTarget', {
    targetId: target.targetId,
    flatten: true
  })
  const page = { targetId: target.targetId, sessionId: attached.sessionId }
  await cdp.send('Page.enable', {}, page.sessionId)
  await refreshMainFrameId(cdp, page)
  installPageContextTracking(cdp, page)
  await cdp.send('Runtime.enable', {}, page.sessionId)
  await cdp.send('DOM.enable', {}, page.sessionId)
  await waitForMainExecutionContext(cdp, page, 1_500)
  return page
}

async function refreshMainFrameId(cdp: CdpClient, page: PageSession): Promise<void> {
  const frameTree = await cdp.send<PageFrameTree>('Page.getFrameTree', {}, page.sessionId)
  page.mainFrameId = frameTree.frameTree.frame.id
}

function installPageContextTracking(cdp: CdpClient, page: PageSession): void {
  cdp.on('Runtime.executionContextsCleared', page.sessionId, () => {
    page.mainContextId = undefined
  })
  cdp.on('Page.frameNavigated', page.sessionId, params => {
    const event = params as unknown as PageFrameNavigatedEvent
    if (!page.mainFrameId || event.frame?.id === page.mainFrameId) {
      page.mainFrameId = event.frame?.id ?? page.mainFrameId
      page.mainContextId = undefined
    }
  })
  cdp.on('Page.frameStartedNavigating', page.sessionId, params => {
    const frameId = typeof params['frameId'] === 'string' ? params['frameId'] : undefined
    if (!page.mainFrameId || frameId === page.mainFrameId) page.mainContextId = undefined
  })
  cdp.on('Page.domContentEventFired', page.sessionId, () => {
    page.domContentEventAtUnixMs = Date.now()
  })
  cdp.on('Page.loadEventFired', page.sessionId, () => {
    page.loadEventAtUnixMs = Date.now()
  })
  cdp.on('Page.frameStoppedLoading', page.sessionId, params => {
    const frameId = typeof params['frameId'] === 'string' ? params['frameId'] : undefined
    if (!page.mainFrameId || frameId === page.mainFrameId) page.mainFrameStoppedLoadingAtUnixMs = Date.now()
  })
  cdp.on('Runtime.executionContextCreated', page.sessionId, params => {
    const event = params as unknown as RuntimeExecutionContextCreatedEvent
    const auxData = event.context?.auxData
    if (
      typeof event.context?.id === 'number' &&
      auxData?.isDefault === true &&
      auxData.frameId &&
      auxData.frameId === page.mainFrameId
    ) {
      page.mainContextId = event.context.id
    }
  })
}

async function captureSnapshot(cdp: CdpClient, page: PageSession, session: string): Promise<BrowserSnapshot> {
  const snapshot = await evaluate<BrowserSnapshot>(cdp, page, `(${snapshotScript.toString()})(${SNAPSHOT_ELEMENT_MAX})`)
  writeRefs(session, snapshot.elements)
  return snapshot
}

function formatSnapshot(snapshot: BrowserSnapshot, opts: { full?: boolean } = {}): string {
  const lines = [`URL: ${snapshot.url}`, `Title: ${snapshot.title || '(untitled)'}`, '', 'Interactive elements:']
  if (snapshot.elements.length === 0) {
    lines.push('(none found)')
  } else {
    for (const element of snapshot.elements) {
      const disabled = element.disabled ? ' disabled' : ''
      const name = element.name ? ` "${element.name}"` : ''
      lines.push(`[${element.ref}] ${element.role || element.tag}${name}${disabled}`)
    }
  }

  const text = opts.full ? snapshot.text : snapshot.text.slice(0, SNAPSHOT_TEXT_MAX)
  if (text.trim()) {
    lines.push('', 'Page text:', text.trim())
    if (!opts.full && snapshot.text.length > SNAPSHOT_TEXT_MAX) lines.push('[truncated]')
  }

  return redactText(lines.join('\n'))
}

function browserNavigationFailureReason(snapshot: BrowserSnapshot): string | undefined {
  const text = snapshot.text.trim()
  if (text === 'Unprocessable Entity' && snapshot.title.trim() === '' && snapshot.elements.length === 0) {
    return 'browser returned a network error page: Unprocessable Entity'
  }
  if (!text.startsWith('Navigation failed')) return undefined
  const reason = text.match(/(?:^|\n)Reason:\s*([^\n]+)/)?.[1]?.trim()
  return reason || 'browser returned a navigation failure page'
}

function sameBrowserUrl(left: string, right: string): boolean {
  try {
    return new URL(left, 'http://invalid.local').toString() === new URL(right, 'http://invalid.local').toString()
  } catch {
    return left === right
  }
}

async function captureScreenshot(
  cdp: CdpClient,
  page: PageSession,
  session: string,
  taskId?: string,
  explicitPath?: string
): Promise<JsonObject> {
  let result: { data: string }
  try {
    result = await cdp.send<{ data: string }>(
      'Page.captureScreenshot',
      { format: 'png', fromSurface: true },
      page.sessionId,
      30_000
    )
  } catch (error) {
    if (isUnsupportedCdpMethod(error)) {
      return {
        screenshot_unsupported: true,
        error: 'browser backend does not support Page.captureScreenshot'
      }
    }
    throw error
  }
  const outputPath = explicitPath
    ? safePath(explicitPath)
    : safePath(`/workspace/user-files/browser/${session}/${sanitizeId(taskId || 'latest')}/screenshot.png`)
  mkdirSync(dirname(outputPath), { recursive: true })
  writeFileSync(outputPath, Buffer.from(result.data, 'base64'))
  return { screenshot_path: toWorkspacePath(outputPath) }
}

async function waitForReadyState(cdp: CdpClient, page: PageSession, timeoutMs: number): Promise<void> {
  const started = Date.now()
  let nextFallbackProbeAt = started + 2_000
  while (Date.now() - started < timeoutMs) {
    if (await pageReady(cdp, page, { sinceUnixMs: started, allowProbe: false })) {
      await sleep(LOCAL_BROWSER_READY_STABLE_MS)
      return
    }

    if (Date.now() >= nextFallbackProbeAt) {
      nextFallbackProbeAt = Date.now() + 1_000
      if (await pageReady(cdp, page, { sinceUnixMs: started, allowProbe: true })) {
        await sleep(LOCAL_BROWSER_READY_STABLE_MS)
        return
      }
    }
    await sleep(250)
  }
}

async function pageReady(
  cdp: CdpClient,
  page: PageSession,
  opts: { sinceUnixMs?: number; allowProbe?: boolean } = {}
): Promise<boolean> {
  const sinceUnixMs = opts.sinceUnixMs ?? 0
  if (
    (page.loadEventAtUnixMs !== undefined && page.loadEventAtUnixMs >= sinceUnixMs) ||
    (page.domContentEventAtUnixMs !== undefined && page.domContentEventAtUnixMs >= sinceUnixMs) ||
    (page.mainFrameStoppedLoadingAtUnixMs !== undefined && page.mainFrameStoppedLoadingAtUnixMs >= sinceUnixMs)
  ) {
    return true
  }

  if (opts.allowProbe !== true) return false

  const readyState = await evaluate<string>(cdp, page, 'document.readyState')
  return readyState === 'complete' || readyState === 'interactive'
}

async function waitPredicate(
  cdp: CdpClient,
  page: PageSession,
  args: { kind?: string; text?: string; selector?: string },
  opts: { allowReadyProbe?: boolean } = {}
): Promise<boolean> {
  if (args.kind === 'text') {
    const text = args.text ?? ''
    return await evaluate<boolean>(cdp, page, `(document.body?.innerText || '').includes(${JSON.stringify(text)})`)
  }

  if (args.kind === 'selector') {
    const selector = args.selector ?? ''
    return await evaluate<boolean>(cdp, page, `Boolean(document.querySelector(${JSON.stringify(selector)}))`)
  }

  return await pageReady(cdp, page, { allowProbe: opts.allowReadyProbe === true })
}

async function evaluate<T>(cdp: CdpClient, page: PageSession, expression: string): Promise<T> {
  const contextId = await waitForMainExecutionContext(cdp, page, 1_500)
  const response = await cdp.send<RuntimeEvaluateResult>(
    'Runtime.evaluate',
    {
      expression,
      awaitPromise: true,
      returnByValue: true,
      userGesture: true,
      ...(contextId === undefined ? {} : { contextId })
    },
    page.sessionId
  )

  if (response.exceptionDetails) {
    throw new Error(
      response.exceptionDetails.exception?.description || response.exceptionDetails.text || 'browser evaluation failed'
    )
  }

  return response.result.value as T
}

async function waitForMainExecutionContext(
  cdp: CdpClient,
  page: PageSession,
  timeoutMs: number
): Promise<number | undefined> {
  if (page.mainContextId !== undefined) return page.mainContextId

  if (!page.mainFrameId) {
    try {
      await refreshMainFrameId(cdp, page)
    } catch {
      return undefined
    }
  }

  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (page.mainContextId !== undefined) return page.mainContextId
    await sleep(50)
  }
  return page.mainContextId
}

class CdpClient {
  private nextId = 1
  readonly closed: Promise<void>
  private resolveClosed!: () => void
  private eventListeners = new Map<string, Set<(params: JsonObject) => void>>()
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
        debugCdp(`message handler failed: ${error instanceof Error ? error.stack || error.message : String(error)}`)
      }
    })
    socket.addEventListener('close', event => {
      debugCdp(`socket closed code=${event.code} reason=${event.reason || ''}`)
      this.rejectAll(new Error('CDP socket closed'))
      this.resolveClosed()
    })
    socket.addEventListener('error', () => {
      debugCdp('socket error')
      this.rejectAll(new Error('CDP socket error'))
    })
  }

  static connect(url: string, opts: { headers?: Record<string, string>; timeoutMs?: number } = {}): Promise<CdpClient> {
    return new Promise((resolveConnect, rejectConnect) => {
      const socket = opts.headers ? new WebSocket(url, { headers: opts.headers } as never) : new WebSocket(url)
      const timeout = setTimeout(() => {
        socket.close()
        rejectConnect(new Error('Timed out connecting to browser CDP'))
      }, opts.timeoutMs ?? 5_000)

      socket.addEventListener(
        'open',
        () => {
          clearTimeout(timeout)
          resolveConnect(new CdpClient(socket))
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

  send<T>(method: string, params: JsonObject = {}, sessionId?: string, timeoutMs = 15_000): Promise<T> {
    if (this.socket.readyState !== WebSocket.OPEN) throw new Error('CDP socket is not open')

    const id = this.nextId++
    const message: JsonObject = { id, method, params }
    if (sessionId) message['sessionId'] = sessionId
    debugCdp(`send id=${id} method=${method} session=${sessionId ?? '-'}`)

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

  close(): void {
    if (this.socket.readyState === WebSocket.OPEN || this.socket.readyState === WebSocket.CONNECTING) {
      this.socket.close()
    }
  }

  isOpen(): boolean {
    return this.socket.readyState === WebSocket.OPEN
  }

  on(method: string, sessionId: string | undefined, listener: (params: JsonObject) => void): () => void {
    const key = eventListenerKey(method, sessionId)
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

  private handleMessage(data: unknown): void {
    const text = typeof data === 'string' ? data : Buffer.from(data as ArrayBuffer).toString('utf8')
    const message = JSON.parse(text) as {
      id?: number
      method?: string
      params?: JsonObject
      sessionId?: string
      result?: unknown
      error?: { message?: string; data?: string }
    }
    if (message.id === undefined) {
      if (message.method) this.emitEvent(message.method, message.sessionId, message.params ?? {})
      return
    }

    const pending = this.pending.get(message.id)
    if (!pending) return
    this.pending.delete(message.id)
    clearTimeout(pending.timeout)

    if (message.error) {
      pending.reject(new Error([message.error.message, message.error.data].filter(Boolean).join(': ')))
    } else {
      debugCdp(`recv id=${message.id}`)
      pending.resolve(message.result)
    }
  }

  private rejectAll(error: Error): void {
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timeout)
      pending.reject(error)
      this.pending.delete(id)
    }
  }

  private emitEvent(method: string, sessionId: string | undefined, params: JsonObject): void {
    for (const key of [eventListenerKey(method, sessionId), eventListenerKey(method, undefined)]) {
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

function eventListenerKey(method: string, sessionId: string | undefined): string {
  return `${sessionId ?? '*'}:${method}`
}

function debugCdp(message: string): void {
  if (process.env.ANKOLE_BROWSER_CDP_DEBUG !== '1') return
  process.stderr.write(`[browser-cdp] ${message}\n`)
}

function readSessionMeta(session: string): BrowserSessionMeta | undefined {
  const path = sessionPath(session)
  if (!existsSync(path)) return undefined
  return JSON.parse(readFileSync(path, 'utf8')) as BrowserSessionMeta
}

function writeSessionMeta(session: string, meta: BrowserSessionMeta): void {
  const path = sessionPath(session)
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, JSON.stringify(meta, null, 2))
}

function sessionPath(session: string): string {
  return resolve(browserRoot(session), 'session.json')
}

function readRefs(session: string): BrowserRef[] {
  const path = resolve(browserRoot(session), 'refs.json')
  if (!existsSync(path)) return []
  const payload = JSON.parse(readFileSync(path, 'utf8')) as { elements?: BrowserRef[] }
  return payload.elements ?? []
}

function writeRefs(session: string, elements: BrowserRef[]): void {
  const path = resolve(browserRoot(session), 'refs.json')
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, JSON.stringify({ elements, updated_at_unix_ms: Date.now() }, null, 2))
}

function browserRoot(session: string): string {
  return safePath(`/workspace/.sessions/${sanitizeId(session)}/browser`)
}

function browserHttpUrl(connectUrl: string, path: string): string {
  const url = new URL(connectUrl)
  url.protocol = url.protocol === 'wss:' ? 'https:' : 'http:'
  url.pathname = path
  url.search = ''
  url.hash = ''
  return url.toString()
}

async function resolveConnectionForSession(
  session: string,
  meta: BrowserSessionMeta,
  options?: BrowserRuntimeOptions
): Promise<BrowserConnection> {
  const remoteConfig = remoteBrowserCdpConfigFromOptions(options)
  if (remoteConfig) {
    const connection =
      remoteConfig.adapter === 'cdp_endpoint'
        ? await resolveRemoteConnection(remoteConfig)
        : meta.connect_url
          ? {
              backend: 'remote_cdp' as const,
              adapter: meta.adapter,
              connectUrl: meta.connect_url,
              redactedConnectUrl: meta.connect_url_redacted ?? redactUrl(meta.connect_url),
              headers: remoteConfig.headers
            }
          : await resolveRemoteConnection(remoteConfig)

    if (!meta.connect_url && connection.connectUrl) {
      writeSessionMeta(session, {
        ...meta,
        connect_url: connection.connectUrl,
        connect_url_redacted: connection.redactedConnectUrl,
        connect_url_source: 'session'
      })
    }

    return connection
  }

  if (meta.backend === 'remote_cdp') {
    throw new Error('browser session was created for remote CDP, but no remote CDP config is currently set')
  }

  if (meta.backend === 'chromium') {
    const sidecarKey = meta.local_sidecar_key ?? localSidecarKey()
    const idleTtlMs = localBrowserIdleTtlMs(options)
    if (meta.connect_url && (await localCdpEndpointAlive(meta.connect_url))) {
      touchLocalChromiumSidecar(sidecarKey, idleTtlMs)
      if (!meta.browser_context_id || !meta.target_id) {
        const context = await createLocalBrowserContext(meta.connect_url)
        writeSessionMeta(session, {
          ...meta,
          browser_context_id: context.browserContextId,
          target_id: context.targetId
        })
      }
      return {
        backend: 'chromium',
        adapter: 'chromium',
        connectUrl: meta.connect_url,
        redactedConnectUrl: meta.connect_url_redacted ?? redactUrl(meta.connect_url)
      }
    }

    const sidecar = await ensureLocalChromiumSidecar(sidecarKey, idleTtlMs)
    const sidecarChanged = meta.connect_url !== sidecar.connectUrl || meta.pid !== sidecar.proc.pid
    const context =
      sidecarChanged || !meta.browser_context_id || !meta.target_id
        ? await createLocalBrowserContext(sidecar.connectUrl)
        : { browserContextId: meta.browser_context_id, targetId: meta.target_id }
    if (sidecarChanged || meta.browser_context_id !== context.browserContextId || meta.target_id !== context.targetId) {
      writeSessionMeta(session, {
        ...meta,
        local_sidecar_key: sidecar.key,
        pid: sidecar.proc.pid,
        connect_url: sidecar.connectUrl,
        connect_url_redacted: redactUrl(sidecar.connectUrl),
        connect_url_source: 'session',
        browser_context_id: context.browserContextId,
        target_id: context.targetId
      })
    }
    return {
      backend: 'chromium',
      adapter: 'chromium',
      connectUrl: sidecar.connectUrl,
      redactedConnectUrl: redactUrl(sidecar.connectUrl)
    }
  }

  throw new Error('unsupported browser session backend')
}

async function localCdpEndpointAlive(connectUrl: string): Promise<boolean> {
  try {
    const response = await fetch(browserHttpUrl(connectUrl, '/json/version'), {
      signal: AbortSignal.timeout(1_000)
    })
    return response.ok
  } catch {
    return false
  }
}

async function resolveRemoteConnection(config: RemoteBrowserCdpConfig): Promise<BrowserConnection> {
  if (config.adapter === 'cdp_endpoint') {
    const endpoint = new URL(config.endpoint_url)
    const connectUrl =
      endpoint.protocol === 'ws:' || endpoint.protocol === 'wss:'
        ? endpoint.toString()
        : await discoverWebSocketUrl(endpoint.toString(), config.headers, connectTimeoutMs(config))

    return {
      backend: 'remote_cdp',
      adapter: 'cdp_endpoint',
      connectUrl,
      redactedConnectUrl: redactUrl(connectUrl),
      headers: config.headers
    }
  }

  const connectUrl = await requestRemoteSession(config)
  return {
    backend: 'remote_cdp',
    adapter: 'cdp_session_request',
    connectUrl,
    redactedConnectUrl: redactUrl(connectUrl),
    headers: config.headers
  }
}

async function discoverWebSocketUrl(
  endpointUrl: string,
  headers: Record<string, string> | undefined,
  timeoutMs: number
): Promise<string> {
  const url = new URL(endpointUrl)
  if (!url.pathname || url.pathname === '/') {
    url.pathname = '/json/version'
  }
  const response = await fetch(url, {
    headers,
    signal: AbortSignal.timeout(timeoutMs)
  })
  if (!response.ok) throw new Error(`CDP /json/version failed with HTTP ${response.status}`)
  const body = (await response.json()) as JsonObject
  const connectUrl = body['webSocketDebuggerUrl']
  if (typeof connectUrl !== 'string' || connectUrl.length === 0) {
    throw new Error('CDP /json/version response is missing webSocketDebuggerUrl')
  }
  return normalizeDiscoveredWebSocketUrl(connectUrl, url)
}

function normalizeDiscoveredWebSocketUrl(connectUrl: string, endpointUrl: URL): string {
  const wsUrl = new URL(connectUrl)
  const isLoopback =
    wsUrl.hostname === '127.0.0.1' ||
    wsUrl.hostname === '::1' ||
    wsUrl.hostname === '[::1]' ||
    wsUrl.hostname === 'localhost'
  if (!isLoopback) return wsUrl.toString()

  wsUrl.hostname = endpointUrl.hostname
  wsUrl.port = endpointUrl.port
  wsUrl.protocol = endpointUrl.protocol === 'https:' ? 'wss:' : 'ws:'
  return wsUrl.toString()
}

async function requestRemoteSession(config: Extract<RemoteBrowserCdpConfig, { adapter: 'cdp_session_request' }>) {
  const request = config.request
  const method = request.method ?? 'GET'
  const response = await fetch(request.url, {
    method,
    headers: request.headers,
    body: method === 'POST' && request.body ? JSON.stringify(request.body) : undefined,
    signal: AbortSignal.timeout(connectTimeoutMs(config))
  })
  if (!response.ok) throw new Error(`remote CDP session request failed with HTTP ${response.status}`)

  const responseSpec = request.response ?? { type: 'text' as const }
  if (responseSpec.type === 'text') {
    const text = (await response.text()).trim()
    if (!text) throw new Error('remote CDP session request returned an empty websocket URL')
    return text
  }

  const body = (await response.json()) as JsonObject
  const value = valueAtJsonPath(body, responseSpec.path)
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`remote CDP session JSON response is missing ${responseSpec.path.join('.')}`)
  }
  return value
}

async function pollJsonVersionForWebSocket(
  url: string,
  headers: Record<string, string> | undefined,
  exited?: Promise<number | null>
): Promise<string> {
  const deadline = Date.now() + 10_000
  let lastError = ''

  while (Date.now() < deadline) {
    if (exited) {
      const exit = await Promise.race([exited.then(code => ({ code })), sleep(0).then(() => null)])
      if (exit?.code !== undefined && exit.code !== null) break
    }

    try {
      const response = await fetch(url, {
        headers,
        signal: AbortSignal.timeout(1_000)
      })
      if (response.ok) {
        const body = (await response.json()) as JsonObject
        const connectUrl = body['webSocketDebuggerUrl']
        if (typeof connectUrl === 'string' && connectUrl.length > 0) return connectUrl
      }
      lastError = `HTTP ${response.status}`
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error)
    }
    await sleep(250)
  }

  throw new Error(`Chromium CDP did not become ready: ${lastError}`)
}

async function ensureLocalChromiumSidecar(key: string, idleTtlMs: number): Promise<LocalChromiumSidecar> {
  installLocalChromiumShutdownHooks()

  const existing = localChromiumSidecars.get(key)
  if (existing && existing.proc.exitCode === null && (await localCdpEndpointAlive(existing.connectUrl))) {
    existing.lastUsedAtUnixMs = Date.now()
    existing.idleTtlMs = idleTtlMs
    scheduleLocalSidecarIdleStop(existing)
    return existing
  }

  if (existing) {
    await stopLocalSidecar(existing)
  }

  const chromium = findChromium()
  if (!chromium) throw new Error('local browser requires Chromium; no remote CDP override is configured')

  const port = await allocateLocalPort()
  const profileDir = resolve(workspaceRoot, '.sessions/_browser/chromium/profile')
  mkdirSync(profileDir, { recursive: true })
  const proc = Bun.spawn(
    [
      chromium,
      '--headless=new',
      '--renderer-process-limit=4',
      '--no-zygote',
      '--no-sandbox',
      '--disable-gpu',
      '--disable-dev-shm-usage',
      '--disable-sync',
      '--disable-background-networking',
      '--disable-default-apps',
      '--disable-translate',
      '--disable-popup-blocking',
      '--disable-notifications',
      '--disable-extensions',
      `--user-agent=${LOCAL_CHROMIUM_USER_AGENT}`,
      '--remote-debugging-address=127.0.0.1',
      `--remote-debugging-port=${port}`,
      `--user-data-dir=${profileDir}`,
      'about:blank'
    ],
    {
      cwd: workspaceRoot,
      env: process.env,
      stdout: 'pipe',
      stderr: 'pipe'
    }
  )
  drainProcessOutput(proc.stdout, `chromium:${key}:stdout`)
  drainProcessOutput(proc.stderr, `chromium:${key}:stderr`)

  const cdpHttpUrl = `http://127.0.0.1:${port}`
  const connectUrl = await pollJsonVersionForWebSocket(`${cdpHttpUrl}/json/version`, undefined, proc.exited)
  const sidecar: LocalChromiumSidecar = {
    key,
    port,
    proc,
    connectUrl,
    cdpHttpUrl,
    profileDir,
    startedAtUnixMs: Date.now(),
    lastUsedAtUnixMs: Date.now(),
    idleTtlMs
  }
  localChromiumSidecars.set(key, sidecar)
  scheduleLocalSidecarIdleStop(sidecar)
  proc.exited.then(() => {
    const current = localChromiumSidecars.get(key)
    if (current === sidecar) {
      if (sidecar.idleTimer) clearTimeout(sidecar.idleTimer)
      localChromiumSidecars.delete(key)
      closeActiveSessionsForConnectUrl(sidecar.connectUrl)
    }
  })
  return sidecar
}

function localSidecarKey(): string {
  return LOCAL_CHROMIUM_SIDECAR_KEY
}

function localBrowserIdleTtlMs(options?: BrowserRuntimeOptions): number {
  const value = options?.localBrowserIdleTtlMs
  if (typeof value === 'number' && Number.isFinite(value) && value > 0) {
    return Math.floor(value)
  }
  return DEFAULT_LOCAL_BROWSER_IDLE_TTL_MS
}

function touchLocalChromiumSidecar(key: string, idleTtlMs: number): void {
  const sidecar = localChromiumSidecars.get(key)
  if (!sidecar || sidecar.proc.exitCode !== null) return
  sidecar.lastUsedAtUnixMs = Date.now()
  sidecar.idleTtlMs = idleTtlMs
  scheduleLocalSidecarIdleStop(sidecar)
}

function scheduleLocalSidecarIdleStop(sidecar: LocalChromiumSidecar): void {
  if (sidecar.idleTimer) clearTimeout(sidecar.idleTimer)
  sidecar.idleTimer = setTimeout(() => {
    const current = localChromiumSidecars.get(sidecar.key)
    if (current !== sidecar) return
    if (Date.now() - sidecar.lastUsedAtUnixMs < sidecar.idleTtlMs) {
      scheduleLocalSidecarIdleStop(sidecar)
      return
    }
    stopLocalSidecar(sidecar).catch(() => {
      // Best-effort idle cleanup.
    })
  }, sidecar.idleTtlMs)
  sidecar.idleTimer.unref?.()
}

async function stopLocalSidecar(sidecar: LocalChromiumSidecar): Promise<void> {
  if (sidecar.idleTimer) clearTimeout(sidecar.idleTimer)
  localChromiumSidecars.delete(sidecar.key)
  closeActiveSessionsForConnectUrl(sidecar.connectUrl)
  if (sidecar.proc.exitCode !== null) return

  try {
    sidecar.proc.kill('SIGTERM')
  } catch {
    return
  }

  const exited = await Promise.race([sidecar.proc.exited.then(() => true), sleep(5_000).then(() => false)])
  if (!exited && sidecar.proc.exitCode === null) {
    try {
      sidecar.proc.kill('SIGKILL')
    } catch {
      // Process may already be gone.
    }
  }
}

function closeActiveSessionsForConnectUrl(connectUrl: string): void {
  for (const [session, active] of activeBrowserSessions) {
    if (active.connectUrl === connectUrl) {
      active.cdp.close()
      activeBrowserSessions.delete(session)
    }
  }
}

function installLocalChromiumShutdownHooks(): void {
  if (localChromiumShutdownHooksInstalled) return
  localChromiumShutdownHooksInstalled = true
  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.once(signal, () => {
      for (const sidecar of localChromiumSidecars.values()) {
        try {
          sidecar.proc.kill('SIGTERM')
        } catch {
          // Process may already be gone.
        }
      }
    })
  }
}

async function allocateLocalPort(): Promise<number> {
  return await new Promise((resolvePort, rejectPort) => {
    const server = createServer()
    server.once('error', rejectPort)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      if (!address || typeof address === 'string') {
        server.close()
        rejectPort(new Error('failed to allocate local browser port'))
        return
      }
      const port = address.port
      server.close(error => {
        if (error) rejectPort(error)
        else resolvePort(port)
      })
    })
  })
}

function normalizeRemoteBrowserCdpConfig(value: unknown): RemoteBrowserCdpConfig {
  const record = objectRecord(value, 'remote browser CDP config')
  const adapter = stringField(record, 'adapter')
  if (adapter === 'cdp_endpoint') {
    return {
      adapter,
      endpoint_url: validateUrl(stringField(record, 'endpoint_url'), ['ws:', 'wss:', 'http:', 'https:']),
      ...optionalHeaders(record, 'headers'),
      ...optionalTimeout(record)
    }
  }

  if (adapter === 'cdp_session_request') {
    const request = objectRecord(record['request'], 'remote browser CDP session request')
    const response = normalizeSessionResponse(request['response'])
    return {
      adapter,
      request: {
        url: validateUrl(stringField(request, 'url'), ['http:', 'https:']),
        method: optionalMethod(request),
        ...optionalHeaders(request, 'headers'),
        ...(request['body'] === undefined
          ? {}
          : { body: objectRecord(request['body'], 'remote browser CDP request body') }),
        ...(response ? { response } : {})
      },
      ...optionalHeaders(record, 'headers'),
      ...optionalTimeout(record)
    }
  }

  throw new Error(`unsupported remote browser CDP adapter: ${adapter}`)
}

function normalizeSessionResponse(value: unknown): RemoteSessionResponse | undefined {
  if (value === undefined) return undefined
  const response = objectRecord(value, 'remote browser CDP session response')
  const type = stringField(response, 'type')
  if (type === 'text') return { type }
  if (type === 'json') {
    const path = response['path']
    if (!Array.isArray(path) || !path.every(item => typeof item === 'string' && item.length > 0)) {
      throw new Error('remote browser CDP session response path must be a non-empty string array')
    }
    return { type, path }
  }
  throw new Error(`unsupported remote browser CDP session response type: ${type}`)
}

function optionalMethod(record: JsonObject): 'GET' | 'POST' | undefined {
  const value = record['method']
  if (value === undefined) return undefined
  if (value === 'GET' || value === 'POST') return value
  throw new Error('remote browser CDP session request method must be GET or POST')
}

function optionalHeaders(record: JsonObject, field: string): { headers?: Record<string, string> } {
  const value = record[field]
  if (value === undefined) return {}
  const headers = objectRecord(value, `remote browser CDP ${field}`)
  const output: Record<string, string> = {}
  for (const [key, item] of Object.entries(headers)) {
    if (key.trim() === '' || typeof item !== 'string') {
      throw new Error(`remote browser CDP ${field} must be a string-to-string object`)
    }
    output[key] = item
  }
  return { headers: output }
}

function optionalTimeout(record: JsonObject): { connect_timeout_ms?: number } {
  const value = record['connect_timeout_ms']
  if (value === undefined) return {}
  if (!Number.isInteger(value) || (value as number) < 1_000 || (value as number) > 120_000) {
    throw new Error('remote browser CDP connect_timeout_ms must be an integer from 1000 to 120000')
  }
  return { connect_timeout_ms: value as number }
}

function connectTimeoutMs(config: RemoteBrowserCdpConfig): number {
  return config.connect_timeout_ms ?? DEFAULT_CDP_CONNECT_TIMEOUT_MS
}

function objectRecord(value: unknown, label: string): JsonObject {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be a JSON object`)
  return value as JsonObject
}

function stringField(record: JsonObject, field: string): string {
  const value = record[field]
  if (typeof value !== 'string' || value.trim() === '') throw new Error(`${field} must be a non-empty string`)
  return value
}

function validateUrl(rawUrl: string, protocols: string[]): string {
  const url = new URL(rawUrl)
  if (!protocols.includes(url.protocol)) {
    throw new Error(`unsupported remote browser CDP URL protocol: ${url.protocol}`)
  }
  return url.toString()
}

function valueAtJsonPath(value: unknown, path: string[]): unknown {
  return path.reduce((current, segment) => {
    if (!current || typeof current !== 'object' || Array.isArray(current)) return undefined
    return (current as JsonObject)[segment]
  }, value)
}

function stableHeadersKey(headers: Record<string, string> | undefined): string {
  if (!headers) return ''
  return JSON.stringify(Object.entries(headers).sort(([left], [right]) => left.localeCompare(right)))
}

function redactUrl(rawUrl: string): string {
  try {
    const url = new URL(rawUrl)
    if (url.username || url.password) {
      url.username = '[redacted]'
      url.password = '[redacted]'
    }
    for (const key of Array.from(url.searchParams.keys())) {
      if (/token|key|secret|password|auth|credential/i.test(key)) url.searchParams.set(key, '[redacted]')
    }
    return url.toString()
  } catch {
    return rawUrl.replace(/\/\/([^/@]+)@/, '//[redacted]@')
  }
}

function isUnsupportedCdpMethod(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error)
  return /wasn't found|was not found|not found|unknown method|method.*not.*support|unsupported/i.test(message)
}

function isRecoverableCdpConnectionError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error)
  return /CDP socket (closed|error|is not open)|Failed to connect to browser CDP|WebSocket is not open|connection.*closed/i.test(
    message
  )
}

function waitForTermination(): Promise<void> {
  return new Promise(resolveWait => {
    const stop = () => resolveWait()
    process.once('SIGTERM', stop)
    process.once('SIGINT', stop)
  })
}

function drainProcessOutput(stream: ReadableStream<Uint8Array> | null, label: string): void {
  if (!stream) return

  const reader = stream.getReader()
  const decoder = new TextDecoder()
  let buffered = ''
  const drain = async () => {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      buffered += decoder.decode(value, { stream: true })
      const lines = buffered.split(/\r?\n/)
      buffered = lines.pop() ?? ''
      for (const line of lines) forwardProcessLogLine(label, line)
    }
    buffered += decoder.decode()
    if (buffered) forwardProcessLogLine(label, buffered)
  }
  drain().catch(() => {
    // Best-effort drain only. Browser logs are diagnostics; the session should
    // not fail because the stream closed while the child process exited.
  })
}

function forwardProcessLogLine(label: string, line: string): void {
  const trimmed = line.trimEnd()
  if (!trimmed) return
  const redacted = redactText(trimmed).slice(0, 2_000)
  process.stderr.write(`[${label}] ${redacted}\n`)
}

function snapshotScript(maxElements: number): BrowserSnapshot {
  const selectors = [
    'a[href]',
    'button',
    'input',
    'textarea',
    'select',
    'summary',
    '[role]',
    '[tabindex]',
    '[contenteditable="true"]'
  ].join(',')

  const elements = Array.from(document.querySelectorAll<Element>(selectors))
    .filter(isVisible)
    .slice(0, maxElements)
    .map((element, index) => ({
      ref: `e${index + 1}`,
      selector: cssPath(element),
      tag: element.tagName.toLowerCase(),
      role: elementRole(element),
      name: accessibleName(element),
      disabled: elementDisabled(element)
    }))

  return {
    url: location.href,
    title: document.title,
    text: document.body?.innerText || document.documentElement?.innerText || '',
    elements
  }

  function isVisible(element: Element): boolean {
    const style = getComputedStyle(element)
    if (style.visibility === 'hidden' || style.display === 'none') return false
    const rect = element.getBoundingClientRect()
    return rect.width > 0 && rect.height > 0
  }

  function elementRole(element: Element): string {
    const explicit = element.getAttribute('role')
    if (explicit) return explicit
    const tag = element.tagName.toLowerCase()
    if (tag === 'a') return 'link'
    if (tag === 'button') return 'button'
    if (tag === 'select') return 'combobox'
    if (tag === 'textarea') return 'textbox'
    if (tag === 'input') {
      const type = (element.getAttribute('type') || 'text').toLowerCase()
      if (type === 'checkbox') return 'checkbox'
      if (type === 'radio') return 'radio'
      if (type === 'submit' || type === 'button') return 'button'
      return 'textbox'
    }
    return tag
  }

  function accessibleName(element: Element): string {
    const labelledBy = element.getAttribute('aria-labelledby')
    const labelledText = labelledBy
      ?.split(/\s+/)
      .map(id => textFromElement(document.getElementById(id)))
      .join(' ')
      .trim()
    const label =
      element.getAttribute('aria-label') ||
      labelledText ||
      labelText(element) ||
      element.getAttribute('alt') ||
      element.getAttribute('placeholder') ||
      valueText(element) ||
      textFromElement(element) ||
      ''
    return label.replace(/\s+/g, ' ').trim().slice(0, 180)
  }

  function textFromElement(element: Element | null): string {
    if (!element) return ''
    try {
      if (element instanceof HTMLElement) return element.innerText || element.textContent || ''
    } catch {
      return element.textContent || ''
    }
    return element.textContent || ''
  }

  function labelText(element: Element): string {
    if (
      element instanceof HTMLInputElement ||
      element instanceof HTMLTextAreaElement ||
      element instanceof HTMLSelectElement
    ) {
      return textFromElement(element.labels?.[0] ?? null)
    }
    return ''
  }

  function valueText(element: Element): string {
    if (
      element instanceof HTMLInputElement ||
      element instanceof HTMLTextAreaElement ||
      element instanceof HTMLButtonElement
    ) {
      return element.value || ''
    }
    return ''
  }

  function elementDisabled(element: Element): boolean {
    if (
      element instanceof HTMLButtonElement ||
      element instanceof HTMLInputElement ||
      element instanceof HTMLSelectElement ||
      element instanceof HTMLTextAreaElement ||
      element instanceof HTMLOptionElement ||
      element instanceof HTMLOptGroupElement
    ) {
      return element.disabled || element.getAttribute('aria-disabled') === 'true'
    }
    return element.getAttribute('aria-disabled') === 'true'
  }

  function cssPath(element: Element): string {
    if (element.id) {
      const idSelector = `#${cssEscape(element.id)}`
      if (document.querySelectorAll(idSelector).length === 1) return idSelector
    }

    const parts: string[] = []
    let current: Element | null = element
    while (current && current.nodeType === Node.ELEMENT_NODE && current !== document.body) {
      const parent: Element | null = current.parentElement
      const tag = current.tagName.toLowerCase()
      if (!parent) {
        parts.unshift(tag)
        break
      }
      const currentTag = current.tagName
      const siblings = Array.from(parent.children).filter((child): child is Element => child.tagName === currentTag)
      const index = siblings.indexOf(current) + 1
      parts.unshift(`${tag}:nth-of-type(${index})`)
      current = parent
    }
    return `body > ${parts.join(' > ')}`
  }

  function cssEscape(value: string): string {
    return value.replace(/[^a-zA-Z0-9_-]/g, char => `\\${char}`)
  }
}

function keyDefinition(key: string): JsonObject {
  const normalized = key.length === 1 ? key : key.toLowerCase()
  const special: Record<string, { key: string; code: string; windowsVirtualKeyCode: number }> = {
    enter: { key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 },
    tab: { key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 },
    escape: { key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 },
    backspace: { key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8 },
    delete: { key: 'Delete', code: 'Delete', windowsVirtualKeyCode: 46 },
    arrowdown: { key: 'ArrowDown', code: 'ArrowDown', windowsVirtualKeyCode: 40 },
    arrowup: { key: 'ArrowUp', code: 'ArrowUp', windowsVirtualKeyCode: 38 },
    arrowleft: { key: 'ArrowLeft', code: 'ArrowLeft', windowsVirtualKeyCode: 37 },
    arrowright: { key: 'ArrowRight', code: 'ArrowRight', windowsVirtualKeyCode: 39 }
  }
  const match = special[normalized]
  if (match) return { ...match, nativeVirtualKeyCode: match.windowsVirtualKeyCode }
  const char = key[0] ?? ''
  return {
    key: char,
    code: `Key${char.toUpperCase()}`,
    text: char,
    unmodifiedText: char,
    windowsVirtualKeyCode: char.toUpperCase().charCodeAt(0),
    nativeVirtualKeyCode: char.toUpperCase().charCodeAt(0)
  }
}

function safePath(path: string): string {
  const normalized = normalize(path)
  const relative = normalized.startsWith('/workspace')
    ? normalized.slice('/workspace'.length)
    : normalized.startsWith('/')
      ? normalized
      : `/${normalized}`
  const resolved = resolve(workspaceRoot, `.${relative}`)
  const root = resolve(workspaceRoot)

  if (resolved !== root && !resolved.startsWith(`${root}/`)) {
    throw new Error('path escapes workspace root')
  }

  return resolved
}

function toWorkspacePath(path: string): string {
  const root = resolve(workspaceRoot)
  const resolved = resolve(path)
  if (resolved === root) return '/workspace'
  if (resolved.startsWith(`${root}/`)) return `/workspace/${resolved.slice(root.length + 1)}`
  return path
}

function truncate(text: string): string {
  return text.length > 8_000 ? `${text.slice(0, 8_000)}\n[truncated]` : text
}

function findTextMatches(
  text: string,
  opts: { query: string; contextLines?: number; matchLimit?: number; caseSensitive?: boolean }
): BrowserFindMatch[] {
  const contextLines = Math.max(0, Math.min(opts.contextLines ?? 4, 12))
  const matchLimit = Math.max(1, Math.min(opts.matchLimit ?? 20, 50))
  const needle = opts.caseSensitive ? opts.query : opts.query.toLowerCase()
  const lines = text
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)

  const matches: BrowserFindMatch[] = []
  for (let index = 0; index < lines.length && matches.length < matchLimit; index += 1) {
    const haystack = opts.caseSensitive ? lines[index] : lines[index].toLowerCase()
    if (!haystack.includes(needle)) continue

    matches.push({
      line: index + 1,
      text: lines[index],
      before: lines.slice(Math.max(0, index - contextLines), index),
      after: lines.slice(index + 1, Math.min(lines.length, index + contextLines + 1))
    })
  }
  return matches
}

function formatFindMatches(matches: BrowserFindMatch[]): string {
  if (matches.length === 0) return '(no matches)'

  return matches
    .map(match => {
      const lines = [`line ${match.line}: ${match.text}`]
      if (match.before.length > 0) lines.unshift(...match.before.map(line => `  ${line}`))
      if (match.after.length > 0) lines.push(...match.after.map(line => `  ${line}`))
      return lines.join('\n')
    })
    .join('\n---\n')
}

function redactText(text: string): string {
  return text
    .replace(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi, '[redacted-email]')
    .replace(/\b(?:api[_-]?key|token|secret|password)\b\s*[:=]\s*["']?[^"'\s<>,;]+/gi, match => {
      const key = match.split(/[:=]/)[0] ?? 'secret'
      return `${key}=[redacted]`
    })
}

function waitBriefly(): Promise<void> {
  return sleep(350)
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolveSleep => setTimeout(resolveSleep, ms))
}

function sanitizeId(value: string): string {
  const safe = value
    .trim()
    .replace(/[^a-zA-Z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
  return safe.slice(0, 96) || 'default'
}
