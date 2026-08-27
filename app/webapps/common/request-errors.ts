/**
 * Reads the machine-readable code from a console API error envelope
 * (`{error: {code, message}}`), so pages can localize known failures instead
 * of showing the server's English message.
 */
export function requestErrorCode(error: unknown): string | undefined {
  if (error && typeof error === 'object' && 'error' in error) {
    const value = (error as { error?: unknown }).error
    if (value && typeof value === 'object' && 'code' in value) {
      const code = (value as { code?: unknown }).code
      if (typeof code === 'string') return code
    }
  }

  return undefined
}

/**
 * Reads the structured detail list from a console API error envelope
 * (`{error: {details: [{...}]}}`), merged into one record. Pages use it to
 * show the real upstream response behind a coded failure.
 */
export function requestErrorDetails(error: unknown): Record<string, unknown> {
  if (error && typeof error === 'object' && 'error' in error) {
    const value = (error as { error?: unknown }).error
    if (value && typeof value === 'object' && 'details' in value) {
      const details = (value as { details?: unknown }).details
      if (Array.isArray(details)) {
        const merged: Record<string, unknown> = {}
        for (const entry of details) {
          if (entry && typeof entry === 'object') Object.assign(merged, entry)
        }
        return merged
      }
    }
  }

  return {}
}

/** Converts caught request failures into UI-safe text. */
export function requestErrorMessage(error: unknown): string {
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
      return 'Request failed'
    }
  }

  return conciseMessage(String(error ?? ''))
}

function conciseMessage(message: string): string {
  const trimmed = message.trim()
  if (!trimmed) return 'Request failed'

  // Phoenix and other development servers can return a full debug page as an
  // exception message. Keep the operator-facing reason, never the request
  // headers, cookies, stack trace, or source dump that follows it.
  const [summary] = trimmed.split(/\n\s*\n|\n##\s/)
  const safe = summary?.trim() || trimmed
  if (safe.startsWith('# ') || safe.includes('\nException:')) return safe.split(/\r?\n/, 1)[0] ?? 'Request failed'
  return safe.length <= 500 ? safe : `${safe.slice(0, 500)}…`
}
