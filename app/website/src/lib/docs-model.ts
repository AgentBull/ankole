import type { Locale } from '../i18n/config'
import { DEFAULT_LOCALE, LOCALES } from '../i18n/config'
import { localePath, t } from '../i18n/utils'

/** Minimal shape of a docs collection entry used for navigation. */
export interface DocLike {
  id: string
  data: {
    title: string
    description: string
    section: string
    order: number
  }
}

export interface DocNavItem {
  slug: string
  title: string
  description: string
}

export interface DocsSection {
  /** Raw section name from frontmatter, e.g. "Getting started". */
  section: string
  docs: DocNavItem[]
}

/** Docs entries live at src/content/docs/<slug>/<locale>.md or .mdx; the slug is the first id segment. */
export function docSlug(id: string): string {
  return id.split('/')[0]
}

/** The locale of the content that an entry holds. */
export function entryLocale(entry: DocLike): Locale {
  return entry.id.split('/')[1] as Locale
}

/** Picks the entry for the requested locale, falling back to the default locale. */
export function localizedEntry<T extends DocLike>(docs: T[], slug: string, locale: Locale): T | undefined {
  return docs.find(d => d.id === `${slug}/${locale}`) ?? docs.find(d => d.id === `${slug}/${DEFAULT_LOCALE}`)
}

/** The notice for a page that shows the default-locale entry because its translation is missing. */
export function fallbackNotice(entry: DocLike, locale: Locale): string | undefined {
  if (entryLocale(entry) === locale) return undefined
  return t(locale, 'docs.fallbackNotice', { lang: t(locale, `lang.${locale}`) })
}

/**
 * Route parameters for every published docs page. Every locale publishes every slug, so a page
 * without a translation still exists and shows the default-locale entry.
 */
export function docsRouteParams(docs: DocLike[]): { lang: Locale; slug: string }[] {
  const slugs = [...new Set(docs.map(d => docSlug(d.id)))]
  return LOCALES.flatMap(lang => slugs.map(slug => ({ lang, slug })))
}

/** Site path of the Markdown version of a docs page, e.g. /en-US/docs/quickstart/index.md. */
export function docMarkdownPath(locale: Locale, slug: string): string {
  return `${localePath(locale, `docs/${slug}`)}index.md`
}

/** Site path of the llms.txt documentation index for one locale. */
export function llmsIndexPath(locale: Locale): string {
  return `${localePath(locale)}llms.txt`
}

/** Site path of the llms-full.txt file that holds every page of one locale. */
export function llmsFullPath(locale: Locale): string {
  return `${localePath(locale)}llms-full.txt`
}

/** i18n key suffix for a section label, e.g. "Getting started" -> "getting-started". */
export function sectionKey(section: string): string {
  return section
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
}

/** Builds the ordered, section-grouped sidebar model and the flat prev/next sequence. */
export function buildDocsNav<T extends DocLike>(
  docs: T[],
  locale: Locale
): { sections: DocsSection[]; flat: DocNavItem[] } {
  const slugs = [...new Set(docs.map(d => docSlug(d.id)))]
  const items = slugs
    .map(slug => localizedEntry(docs, slug, locale))
    .filter((d): d is T => Boolean(d))
    .sort((a, b) => a.data.order - b.data.order)

  const sections: DocsSection[] = []
  const flat: DocNavItem[] = []
  for (const doc of items) {
    const item: DocNavItem = {
      slug: docSlug(doc.id),
      title: doc.data.title,
      description: doc.data.description
    }
    flat.push(item)
    const existing = sections.find(s => s.section === doc.data.section)
    if (existing) {
      existing.docs.push(item)
    } else {
      sections.push({ section: doc.data.section, docs: [item] })
    }
  }
  return { sections, flat }
}
