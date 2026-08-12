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
