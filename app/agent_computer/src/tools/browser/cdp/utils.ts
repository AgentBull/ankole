import { webURLFacts } from '@ankole/kernel'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import {
  resolveWorkspacePath,
  sanitizePathSegment,
  toWorkspacePath as workspaceModelPath
} from '../../../core/workspace-paths'
import { workspaceRoot } from './constants'
import type { BrowserRuntimeOptions } from './types'

/**
 * Recursively redacts browser diagnostic values before they reach logs or tool
 * output.
 */
export function redactBrowserJSON<T>(value: T): T {
  if (typeof value === 'string') return redactText(value) as T
  if (Array.isArray(value)) return value.map(item => redactBrowserJSON(item)) as T
  if (value && typeof value === 'object') {
    const output: JSONObject = {}
    for (const [key, item] of Object.entries(value)) {
      output[key] = /password|secret|token|api[_-]?key|authorization/i.test(key)
        ? '[redacted]'
        : redactBrowserJSON(item)
    }
    return output as T
  }
  return value
}

export interface BrowserURLPolicy {
  blockPrivateNetwork?: boolean
}

/**
 * Rejects model-supplied navigation URLs: cloud metadata surfaces always, and
 * non-public hosts when the `web_tools.block_private_network` policy is on.
 *
 * Parsing and host classification come from the native kernel, so this guard
 * and the AIGateway `web_fetch` validation share one classifier. Page-driven
 * navigation (real clicks, JS redirects) never passes through here; this is a
 * model input filter, not a network-layer control.
 */
export function assertSafeBrowserURL(rawURL: string, policy?: BrowserURLPolicy): void {
  const facts = webURLFacts(rawURL)
  if (facts.scheme === 'data' || facts.scheme === 'about') return
  if (facts.scheme !== 'http' && facts.scheme !== 'https') {
    throw new Error(`unsupported browser URL protocol: ${facts.scheme}:`)
  }

  if (facts.hostClass === 'metadata') {
    throw new Error('blocked browser navigation to cloud metadata endpoint')
  }
  if (policy?.blockPrivateNetwork === true && facts.hostClass === 'private') {
    throw new Error('blocked non-public URL by the web_tools.block_private_network policy')
  }
}

/**
 * Converts a browser WebSocket URL to its matching CDP HTTP URL.
 */
export function browserHTTPURL(connectURL: string, path: string): string {
  const url = new URL(connectURL)
  url.protocol = url.protocol === 'wss:' ? 'https:' : 'http:'
  url.pathname = path
  url.search = ''
  url.hash = ''
  return url.toString()
}

/**
 * Checks whether a local CDP endpoint still answers quickly.
 */
export async function localCDPEndpointAlive(connectURL: string): Promise<boolean> {
  try {
    const response = await fetch(browserHTTPURL(connectURL, '/json/version'), {
      signal: AbortSignal.timeout(1_000)
    })
    return response.ok
  } catch {
    return false
  }
}

/**
 * Builds a deterministic cache key for remote CDP headers.
 */
export function stableHeadersKey(headers: Record<string, string> | undefined): string {
  if (!headers) return ''
  return JSON.stringify(Object.entries(headers).sort(([left], [right]) => left.localeCompare(right)))
}

/**
 * Redacts credentials in a URL for logs and tool output.
 */
export function redactURL(rawURL: string): string {
  try {
    const url = new URL(rawURL)
    if (url.username || url.password) {
      url.username = '[redacted]'
      url.password = '[redacted]'
    }
    for (const key of Array.from(url.searchParams.keys())) {
      if (/token|key|secret|password|auth|credential/i.test(key)) url.searchParams.set(key, '[redacted]')
    }
    return url.toString()
  } catch {
    return rawURL.replace(/\/\/([^/@]+)@/, '//[redacted]@')
  }
}

/**
 * Detects CDP method-not-supported errors across several backend wordings.
 */
export function isUnsupportedCDPMethod(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error)
  return /wasn't found|was not found|not found|unknown method|method.*not.*support|unsupported/i.test(message)
}

/**
 * Detects CDP connection errors that are worth one local Chromium recovery.
 */
export function isRecoverableCDPConnectionError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error)
  return /CDP socket (closed|error|is not open)|Failed to connect to browser CDP|WebSocket is not open|connection.*closed/i.test(
    message
  )
}

/**
 * Drains child-process stdout/stderr into redacted worker logs.
 */
export function drainProcessOutput(stream: ReadableStream<Uint8Array> | null, label: string): void {
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

/**
 * Writes one redacted child-process log line.
 */
export function forwardProcessLogLine(label: string, line: string): void {
  const trimmed = line.trimEnd()
  if (!trimmed) return
  const redacted = redactText(trimmed).slice(0, 2_000)
  process.stderr.write(`[${label}] ${redacted}\n`)
}

/**
 * Compares browser URLs after URL normalization.
 */
export function sameBrowserURL(left: string, right: string): boolean {
  try {
    return new URL(left, 'http://invalid.local').toString() === new URL(right, 'http://invalid.local').toString()
  } catch {
    return left === right
  }
}

/**
 * Resolves a model-supplied output path under `/workspace`.
 */
export function safePath(path: string, options?: BrowserRuntimeOptions): string {
  return resolveWorkspacePath(browserWorkspaceRoot(options), path)
}

/**
 * Converts an absolute container path back to the model-facing `/workspace`
 * path when possible.
 */
export function toWorkspacePath(path: string, options?: BrowserRuntimeOptions): string {
  return workspaceModelPath(browserWorkspaceRoot(options), path)
}

/**
 * Caps long browser text before returning it as tool output.
 */
export function truncate(text: string): string {
  return text.length > 8_000 ? `${text.slice(0, 8_000)}\n[truncated]` : text
}

/**
 * Redacts common secrets and emails from browser text.
 */
export function redactText(text: string): string {
  return text
    .replace(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi, '[redacted-email]')
    .replace(/\b(?:api[_-]?key|token|secret|password)\b\s*[:=]\s*["']?[^"'\s<>,;]+/gi, match => {
      const key = match.split(/[:=]/)[0] ?? 'secret'
      return `${key}=[redacted]`
    })
}

/**
 * Gives the page a short chance to update after an input action.
 */
export function waitBriefly(): Promise<void> {
  return sleep(350)
}

/**
 * Sleeps for a fixed number of milliseconds.
 */
export function sleep(ms: number): Promise<void> {
  return new Promise(resolveSleep => setTimeout(resolveSleep, ms))
}

/**
 * Sanitizes a browser session or artifact id.
 */
export function sanitizeID(value: string, fallback = 'default'): string {
  return sanitizePathSegment(value, { fallback })
}

function browserWorkspaceRoot(options?: BrowserRuntimeOptions): string {
  return options?.workspaceRoot ?? workspaceRoot
}
