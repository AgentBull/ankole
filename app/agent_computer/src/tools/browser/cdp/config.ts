import { DEFAULT_CDP_CONNECT_TIMEOUT_MS, REMOTE_CONFIG_ENV } from './constants'
import { redactBrowserJson, redactUrl } from './utils'
import type { BrowserRuntimeOptions, JsonObject, RemoteBrowserCdpConfig, RemoteSessionResponse } from './types'

/**
 * Parses remote CDP configuration from the operator-provided environment value.
 */
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

/**
 * Resolves remote CDP configuration from per-call options, falling back to env.
 */
export function remoteBrowserCdpConfigFromOptions(options?: BrowserRuntimeOptions): RemoteBrowserCdpConfig | null {
  if (options && 'remoteCdpConfig' in options) {
    const value = options.remoteCdpConfig
    if (value === null || value === undefined) return null
    return normalizeRemoteBrowserCdpConfig(value)
  }

  return remoteBrowserCdpConfigFromEnv()
}

/**
 * Redacts a remote CDP config for diagnostics.
 */
export function redactRemoteBrowserConfig(config: RemoteBrowserCdpConfig): JsonObject {
  const redacted = redactBrowserJson(config) as JsonObject
  redactUrlFields(redacted)
  return redacted
}

/**
 * Redacts URL-like fields after generic secret redaction has run.
 */
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

/**
 * Validates the two supported remote CDP adapter shapes.
 */
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

/**
 * Parses the optional response extractor for session-request adapters.
 */
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

/**
 * Parses the optional HTTP method for session-request adapters.
 */
function optionalMethod(record: JsonObject): 'GET' | 'POST' | undefined {
  const value = record['method']
  if (value === undefined) return undefined
  if (value === 'GET' || value === 'POST') return value
  throw new Error('remote browser CDP session request method must be GET or POST')
}

/**
 * Parses string headers from a config object.
 */
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

/**
 * Parses and bounds the remote CDP connection timeout.
 */
function optionalTimeout(record: JsonObject): { connect_timeout_ms?: number } {
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
export function connectTimeoutMs(config: RemoteBrowserCdpConfig): number {
  return config.connect_timeout_ms ?? DEFAULT_CDP_CONNECT_TIMEOUT_MS
}

/**
 * Requires a JSON object and labels validation failures.
 */
function objectRecord(value: unknown, label: string): JsonObject {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be a JSON object`)
  return value as JsonObject
}

/**
 * Reads a required non-empty string field from a config object.
 */
function stringField(record: JsonObject, field: string): string {
  const value = record[field]
  if (typeof value !== 'string' || value.trim() === '') throw new Error(`${field} must be a non-empty string`)
  return value
}

/**
 * Validates a URL and restricts it to the allowed protocols.
 */
function validateUrl(rawUrl: string, protocols: string[]): string {
  const url = new URL(rawUrl)
  if (!protocols.includes(url.protocol)) {
    throw new Error(`unsupported remote browser CDP URL protocol: ${url.protocol}`)
  }
  return url.toString()
}

/**
 * Reads a nested value using the JSON path declared by a remote session adapter.
 */
export function valueAtJsonPath(value: unknown, path: string[]): unknown {
  return path.reduce((current, segment) => {
    if (!current || typeof current !== 'object' || Array.isArray(current)) return undefined
    return (current as JsonObject)[segment]
  }, value)
}
