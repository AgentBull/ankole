import { uuidExpand, uuidShorten } from './uuid-url'

type Transliterate = (value: string) => string
type TransliterationLoader = () => Promise<Transliterate>

const SHORT_UUID_LEN = 26
const MAX_INCOMING_SLUG_LEN = 120
const MAX_PAGE_SLUG_LEN = 60
const MIN_WORD_BOUNDARY_LEN = 16
const INCOMING_SLUG_PATTERN = /^[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)*$/

const defaultTransliterationLoader: TransliterationLoader = () => import('any-ascii').then(module => module.default)

let transliterate: Transliterate | undefined
let transliterationLoading: Promise<void> | undefined
let loadTransliterator: TransliterationLoader = defaultTransliterationLoader
let transliterationListeners: Set<() => void> | undefined

function notifyTransliterationListeners(): void {
  if (!transliterationListeners) return
  for (const listener of transliterationListeners) listener()
}

export function installPageTransliteration(source: Transliterate | { load: TransliterationLoader }): void {
  transliterationLoading = undefined
  if (typeof source === 'function') {
    transliterate = source
    loadTransliterator = defaultTransliterationLoader
  } else {
    transliterate = undefined
    loadTransliterator = source.load
  }
  notifyTransliterationListeners()
}

function ensureTransliteration(): Promise<void> {
  if (transliterate) return Promise.resolve()
  if (!transliterationLoading) {
    const loader = loadTransliterator
    const pending = loader().then(
      fn => {
        if (loadTransliterator === loader) installPageTransliteration(fn)
      },
      () => {
        if (transliterationLoading === pending) transliterationLoading = undefined
      }
    )
    transliterationLoading = pending
  }
  return transliterationLoading
}

export function subscribePageTransliteration(listener: () => void): () => void {
  transliterationListeners ??= new Set()
  transliterationListeners.add(listener)
  return () => {
    transliterationListeners?.delete(listener)
  }
}

export function hasPageTransliteration(): boolean {
  return Boolean(transliterate)
}

export function isPageSlugReady(
  title: string | null | undefined,
  transliterationReady = Boolean(transliterate)
): boolean {
  return !title || isAscii(title) || transliterationReady
}

export function pageUrlSlug(title: string): string {
  if (!title) return ''
  if (!isAscii(title) && !transliterate) {
    void ensureTransliteration()
    return ''
  }

  let transliterated = ''
  for (const ch of title) {
    const codePoint = ch.codePointAt(0)!
    if (codePoint <= 0x7f) {
      transliterated += ch
    } else {
      const ascii = transliterate!(ch)
      transliterated += isHan(codePoint) ? ` ${ascii} ` : ascii
    }
  }

  let slug = ''
  let pendingDash = false
  for (let index = 0; index < transliterated.length; index += 1) {
    const code = transliterated.charCodeAt(index)
    if (code === 0x2e) continue
    const lower = code >= 0x41 && code <= 0x5a ? code + 0x20 : code
    if ((lower >= 0x61 && lower <= 0x7a) || (lower >= 0x30 && lower <= 0x39)) {
      if (pendingDash && slug.length > 0) slug += '-'
      slug += String.fromCharCode(lower)
      pendingDash = false
    } else if (slug.length > 0) {
      pendingDash = true
    }
  }

  return truncatePageSlug(slug)
}

export function podRouteID(value: string | undefined): string | undefined {
  if (!value) return
  return expandShortID(value) ?? (uuidShorten(value) ? value : undefined)
}

export function podPageRouteID(value: string | undefined): string | undefined {
  return value ? parsePageSegment(value)?.id : undefined
}

export function podPagePathnameID(pathname: string, options?: { allowTrailingSlash?: boolean }): string | undefined {
  const match = (options?.allowTrailingSlash ? /^\/pages\/([^/]+)\/?$/ : /^\/pages\/([^/]+)$/).exec(pathname)
  if (!match?.[1]) return
  try {
    return podPageRouteID(decodeURIComponent(match[1]))
  } catch {
    return
  }
}

export function podPagePath(id: string, title?: string | null): string {
  const canonicalID = podRouteID(id)
  if (!canonicalID) throw new Error('Invalid Pod route ID')
  const short = uuidShorten(canonicalID)!
  const slug = title ? pageUrlSlug(title) : ''
  return slug ? `/pages/${slug}-${short}` : `/pages/${short}`
}

export async function resolvePodPagePath(id: string, title?: string | null): Promise<string> {
  const canonicalID = podRouteID(id)
  if (!canonicalID) throw new Error('Invalid Pod route ID')
  if (title && !isAscii(title) && !transliterate) {
    await ensureTransliteration()
  }
  return podPagePath(canonicalID, title)
}

export function podLocation(
  path: string,
  query: Record<string, string | null | undefined> = {}
): { pathname: string; search: string } {
  const pathname = path.replace(/^\/(pages|conversations)\/([^/]+)$/, (_match, kind, value) => {
    if (kind === 'pages') {
      const parsed = parsePageSegment(value)
      if (!parsed) throw new Error('Invalid Pod route ID')
      return `/pages/${parsed.segment}`
    }
    const id = podRouteID(value)
    if (!id) throw new Error('Invalid Pod route ID')
    return `/conversations/${uuidShorten(id)}`
  })
  const params = new URLSearchParams()
  for (const [key, value] of Object.entries(query)) {
    if (value == null || key === 'tenant_id') continue
    const id = key === 'chat' ? podRouteID(value) : undefined
    params.set(key, id ? uuidShorten(id)! : value)
  }
  return { pathname, search: params.size ? `?${params}` : '' }
}

function expandShortID(value: string): string | undefined {
  return value.length === SHORT_UUID_LEN ? uuidExpand(value.toLowerCase()) : undefined
}

function parsePageSegment(value: string): { id: string; segment: string } | undefined {
  const directID = podRouteID(value)
  if (directID) return { id: directID, segment: uuidShorten(directID)! }
  if (value.length <= SHORT_UUID_LEN + 1) return

  const separatorIndex = value.length - SHORT_UUID_LEN - 1
  if (separatorIndex > MAX_INCOMING_SLUG_LEN || value[separatorIndex] !== '-') return

  const prefix = value.slice(0, separatorIndex)
  const suffix = value.slice(separatorIndex + 1)
  if (!INCOMING_SLUG_PATTERN.test(prefix)) return

  const id = expandShortID(suffix)
  if (!id) return

  const slug = truncatePageSlug(prefix.toLowerCase().replaceAll('_', '-'))
  return { id, segment: `${slug}-${suffix.toLowerCase()}` }
}

function truncatePageSlug(slug: string): string {
  if (slug.length <= MAX_PAGE_SLUG_LEN) return slug
  const sliced = slug.slice(0, MAX_PAGE_SLUG_LEN).replace(/-+$/, '')
  const lastDash = sliced.lastIndexOf('-')
  return lastDash >= MIN_WORD_BOUNDARY_LEN ? sliced.slice(0, lastDash) : sliced
}

function isAscii(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    if (value.charCodeAt(index) > 0x7f) return false
  }
  return true
}

function isHan(codePoint: number): boolean {
  return (
    (codePoint >= 0x3400 && codePoint <= 0x4dbf) ||
    (codePoint >= 0x4e00 && codePoint <= 0x9fff) ||
    (codePoint >= 0xf900 && codePoint <= 0xfaff) ||
    (codePoint >= 0x20000 && codePoint <= 0x323af)
  )
}
