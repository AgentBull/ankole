// The generated mutations/queries run with throwOnError, so a failed request
// throws the parsed error body (our API's Error schema, `{ message, ... }`).
export function errorMessage(error: unknown, fallback = "Something went wrong."): string {
  if (!error) {
    return fallback
  }
  if (typeof error === "string") {
    return error
  }
  if (typeof error === "object") {
    const message = (error as Record<string, unknown>).message
    if (typeof message === "string" && message !== "") {
      return message
    }
  }
  return fallback
}
