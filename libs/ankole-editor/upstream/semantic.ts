import type { Node as CommonmarkNode } from 'commonmark'
import type { Node as EditorNode, Leaf, Plot } from '../src/core/doc'
import * as T from '../src/core/types'
import { Callout } from '../src/blocks/callout'
import { Database } from '../src/blocks/database'
import { textOf, type Node } from '../src/document/tree'
import { markValue } from '../src/editor/attributes'
import { thaw } from '../src/editor/convert'
import * as S from '../src/editor/schema'

/** What a reader sees: blocks, text with formats, links and images. */
export type Content = {
  tag: string
  text?: string
  format?: number
  attrs?: Record<string, unknown>
  children?: Content[]
}

const formats: Record<string, number> = {
  strong: 1,
  em: 2,
  s: 4,
  u: 8,
  code: 16,
  sub: 32,
  sup: 64,
  mark: 128
}
const bold = formats.strong!
const italic = formats.em!

// White space looks the same in bold or italic text. A soft break shows as a space.
function merge(nodes: Content[]): Content[] {
  const result: Content[] = []
  for (const node of nodes.flatMap(spaces)) {
    if (node.tag === 'text' && !node.text) continue
    const previous = result.at(-1)
    if (node.tag === 'text' && previous?.tag === 'text' && previous.format === node.format) {
      previous.text += node.text ?? ''
    } else if (
      node.tag === 'a' &&
      previous?.tag === 'a' &&
      node.attrs?.href === previous.attrs?.href &&
      node.attrs?.title === previous.attrs?.title
    ) {
      previous.children = merge([...previous.children!, ...node.children!])
    } else result.push(node)
  }
  return result
}

function spaces(node: Content): Content[] {
  if (node.tag !== 'text' || !node.text || !(node.format! & (bold | italic))) return [node]
  return node.text
    .split(/(\s+)/u)
    .filter(Boolean)
    .map(part => ({ ...node, text: part, format: /^\s+$/u.test(part) ? node.format! & ~(bold | italic) : node.format }))
}

function text(value: string, format = 0): Content[] {
  return value
    .split(/(\n)/)
    .filter(Boolean)
    .map(part => ({ tag: 'text', text: part, format: part === '\n' ? 0 : format }))
}

function url(value: unknown) {
  try {
    return decodeURI(String(value ?? ''))
  } catch {
    return String(value ?? '')
  }
}

function listItem(children: Content[]): Content[] {
  const result: Content[] = []
  for (const child of children) {
    if (child.tag === 'p') {
      if (result.length && result.at(-1)?.tag === 'text') result.push({ tag: 'paragraph-break' })
      result.push(...(child.children ?? []))
    } else if (child.tag !== 'paragraph-break' || result.at(-1)?.tag === 'text') result.push(child)
  }
  return merge(result)
}

/**
 * Inspect the editor document directly. Do not pass it through the page reader or the Markdown
 * printer. The empty paragraph that an empty page shows is not content (SPEC §7.2).
 */
export function editorContent(doc: Plot.Doc): Content {
  const blocks = doc.content.filter(
    node => !(node.isPlot && !node.content.length && S.PagePlaceholder.isInSet(node.marks))
  )
  return { tag: 'doc', children: merge(blocks.flatMap(editorBlock)) }
}

const is = (node: EditorNode, type: { type: unknown } | unknown) =>
  node.type === ((type as { type?: unknown }).type ?? type)

function editorBlock(node: EditorNode): Content[] {
  if (is(node, S.UnknownBlock)) return elementContent(thaw((node as Leaf).param as S.Frozen))
  if (is(node, T.HorizontalRule)) return [{ tag: 'hr', children: [] }]
  if (is(node, Database)) return [{ tag: 'database', children: [] }]
  if (node.isLeaf) throw new Error(`No content adapter for editor leaf ${node.name}`)
  if (is(node, T.Paragraph)) return [{ tag: 'p', children: editorInline(node.content) }]
  if (is(node, T.Heading)) return [{ tag: `h${node.tag.param}`, children: editorInline(node.content) }]
  if (is(node, T.CodeBlock)) {
    const value = node.content.map(leaf => (leaf.isText ? (leaf.param as string) : '\n')).join('')
    return [{ tag: 'pre', text: value, attrs: { language: markValue(node, T.CodeBlockLanguage) ?? '' } }]
  }
  const children = node.content.flatMap(editorBlock)
  if (is(node, T.OrderedList)) return [{ tag: 'ol', attrs: { start: node.tag.param }, children }]
  if (is(node, S.ListItem)) {
    const task = markValue(node, S.Task)
    return [{ tag: 'li', ...(task ? { attrs: { checked: task === 'done' } } : {}), children: listItem(children) }]
  }
  const tag = [
    [T.BulletList, 'ul'],
    [S.Blockquote, 'blockquote'],
    [S.Table, 'table'],
    [S.TableRow, 'tr'],
    [S.HeaderCell, 'th'],
    [S.DataCell, 'td'],
    [Callout, 'callout']
  ].find(([type]) => is(node, type))?.[1]
  if (!tag) throw new Error(`No content adapter for editor node ${node.name}`)
  return [{ tag: tag as string, children: merge(children) }]
}

function editorInline(nodes: readonly EditorNode[]): Content[] {
  return merge(
    nodes.flatMap(node => {
      const format = Object.entries(S.formats).reduce(
        (bits, [name, mark]) => bits | (mark.isInSet(node.marks) ? formats[name]! : 0),
        0
      )
      let content: Content[]
      if (node.isText) content = text(node.param as string, format)
      else if (is(node, T.LineBreak)) content = text('\n')
      else if (is(node, T.Image)) {
        const alt = markValue(node, T.ImageAlt)
        const title = markValue(node, S.ImageTitle)
        content = [{ tag: 'img', attrs: { src: url((node as Leaf).param), alt: alt ?? '', title: title ?? '' } }]
      } else if (is(node, S.InlineElement)) content = elementContent(thaw((node as Leaf).param as S.Frozen), format)
      else throw new Error(`No content adapter for editor node ${node.name}`)
      const link = markValue(node, S.Link)
      if (!link) return content
      const attr = (name: string) => link.find(pair => pair[0] === name)?.[1]
      return [{ tag: 'a', attrs: { href: url(attr('href')), title: attr('title') ?? '' }, children: merge(content) }]
    })
  )
}

/** Content of a page element. Unknown elements look like no CommonMark output. */
export function elementContent(node: Node, format = 0): Content[] {
  if (node.type === 'text') return text(node.value, format)
  const bit = formats[node.name]
  if (bit !== undefined) return node.children.flatMap(child => elementContent(child, format | bit))
  if (node.name === 'span') return node.children.flatMap(child => elementContent(child, format))
  if (node.name === 'br') return text('\n')
  const children = merge(node.children.flatMap(child => elementContent(child, format)))
  const { attrs } = node
  switch (node.name) {
    case 'page':
      return [{ tag: 'doc', children }]
    case 'a':
      return [{ tag: 'a', attrs: { href: url(attrs.href), title: attrs.title ?? '' }, children }]
    case 'img':
      return [{ tag: 'img', attrs: { src: url(attrs.src), alt: attrs.alt ?? '', title: attrs.title ?? '' } }]
    case 'pre':
      return [{ tag: 'pre', text: textOf(node), attrs: { language: attrs.lang ?? '' } }]
    case 'ol':
      return [{ tag: 'ol', attrs: { start: Number(attrs.start ?? 1) }, children }]
    case 'li':
      return [
        {
          tag: 'li',
          ...(attrs.task ? { attrs: { checked: attrs.task === 'done' } } : {}),
          children: listItem(children)
        }
      ]
    case 'p':
    case 'h1':
    case 'h2':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
    case 'blockquote':
    case 'ul':
    case 'hr':
    case 'table':
    case 'tr':
    case 'th':
    case 'td':
    case 'callout':
    case 'database':
      return [{ tag: node.name, children }]
    default:
      return [{ tag: 'unknown', attrs: { name: node.name }, children }]
  }
}

/** The reference parser keeps raw HTML as data. A page reads tags instead, so raw HTML never matches. */
export function commonmarkContent(node: CommonmarkNode, format = 0): Content {
  const nestedFormat = format | (node.type === 'strong' ? 1 : node.type === 'emph' ? 2 : node.type === 'code' ? 16 : 0)
  const children: Content[] = []
  // Line break characters in HTML text show as one space.
  let literal = ''
  const flush = () => {
    children.push(...text(literal.replace(/[ \t]*\n[ \t\n]*/g, ' '), nestedFormat))
    literal = ''
  }
  for (let child = node.firstChild; child; child = child.next) {
    if (child.type === 'text') {
      literal += child.literal ?? ''
      continue
    }
    flush()
    if (child.type === 'code') children.push(...text(child.literal ?? '', nestedFormat | 16))
    else if (child.type === 'strong' || child.type === 'emph') {
      children.push(...(commonmarkContent(child, nestedFormat).children ?? []))
    } else children.push(commonmarkContent(child, nestedFormat))
  }
  flush()
  if (node.type === 'softbreak') return { tag: 'text', text: ' ', format: 0 }
  if (node.type === 'linebreak') return { tag: 'text', text: '\n', format: 0 }
  if (node.type === 'html_inline' || node.type === 'html_block') {
    return { tag: 'raw-html', text: node.literal?.replace(/\n+$/, '') ?? '' }
  }
  if (node.type === 'code_block') {
    return {
      tag: 'pre',
      text: node.literal?.replace(/\n$/, '') ?? '',
      attrs: { language: node.info?.split(/\s+/)[0] ?? '' }
    }
  }
  if (node.type === 'link') {
    return { tag: 'a', attrs: { href: url(node.destination), title: node.title ?? '' }, children: merge(children) }
  }
  if (node.type === 'image') {
    const plain = (node: Content): string =>
      node.tag === 'img' ? String(node.attrs?.alt ?? '') : (node.text ?? node.children?.map(plain).join('') ?? '')
    return {
      tag: 'img',
      attrs: { src: url(node.destination), title: node.title ?? '', alt: children.map(plain).join('') }
    }
  }
  if (node.type === 'list') {
    return {
      tag: node.listType === 'ordered' ? 'ol' : 'ul',
      ...(node.listType === 'ordered' ? { attrs: { start: node.listStart } } : {}),
      children
    }
  }
  if (node.type === 'item') return { tag: 'li', children: listItem(children) }
  const tags: Record<string, string> = {
    document: 'doc',
    paragraph: 'p',
    block_quote: 'blockquote',
    heading: `h${node.level}`,
    thematic_break: 'hr'
  }
  return { tag: tags[node.type] ?? node.type, children: merge(children) }
}

export type TiptapNode = {
  type: string
  content?: TiptapNode[]
  text?: string
  attrs?: Record<string, unknown>
  marks?: { type: string; attrs?: Record<string, unknown> }[]
}

// Tiptap splits a list where task items and plain items meet. GFM and a page keep one list.
function joinTaskLists(nodes: TiptapNode[]): TiptapNode[] {
  const result: TiptapNode[] = []
  for (const node of nodes) {
    const previous = result.at(-1)
    const types = [previous?.type, node.type]
    if (types.every(type => type === 'bulletList' || type === 'taskList') && types.includes('taskList')) {
      result[result.length - 1] = { type: 'bulletList', content: [...previous!.content!, ...node.content!] }
    } else result.push(node)
  }
  return result
}

/** Translate upstream assertions, without importing the upstream editor. */
export function tiptapContent(node: TiptapNode): Content {
  const names: Record<string, number> = {
    bold: 1,
    italic: 2,
    strike: 4,
    underline: 8,
    code: 16,
    subscript: 32,
    superscript: 64,
    highlight: 128
  }
  const runs = joinTaskLists(node.content ?? []).flatMap(child => {
    if (child.type !== 'text') return [tiptapContent(child)]
    const format = child.marks?.reduce((bits, mark) => bits | (names[mark.type] ?? 0), 0) ?? 0
    const children = text(child.text ?? '', format)
    const link = child.marks?.find(mark => mark.type === 'link')
    return link
      ? [{ tag: 'a', attrs: { href: url(link.attrs?.href), title: link.attrs?.title ?? '' }, children }]
      : children
  })
  if (node.type === 'hardBreak') return { tag: 'text', text: '\n', format: 0 }
  if (node.type === 'orderedList') return { tag: 'ol', attrs: { start: node.attrs?.start ?? 1 }, children: runs }
  if (node.type === 'bulletList' || node.type === 'taskList') return { tag: 'ul', children: runs }
  if (node.type === 'listItem' || node.type === 'taskItem') {
    return {
      tag: 'li',
      ...(node.type === 'taskItem' ? { attrs: { checked: node.attrs?.checked ?? false } } : {}),
      children: listItem(runs)
    }
  }
  const tag = {
    doc: 'doc',
    paragraph: 'p',
    blockquote: 'blockquote',
    customBlock: 'callout',
    heading: `h${node.attrs?.level}`
  }[node.type]
  if (!tag) throw new Error(`No assertion adapter for Tiptap ${node.type}`)
  return { tag, children: merge(runs) }
}
