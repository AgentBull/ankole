/** Converts caught request failures into UI-safe text. */
export function requestErrorMessage(error: unknown): string {
  if (error && typeof error === 'object' && 'error' in error) {
    const value = (error as { error?: unknown }).error
    if (value && typeof value === 'object' && 'message' in value) {
      const message = (value as { message?: unknown }).message
      if (typeof message === 'string') return message
    }
    if (typeof value === 'string') return value
  }

  return error instanceof Error ? error.message : String(error)
}
