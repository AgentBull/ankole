// Maps a raw provider/SDK error (or even a bare error string) into a small, backend-independent
// taxonomy that the runtime uses to decide retry, compaction, and user-facing wording. The provider
// surface is deliberately wide: Ankole talks to OpenAI, Anthropic, Bedrock, and OpenAI-compatible
// gateways, each of which signals the same failure differently (HTTP status, an SDK `code` string, or
// only a message). So every branch probes status + code + message and treats a hit on any of them as
// the class. The branch order is significant — auth/rate-limit/timeout/server are checked before the
// message-only overflow check, because an overflow phrase ("too many tokens") can co-occur with a 429
// or 413 and we want the transport-level class to win there.

import { match, P } from '@agentbull/active-support'
import { isRecord } from '@agentbull/active-support'
import type { JsonObject as JSONObject } from '@agentbull/active-support'

/** Backend-independent failure class derived from a raw LLM error. */
export type LLMErrorKind = 'auth' | 'content_filter' | 'overflow' | 'rate_limit' | 'server' | 'timeout' | 'unknown'

export interface LLMErrorClassification {
  kind: LLMErrorKind
  /** Safe to re-issue the same request as-is (transient transport/capacity failures). */
  retryable: boolean
  /**
   * Advisory hint that the fix is to shrink the context, not to retry (set only for `overflow`).
   */
  shouldCompress: boolean
  /**
   * Advisory hint that switching to a fallback provider could help. False for classes whose fix
   * is not a different provider, such as `overflow` and `content_filter`.
   */
  shouldFallbackProvider: boolean
}

/**
 * Classifies a raw error thrown by the LLM SDK or provider into an {@link LLMErrorClassification}.
 *
 * Accepts `unknown` because the error can arrive as an `Error`, a provider response object, a wrapped
 * cause chain, or a plain string; it digs through nested `cause`/`error`/`response` to find a usable
 * status, code, and message before matching.
 */
export function classifyLLMError(error: unknown): LLMErrorClassification {
  const classification = classifyLLMErrorBySignals(error)
  const retryable = findErrorProperty(error, ['retryable'], value => (typeof value === 'boolean' ? value : undefined))
  return retryable === undefined ? classification : { ...classification, retryable }
}

function classifyLLMErrorBySignals(error: unknown): LLMErrorClassification {
  const status = findErrorProperty(error, ['status', 'statusCode', 'code'], value => {
    const parsed = typeof value === 'number' ? value : typeof value === 'string' ? Number.parseInt(value, 10) : NaN
    return Number.isInteger(parsed) && parsed >= 100 && parsed <= 599 ? parsed : undefined
  })
  const code = llmErrorCode(error)?.toLowerCase() ?? ''
  const message = messageFromError(error)

  // Bad/expired API key, disabled org, or region/model not permitted (OpenAI 401, Bedrock 403).
  // Not retryable: the same credentials will keep failing. Fallback provider may have valid keys.
  if (status === 401 || status === 403 || includesAny(code, ['401', '403', 'auth', 'unauthorized', 'forbidden'])) {
    return classified('auth', false, false, true)
  }

  // Throttling: OpenAI 429 / `rate_limit_exceeded`, Bedrock `ThrottlingException`, Vertex
  // `RESOURCE_EXHAUSTED`, plus TPM/RPM and gateway "model_cooldown" / Chinese quota phrasings. The
  // trailing 413 clause catches gateways that report a per-minute *token* budget as 413 rather than
  // 429 — that is still throttling, not a context overflow. Retryable after a short backoff.
  if (
    status === 429 ||
    includesAny(code, ['429', 'rate_limit', 'rate-limit', 'ratelimit', 'resource_exhausted', 'throttlingexception']) ||
    containsHTTPStatus(message, 429) ||
    includesAny(message, [
      'rate limit',
      'rate_limit',
      'too many requests',
      'retry after',
      'resource exhausted',
      'throttlingexception',
      'tokens per minute',
      'requests per minute',
      'model_cooldown',
      '请求过于频繁',
      '频率限制',
      '配额已用尽'
    ]) ||
    (status === 413 && includesAny(message, ['tpm', 'tokens per minute']))
  ) {
    return classified('rate_limit', true, false, true)
  }

  // Transport reset / stall: HTTP 408, an aborted/timed-out fetch, or a dropped socket mid-stream.
  // The `und_err_*` codes are Node/undici internals (headers/body/connect timeouts, socket teardown)
  // that surface when a streamed response is cut off partway. The `websocket_*_failed` codes are the
  // AIGateway kernel's upstream WebSocket leg (connect/send/read teardown), which the gateway itself
  // treats as retryable transport; they arrive here verbatim in mid-stream error frames. Retryable —
  // the request may well succeed on a fresh connection.
  if (
    status === 408 ||
    includesAny(code, [
      'timeout',
      'timedout',
      'etimedout',
      'aborterror',
      'aigateway_websocket_',
      'und_err_socket',
      'upstream_read_failed',
      'upstream_stream_closed',
      'websocket_connect_failed',
      'websocket_read_failed',
      'websocket_send_failed',
      'closed_before_terminal'
    ]) ||
    includesAny(message, [
      'timeout',
      'timed out',
      'deadline exceeded',
      'socket hang up',
      'connection error',
      'network error',
      'failed to connect',
      'aigateway websocket transport error',
      'aigateway websocket closed before open',
      'aigateway websocket closed before response.completed',
      'llm provider call aborted',
      'econnreset',
      'und_err_socket',
      'und_err_connect',
      'und_err_headers',
      'und_err_body',
      'operation was aborted',
      'stream disconnected',
      'stream closed before completion',
      'upstream_stream_closed',
      'upstream stream closed',
      'closed before terminal event',
      'stream_read_error',
      'terminated'
    ])
  ) {
    return classified('timeout', true, false, true)
  }

  // Provider-side fault: any 5xx, plus Anthropic's 529 "Overloaded" and the matching
  // `overloaded_error` code, and capacity/"temporarily unavailable" phrasings from gateways. (529 is
  // listed explicitly as well as caught by `>= 500` to keep it covered even when only a code/message
  // is present and no numeric status was found.) Retryable.
  if (
    (typeof status === 'number' && status >= 500) ||
    status === 529 ||
    [502, 503, 504].some(upstreamStatus => containsHTTPStatus(message, upstreamStatus)) ||
    includesAny(code, ['500', '502', '503', '504', '529', 'server_error', 'internal', 'overloaded_error']) ||
    includesAny(message, [
      'internal server error',
      'bad gateway',
      'service unavailable',
      'gateway timeout',
      'overloaded',
      'capacity',
      'temporarily unavailable'
    ])
  ) {
    return classified('server', true, false, true)
  }

  // Safety truncation: the provider stopped the response for content policy reasons. Not retryable,
  // not compressible, and not a fallback-provider candidate because the response must not be surfaced
  // as a normal assistant reply.
  if (
    includesAny(code, ['content_filter', 'content-filter']) ||
    includesAny(message, ['content_filter', 'content-filter', 'content filter'])
  ) {
    return classified('content_filter', false, false, false)
  }

  // Prompt exceeds the model's context window. Matched on message text only: providers usually return
  // this as a 400 (OpenAI `context_length_exceeded`, Anthropic "prompt is too long"), and 400 is too
  // generic to key on, so the wording is the signal. Not retryable and not a fallback candidate — the
  // only fix is to send less, hence `shouldCompress`. Legacy terminal-error paths can also surface
  // max_output_tokens as a bare error string; the WebSocket terminal mapper should handle that as
  // `length` first, but the classifier keeps this fallback for durable error details already in flight.
  // Reached after the status-based classes above so a 413/429 that also mentions tokens is treated as
  // throttling, not overflow.
  if (
    includesAny(message, [
      'context window',
      'context length',
      'maximum context',
      'too many tokens',
      'max_output_tokens',
      'max output tokens',
      'maximum output tokens',
      'prompt is too long',
      'context_window_exceeded',
      'model_context_window_exceeded',
      'context overflow',
      'exceed context limit',
      'exceeds model context window',
      '上下文过长',
      '上下文长度',
      '请压缩上下文',
      '超过最大上下文'
    ]) ||
    includesAny(code, ['context_overflow', 'context_length_exceeded', 'context_window_exceeded'])
  ) {
    return classified('overflow', false, true, false)
  }

  // Unrecognized. Treated as fatal and provider-stable: nothing matched, so we neither retry nor fall
  // back blindly. A genuinely transient failure that lands here will surface to the user rather than
  // being silently re-tried forever.
  return classified('unknown', false, false, false)
}

/** Returns the most specific structured or rendered provider error code. */
export function llmErrorCode(error: unknown): string | undefined {
  const renderedCode = messageFromError(error).match(/\bcode=([a-z0-9_.:-]+)\b/)?.[1]
  if (renderedCode) return renderedCode

  return findErrorProperty(error, ['code'], value => (typeof value === 'string' && value ? value : undefined))
}

/** Convenience predicate used on the retry hot path; equivalent to `classifyLLMError(error).retryable`. */
export function isRetryableLLMError(error: unknown): boolean {
  return classifyLLMError(error).retryable
}

/**
 * Local retries re-issue the request from inside the worker. A transport owner can use an explicit
 * local hint when only durable redelivery is safe.
 */
export function isLocallyRetryableLLMError(error: unknown): boolean {
  if (!isRetryableLLMError(error)) return false

  const hint = localRetryableHint(error)
  return hint ?? true
}

/**
 * Builds the normalized classification object.
 */
function classified(
  kind: LLMErrorKind,
  retryable: boolean,
  shouldCompress: boolean,
  shouldFallbackProvider: boolean
): LLMErrorClassification {
  return { kind, retryable, shouldCompress, shouldFallbackProvider }
}

/**
 * Flattens every message string reachable through the error's cause chain into
 * one lowercased blob.
 *
 * A phrase can live on a nested cause rather than the top-level error; lowering
 * once here keeps the classifier branches simple.
 */
function messageFromError(error: unknown): string {
  const messages: string[] = []
  collectMessages(error, messages, new WeakSet<object>())
  return messages.join('\n').toLowerCase()
}

/**
 * Checks whether text contains any known classifier phrase.
 */
function includesAny(text: string, needles: string[]): boolean {
  return needles.some(needle => text.includes(needle))
}

/**
 * Finds an HTTP status code in free-form text without matching larger numbers.
 */
function containsHTTPStatus(text: string, status: number): boolean {
  return new RegExp(`(^|\\D)${status}(\\D|$)`).test(text)
}

/**
 * Reads the AIGateway local-retry hint from structured error details.
 */
function localRetryableHint(error: unknown): boolean | undefined {
  if (!error || typeof error !== 'object') return undefined
  const record = error as JSONObject
  const details = record.details
  if (!isRecord(details)) return undefined
  const value = details.local_retryable
  return typeof value === 'boolean' ? value : undefined
}

/**
 * Walks the error graph looking for the first property accepted by `parse`.
 *
 * Current-object fields win over nested fields. WeakSet and depth guards defend
 * against cyclic SDK error graphs and very deep wrapper chains.
 */
function findErrorProperty<T>(
  error: unknown,
  keys: string[],
  parse: (value: unknown) => T | undefined,
  seen = new WeakSet<object>(),
  depth = 0
): T | undefined {
  if (!error || typeof error !== 'object' || seen.has(error) || depth > 25) return undefined
  seen.add(error)
  const record = error as JSONObject
  for (const key of keys) {
    const parsed = parse(record[key])
    if (parsed !== undefined) return parsed
  }
  for (const key of ['cause', 'error', 'response']) {
    const parsed = findErrorProperty(record[key], keys, parse, seen, depth + 1)
    if (parsed !== undefined) return parsed
  }
}

/**
 * Collects message strings from one error node and its common wrapper children.
 */
function collectMessages(error: unknown, messages: string[], seen: WeakSet<object>, depth = 0): void {
  if (error === undefined || error === null || depth > 25) return
  const scalarMessage = match(error)
    .with(P.string, value => value)
    .when(
      value => typeof value !== 'object',
      value => String(value)
    )
    .otherwise(() => undefined)
  if (scalarMessage !== undefined) {
    messages.push(scalarMessage)
    return
  }

  if (seen.has(error)) return
  seen.add(error)
  const record = error as JSONObject
  match(error)
    .when(
      (value): value is Error => value instanceof Error,
      value => messages.push(value.message)
    )
    .with({ message: P.string }, value => messages.push(value.message))
    .otherwise(() => undefined)
  for (const key of ['cause', 'error', 'response']) collectMessages(record[key], messages, seen, depth + 1)
}
