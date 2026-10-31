import { parseXml, printMarkdown, resourceContent, resourceText } from '@ankole/block-editor/document'

type DocumentElement = ReturnType<typeof parseXml>
type DocumentNode = DocumentElement['children'][number]

export type DocumentReference = { title: string; href: string; filePageID?: string; restricted?: boolean }
export type DocumentPrincipalReference = { name: string; restricted?: boolean }
export type DocumentProjection = {
  resolveAsset?: (source: string) => string
  resolveReference?: (ref: string) => DocumentReference | undefined
  resolveEmbed?: (ref: string) => DocumentReference | undefined
  resolvePrincipal?: (uid: string) => DocumentPrincipalReference | undefined
  /** Statistics count the text people wrote, not resource titles and addresses. */
  omitResources?: boolean
}

function walkDocument(xml: string, visit: (node: DocumentElement) => void): DocumentElement {
  const page = parseXml(xml)
  const walk = (node: DocumentNode) => {
    if (node.type === 'text') return
    visit(node)
    node.children.forEach(walk)
  }
  walk(page)
  return page
}

function assetSource(node: DocumentElement): [string, string] | undefined {
  const attribute = ['img', 'media', 'bookmark'].includes(node.name) ? 'src' : node.name === 'a' ? 'href' : undefined
  const source = attribute && node.attrs[attribute]
  return attribute && source?.startsWith('ankole:asset/') ? [attribute, source] : undefined
}

export function documentReferenceIDs(xml: string): string[] {
  const refs = new Set<string>()
  walkDocument(xml, node => {
    if (node.name === 'embed' && node.attrs.ref) refs.add(node.attrs.ref)
    if (node.name === 'mention' && node.attrs.page) refs.add(node.attrs.page)
    if (node.name === 'a' && node.attrs.href?.startsWith('ankole:page/')) {
      refs.add(node.attrs.href.slice('ankole:page/'.length))
    }
  })
  return [...refs]
}

export function documentEmbedIDs(xml: string): string[] {
  const refs = new Set<string>()
  walkDocument(xml, node => {
    if (node.name === 'embed' && node.attrs.ref) refs.add(node.attrs.ref)
  })
  return [...refs]
}

export function documentPrincipalUIDs(xml: string): string[] {
  const uids = new Set<string>()
  walkDocument(xml, node => {
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
    if (/^(p|h[1-6]|pre)$/.test(node.name)) {
      if (!firstBlock) text += '\n'
      firstBlock = false
    }
    if (node.name === 'br') text += '\n'
    const asset = assetSource(node)
    // A resolved file address follows its link text or image, as a page link's address does.
    const resolved = asset && projection.resolveAsset ? projection.resolveAsset(asset[1]) : null
    if (asset && resolved) node.attrs[asset[0]] = resolved
    const resource = projection.omitResources ? null : resourceText(node)
    if (resource !== null) {
      if (!firstBlock) text += '\n'
      firstBlock = false
      text += resource
    }
    if (node.name === 'img' && !projection.omitResources) {
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

/** Unicode word boundaries cover unspaced CJK text; reading time estimates 200 words per minute. */
export function textStats(text: string) {
  let words = 0
  for (const segment of wordSegmenter.segment(text)) {
    if (segment.isWordLike) words++
  }
  return {
    words,
    characters: text.length,
    paragraphs: text.split('\n').filter(line => line.trim()).length,
    readingTime: Math.ceil(words / 200)
  }
}

export function documentFilename(title: string, fallback = 'document'): string {
  const name = title
    .trim()
    .replace(/^\.+/, '')
    .replace(/[\\/:*?"<>|\p{Cc}]+/gu, '-')
    .replace(/\s+/g, '-')
    .replace(/^[.-]+|-+$/g, '')
    .slice(0, 60)
  return `${name || fallback}.md`
}
