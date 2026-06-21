import { ApiError } from './api-error'

// Substring (not exact) match so a `content-type` with a charset or other
// parameters — e.g. `application/json; charset=utf-8` — still counts.
function contentTypeMatches(response: Response, expected: string): boolean {
  const header = response.headers.get('content-type') ?? ''
  return header.toLowerCase().includes(expected)
}

/**
 * Guard a successful `readFile` response: the worker must return
 * `application/octet-stream`, never a JSON error body masquerading as content.
 */
export function expectOctetStream(response: Response, method: string, url: string): void {
  if (!contentTypeMatches(response, 'application/octet-stream')) {
    throw new ApiError({
      status: response.status,
      code: 'unexpected_content_type',
      message: `expected application/octet-stream, got "${response.headers.get('content-type') ?? 'none'}"`,
      method,
      url
    })
  }
}

/** True if the response is an NDJSON stream, accepting both the `x-ndjson` and `ndjson` spellings the worker may use. */
export function isNdjson(response: Response): boolean {
  return contentTypeMatches(response, 'application/x-ndjson') || contentTypeMatches(response, 'application/ndjson')
}
