import { beforeAll, expect, test } from 'bun:test'
import anyAscii from 'any-ascii'
import vectors from '../../kernel/test/vectors/pod_url.json'
import {
  installPageTransliteration,
  localReturnPath,
  pageUrlSlug,
  podLocation,
  podPagePath,
  podPagePathnameID,
  podPageRouteID,
  podRouteID,
  resolvePodPagePath
} from './pod-url'

const id = '00112233-4455-6677-8899-aabbccddeeff'
const short = '0024h36h2ncsvrh6daqf6dvvqz'

type SlugVector = { title: string; slug: string }
type PagePathVector = { id: string; title: string; expected_path: string }
type RouteVector = {
  path: string
  query: Record<string, string>
  expected_path: string
  expected_query: Record<string, string>
}

type InvalidRouteVector = { path: string; query: Record<string, string> }

beforeAll(() => {
  installPageTransliteration(anyAscii)
})

test('task return paths preserve local conversation state and exclude non-route intents', () => {
  const origin = 'https://pod.ankole.test'
  expect(localReturnPath('/conversations/abc?thread=1#latest', origin)).toBe('/conversations/abc?thread=1#latest')
  expect(localReturnPath(`/pages/${short}?automation_job=42`, origin)).toBe(`/pages/${short}?automation_job=42`)
  for (const value of [
    null,
    'figma',
    'watch-design',
    'https://elsewhere.test/task',
    '//elsewhere.test',
    '/\\elsewhere.test'
  ]) {
    expect(localReturnPath(value, origin)).toBeUndefined()
  }
})

test('Pod browser paths use Crockford Base32 short UUIDs and optional Page title slugs without changing durable identity', () => {
  expect(podLocation(`/pages/${id}`)).toEqual({ pathname: `/pages/${short}`, search: '' })
  expect(podLocation(`/conversations/${id}`)).toEqual({ pathname: `/conversations/${short}`, search: '' })
  expect(podLocation(`/pages/${id}`, { chat: id, tenant_id: 'obsolete' })).toEqual({
    pathname: `/pages/${short}`,
    search: `?chat=${short}`
  })
  expect(podRouteID(short)).toBe(id)
  expect(podRouteID(short.toUpperCase())).toBe(id)
  expect(podRouteID(id)).toBe(id)
  expect(podRouteID(`${short.slice(0, -1)}i`)).toBeUndefined()
  expect(podPageRouteID(`q4-design-spec-${short}`)).toBe(id)
  expect(podPageRouteID(`Q4-Design_Spec-${short.toUpperCase()}`)).toBe(id)
  expect(podPageRouteID(`-${short}`)).toBeUndefined()
  expect(podPagePathnameID(`/pages/q4-design-spec-${short}`)).toBe(id)
  expect(podPagePathnameID(`/pages/q4-design-spec-${short}/`)).toBeUndefined()
  expect(podPagePathnameID(`/pages/q4-design-spec-${short}/`, { allowTrailingSlash: true })).toBe(id)
  expect(podPagePathnameID(`/pages/Q4%5FDesign-${short}`)).toBe(id)
  expect(podPagePathnameID('/pages/%E0%A4%A')).toBeUndefined()
  expect(podPagePathnameID(`/conversations/${short}`)).toBeUndefined()
  expect(podLocation(`/pages/${id}`, { chat: 'new' }).search).toBe('?chat=new')
})

test('Page title slugs and paths match the shared kernel and control-plane vectors', () => {
  for (const entry of vectors.slugs as SlugVector[]) {
    expect(pageUrlSlug(entry.title)).toBe(entry.slug)
  }
  for (const entry of vectors.page_paths as PagePathVector[]) {
    expect(podPagePath(entry.id, entry.title)).toBe(entry.expected_path)
  }
})

test('Pod browser paths match the shared control-plane vectors', () => {
  for (const route of vectors.routes as RouteVector[]) {
    const location = podLocation(route.path, route.query)
    expect(location.pathname).toBe(route.expected_path)
    expect(Object.fromEntries(new URLSearchParams(location.search))).toEqual(route.expected_query)
  }
})

test('malformed Pod route IDs fail closed', () => {
  for (const route of vectors.invalid_routes as InvalidRouteVector[]) {
    expect(() => podLocation(route.path, route.query)).toThrow('Invalid Pod route ID')
  }
  expect(() => resolvePodPagePath('not-a-uuid', '产品规划')).toThrow('Invalid Pod route ID')
})

test('resolvePodPagePath falls back to bare short ID when transliteration chunk fails and recovers on retry', async () => {
  let attempts = 0
  installPageTransliteration({
    load: async () => {
      attempts += 1
      if (attempts === 1) throw new Error('chunk load failed')
      return anyAscii
    }
  })

  try {
    expect(await resolvePodPagePath(id, '产品规划')).toBe(`/pages/${short}`)
    expect(await resolvePodPagePath(id, '产品规划')).toBe(`/pages/chan-pin-gui-hua-${short}`)
    expect(attempts).toBe(2)
  } finally {
    installPageTransliteration(anyAscii)
  }
})
