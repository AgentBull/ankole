type Transliterate = (value: string) => string

let transliterate: Transliterate | undefined
let transliterationLoading: Promise<void> | undefined

export function preloadTransliteration(): Promise<void> {
  transliterationLoading ??= import('any-ascii').then(module => {
    transliterate = module.default
  })
  return transliterationLoading
}

export function spaceSlugFromName(value: string): string {
  const prepared = value.replace(/[\p{Script=Han}\p{Script=Hangul}]+/gu, characters => {
    const latin = transliterate?.(characters).replace(/\s+/g, '')
    return ` ${latin ?? characters} `
  })
  return (transliterate ? transliterate(prepared) : prepared.normalize('NFKD'))
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 63)
    .replace(/-+$/g, '')
}

export function validTenantSlug(slug: string): boolean {
  return /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(slug)
}
