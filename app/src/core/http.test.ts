import { describe, expect, it } from 'bun:test'
import { appendSetCookie, redirectWithSetCookies } from './http'

describe('HTTP response helpers', () => {
  it('appends Set-Cookie values on mutable Elysia response sets', () => {
    const set: { headers?: Record<string, unknown> } = {}

    appendSetCookie(set, 'a=1; Path=/')
    appendSetCookie(set, 'b=2; Path=/')

    expect(set.headers?.['Set-Cookie']).toEqual(['a=1; Path=/', 'b=2; Path=/'])
  })

  it('preserves multiple Set-Cookie headers on redirects', () => {
    const response = redirectWithSetCookies('/console', ['a=1; Path=/', 'b=2; Path=/'])

    expect(response.status).toBe(302)
    expect(response.headers.get('Location')).toBe('/console')
    expect(response.headers.getSetCookie()).toEqual(['a=1; Path=/', 'b=2; Path=/'])
  })
})
