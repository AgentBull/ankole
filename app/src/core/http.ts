export function appendSetCookie(set: { headers?: Record<string, unknown> }, value: string): void {
  const existing = set.headers?.['Set-Cookie']
  if (!set.headers) set.headers = {}
  if (!existing) {
    set.headers['Set-Cookie'] = value
    return
  }

  set.headers['Set-Cookie'] = Array.isArray(existing) ? [...existing, value] : [String(existing), value]
}

export function redirectWithSetCookies(
  url: string,
  cookies: string[],
  status: 301 | 302 | 303 | 307 | 308 = 302
): Response {
  const headers = new Headers({ Location: url })
  for (const cookie of cookies) {
    headers.append('Set-Cookie', cookie)
  }

  return new Response(null, {
    status,
    headers
  })
}
