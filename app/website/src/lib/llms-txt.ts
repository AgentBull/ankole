import type { CollectionEntry } from 'astro:content'
import { LOCALE_LABELS, LOCALES, type Locale } from '../i18n/config'
import { localePath, t } from '../i18n/utils'
import { docBodyMarkdown, docMarkdownUrl } from './docs-markdown'
import { buildDocsNav, fallbackNotice, llmsFullPath, llmsIndexPath, localizedEntry, sectionKey } from './docs-model'
import { blockquote, blocks, bulletList, heading } from './markdown-text'

/*
 * The llms.txt format (https://llmstxt.org): an H1 name, a quoted summary, free text, and H2
 * sections of links. Each locale has its own index and full file, because one file with four
 * languages is four times as large for an agent that needs one.
 */

type DocEntry = CollectionEntry<'docs'>

/** The documentation index for one locale. Every page link targets the page's Markdown version. */
export function llmsIndex(docs: DocEntry[], locale: Locale, site: URL): string {
  const { sections, flat } = buildDocsNav(docs, locale)
  const pageLink = (slug: string) => {
    const doc = flat.find(item => item.slug === slug)
    if (doc === undefined) throw new Error(`llms.txt links the docs page ${slug}, which does not exist`)
    return `[${doc.title}](${docMarkdownUrl(locale, slug, site)})`
  }

  return `${blocks(
    heading(1, t(locale, 'site.title')),
    blockquote(t(locale, 'site.description')),
    t(locale, 'llms.intro'),
    t(locale, 'llms.start', { quickstart: pageLink('quickstart'), faq: pageLink('faq') }),
    ...sections.map(section =>
      blocks(
        heading(2, t(locale, `docs.section.${sectionKey(section.section)}`)),
        bulletList(
          section.docs.map(doc => `[${doc.title}](${docMarkdownUrl(locale, doc.slug, site)}): ${doc.description}`)
        )
      )
    ),
    heading(2, t(locale, 'llms.languages')),
    bulletList(
      LOCALES.filter(other => other !== locale).map(
        other => `[${LOCALE_LABELS[other]}](${new URL(llmsIndexPath(other), site).href})`
      )
    ),
    // "Optional" is a fixed llms.txt section name: an agent with little context can skip it.
    heading(2, 'Optional'),
    bulletList([
      `[${t(locale, 'llms.full')}](${new URL(llmsFullPath(locale), site).href}): ${t(locale, 'llms.fullNote')}`
    ])
  )}\n`
}

/** Every page of one locale in navigation order, as one Markdown document. */
export function llmsFull(docs: DocEntry[], locale: Locale, site: URL): string {
  const pages = buildDocsNav(docs, locale).flat.map(doc => {
    const entry = localizedEntry(docs, doc.slug, locale)
    if (entry === undefined) throw new Error(`the docs page ${doc.slug} has no entry`)
    const notice = fallbackNotice(entry, locale)

    return blocks(
      heading(1, doc.title),
      `URL: ${new URL(localePath(locale, `docs/${doc.slug}`), site).href}\nMarkdown: ${docMarkdownUrl(locale, doc.slug, site)}`,
      blockquote(doc.description),
      notice && blockquote(notice),
      docBodyMarkdown(entry, { locale, slug: doc.slug, site })
    )
  })

  return `${blocks(
    heading(1, t(locale, 'site.title')),
    blockquote(t(locale, 'site.description')),
    t(locale, 'docs.markdown.index', { url: new URL(llmsIndexPath(locale), site).href }),
    ...pages
  )}\n`
}
