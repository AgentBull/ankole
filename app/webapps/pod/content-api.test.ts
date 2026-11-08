import { expect, spyOn, test } from 'bun:test'
import * as browserContext from '../common/browser-context'
import * as internalApiClient from '../common/internal-api-client'
import { createAppletRoutes } from './applet-routes'
import { limitPageTitle, podFileURL } from './content-api'

test('a Page title keeps 255 code points without splitting a character', () => {
  const emoji = '😀'.repeat(255)
  expect(limitPageTitle(emoji)).toBe(emoji)
  expect(limitPageTitle(`${emoji}😀`)).toBe(emoji)
  // Each accented letter is one grapheme cluster of two code points, as the control plane counts them
  expect(limitPageTitle('é'.repeat(128))).toBe('é'.repeat(127))
  expect(limitPageTitle('short')).toBe('short')
})

test('an edit over the limit keeps the existing title and shortens only the inserted text', () => {
  const previous = 'a'.repeat(250)
  expect(limitPageTitle(`${'x'.repeat(10)}${previous}`, previous)).toBe(`${'x'.repeat(5)}${previous}`)
  // A family emoji is one grapheme cluster of five code points
  const family = '👨‍👩‍👧'
  expect(limitPageTitle(`a${family.repeat(2)}${previous.slice(1)}`, previous)).toBe(`a${family}${previous.slice(1)}`)
})

test('an edit keeps the previous title when no whole inserted character fits', () => {
  // A zero-width joiner after the existing man emoji would join a family that no longer fits
  const man = `${'a'.repeat(253)}👨`
  expect(limitPageTitle(`${man}\u200d👩`, man)).toBe(man)
  const full = `${'a'.repeat(251)}test`
  expect(limitPageTitle(`${'a'.repeat(251)}👨‍👩‍👧`, full)).toBe(full)
})

test('an edit keeps an accent with the inserted letter it belongs to', () => {
  const previous = `${'a'.repeat(253)}b\u0301`
  expect(limitPageTitle(`${'a'.repeat(253)}xyc\u0301`, previous)).toBe(`${'a'.repeat(253)}xy`)
})

test('a legacy title above the limit can still lose text', () => {
  const legacy = 'a'.repeat(300)
  expect(limitPageTitle(legacy.slice(1), legacy)).toBe(legacy.slice(1))
  expect(limitPageTitle(`${legacy}b`, legacy)).toBe(legacy)
})

test('podFileURL pins the calling document authentication_ref onto Pod file targets without mutating input objects', () => {
  const appletPageID = '019a2b00-0000-7000-8000-000000000010'
  const basePageID = '019a2b00-0000-7000-8000-000000000020'
  const authSpy = spyOn(browserContext, 'authenticationRef').mockReturnValue('auth-tab-a')

  try {
    expect(podFileURL(appletPageID, 'assets/sha123/generated.png')).toBe(
      `/api/v2/pod/pages/${appletPageID}/files/content?path=assets%2Fsha123%2Fgenerated.png&authentication_ref=auth-tab-a`
    )

    expect(podFileURL(appletPageID, `pages/${basePageID}/attachments/sha456/hero.png`)).toBe(
      `/api/v2/pod/pages/${basePageID}/files/content?path=attachments%2Fsha456%2Fhero.png&authentication_ref=auth-tab-a`
    )

    const target = {
      path: `pages/${basePageID}/attachments/sha456/hero.png`,
      pageId: basePageID,
      sha256: 'sha456'
    }
    expect(podFileURL(appletPageID, target)).toBe(
      `/api/v2/pod/pages/${basePageID}/files/content?path=attachments%2Fsha456%2Fhero.png&sha256=sha456&authentication_ref=auth-tab-a`
    )
    expect(target).toEqual({
      path: `pages/${basePageID}/attachments/sha456/hero.png`,
      pageId: basePageID,
      sha256: 'sha456'
    })

    expect(
      podFileURL(
        appletPageID,
        `/api/v2/pod/pages/${appletPageID}/files/content?path=assets%2Fsha123%2Fgenerated.png&authentication_ref=stale-ref`
      )
    ).toBe(
      `/api/v2/pod/pages/${appletPageID}/files/content?path=assets%2Fsha123%2Fgenerated.png&authentication_ref=auth-tab-a`
    )

    expect(podFileURL(appletPageID, 'metadata/emojis/rocket.png')).toBe(
      '/api/v2/pod/metadata/files/content?path=metadata%2Femojis%2Frocket.png&authentication_ref=auth-tab-a'
    )
  } finally {
    authSpy.mockRestore()
  }
})

test('createAppletRoutes preserves business JSON strings verbatim, including strings shaped like Pod file content URLs', async () => {
  const appletPageID = '019a2b00-0000-7000-8000-000000000011'
  const authSpy = spyOn(browserContext, 'authenticationRef').mockReturnValue('auth-tab-viewer')
  const rawContentPath = `/api/v2/pod/pages/${appletPageID}/files/content?path=assets%2Fa.png`
  const boundServerUrl = `/api/v2/pod/pages/${appletPageID}/files/content?path=assets%2Fabc%2Fgenerated.png&authentication_ref=auth-tab-viewer`
  const configSpy = spyOn(internalApiClient, 'createClientConfig').mockImplementation(config => ({
    ...config,
    fetch: (async (input, init) => {
      expect(String(input)).toBe(`/api/v2/pod/pages/${appletPageID}/routes/posters`)
      expect(init?.method).toBe('POST')
      return new Response(
        JSON.stringify({
          original: rawContentPath,
          nested: [{ template: rawContentPath }],
          url: boundServerUrl,
          file: {
            path: `pages/${appletPageID}/assets/abc/generated.png`,
            pageId: appletPageID,
            name: 'generated.png',
            mime: 'image/png',
            size: 68
          }
        }),
        { status: 200, headers: { 'content-type': 'application/json' } }
      )
    }) as typeof fetch
  }))

  try {
    const routes = createAppletRoutes(appletPageID, 2, () => {})
    const result = await routes.call<{
      original: string
      nested: Array<{ template: string }>
      url: string
      file: { path: string }
    }>({
      method: 'POST',
      path: '/posters',
      body: { prompt: 'Harbor lighthouse' }
    })
    expect(result.original).toBe(rawContentPath)
    expect(result.nested).toEqual([{ template: rawContentPath }])
    expect(result.url).toBe(boundServerUrl)
    expect(result.file.path).toBe(`pages/${appletPageID}/assets/abc/generated.png`)
  } finally {
    configSpy.mockRestore()
    authSpy.mockRestore()
  }
})
