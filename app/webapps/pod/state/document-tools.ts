import {
  parseXml,
  printMarkdown,
  resourceContent,
  resourceText,
  unwrapMathDelimiters
} from '@ankole/block-editor/document'

export type DocumentElement = ReturnType<typeof parseXml>
type DocumentNode = DocumentElement['children'][number]

export type DocumentReference = { title: string; href: string; filePageID?: string; restricted?: boolean }
export type DocumentPrincipalReference = { name: string; restricted?: boolean }
export type DocumentProjection = {
  resolveAsset?: (source: string) => string
  resolveReference?: (ref: string) => DocumentReference | undefined
  resolveEmbed?: (ref: string) => DocumentReference | undefined
  resolvePrincipal?: (uid: string) => DocumentPrincipalReference | undefined
}
export type EditingStats = {
  words: number
  characters: number
  paragraphs: number
  readingTime: number
}

function walkDocument(source: string | DocumentElement, visit: (node: DocumentElement) => void): DocumentElement {
  const page = typeof source === 'string' ? parseXml(source) : source
  const walk = (node: DocumentNode) => {
    if (node.type === 'text') return
    visit(node)
    node.children.forEach(walk)
  }
  walk(page)
  return page
}

function assetSource(node: DocumentElement): [string, string] | undefined {
  const attribute = ['img', 'media'].includes(node.name) ? 'src' : node.name === 'a' ? 'href' : undefined
  const source = attribute && node.attrs[attribute]
  return attribute && source?.startsWith('ankole:asset/') ? [attribute, source] : undefined
}

export function documentReferenceIDs(source: string | DocumentElement): string[] {
  const refs = new Set<string>()
  walkDocument(source, node => {
    if (node.name === 'embed' && node.attrs.ref) refs.add(node.attrs.ref)
    if (node.name === 'mention' && node.attrs.page) refs.add(node.attrs.page)
    if (node.name === 'a' && node.attrs.href?.startsWith('ankole:page/')) {
      refs.add(node.attrs.href.slice('ankole:page/'.length))
    }
  })
  return [...refs]
}

export function documentEmbedIDs(source: string | DocumentElement): string[] {
  const refs = new Set<string>()
  walkDocument(source, node => {
    if (node.name === 'embed' && node.attrs.ref) refs.add(node.attrs.ref)
  })
  return [...refs]
}

export function documentPrincipalUIDs(source: string | DocumentElement): string[] {
  const uids = new Set<string>()
  walkDocument(source, node => {
    if (node.name === 'mention' && node.attrs.principal) uids.add(node.attrs.principal)
  })
  return [...uids]
}

export function documentAssets(xml: string): string[] {
  const assets = new Set<string>()
  walkDocument(xml, node => {
    const asset = assetSource(node)
    if (asset) assets.add(asset[1])
  })
  return [...assets]
}

/** Export and Markdown copy include the title; plain-text copy uses the document body. */
export function documentMarkdown(xml: string, title: string, projection: DocumentProjection = {}): string {
  const page = walkDocument(xml, node => {
    const asset = assetSource(node)
    // A resolved file address follows its link text or image, as a page link's address does.
    const resolved = asset && projection.resolveAsset ? projection.resolveAsset(asset[1]) : null
    if (asset && resolved) node.attrs[asset[0]] = resolved
    if (node.name === 'a' && node.attrs.href?.startsWith('ankole:page/')) {
      const reference = projection.resolveReference?.(node.attrs.href.slice('ankole:page/'.length))
      if (reference) node.attrs.href = reference.href
    }
    if (node.name === 'embed' && node.attrs.ref) {
      const reference = (projection.resolveEmbed ?? projection.resolveReference)?.(node.attrs.ref)
      if (reference) {
        node.name = 'p'
        node.attrs = {}
        node.children = reference.restricted
          ? [{ type: 'text', value: reference.title }]
          : [
              {
                type: 'element',
                name: 'a',
                attrs: { href: reference.href },
                children: [{ type: 'text', value: reference.title }]
              }
            ]
      }
    }
  })
  const heading = title.trim()
  if (heading) {
    page.children.unshift({
      type: 'element',
      name: 'h1',
      attrs: {},
      children: [{ type: 'text', value: heading }]
    })
  }
  const portable = (node: DocumentNode): DocumentNode[] => {
    if (node.type === 'text') return [node]
    node.children = node.children.flatMap(portable)
    if (node.name === 'mention' && node.attrs.page) {
      const reference = projection.resolveReference?.(node.attrs.page)
      if (!reference) return [node]
      return reference.restricted
        ? [{ type: 'text', value: reference.title }]
        : [
            {
              type: 'element',
              name: 'a',
              attrs: { href: reference.href },
              children: [{ type: 'text', value: reference.title }]
            }
          ]
    }
    if (node.name === 'mention' && node.attrs.principal) {
      const principal = projection.resolvePrincipal?.(node.attrs.principal)
      if (!principal) return [node]
      return [{ type: 'text', value: `@${principal.name}` }]
    }
    if (['columns', 'column', 'block', 'span'].includes(node.name)) return node.children
    const resource = resourceContent(node)
    if (resource) {
      const { src, title, image } = resource
      node.name = 'p'
      node.attrs = {}
      node.children = src
        ? [
            {
              type: 'element',
              name: image ? 'img' : 'a',
              attrs: image ? { src, alt: title } : { href: src },
              children: image ? [] : [{ type: 'text', value: title }]
            }
          ]
        : []
    }
    if (node.name === 'callout') {
      node.name = 'blockquote'
      node.attrs = {}
    }
    if (/^(p|h[1-6])$/.test(node.name)) node.attrs = {}
    return [node]
  }
  // Portable Markdown has no empty paragraph, and its lossless `<p />` form is noise outside Ankole.
  page.children = page.children
    .flatMap(portable)
    .filter(node => node.type === 'text' || node.name !== 'p' || node.children.length > 0)
  return printMarkdown(page)
}

/** Read text from the canonical tree so code, links, and literal Markdown keep their visible text. */
export function documentPlainText(xml: string, projection: DocumentProjection = {}): string {
  return plainTextNodes([parseXml(xml)], projection)
}

function plainTextNodes(nodes: DocumentNode[], projection: DocumentProjection): string {
  let text = ''
  let firstBlock = true
  const visit = (node: DocumentNode) => {
    if (node.type === 'text') {
      text += node.value
      return
    }
    if (node.name === 'table') {
      if (!firstBlock) text += '\n'
      firstBlock = false
      text += node.children
        .map(row =>
          row.type === 'element'
            ? row.children
                .map(cell =>
                  cell.type === 'element' ? plainTextNodes(cell.children, projection).replace(/\n/g, ' ') : cell.value
                )
                .join('\t')
            : row.value
        )
        .join('\n')
      return
    }
    if (/^(p|h[1-6]|pre|mermaid|infographic|math)$/.test(node.name)) {
      if (!firstBlock) text += '\n'
      firstBlock = false
    }
    if (node.name === 'br') text += '\n'
    const asset = assetSource(node)
    // A resolved file address follows its link text or image, as a page link's address does.
    const resolved = asset && projection.resolveAsset ? projection.resolveAsset(asset[1]) : null
    if (asset && resolved) node.attrs[asset[0]] = resolved
    const resource = resourceText(node)
    if (resource !== null) {
      if (!firstBlock) text += '\n'
      firstBlock = false
      text += resource
    }
    if (node.name === 'img') {
      text += node.attrs.alt ? `(image: ${node.attrs.alt})` : '(image)'
      if (resolved) text += ` (${resolved})`
    }
    if (node.name === 'mention' && node.attrs.page) {
      const reference = projection.resolveReference?.(node.attrs.page)
      if (reference) text += reference.title
      return
    }
    if (node.name === 'mention' && node.attrs.principal) {
      const principal = projection.resolvePrincipal?.(node.attrs.principal)
      if (principal) text += `@${principal.name}`
      return
    }
    if (node.name === 'embed' && node.attrs.ref) {
      const reference = (projection.resolveEmbed ?? projection.resolveReference)?.(node.attrs.ref)
      if (reference) {
        if (!firstBlock) text += '\n'
        firstBlock = false
        text += reference.restricted ? reference.title : `${reference.title} (${reference.href})`
      }
    }
    node.children.forEach(visit)
    if (node.name === 'a' && resolved) text += ` (${resolved})`
    if (node.name === 'a' && node.attrs.href?.startsWith('ankole:page/')) {
      const reference = projection.resolveReference?.(node.attrs.href.slice('ankole:page/'.length))
      if (reference) text += ` (${reference.href})`
    }
  }
  nodes.forEach(visit)
  return text
}

const wordSegmenter = new Intl.Segmenter(undefined, { granularity: 'word' })
const CJK_SEGMENT_RE = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\u30fc]/u
const CJK_CHAR_RE = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\u30fc]/gu
const NON_WHITESPACE_TOKEN_RE = /\S+/g
const MATH_SYMBOL_TOKEN_RE = /\\[a-zA-Z]+|[a-zA-Z0-9]+/g

/** Brysbaert (2019) non-fiction silent reading baseline for word-spaced scripts. */
const NON_CJK_WORDS_PER_MINUTE = 238
/** IReST cross-language non-fiction baseline for Han, Hiragana, and Katakana text. */
const CJK_CHARS_PER_MINUTE = 350
/** Code and symbolic math are scanned token-by-token rather than read as prose. */
const CODE_TOKENS_PER_MINUTE = 50
/** Eye-tracking visual inspection baseline (~15s) per rendered diagram or image figure. */
const SECONDS_PER_VISUAL_BLOCK = 15
/** Standalone display equations carry brief visual framing before symbol scanning. */
const SECONDS_PER_DISPLAY_MATH = 5

const KNOWN_BLOCK_CONTAINERS = new Set([
  'page',
  'block',
  'columns',
  'column',
  'blockquote',
  'ul',
  'ol',
  'li',
  'tr',
  'th',
  'td',
  'callout'
])

const KNOWN_INLINE_ELEMENTS = new Set([
  'a',
  'img',
  'inline-math',
  'mention',
  'br',
  'span',
  'strong',
  'em',
  's',
  'u',
  'mark',
  'sub',
  'sup',
  'code'
])

function extractRawText(node: DocumentNode): string {
  const parts: string[] = []
  const collect = (current: DocumentNode) => {
    if (current.type === 'text') parts.push(current.value)
    else current.children.forEach(collect)
  }
  collect(node)
  return parts.join('')
}

function analyzeProse(text: string): { words: number; nonCjkWords: number; cjkChars: number } {
  if (!text) return { words: 0, nonCjkWords: 0, cjkChars: 0 }
  let words = 0
  let nonCjkWords = 0
  for (const { segment, isWordLike } of wordSegmenter.segment(text)) {
    if (!isWordLike) continue
    words++
    if (!CJK_SEGMENT_RE.test(segment)) nonCjkWords++
  }
  const cjkChars = text.match(CJK_CHAR_RE)?.length ?? 0
  return { words, nonCjkWords, cjkChars }
}

function estimateReadingMinutes(input: {
  nonCjkWords: number
  cjkChars: number
  codeTokens: number
  mathTokens: number
  displayMathCount: number
  visualCount: number
}): number {
  const minutes =
    input.nonCjkWords / NON_CJK_WORDS_PER_MINUTE +
    input.cjkChars / CJK_CHARS_PER_MINUTE +
    (input.codeTokens + input.mathTokens) / CODE_TOKENS_PER_MINUTE +
    (input.visualCount * SECONDS_PER_VISUAL_BLOCK + input.displayMathCount * SECONDS_PER_DISPLAY_MATH) / 60
  return minutes > 0 ? Math.ceil(minutes) : 0
}

/**
 * Compute prose authoring counts and multimodal reading time from the canonical `<page>` tree.
 * Diagrams (`<mermaid>`, `<infographic>`), fenced code (`<pre>`), formulas (`<math>`, `<inline-math>`),
 * and media/embeds stay out of prose word, character, and paragraph totals while contributing
 * cognitive scanning or visual inspection time to `readingTime`.
 */
export function documentStats(xml: string): EditingStats {
  const page = parseXml(xml)
  const proseChunks: string[] = []
  let characters = 0
  let paragraphs = 0
  let codeTokens = 0
  let mathTokens = 0
  let displayMathCount = 0
  let visualCount = 0

  const addMath = (raw: string, display: boolean) => {
    const source = unwrapMathDelimiters(raw).trim()
    if (!source) return
    mathTokens += source.match(MATH_SYMBOL_TOKEN_RE)?.length ?? 1
    if (display) displayMathCount++
  }

  const collectInlineProse = (children: DocumentNode[]): boolean => {
    const tokens: string[] = []
    let hasVisibleProse = false
    const visitInline = (node: DocumentNode) => {
      if (node.type === 'text') {
        if (!node.value) return
        characters += node.value.length
        tokens.push(node.value)
        if (node.value.trim()) hasVisibleProse = true
        return
      }
      if (node.name === 'inline-math') {
        addMath(extractRawText(node), false)
        tokens.push(' ')
        return
      }
      if (node.name === 'img') {
        if (node.attrs.src?.trim()) visualCount++
        tokens.push(' ')
        return
      }
      if (node.name === 'mention' || node.name === 'br') {
        tokens.push(' ')
        return
      }
      node.children.forEach(visitInline)
    }
    children.forEach(visitInline)
    if (tokens.length > 0) proseChunks.push(tokens.join(''))
    return hasVisibleProse
  }

  const visitBlock = (node: DocumentNode, insideTable: boolean): boolean => {
    if (node.type === 'text') {
      return node.value.trim() ? collectInlineProse([node]) : false
    }
    if (node.name === 'mermaid' || node.name === 'infographic') {
      if (extractRawText(node).trim()) visualCount++
      return false
    }
    if (node.name === 'pre') {
      codeTokens += extractRawText(node).match(NON_WHITESPACE_TOKEN_RE)?.length ?? 0
      return false
    }
    if (node.name === 'math') {
      addMath(extractRawText(node), true)
      return false
    }
    if (node.name === 'media') {
      const resource = resourceContent(node)
      if (resource?.image && resource.src.trim() && (!node.attrs.view || node.attrs.view === 'preview')) {
        visualCount++
      }
      return false
    }
    if (node.name === 'embed' || node.name === 'hr') {
      return false
    }
    if (node.name === 'table') {
      let tableHasProse = false
      for (const child of node.children) {
        if (visitBlock(child, true)) tableHasProse = true
      }
      if (tableHasProse && !insideTable) paragraphs++
      return tableHasProse
    }
    if (/^(p|h[1-6])$/.test(node.name)) {
      const hasProse = collectInlineProse(node.children)
      if (hasProse && !insideTable) paragraphs++
      return hasProse
    }
    if (
      !KNOWN_BLOCK_CONTAINERS.has(node.name) &&
      node.name !== 'comment' &&
      node.children.some(
        child =>
          (child.type === 'text' && Boolean(child.value.trim())) ||
          (child.type === 'element' && KNOWN_INLINE_ELEMENTS.has(child.name))
      )
    ) {
      const hasProse = collectInlineProse(node.children)
      if (hasProse && !insideTable) paragraphs++
      return hasProse
    }
    let hasProse = false
    for (const child of node.children) {
      if (visitBlock(child, insideTable)) hasProse = true
    }
    return hasProse
  }

  visitBlock(page, false)
  const { words, nonCjkWords, cjkChars } = analyzeProse(proseChunks.join(' '))
  return {
    words,
    characters,
    paragraphs,
    readingTime: estimateReadingMinutes({
      nonCjkWords,
      cjkChars,
      codeTokens,
      mathTokens,
      displayMathCount,
      visualCount
    })
  }
}

/** Plain-text statistics for active DOM selections and standalone prose strings. */
export function textStats(text: string): EditingStats {
  const { words, nonCjkWords, cjkChars } = analyzeProse(text)
  return {
    words,
    characters: text.length,
    paragraphs: text.split('\n').filter(line => line.trim()).length,
    readingTime: estimateReadingMinutes({
      nonCjkWords,
      cjkChars,
      codeTokens: 0,
      mathTokens: 0,
      displayMathCount: 0,
      visualCount: 0
    })
  }
}

export function documentFilename(
  title: string,
  fallback = 'document',
  extension: 'md' | 'docx' | 'pdf' = 'md'
): string {
  const name = title
    .trim()
    .replace(/^\.+/, '')
    .replace(/[\\/:*?"<>|\p{Cc}]+/gu, '-')
    .replace(/\s+/g, '-')
    .replace(/^[.-]+|-+$/g, '')
    .slice(0, 60)
  return `${name || fallback}.${extension}`
}
