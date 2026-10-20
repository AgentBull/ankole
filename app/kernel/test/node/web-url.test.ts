import { expect, test } from 'bun:test'
import { readFile } from 'node:fs/promises'
import { validateIPAddresses, validateWebURL, webURLFacts } from '../../node'

test('Node-API uses the shared URL, IP, and invalid-input vectors', async () => {
  const vectors = JSON.parse(
    await readFile(new URL('../vectors/web_url_host_classification.json', import.meta.url), 'utf8')
  )
  const urls = [
    ...vectors.addresses.map(({ input, class: hostClass }: { input: string; class: string }) => ({
      input: input.includes(':') ? `https://[${input}]/` : `https://${input}/`,
      class: hostClass
    })),
    ...vectors.urls
  ]
  for (const { input, class: hostClass } of urls) {
    expect(webURLFacts(input).hostClass).toBe(hostClass)
    expect(validateWebURL(input, ['https'], true) ?? null).toBe(hostClass === 'public' ? null : hostClass)
    expect(validateWebURL(input, ['https'], false) ?? null).toBe(hostClass === 'metadata' ? 'metadata' : null)
  }
  for (const input of vectors.invalid_urls) expect(validateWebURL(input, ['https'], false)).toBe('invalid')
  expect(validateWebURL('http://example.com/', ['https'], false)).toBe('invalid')
  expect(validateIPAddresses([], false)).toBe('invalid')
  expect(validateIPAddresses(['garbage'], false)).toBe('invalid')
  expect(validateIPAddresses(['8.8.8.8', '::ffff:169.254.169.254'], false)).toBe('metadata')
  expect(validateIPAddresses(['8.8.8.8', '10.0.0.1'], true)).toBe('private')
  expect(validateIPAddresses(['8.8.8.8', '10.0.0.1'], false) ?? null).toBeNull()
})
