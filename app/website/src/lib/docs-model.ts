import type { Locale } from '../i18n/config'
import { DEFAULT_LOCALE } from '../i18n/config'

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
}

export interface DocsSection {
  /** Raw section name from frontmatter, e.g. "Getting started". */
  section: string
  docs: DocNavItem[]
}

/** Docs entries live at src/content/docs/<slug>/<locale>.md; the slug is the first id segment. */
export function docSlug(id: string): string {
  return id.split('/')[0]
}

/** Picks the entry for the requested locale, falling back to the default locale. */
export function localizedEntry<T extends DocLike>(docs: T[], slug: string, locale: Locale): T | undefined {
  return docs.find(d => d.id === `${slug}/${locale}`) ?? docs.find(d => d.id === `${slug}/${DEFAULT_LOCALE}`)
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
    const item: DocNavItem = { slug: docSlug(doc.id), title: doc.data.title }
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
