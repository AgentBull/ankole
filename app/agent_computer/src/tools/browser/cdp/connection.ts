import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { remoteBrowserCDPConfigFromOptions, connectTimeoutMs, valueAtJSONPath } from './config'
import {
  ensureLocalChromiumSidecar,
  createLocalBrowserContext,
  localBrowserIdleTtlMs,
  localSidecarKey,
  touchLocalChromiumSidecar
} from './chromium'
import { writeSessionMeta } from './session-store'
import { localCDPEndpointAlive, redactURL } from './utils'
import type { BrowserConnection, BrowserRuntimeOptions, BrowserSessionMeta, RemoteBrowserCDPConfig } from './types'

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
  const remoteConfig = remoteBrowserCDPConfigFromOptions(options)
  if (remoteConfig) {
    const connection =
      remoteConfig.adapter === 'cdp_endpoint'
        ? await resolveRemoteConnection(remoteConfig)
        : meta.connect_url
          ? {
              backend: 'remote_cdp' as const,
              adapter: meta.adapter,
              connectURL: meta.connect_url,
              redactedConnectURL: meta.connect_url_redacted ?? redactURL(meta.connect_url),
              headers: remoteConfig.headers
            }
          : await resolveRemoteConnection(remoteConfig)

    if (!meta.connect_url && connection.connectURL) {
      writeSessionMeta(
        session,
        {
          ...meta,
          connect_url: connection.connectURL,
          connect_url_redacted: connection.redactedConnectURL,
          connect_url_source: 'session'
        },
        options
      )
    }

    return connection
  }

  if (meta.backend === 'remote_cdp') {
    throw new Error('browser session was created for remote CDP, but no remote CDP config is currently set')
  }

  if (meta.backend === 'chromium') {
    const sidecarKey = meta.local_sidecar_key ?? localSidecarKey()
    const idleTtlMs = localBrowserIdleTtlMs(options)
    if (meta.connect_url && (await localCDPEndpointAlive(meta.connect_url))) {
      touchLocalChromiumSidecar(sidecarKey, idleTtlMs)
      if (!meta.browser_context_id || !meta.target_id) {
        const context = await createLocalBrowserContext(meta.connect_url)
        writeSessionMeta(
          session,
          {
            ...meta,
            browser_context_id: context.browserContextID,
            target_id: context.targetID
          },
          options
        )
      }
      return {
        backend: 'chromium',
        adapter: 'chromium',
        connectURL: meta.connect_url,
        redactedConnectURL: meta.connect_url_redacted ?? redactURL(meta.connect_url)
      }
    }

    const sidecar = await ensureLocalChromiumSidecar(sidecarKey, idleTtlMs, options?.workspaceRoot)
    const sidecarChanged = meta.connect_url !== sidecar.connectURL || meta.pid !== sidecar.proc.pid
    const context =
      sidecarChanged || !meta.browser_context_id || !meta.target_id
        ? await createLocalBrowserContext(sidecar.connectURL)
        : { browserContextID: meta.browser_context_id, targetID: meta.target_id }
    if (sidecarChanged || meta.browser_context_id !== context.browserContextID || meta.target_id !== context.targetID) {
      writeSessionMeta(
        session,
        {
          ...meta,
          local_sidecar_key: sidecar.key,
          pid: sidecar.proc.pid,
          connect_url: sidecar.connectURL,
          connect_url_redacted: redactURL(sidecar.connectURL),
          connect_url_source: 'session',
          browser_context_id: context.browserContextID,
          target_id: context.targetID
        },
        options
      )
    }
    return {
      backend: 'chromium',
      adapter: 'chromium',
      connectURL: sidecar.connectURL,
      redactedConnectURL: redactURL(sidecar.connectURL)
    }
  }

  throw new Error('unsupported browser session backend')
}

/**
 * Resolves a remote CDP config into a browser WebSocket connection.
 */
export async function resolveRemoteConnection(config: RemoteBrowserCDPConfig): Promise<BrowserConnection> {
  if (config.adapter === 'cdp_endpoint') {
    const endpoint = new URL(config.endpoint_url)
    const connectURL =
      endpoint.protocol === 'ws:' || endpoint.protocol === 'wss:'
        ? endpoint.toString()
        : await discoverWebSocketURL(endpoint.toString(), config.headers, connectTimeoutMs(config))

    return {
      backend: 'remote_cdp',
      adapter: 'cdp_endpoint',
      connectURL,
      redactedConnectURL: redactURL(connectURL),
      headers: config.headers
    }
  }

  const connectURL = await requestRemoteSession(config)
  return {
    backend: 'remote_cdp',
    adapter: 'cdp_session_request',
    connectURL,
    redactedConnectURL: redactURL(connectURL),
    headers: config.headers
  }
}

/**
 * Discovers a WebSocket URL from a CDP HTTP endpoint.
 */
async function discoverWebSocketURL(
  endpointURL: string,
  headers: Record<string, string> | undefined,
  timeoutMs: number
): Promise<string> {
  const url = new URL(endpointURL)
  if (!url.pathname || url.pathname === '/') {
    url.pathname = '/json/version'
  }
  const response = await fetch(url, {
    headers,
    signal: AbortSignal.timeout(timeoutMs)
  })
  if (!response.ok) throw new Error(`CDP /json/version failed with HTTP ${response.status}`)
  const body = (await response.json()) as JSONObject
  const connectURL = body['webSocketDebuggerUrl']
  if (typeof connectURL !== 'string' || connectURL.length === 0) {
    throw new Error('CDP /json/version response is missing webSocketDebuggerUrl')
  }
  return normalizeDiscoveredWebSocketURL(connectURL, url)
}

/**
 * Rewrites loopback WebSocket URLs returned by remote `/json/version`.
 *
 * Some CDP providers proxy `/json/version` but return `127.0.0.1` from the
 * browser's point of view. The worker must connect back to the provider host,
 * not to its own loopback interface.
 */
function normalizeDiscoveredWebSocketURL(connectURL: string, endpointURL: URL): string {
  const wsURL = new URL(connectURL)
  const isLoopback =
    wsURL.hostname === '127.0.0.1' ||
    wsURL.hostname === '::1' ||
    wsURL.hostname === '[::1]' ||
    wsURL.hostname === 'localhost'
  if (!isLoopback) return wsURL.toString()

  wsURL.hostname = endpointURL.hostname
  wsURL.port = endpointURL.port
  wsURL.protocol = endpointURL.protocol === 'https:' ? 'wss:' : 'ws:'
  return wsURL.toString()
}

/**
 * Requests a new remote browser session and extracts its WebSocket URL.
 */
async function requestRemoteSession(config: Extract<RemoteBrowserCDPConfig, { adapter: 'cdp_session_request' }>) {
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

  const body = (await response.json()) as JSONObject
  const value = valueAtJSONPath(body, responseSpec.path)
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`remote CDP session JSON response is missing ${responseSpec.path.join('.')}`)
  }
  return value
}
