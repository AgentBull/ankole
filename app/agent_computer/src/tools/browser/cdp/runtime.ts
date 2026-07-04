import { CdpClient } from './client'
import {
  ensureLocalChromiumSidecar,
  createLocalBrowserContext,
  localBrowserIdleTtlMs,
  localSidecarKey,
  setLocalChromiumSessionCloser,
  stopLocalSidecarByKey
} from './chromium'
import { resolveConnectionForSession } from './connection'
import { attachPage } from './page'
import { readRefs, readSessionMeta, writeSessionMeta } from './session-store'
import { isRecoverableCdpConnectionError, redactUrl, sanitizeId, stableHeadersKey } from './utils'
import type { BrowserConnection, BrowserRef, BrowserRuntimeOptions, BrowserSessionMeta, PageSession } from './types'

interface ActiveBrowserSession {
  cdp: CdpClient
  page: PageSession
  connectUrl: string
  headersKey: string
}

const activeBrowserSessions = new Map<string, ActiveBrowserSession>()

/**
 * Runs an operation against the active page for a browser session.
 *
 * CDP connections are cached per session, but the on-disk session metadata is
 * the source of truth. If local Chromium disappeared, the caller can opt into
 * one recovery attempt that creates a fresh context and retries the operation.
 */
export async function withPage<T>(
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

/**
 * Drops the cached CDP connection for a session.
 */
export function forgetActiveBrowserSession(session: string): void {
  const active = activeBrowserSessions.get(session)
  if (!active) return
  activeBrowserSessions.delete(session)
  active.cdp.close()
}

/**
 * Restarts local Chromium for a session after a recoverable disconnect.
 *
 * Remote CDP recovery is not attempted here because the remote backend may have
 * provider-owned session semantics the worker should not guess.
 */
export async function recoverLocalChromiumConnection(
  session: string,
  meta: BrowserSessionMeta,
  options?: BrowserRuntimeOptions
): Promise<BrowserConnection> {
  const sidecarKey = meta.local_sidecar_key ?? localSidecarKey()
  await stopLocalSidecarByKey(sidecarKey)

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

/**
 * Returns the cached active page or attaches a new CDP session.
 *
 * Header changes are part of the cache key because remote CDP services often
 * use per-request auth headers.
 */
export async function activePageForSession(
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

/**
 * Resolves a snapshot ref and runs an operation against that element.
 *
 * Refs are intentionally snapshot-scoped. A stale ref asks the model to take a
 * new snapshot instead of guessing at a changed DOM.
 */
export async function actOnRef<T>(
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

/**
 * Closes cached CDP clients attached to a browser endpoint that is going away.
 */
export function closeActiveSessionsForConnectUrl(connectUrl: string): void {
  for (const [session, active] of activeBrowserSessions) {
    if (active.connectUrl === connectUrl) {
      active.cdp.close()
      activeBrowserSessions.delete(session)
    }
  }
}

setLocalChromiumSessionCloser(closeActiveSessionsForConnectUrl)
