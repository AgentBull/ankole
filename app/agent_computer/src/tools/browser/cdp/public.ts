import { mkdirSync } from 'node:fs'
import { resolve } from 'node:path'
import type { JsonObject } from '@pleisto/active-support'
import { CdpClient } from './client'
import { BROWSER_NAVIGATION_ATTEMPTS, DEFAULT_BROWSER_COMMAND_TIMEOUT_MS, DEFAULT_WAIT_MS } from './constants'
import {
  createLocalBrowserContext,
  ensureLocalChromiumSidecar,
  localBrowserIdleTtlMs,
  localSidecarKey
} from './chromium'
import { remoteBrowserCdpConfigFromOptions } from './config'
import { resolveConnectionForSession, resolveRemoteConnection } from './connection'
import { captureScreenshot, captureSnapshot, evaluate, waitForReadyState, waitPredicate } from './page'
import { actOnRef, forgetActiveBrowserSession, withPage } from './runtime'
import { browserRoot, readSessionMeta, writeSessionMeta } from './session-store'
import {
  assertSafeBrowserUrl,
  redactBrowserJson,
  redactText,
  redactUrl,
  sameBrowserUrl,
  sanitizeId,
  sleep,
  toWorkspacePath,
  truncate,
  waitBriefly
} from './utils'
import {
  browserNavigationFailureReason,
  findTextMatches,
  formatFindMatches,
  formatSnapshot,
  keyDefinition
} from './snapshot'
import type {
  BrowserRuntimeOptions,
  BrowserSessionMeta,
  BrowserSnapshot,
  PageNavigateResult,
  PageSession
} from './types'

/**
 * Ensures a named browser session exists before a tool uses it.
 */
export async function ensureBrowserSession(
  args: { session: string | undefined },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  const session = sanitizeId(args.session || 'default')
  const status = await browserStatus({ session }, options)
  if (status.ok === true) return status
  return await startBrowserSession(session, options)
}

/**
 * Releases a browser session's isolated BrowserContext when possible.
 *
 * The local sidecar process can remain alive for other sessions; release is
 * about session isolation, not necessarily killing Chromium.
 */
export async function releaseBrowserSession(
  args: { session: string | undefined },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  const session = sanitizeId(args.session || 'default')
  forgetActiveBrowserSession(session)

  const meta = readSessionMeta(session, options)
  let browserContextDisposed = false
  let browserContextDisposeError: string | undefined
  if (meta?.browser_context_id) {
    try {
      const connection = await resolveConnectionForSession(session, meta, options)
      const cdp = await CdpClient.connect(connection.connectUrl, {
        headers: connection.headers,
        timeoutMs: DEFAULT_BROWSER_COMMAND_TIMEOUT_MS
      })
      try {
        await cdp.send(
          'Target.disposeBrowserContext',
          { browserContextId: meta.browser_context_id },
          undefined,
          DEFAULT_BROWSER_COMMAND_TIMEOUT_MS
        )
        browserContextDisposed = true
      } finally {
        cdp.close()
      }
    } catch (error) {
      browserContextDisposeError = error instanceof Error ? error.message : String(error)
    }

    const {
      browser_context_id: _browserContextId,
      target_id: _targetId,
      ...updated
    } = readSessionMeta(session, options) ?? meta
    writeSessionMeta(session, updated, options)
  }

  return {
    ok: true,
    session,
    released: true,
    browser_context_disposed: browserContextDisposed,
    ...(browserContextDisposeError ? { browser_context_dispose_error: browserContextDisposeError } : {})
  }
}

/**
 * Creates session metadata for either a remote CDP backend or local Chromium.
 */
async function startBrowserSession(session: string, options?: BrowserRuntimeOptions): Promise<JsonObject> {
  const remoteConfig = remoteBrowserCdpConfigFromOptions(options)

  const root = browserRoot(session, options)
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
    writeSessionMeta(session, meta, options)

    return {
      ok: true,
      backend: 'remote_cdp',
      adapter: remoteConfig.adapter,
      session,
      pid: null,
      connect_url: connection.redactedConnectUrl
    }
  }

  const sidecar = await ensureLocalChromiumSidecar(
    localSidecarKey(),
    localBrowserIdleTtlMs(options),
    options?.workspaceRoot
  )
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
  writeSessionMeta(session, meta, options)

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

/**
 * Checks whether the saved browser session can still reach its CDP backend.
 */
export async function browserStatus(
  args: { session: string | undefined },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  const session = sanitizeId(args.session || 'default')

  const meta = readSessionMeta(session, options)
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
      timeoutMs: DEFAULT_BROWSER_COMMAND_TIMEOUT_MS
    })
    let body: JsonObject
    try {
      body = await cdp.send<JsonObject>('Browser.getVersion', {}, undefined, DEFAULT_BROWSER_COMMAND_TIMEOUT_MS)
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

/**
 * Navigates the active page and returns a fresh model-readable snapshot.
 *
 * Navigation is retried a small number of times because local Chromium can
 * briefly surface transient network error pages during initial connection or
 * redirects.
 */
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
        snapshot = await captureSnapshot(cdp, page, session, options)
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
        Object.assign(result, await captureScreenshot(cdp, page, session, args.taskId, undefined, options))
      }
      return result
    },
    { retryLocalDisconnect: true }
  )
}

/**
 * Captures the current page snapshot without changing browser state.
 */
export async function browserSnapshot(
  args: { session: string | undefined; full?: boolean },
  options?: BrowserRuntimeOptions
): Promise<JsonObject> {
  return withPage(
    args.session,
    options,
    async (cdp, page, session, connection) => {
      const snapshot = await captureSnapshot(cdp, page, session, options)
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

/**
 * Searches the current page text and returns bounded context around matches.
 */
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

/**
 * Clicks a snapshot ref and returns the resulting page snapshot.
 *
 * Some pages swallow synthetic mouse events on links; when the URL did not
 * change and the ref had an href, a direct Page.navigate fallback keeps normal
 * link-click workflows usable.
 */
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
    let snapshot = await captureSnapshot(cdp, page, session, options)
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
      snapshot = await captureSnapshot(cdp, page, session, options)
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

/**
 * Sets text on an input-like ref and dispatches input/change events.
 *
 * The value setter is called through the element prototype when possible so
 * React-style controlled inputs observe the update.
 */
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
    const snapshot = await captureSnapshot(cdp, page, session, options)
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

/**
 * Presses one keyboard key through CDP input events.
 */
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
    const snapshot = await captureSnapshot(cdp, page, session, options)
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

/**
 * Scrolls either the page or a referenced scrollable element.
 */
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
      const snapshot = await captureSnapshot(cdp, page, session, options)
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
    const snapshot = await captureSnapshot(cdp, page, session, options)
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

/**
 * Selects an option by value or visible text on a referenced `<select>`.
 */
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
    const snapshot = await captureSnapshot(cdp, page, session, options)
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

/**
 * Waits for page readiness, text, or selector presence.
 */
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
      const timeoutMs = Math.max(1_000, args.timeoutMs ?? DEFAULT_WAIT_MS)
      const started = Date.now()
      let nextFallbackProbeAt = started + 2_000
      while (Date.now() - started < timeoutMs) {
        const allowReadyProbe = Date.now() >= nextFallbackProbeAt
        if (allowReadyProbe) nextFallbackProbeAt = Date.now() + 1_000
        const ok = await waitPredicate(cdp, page, args, { allowReadyProbe })
        if (ok) {
          const snapshot = await captureSnapshot(cdp, page, session, options)
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

/**
 * Navigates to the previous browser history entry.
 */
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
      const snapshot = await captureSnapshot(cdp, page, session, options)
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

/**
 * Clears navigation markers before an operation that should wait for a fresh
 * load signal.
 */
function resetPageNavigationState(page: PageSession): void {
  page.mainContextId = undefined
  page.domContentEventAtUnixMs = undefined
  page.loadEventAtUnixMs = undefined
  page.mainFrameStoppedLoadingAtUnixMs = undefined
}

/**
 * Captures a screenshot from the current page into the worker workspace.
 */
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
      const screenshot = await captureScreenshot(cdp, page, session, args.taskId, args.path, options)
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

/**
 * Fetches readable text through the browser session, optionally navigating first.
 *
 * This powers local-browser web_fetch fallback where rendered page text is more
 * useful than raw HTTP and still goes through the same browser safety checks.
 */
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
