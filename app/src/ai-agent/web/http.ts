import { WebProviderError } from './provider'

const DEFAULT_TIMEOUT_MS = 30_000

export function isRetryableStatus(status: number): boolean {
  return status === 408 || status === 425 || status === 429 || (status >= 500 && status <= 599)
}

function combineSignals(signal: AbortSignal | null | undefined, timeoutMs: number): AbortSignal {
  const timeout = AbortSignal.timeout(timeoutMs)
  return signal ? AbortSignal.any([signal, timeout]) : timeout
}

/**
 * POST/GET JSON helper shared by web providers. Maps transport errors and
 * non-2xx responses to `WebProviderError` with a `retryable` hint (408/425/429/5xx).
 */
export async function requestJson<T>(
  providerId: string,
  url: string,
  init: RequestInit & { timeoutMs?: number }
): Promise<T> {
  const { timeoutMs = DEFAULT_TIMEOUT_MS, signal, ...rest } = init
  let response: Response
  try {
    response = await fetch(url, { ...rest, signal: combineSignals(signal, timeoutMs) })
  } catch (error) {
    throw new WebProviderError(`${providerId} request failed: ${error instanceof Error ? error.message : String(error)}`, {
      retryable: true,
      providerId
    })
  }
  if (!response.ok) {
    const body = await response.text().catch(() => '')
    throw new WebProviderError(`${providerId} HTTP ${response.status}: ${body.slice(0, 200)}`, {
      retryable: isRetryableStatus(response.status),
      providerId,
      status: response.status
    })
  }
  return (await response.json()) as T
}

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
