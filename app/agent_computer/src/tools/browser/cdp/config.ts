import { isRecord, match, safeJsonParse as safeJSONParse } from '@pleisto/active-support'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { DEFAULT_CDP_CONNECT_TIMEOUT_MS, REMOTE_CONFIG_ENV } from './constants'
import type { BrowserRuntimeOptions, RemoteBrowserCDPConfig, RemoteSessionResponse } from './types'

/**
 * Parses remote CDP configuration from the operator-provided environment value.
 */
export function remoteBrowserCDPConfigFromEnv(
  env: Record<string, string | undefined> = process.env
): RemoteBrowserCDPConfig | null {
  const raw = env[REMOTE_CONFIG_ENV]
  if (!raw || raw.trim() === '' || raw.trim() === 'null') return null

  const parsed = safeJSONParse(raw).match(
    value => value,
    error => {
      throw new Error(`invalid ${REMOTE_CONFIG_ENV}: ${error instanceof Error ? error.message : String(error)}`)
    }
  )

  return normalizeRemoteBrowserCDPConfig(parsed)
}

/**
 * Resolves remote CDP configuration from per-call options, falling back to env.
 */
export function remoteBrowserCDPConfigFromOptions(options?: BrowserRuntimeOptions): RemoteBrowserCDPConfig | null {
  if (options && 'remoteCDPConfig' in options) {
    const value = options.remoteCDPConfig
    if (value === null || value === undefined) return null
    return normalizeRemoteBrowserCDPConfig(value)
  }

  return remoteBrowserCDPConfigFromEnv()
}

/**
 * Validates the two supported remote CDP adapter shapes.
 */
function normalizeRemoteBrowserCDPConfig(value: unknown): RemoteBrowserCDPConfig {
  const record = objectRecord(value, 'remote browser CDP config')
  const adapter = stringField(record, 'adapter')

  return match(adapter)
    .with('cdp_endpoint', () => ({
      adapter: 'cdp_endpoint' as const,
      endpoint_url: validateURL(stringField(record, 'endpoint_url'), ['ws:', 'wss:', 'http:', 'https:']),
      ...optionalHeaders(record, 'headers'),
      ...optionalTimeout(record)
    }))
    .with('cdp_session_request', () => {
      const request = objectRecord(record['request'], 'remote browser CDP session request')
      const response = normalizeSessionResponse(request['response'])
      return {
        adapter: 'cdp_session_request' as const,
        request: {
          url: validateURL(stringField(request, 'url'), ['http:', 'https:']),
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
    })
    .otherwise(() => {
      throw new Error(`unsupported remote browser CDP adapter: ${adapter}`)
    })
}

/**
 * Parses the optional response extractor for session-request adapters.
 */
function normalizeSessionResponse(value: unknown): RemoteSessionResponse | undefined {
  if (value === undefined) return undefined
  const response = objectRecord(value, 'remote browser CDP session response')
  const type = stringField(response, 'type')

  return match(type)
    .with('text', () => ({ type: 'text' as const }))
    .with('json', () => {
      const path = response['path']
      if (!Array.isArray(path) || !path.every(item => typeof item === 'string' && item.length > 0)) {
        throw new Error('remote browser CDP session response path must be a non-empty string array')
      }
      return { type: 'json' as const, path }
    })
    .otherwise(() => {
      throw new Error(`unsupported remote browser CDP session response type: ${type}`)
    })
}

/**
 * Parses the optional HTTP method for session-request adapters.
 */
function optionalMethod(record: JSONObject): 'GET' | 'POST' | undefined {
  const value = record['method']
  if (value === undefined) return undefined
  return match(value)
    .with('GET', 'POST', method => method)
    .otherwise(() => {
      throw new Error('remote browser CDP session request method must be GET or POST')
    })
}

/**
 * Parses string headers from a config object.
 */
function optionalHeaders(record: JSONObject, field: string): { headers?: Record<string, string> } {
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

/**
 * Parses and bounds the remote CDP connection timeout.
 */
function optionalTimeout(record: JSONObject): { connect_timeout_ms?: number } {
  const value = record['connect_timeout_ms']
  if (value === undefined) return {}
  if (!Number.isInteger(value) || (value as number) < 1_000 || (value as number) > 120_000) {
    throw new Error('remote browser CDP connect_timeout_ms must be an integer from 1000 to 120000')
  }
  return { connect_timeout_ms: value as number }
}

/**
 * Returns the configured CDP connection timeout.
 */
export function connectTimeoutMs(config: RemoteBrowserCDPConfig): number {
  return config.connect_timeout_ms ?? DEFAULT_CDP_CONNECT_TIMEOUT_MS
}

/**
 * Requires a JSON object and labels validation failures.
 */
function objectRecord(value: unknown, label: string): JSONObject {
  if (!isRecord(value)) throw new Error(`${label} must be a JSON object`)
  return value as JSONObject
}

/**
 * Reads a required non-empty string field from a config object.
 */
function stringField(record: JSONObject, field: string): string {
  const value = record[field]
  if (typeof value !== 'string' || value.trim() === '') throw new Error(`${field} must be a non-empty string`)
  return value
}

/**
 * Validates a URL and restricts it to the allowed protocols.
 */
function validateURL(rawURL: string, protocols: string[]): string {
  const url = new URL(rawURL)
  if (!protocols.includes(url.protocol)) {
    throw new Error(`unsupported remote browser CDP URL protocol: ${url.protocol}`)
  }
  return url.toString()
}

/**
 * Reads a nested value using the JSON path declared by a remote session adapter.
 */
export function valueAtJSONPath(value: unknown, path: string[]): unknown {
  return path.reduce((current, segment) => {
    if (!isRecord(current)) return undefined
    return current[segment]
  }, value)
}
