import i18n from './i18n'

/** Pages localize known failures from this code instead of showing the server's English message. */
export function requestErrorCode(error: unknown): string | undefined {
  const [first] = jsonApiErrors(error)
  if (typeof first?.code === 'string') return first.code
  if (error && typeof error === 'object' && 'error' in error) {
    const value = (error as { error?: unknown }).error
    if (value && typeof value === 'object' && 'code' in value) {
      const code = (value as { code?: unknown }).code
      if (typeof code === 'string') return code
    }
  }

  return undefined
}

/** Pages show the upstream response behind a coded failure from these details. */
export function requestErrorDetails(error: unknown): Record<string, unknown> {
  return Object.assign({}, ...requestErrorDetailList(error))
}

/** Keeps separate validation paths and line numbers in the API response. */
export function requestErrorDetailList(error: unknown): Record<string, unknown>[] {
  const apiDetails = jsonApiErrors(error).flatMap(item => {
    const meta = item.meta
    if (!isObject(meta)) return []
    const details = meta.details
    return Array.isArray(details) ? details.filter(isObject) : isObject(details) ? [details] : []
  })
  if (apiDetails.length) return apiDetails
  if (error && typeof error === 'object' && 'error' in error) {
    const value = (error as { error?: unknown }).error
    if (value && typeof value === 'object' && 'details' in value) {
      const details = (value as { details?: unknown }).details
      if (Array.isArray(details)) {
        return details.filter((entry): entry is Record<string, unknown> =>
          Boolean(entry && typeof entry === 'object' && !Array.isArray(entry))
        )
      }
    }
  }

  return []
}

export function requestErrorMessage(error: unknown): string {
  const [first] = jsonApiErrors(error)
  if (typeof first?.detail === 'string') return conciseMessage(first.detail)
  if (typeof first?.title === 'string') return conciseMessage(first.title)
  if (error && typeof error === 'object') {
    if ('error' in error) {
      const value = (error as { error?: unknown }).error
      if (value && typeof value === 'object' && 'message' in value) {
        const message = (value as { message?: unknown }).message
        if (typeof message === 'string') return conciseMessage(message)
      }
      if (typeof value === 'string') return conciseMessage(value)
    }

    // Phoenix's default envelope for unhandled exceptions and unmatched
    // routes: {"errors": {"detail": "Internal Server Error"}}.
    if ('errors' in error) {
      const errors = (error as { errors?: unknown }).errors
      if (errors && typeof errors === 'object' && 'detail' in errors) {
        const detail = (errors as { detail?: unknown }).detail
        if (typeof detail === 'string') return conciseMessage(detail)
      }
    }

    if (error instanceof Error) return conciseMessage(error.message)

    // A parsed JSON body in an unrecognized shape: show the JSON rather than
    // the "[object Object]" that String() would produce.
    try {
      return conciseMessage(JSON.stringify(error))
    } catch {
      return i18n.t('common.request_failed')
    }
  }

  return conciseMessage(String(error ?? ''))
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function jsonApiErrors(value: unknown): Record<string, unknown>[] {
  return isObject(value) && Array.isArray(value.errors) ? value.errors.filter(isObject) : []
}

function conciseMessage(message: string): string {
  const trimmed = message.trim()
  if (!trimmed) return i18n.t('common.request_failed')

  // Phoenix and other development servers can return a full debug page as an
  // exception message. Keep the operator-facing reason, never the request
  // headers, cookies, stack trace, or source dump that follows it.
  const [summary] = trimmed.split(/\n\s*\n|\n##\s/)
  const safe = summary?.trim() || trimmed
  if (safe.startsWith('# ') || safe.includes('\nException:')) {
    return safe.split(/\r?\n/, 1)[0] ?? i18n.t('common.request_failed')
  }
  return safe.length <= 500 ? safe : `${safe.slice(0, 500)}…`
}
