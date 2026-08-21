export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export function toError(error: unknown): Error {
  return error instanceof Error ? error : new Error(errorMessage(error))
}

/** Returns the string `code` of a Node-style error value, if present. */
export function nodeErrorCode(error: unknown): string | undefined {
  if (typeof error !== 'object' || error === null || !('code' in error)) return undefined
  return typeof error.code === 'string' ? error.code : undefined
}
