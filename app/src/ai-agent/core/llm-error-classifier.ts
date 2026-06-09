export type LlmErrorKind = 'auth' | 'overflow' | 'rate_limit' | 'server' | 'timeout' | 'unknown'

export interface LlmErrorClassification {
  kind: LlmErrorKind
  retryable: boolean
  shouldCompress: boolean
  shouldFallbackProvider: boolean
}

export function classifyLlmError(error: unknown): LlmErrorClassification {
  const status = findErrorProperty(error, ['status', 'statusCode', 'code'], value => {
    const parsed = typeof value === 'number' ? value : typeof value === 'string' ? Number.parseInt(value, 10) : NaN
    return Number.isInteger(parsed) && parsed >= 100 && parsed <= 599 ? parsed : undefined
  })
  const code =
    findErrorProperty(error, ['code'], value => (typeof value === 'string' ? value.toLowerCase() : undefined)) ?? ''
  const message = messageFromError(error)

  if (status === 401 || status === 403 || includesAny(code, ['401', '403', 'auth', 'unauthorized', 'forbidden'])) {
    return classified('auth', false, false, true)
  }

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

  if (
    status === 408 ||
    includesAny(code, ['timeout', 'timedout', 'etimedout', 'aborterror', 'und_err_socket']) ||
    includesAny(message, [
      'timeout',
      'timed out',
      'deadline exceeded',
      'socket hang up',
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

  return classified('unknown', false, false, false)
}

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

function messageFromError(error: unknown): string {
  const messages: string[] = []
  collectMessages(error, messages, new WeakSet<object>())
  return messages.join('\n').toLowerCase()
}

function includesAny(text: string, needles: string[]): boolean {
  return needles.some(needle => text.includes(needle))
}

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
