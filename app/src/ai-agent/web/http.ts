import { createCombinedAbortSignal, withRetry } from '@/common/async'
import { ms } from '@pleisto/active-support'
import { WebProviderError } from './provider'

const DEFAULT_TIMEOUT_MS = ms('30s')

/**
 * Classifies an HTTP status as worth retrying. Covers the transient cases only:
 * request timeout (408), too-early (425), rate-limit (429), and any 5xx server
 * error. A 4xx other than these is a caller/contract problem (bad key, bad query)
 * that a retry cannot fix, so it is treated as terminal.
 */
export function isRetryableStatus(status: number): boolean {
  return status === 408 || status === 425 || status === 429 || (status >= 500 && status <= 599)
}

/**
 * POST/GET JSON helper shared by web providers. Maps transport errors and
 * non-2xx responses to `WebProviderError` with a `retryable` hint (408/425/429/5xx),
 * and retries transient failures with abort-aware backoff before surfacing the error
 * (consumes its own `retryable` classification instead of forcing a model re-call).
 */
export async function requestJson<T>(
  providerId: string,
  url: string,
  init: RequestInit & { timeoutMs?: number; maxAttempts?: number }
): Promise<T> {
  const { timeoutMs = DEFAULT_TIMEOUT_MS, maxAttempts = 3, signal, ...rest } = init
  return withRetry(
    async () => {
      const combined = createCombinedAbortSignal(signal, timeoutMs)
      try {
        let response: Response
        try {
          response = await fetch(url, { ...rest, signal: combined.signal })
        } catch (error) {
          // A thrown fetch is a connection-level failure (DNS, reset, timeout abort) —
          // always transient, so mark retryable unconditionally. (Distinct from the
          // status-based branch below, where retryability depends on the status code.)
          throw new WebProviderError(
            `${providerId} request failed: ${error instanceof Error ? error.message : String(error)}`,
            { retryable: true, providerId }
          )
        }
        if (!response.ok) {
          // Best-effort read of the error body for diagnostics; swallow a read failure
          // (empty string) so a broken body never masks the real HTTP status. Capped at
          // 200 chars so a huge HTML error page does not bloat the message/logs.
          const body = await response.text().catch(() => '')
          throw new WebProviderError(`${providerId} HTTP ${response.status}: ${body.slice(0, 200)}`, {
            retryable: isRetryableStatus(response.status),
            providerId,
            status: response.status
          })
        }
        return (await response.json()) as T
      } finally {
        combined.cleanup()
      }
    },
    { maxAttempts, signal, isRetryable: error => error instanceof WebProviderError && error.retryable }
  )
}

/**
 * Hostname of a URL, or `''` when the input is not a parseable URL. Returns the
 * empty sentinel instead of throwing so callers can use it in best-effort string
 * matching without each wrapping a try/catch.
 */
export function hostnameOf(url: string): string {
  try {
    return new URL(url).hostname
  } catch {
    return ''
  }
}

/** Normalize a URL for cross-provider matching (trim + strip trailing slashes). */
export function normalizeUrl(url: string): string {
  return url.trim().replace(/\/+$/, '')
}
