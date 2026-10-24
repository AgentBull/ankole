import { expect, test } from 'bun:test'
import { invitationToken } from './join-space'

const origin = 'https://console.example.test'

test('invitation paste accepts a code, absolute link, relative link, or domain without a scheme', () => {
  for (const input of [
    '  AB-CD12  ',
    'https://team.example.test/join/AB-CD12',
    '/join/AB-CD12',
    'team.example.test/join/AB-CD12'
  ]) {
    expect(invitationToken(input, origin)).toBe('AB-CD12')
  }
})

test('a pasted link decodes its token once before navigation encodes it', () => {
  const token = invitationToken('/join/a%2Fb%2B%25?from=mail#join', origin)
  expect(token).toBe('a/b+%')
  expect(`/join/${encodeURIComponent(token)}`).toBe('/join/a%2Fb%2B%25')
})

test('malformed escapes reject inside the request instead of producing a doubled token', () => {
  expect(() => invitationToken('/join/broken%2', origin)).toThrow()
})
