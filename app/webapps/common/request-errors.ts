/** Converts caught request failures into UI-safe text. */
export function requestErrorMessage(error: unknown): string {
  if (error && typeof error === 'object' && 'error' in error) {
    const value = (error as { error?: unknown }).error
    if (value && typeof value === 'object' && 'message' in value) {
      const message = (value as { message?: unknown }).message
      if (typeof message === 'string') return conciseMessage(message)
    }
    if (typeof value === 'string') return conciseMessage(value)
  }

  return conciseMessage(error instanceof Error ? error.message : String(error))
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
