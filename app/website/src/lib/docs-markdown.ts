import type { CollectionEntry } from 'astro:content'
import remarkGfm from 'remark-gfm'
import remarkMdx from 'remark-mdx'
import remarkParse from 'remark-parse'
import { unified } from 'unified'
import { renderArchitectureDiagram } from '../components/docs/architecture-diagram'
import { renderFaqIssueList, renderFaqProviderTabs } from '../components/docs/faq-markdown'
import {
  renderQuickstartAgentPrompt,
  renderQuickstartDisclosure,
  renderQuickstartTabs
} from '../components/docs/quickstart-markdown'
import { LOCALES, type Locale } from '../i18n/config'
import { localePath, t } from '../i18n/utils'
import { docMarkdownPath, entryLocale, fallbackNotice, llmsIndexPath } from './docs-model'
import { blockquote, blocks, type ComponentMarkdownRenderer, heading, requiredProp } from './markdown-text'

/*
 * Writes the Markdown version of a docs page from its source. Markdown pages keep their source text;
 * the build replaces only the source ranges that need a change, so nothing else is reformatted:
 *
 * - A relative link becomes an absolute URL. A link to a docs page targets that page's Markdown
 *   version, so an agent that follows it keeps reading Markdown.
 * - MDX import and export statements go away.
 * - An MDX component becomes the text of its renderer in COMPONENTS, which receives the same props
 *   as the page. A component without a renderer fails the build instead of disappearing.
 */

type DocEntry = CollectionEntry<'docs'>

/** Where the Markdown is published. Relative links resolve against this page URL. */
export interface DocMarkdownTarget {
  locale: Locale
  slug: string
  site: URL
}

const renderKnowledgeNote: ComponentMarkdownRenderer = (props, { children }) =>
  blockquote(blocks(`**${requiredProp<string>(props, 'label')}**`, children || requiredProp<string>(props, 'text')))

const COMPONENTS: Record<string, ComponentMarkdownRenderer> = {
  DocsArchitectureDiagram: renderArchitectureDiagram,
  DocsKnowledgeNote: renderKnowledgeNote,
  FaqIssueList: renderFaqIssueList,
  FaqProviderTabs: renderFaqProviderTabs,
  QuickstartAgentPrompt: renderQuickstartAgentPrompt,
  QuickstartDisclosure: renderQuickstartDisclosure,
  QuickstartTabs: renderQuickstartTabs
}

/** Component props name values that the MDX file exports, such as `tabs={deploymentTabs}`. */
const MDX_MODULES = import.meta.glob<Record<string, unknown>>('/src/content/docs/*/*.mdx', { eager: true })

const markdownParser = unified().use(remarkParse).use(remarkGfm)
const mdxParser = unified().use(remarkParse).use(remarkMdx).use(remarkGfm)

const BASE_PATH = import.meta.env.BASE_URL.replace(/\/+$/, '')
const DOCS_PAGE_PATH = new RegExp(
  `^${BASE_PATH.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/(${LOCALES.join('|')})/docs/([^/]+)/$`
)

interface SourcePoint {
  line: number
  offset?: number
}

/** The mdast and MDX node fields that this module reads. */
interface MarkdownNode {
  type: string
  position?: { start: SourcePoint; end: SourcePoint }
  children?: MarkdownNode[]
  depth?: number
  url?: string
  title?: string | null
  label?: string | null
  value?: string
  name?: string | null
  attributes?: JsxAttribute[]
}

interface JsxAttribute {
  type: string
  name?: string
  value?: string | null | { type: string; value: string }
}

interface Replacement {
  start: number
  end: number
  text: string
}

interface TransformContext {
  source: string
  file: string
  exports: Record<string, unknown>
  headings: { offset: number; depth: number }[]
  link: (href: string) => string
  docMarkdownUrl: (locale: Locale, slug: string) => string
}

/** The site origin for absolute links, from `site` in astro.config.mjs. */
export function requireSite(site: URL | undefined): URL {
  if (site === undefined) {
    throw new Error('Markdown and llms.txt files need absolute URLs; set `site` in astro.config.mjs')
  }
  return site
}

/** Absolute URL of the Markdown version of a docs page. */
export function docMarkdownUrl(locale: Locale, slug: string, site: URL): string {
  return new URL(docMarkdownPath(locale, slug), site).href
}

/** The complete Markdown version of a docs page: frontmatter, index pointer, title, and body. */
export function docPageMarkdown(entry: DocEntry, target: DocMarkdownTarget): string {
  const { locale, slug, site } = target
  const notice = fallbackNotice(entry, locale)
  const frontmatter = [
    '---',
    `title: ${JSON.stringify(entry.data.title)}`,
    `description: ${JSON.stringify(entry.data.description)}`,
    `url: ${JSON.stringify(new URL(localePath(locale, `docs/${slug}`), site).href)}`,
    `lang: ${JSON.stringify(entryLocale(entry))}`,
    '---'
  ].join('\n')

  return `${blocks(
    frontmatter,
    blockquote(t(locale, 'docs.markdown.index', { url: new URL(llmsIndexPath(locale), site).href })),
    heading(1, entry.data.title),
    notice && blockquote(notice),
    docBodyMarkdown(entry, target)
  )}\n`
}

/** The page body as Markdown, with links resolved for the target URL. */
export function docBodyMarkdown(entry: DocEntry, target: DocMarkdownTarget): string {
  const file = entry.filePath ?? entry.id
  if (entry.body === undefined) throw new Error(`${file}: the docs collection did not keep the page source`)

  const isMdx = file.endsWith('.mdx')
  const exports = isMdx ? MDX_MODULES[`/${file}`] : {}
  if (exports === undefined) throw new Error(`${file}: the MDX module is not in the build`)

  const tree = (isMdx ? mdxParser : markdownParser).parse(entry.body) as unknown as MarkdownNode
  const context: TransformContext = {
    source: entry.body,
    file,
    exports,
    headings: collectHeadings(tree),
    link: createLinkResolver(target),
    docMarkdownUrl: (locale, slug) => docMarkdownUrl(locale, slug, target.site)
  }
  return transform(context, 0, entry.body.length, tree.children ?? []).trim()
}

function createLinkResolver({ locale, slug, site }: DocMarkdownTarget): (href: string) => string {
  const pageUrl = new URL(localePath(locale, `docs/${slug}`), site)

  return href => {
    if (!isInternalHref(href)) return href

    const url = new URL(href, pageUrl)
    // Keep the fragment as written: a percent-encoded CJK heading ID is harder for a reader to use.
    const hashIndex = href.indexOf('#')
    const hash = hashIndex === -1 ? '' : href.slice(hashIndex)
    const docsPage = url.pathname.match(DOCS_PAGE_PATH)
    if (docsPage === null) return `${url.origin}${url.pathname}${url.search}${hash}`

    return `${docMarkdownUrl(docsPage[1] as Locale, docsPage[2], site)}${url.search}${hash}`
  }
}

function isInternalHref(href: string): boolean {
  return !href.startsWith('//') && !/^[a-z][a-z\d+.-]*:/i.test(href)
}

function transform(context: TransformContext, start: number, end: number, nodes: MarkdownNode[]): string {
  let text = ''
  let cursor = start
  for (const replacement of nodes.flatMap(node => replacementsFor(context, node))) {
    text += context.source.slice(cursor, replacement.start) + replacement.text
    cursor = replacement.end
  }
  return text + context.source.slice(cursor, end)
}

function replacementsFor(context: TransformContext, node: MarkdownNode): Replacement[] {
  switch (node.type) {
    case 'mdxjsEsm':
      return [removeBlock(context, node)]
    case 'mdxFlowExpression':
    case 'mdxTextExpression':
      throw sourceError(context, node, 'a JavaScript expression has no Markdown form')
    case 'mdxJsxFlowElement':
    case 'mdxJsxTextElement':
      return jsxReplacements(context, node)
    case 'link':
    case 'definition':
      return linkReplacements(context, node)
    case 'html':
      assertNoInternalHref(context, node, node.value ?? '')
      return []
    case 'paragraph': {
      // MDX parses `<Note>text</Note>` on one line as an element inside a paragraph.
      const component = soleComponent(node)
      if (component === undefined) return childReplacements(context, node)
      return [componentReplacement(context, component, sourceRange(context, node))]
    }
    default:
      return childReplacements(context, node)
  }
}

function soleComponent(paragraph: MarkdownNode): MarkdownNode | undefined {
  const children = (paragraph.children ?? []).filter(child => !(child.type === 'text' && child.value?.trim() === ''))
  const [only] = children
  return children.length === 1 && only.type === 'mdxJsxTextElement' && isComponentName(only.name) ? only : undefined
}

function isComponentName(name: string | null | undefined): boolean {
  return typeof name === 'string' && /^[A-Z]/.test(name)
}

function childReplacements(context: TransformContext, node: MarkdownNode): Replacement[] {
  return (node.children ?? []).flatMap(child => replacementsFor(context, child))
}

function jsxReplacements(context: TransformContext, node: MarkdownNode): Replacement[] {
  const name = node.name
  if (!name) throw sourceError(context, node, 'a JSX fragment has no Markdown form')

  // An HTML element stays as written; Markdown accepts inline HTML.
  if (!isComponentName(name)) {
    for (const attribute of node.attributes ?? []) {
      if (attribute.type !== 'mdxJsxAttribute' || (attribute.value !== null && typeof attribute.value === 'object')) {
        throw sourceError(context, node, `<${name}> attributes must be literal strings`)
      }
      if (attribute.name === 'href' && typeof attribute.value === 'string' && isInternalHref(attribute.value)) {
        throw sourceError(context, node, `write <${name} href="${attribute.value}"> as a Markdown link`)
      }
    }
    if (!node.children?.length) {
      // A scroll anchor such as <span id="deployment" /> stays as an HTML anchor, because other
      // pages link to page.md#deployment. Any other empty element has nothing for a reader.
      const id = node.attributes?.find(attribute => attribute.name === 'id')?.value
      if (typeof id === 'string') return [{ ...sourceRange(context, node), text: `<a id="${id}"></a>` }]
      return [
        node.type === 'mdxJsxFlowElement' ? removeBlock(context, node) : { ...sourceRange(context, node), text: '' }
      ]
    }
    return childReplacements(context, node)
  }

  if (node.type !== 'mdxJsxFlowElement') {
    throw sourceError(context, node, `<${name}> must be the only content of its paragraph`)
  }
  return [componentReplacement(context, node, sourceRange(context, node))]
}

/** Replaces a source range with the Markdown that the component renderer writes. */
function componentReplacement(
  context: TransformContext,
  node: MarkdownNode,
  { start, end }: { start: number; end: number }
): Replacement {
  const name = node.name ?? ''
  const render = COMPONENTS[name]
  if (render === undefined) throw sourceError(context, node, `<${name}> has no Markdown renderer in COMPONENTS`)

  const props = componentProps(context, node, name)
  const children = childrenMarkdown(context, node).trim()
  try {
    const text = render(props, {
      children,
      depth: headingDepthAt(context, start),
      link: context.link,
      docMarkdownUrl: context.docMarkdownUrl
    })
    return { start, end, text }
  } catch (error) {
    throw sourceError(context, node, `<${name}>: ${error instanceof Error ? error.message : String(error)}`)
  }
}

function componentProps(context: TransformContext, node: MarkdownNode, name: string): Record<string, unknown> {
  const props: Record<string, unknown> = {}
  for (const attribute of node.attributes ?? []) {
    if (attribute.type !== 'mdxJsxAttribute' || !attribute.name) {
      throw sourceError(context, node, `<${name}> cannot spread props`)
    }
    // Astro directives such as client:visible control hydration, not content.
    if (attribute.name.includes(':')) continue

    const value = attribute.value
    if (value === null || value === undefined) {
      props[attribute.name] = true
    } else if (typeof value === 'string') {
      props[attribute.name] = value
    } else {
      const identifier = value.value.trim()
      if (!/^[A-Za-z_$][\w$]*$/.test(identifier) || !(identifier in context.exports)) {
        throw sourceError(context, node, `<${name} ${attribute.name}={${identifier}}> must name an export of this file`)
      }
      props[attribute.name] = context.exports[identifier]
    }
  }
  return props
}

function linkReplacements(context: TransformContext, node: MarkdownNode): Replacement[] {
  const url = node.url ?? ''
  const resolved = context.link(url)
  if (resolved === url) return childReplacements(context, node)

  const title = node.title ? ` ${JSON.stringify(node.title)}` : ''
  const text =
    node.type === 'definition'
      ? `[${node.label ?? ''}]: ${resolved}${title}`
      : `[${childrenMarkdown(context, node)}](${resolved}${title})`
  return [{ ...sourceRange(context, node), text }]
}

function childrenMarkdown(context: TransformContext, node: MarkdownNode): string {
  const children = node.children ?? []
  if (children.length === 0) return ''
  return transform(
    context,
    sourceRange(context, children[0]).start,
    sourceRange(context, children[children.length - 1]).end,
    children
  )
}

/** Removes a block together with the blank lines after it, so no gap stays behind. */
function removeBlock(context: TransformContext, node: MarkdownNode): Replacement {
  const { start, end } = sourceRange(context, node)
  const trailing = context.source.slice(end).match(/^(?:[ \t]*\r?\n)+/)
  return { start, end: end + (trailing?.[0].length ?? 0), text: '' }
}

function assertNoInternalHref(context: TransformContext, node: MarkdownNode, html: string) {
  for (const match of html.matchAll(/\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')/gi)) {
    const href = match[1] ?? match[2]
    if (isInternalHref(href)) throw sourceError(context, node, `write the HTML link to ${href} as a Markdown link`)
  }
}

function collectHeadings(node: MarkdownNode): { offset: number; depth: number }[] {
  const own =
    node.type === 'heading' && node.depth !== undefined && node.position?.start.offset !== undefined
      ? [{ offset: node.position.start.offset, depth: node.depth }]
      : []
  return [...own, ...(node.children ?? []).flatMap(collectHeadings)]
}

/** Depth of the last heading before an offset. The page title is the depth-1 heading. */
function headingDepthAt(context: TransformContext, offset: number): number {
  return context.headings.findLast(item => item.offset < offset)?.depth ?? 1
}

function sourceRange(context: TransformContext, node: MarkdownNode): { start: number; end: number } {
  const start = node.position?.start.offset
  const end = node.position?.end.offset
  if (start === undefined || end === undefined) throw sourceError(context, node, `${node.type} has no source position`)
  return { start, end }
}

function sourceError(context: TransformContext, node: MarkdownNode, message: string): Error {
  return new Error(`${context.file} (body line ${node.position?.start.line ?? '?'}): ${message}`)
}
