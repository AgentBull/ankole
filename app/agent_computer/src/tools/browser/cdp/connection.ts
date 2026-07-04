import { remoteBrowserCdpConfigFromOptions, connectTimeoutMs, valueAtJsonPath } from './config'
import {
  ensureLocalChromiumSidecar,
  createLocalBrowserContext,
  localBrowserIdleTtlMs,
  localSidecarKey,
  touchLocalChromiumSidecar
} from './chromium'
import { writeSessionMeta } from './session-store'
import { browserHttpUrl, localCdpEndpointAlive, redactUrl } from './utils'
import type {
  BrowserConnection,
  BrowserRuntimeOptions,
  BrowserSessionMeta,
  JsonObject,
  RemoteBrowserCdpConfig
} from './types'

/**
 * Resolves the CDP endpoint that should back an existing browser session.
 *
 * Remote session-request adapters can return a per-session WebSocket URL, so
 * the resolved URL is persisted into session metadata after the first request.
 */
export async function resolveConnectionForSession(
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

/**
 * Resolves a remote CDP config into a browser WebSocket connection.
 */
export async function resolveRemoteConnection(config: RemoteBrowserCdpConfig): Promise<BrowserConnection> {
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

/**
 * Discovers a WebSocket URL from a CDP HTTP endpoint.
 */
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

/**
 * Rewrites loopback WebSocket URLs returned by remote `/json/version`.
 *
 * Some CDP providers proxy `/json/version` but return `127.0.0.1` from the
 * browser's point of view. The worker must connect back to the provider host,
 * not to its own loopback interface.
 */
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

/**
 * Requests a new remote browser session and extracts its WebSocket URL.
 */
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
