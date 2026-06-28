// Maps a raw provider/SDK error (or even a bare error string) into a small, backend-independent
// taxonomy that the runtime uses to decide retry, compaction, and user-facing wording. The provider
// surface is deliberately wide: Ankole talks to OpenAI, Anthropic, Bedrock, and OpenAI-compatible
// gateways, each of which signals the same failure differently (HTTP status, an SDK `code` string, or
// only a message). So every branch probes status + code + message and treats a hit on any of them as
// the class. The branch order is significant — auth/rate-limit/timeout/server are checked before the
// message-only overflow check, because an overflow phrase ("too many tokens") can co-occur with a 429
// or 413 and we want the transport-level class to win there.

/** Backend-independent failure class derived from a raw LLM error. */
export type LlmErrorKind = 'auth' | 'overflow' | 'rate_limit' | 'server' | 'timeout' | 'unknown'

export interface LlmErrorClassification {
  kind: LlmErrorKind
  /** Safe to re-issue the same request as-is (transient transport/capacity failures). */
  retryable: boolean
  /**
   * Advisory hint that the fix is to shrink the context, not to retry (set only for `overflow`).
   * Currently informational — the runtime acts on `kind`/`retryable`; no caller reads this field yet.
   */
  shouldCompress: boolean
  /**
   * Advisory hint that switching to a fallback provider could help. True for every class except
   * `overflow` (a context that overflows one model will overflow its peer). Like `shouldCompress`,
   * this is not yet consumed by any caller.
   */
  shouldFallbackProvider: boolean
}

/**
 * Classifies a raw error thrown by the LLM SDK or provider into an {@link LlmErrorClassification}.
 *
 * Accepts `unknown` because the error can arrive as an `Error`, a provider response object, a wrapped
 * cause chain, or a plain string; it digs through nested `cause`/`error`/`response` to find a usable
 * status, code, and message before matching.
 */
export function classifyLlmError(error: unknown): LlmErrorClassification {
  const status = findErrorProperty(error, ['status', 'statusCode', 'code'], value => {
    const parsed = typeof value === 'number' ? value : typeof value === 'string' ? Number.parseInt(value, 10) : NaN
    return Number.isInteger(parsed) && parsed >= 100 && parsed <= 599 ? parsed : undefined
  })
  const code =
    findErrorProperty(error, ['code'], value => (typeof value === 'string' ? value.toLowerCase() : undefined)) ?? ''
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
  // that surface when a streamed response is cut off partway. Retryable — the request may well
  // succeed on a fresh connection.
  if (
    status === 408 ||
    includesAny(code, ['timeout', 'timedout', 'etimedout', 'aborterror', 'und_err_socket']) ||
    includesAny(message, [
      'timeout',
      'timed out',
      'deadline exceeded',
      'socket hang up',
      'connection error',
      'network error',
      'failed to connect',
      'econnreset',
      'und_err_socket',
      'und_err_connect',
      'und_err_headers',
      'und_err_body',
      'operation was aborted',
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

  // Prompt exceeds the model's context window. Matched on message text only: providers usually return
  // this as a 400 (OpenAI `context_length_exceeded`, Anthropic "prompt is too long"), and 400 is too
  // generic to key on, so the wording is the signal. Not retryable and not a fallback candidate — the
  // only fix is to send less, hence `shouldCompress`. Reached after the status-based classes above so
  // a 413/429 that also mentions tokens is treated as throttling, not overflow.
  if (
    includesAny(message, [
      'context window',
      'context length',
      'maximum context',
      'too many tokens',
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
    ])
  ) {
    return classified('overflow', false, true, false)
  }

  // Unrecognized. Treated as fatal and provider-stable: nothing matched, so we neither retry nor fall
  // back blindly. A genuinely transient failure that lands here will surface to the user rather than
  // being silently re-tried forever.
  return classified('unknown', false, false, false)
}

/** Convenience predicate used on the retry hot path; equivalent to `classifyLlmError(error).retryable`. */
export function isRetryableLlmError(error: unknown): boolean {
  return classifyLlmError(error).retryable
}

function classified(
  kind: LlmErrorKind,
  retryable: boolean,
  shouldCompress: boolean,
  shouldFallbackProvider: boolean
): LlmErrorClassification {
  return { kind, retryable, shouldCompress, shouldFallbackProvider }
}

// Flattens every message string reachable through the error's cause chain into one lowercased blob,
// so a single `includes` scan can match a phrase that lives on a nested cause rather than the top-level
// error. Lowercased once here so all the needle lists can be written in lowercase.
function messageFromError(error: unknown): string {
  const messages: string[] = []
  collectMessages(error, messages, new WeakSet<object>())
  return messages.join('\n').toLowerCase()
}

function includesAny(text: string, needles: string[]): boolean {
  return needles.some(needle => text.includes(needle))
}

// Walks the error and its `cause`/`error`/`response` children looking for the first property in `keys`
// that `parse` accepts. Tries the keys on the current object before recursing, so a status on the
// outer error wins over one buried deeper. The WeakSet + depth cap defend against cyclic error graphs
// (an error whose `cause` points back at itself) and pathologically deep wrapping.
function findErrorProperty<T>(
  error: unknown,
  keys: string[],
  parse: (value: unknown) => T | undefined,
  seen = new WeakSet<object>(),
  depth = 0
): T | undefined {
  if (!error || typeof error !== 'object' || seen.has(error) || depth > 25) return undefined
  seen.add(error)
  const record = error as Record<string, unknown>
  for (const key of keys) {
    const parsed = parse(record[key])
    if (parsed !== undefined) return parsed
  }
  for (const key of ['cause', 'error', 'response']) {
    const parsed = findErrorProperty(record[key], keys, parse, seen, depth + 1)
    if (parsed !== undefined) return parsed
  }
}

// Recursive companion to messageFromError: appends this node's message, then descends into
// cause/error/response. Same cycle/depth guards as findErrorProperty. Accepts both real Error objects
// and plain `{ message }` shapes because provider SDKs return either.
function collectMessages(error: unknown, messages: string[], seen: WeakSet<object>, depth = 0): void {
  if (error === undefined || error === null || depth > 25) return
  if (typeof error === 'string') {
    messages.push(error)
    return
  }
  if (typeof error !== 'object') {
    messages.push(String(error))
    return
  }
  if (seen.has(error)) return
  seen.add(error)
  const record = error as Record<string, unknown>
  if (error instanceof Error) messages.push(error.message)
  else if (typeof record.message === 'string') messages.push(record.message)
  for (const key of ['cause', 'error', 'response']) collectMessages(record[key], messages, seen, depth + 1)
}
