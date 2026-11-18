import { expect, test } from 'bun:test'
import { createEmbedBridge, EMBED_SOURCE, embedTarget } from './embed-bridge'

const allowed = ['https://portal.example.com']

test('the bridge posts only to a framing origin the Pod allows', () => {
  expect(embedTarget(allowed, ['https://portal.example.com'], '')).toBe('https://portal.example.com')
  expect(embedTarget(allowed, ['https://evil.example.net'], 'https://portal.example.com/x')).toBeUndefined()
  // Browsers without ancestorOrigins fall back to the referrer's origin.
  expect(embedTarget(allowed, undefined, 'https://portal.example.com/tables?id=1')).toBe('https://portal.example.com')
  expect(embedTarget(allowed, undefined, '')).toBeUndefined()
  expect(embedTarget([], ['https://portal.example.com'], '')).toBeUndefined()
})

test('messages carry the embed source and reach only the allowed origin', () => {
  const posted: Array<[unknown, string]> = []
  const parent = { postMessage: (message: unknown, origin: string) => posted.push([message, origin]) }
  const bridge = createEmbedBridge(parent, 'https://portal.example.com')
  bridge.post({ type: 'loaded', pageID: 'p1' })
  bridge.post({ type: 'height', height: 420 })
  bridge.post({ type: 'height', height: 420 })
  bridge.post({ type: 'unauthenticated' })
  expect(posted).toEqual([
    [{ source: EMBED_SOURCE, type: 'loaded', pageID: 'p1' }, 'https://portal.example.com'],
    [{ source: EMBED_SOURCE, type: 'height', height: 420 }, 'https://portal.example.com'],
    [{ source: EMBED_SOURCE, type: 'unauthenticated' }, 'https://portal.example.com']
  ])

  const silent: unknown[] = []
  createEmbedBridge({ postMessage: (message: unknown) => silent.push(message) }, undefined).post({
    type: 'unauthenticated'
  })
  expect(silent).toEqual([])
})

test('the embed path names one Page', async () => {
  const { embeddedPageID } = await import('./base-embed')
  const id = '00112233-4455-6677-8899-aabbccddeeff'
  expect(embeddedPageID(`/embed/pages/${id}`)).toBe(id)
  expect(embeddedPageID(`/pages/${id}`)).toBeUndefined()
  expect(embeddedPageID('/embed/pages/')).toBeUndefined()
})
