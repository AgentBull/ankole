export type LlmErrorKind = 'auth' | 'overflow' | 'rate_limit' | 'server' | 'timeout' | 'unknown'

export interface LlmErrorClassification {
  kind: LlmErrorKind
  retryable: boolean
  shouldCompress: boolean
  shouldFallbackProvider: boolean
}

export function classifyLlmError(error: unknown): LlmErrorClassification {
  const status = statusFromError(error)
  const code = codeFromError(error)
  const message = messageFromError(error)

  if (status === 401 || status === 403 || includesAny(code, ['401', '403', 'auth', 'unauthorized', 'forbidden'])) {
    return classified('auth', false, false, true)
  }

  if (
    status === 429 ||
    includesAny(code, ['429', 'rate_limit', 'rate-limit', 'ratelimit']) ||
    includesAny(message, ['rate limit', 'rate_limit', 'too many requests', 'retry after'])
  ) {
    return classified('rate_limit', true, false, true)
  }

  if (
    status === 408 ||
    includesAny(code, ['timeout', 'timedout', 'etimedout', 'aborterror']) ||
    includesAny(message, ['timeout', 'timed out', 'deadline exceeded', 'socket hang up', 'econnreset'])
  ) {
    return classified('timeout', true, false, true)
  }

  if (
    (typeof status === 'number' && status >= 500) ||
    includesAny(code, ['500', '502', '503', '504', 'server_error', 'internal']) ||
    includesAny(message, ['internal server error', 'bad gateway', 'service unavailable', 'gateway timeout'])
  ) {
    return classified('server', true, false, true)
  }

  if (includesAny(message, ['context window', 'context length', 'maximum context', 'too many tokens'])) {
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

function statusFromError(error: unknown): number | undefined {
  if (!error || typeof error !== 'object') return undefined
  for (const key of ['status', 'statusCode', 'code']) {
    const value = (error as Record<string, unknown>)[key]
    const parsed = typeof value === 'number' ? value : typeof value === 'string' ? Number.parseInt(value, 10) : NaN
    if (Number.isInteger(parsed) && parsed >= 100 && parsed <= 599) return parsed
  }
  return undefined
}

function codeFromError(error: unknown): string {
  if (!error || typeof error !== 'object') return ''
  const code = (error as Record<string, unknown>).code
  return typeof code === 'string' ? code.toLowerCase() : ''
}

function messageFromError(error: unknown): string {
  return error instanceof Error ? error.message.toLowerCase() : String(error).toLowerCase()
}

function includesAny(text: string, needles: string[]): boolean {
  return needles.some(needle => text.includes(needle))
}
