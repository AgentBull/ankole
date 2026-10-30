/*
 * Page tree <-> editor document.
 *
 * `pageDocument(tree)` applies N and builds the document; the document constructor checks it
 * against the schema. `readTree(doc)` writes every leaf with its own marks as wrapping elements and
 * applies N, which merges and re-nests them.
 */
import { Leaf, Mark, type Node, type Plot } from '../core/doc'
import type { GardState, Transaction } from '../core/state'
import * as T from '../core/types'
import { normalizeTree } from '../document/normalize'
import { element, removeInvalidCharacters, text, type Element, type Node as PageNode } from '../document/tree'
import { blocks as blockDefinitions } from '../blocks'
import {
  codeNodes,
  extraAttrs as extra,
  extraOf as attrsBack,
  markSet,
  markValue,
  pairsOf,
  recordOf,
  type Pairs
} from './attributes'
import * as S from './schema'
import { commentIDs } from '../document/comments'

export function freeze(node: Element): S.Frozen {
  return Object.freeze({
    name: node.name,
    attrs: Object.freeze(pairsOf(node.attrs).map(pair => Object.freeze(pair))) as Pairs,
    children: Object.freeze(node.children.map(child => (child.type === 'text' ? child.value : freeze(child))))
  })
}

export function thaw(frozen: S.Frozen): Element {
  return element(
    frozen.name,
    recordOf(frozen.attrs),
    frozen.children.map(child => (typeof child === 'string' ? text(child) : thaw(child)))
  )
}

const is = (node: Node, type: { type: unknown } | unknown) => node.type === ((type as { type?: unknown }).type ?? type)

// ---------------------------------------------------------------------------
// Page tree -> document

/** The editor document for a page tree. Applies N first. An empty page gets its placeholder paragraph. */
export function pageDocument(tree: Element): Plot.Doc {
  return normalizedPageDocument(normalizeTree(tree))
}

/** @internal Builds a document from an already validated normal form. */
export function normalizedPageDocument(page: Element): Plot.Doc {
  const content = (page.children as Element[]).map(block)
  return S.schema.doc(content.length ? content : [T.Paragraph.withMarks([S.PagePlaceholder]).create([])])
}

/** A transaction that replaces the whole page. */
export function replaceTree(state: GardState, tree: Element): Transaction.Spec {
  const doc = pageDocument(tree)
  return { changes: { from: 0, to: state.doc.length, insert: doc.content } }
}

const blocks = (node: Element) => (node.children as Element[]).map(block)
const codeContent = (nodes: readonly PageNode[]) =>
  inline(nodes).flatMap(leaf => codeNodes((leaf as Leaf).param as string, leaf.marks))
const blockImport = { blocks: (nodes: readonly PageNode[]) => (nodes as Element[]).map(block), code: codeContent }

function textBlockMarks(attrs: Record<string, string>) {
  return markSet([
    attrs.align && S.Align.of(attrs.align as 'left'),
    attrs.indent && S.Indent.of(Number(attrs.indent)),
    attrs.style && S.BlockStyle.of(attrs.style),
    extra(attrs, ['align', 'indent', 'style'])
  ])
}

function block(node: Element): Node {
  const attrs = node.attrs
  switch (node.name) {
    case 'block':
      return S.BlockGroup.withMarks(markSet([extra(attrs)])).create(blocks(node))
    case 'columns':
      return S.Columns.withMarks(markSet([extra(attrs)])).create(blocks(node))
    case 'column':
      return S.Column.withMarks(
        markSet([attrs.width && S.ColumnWidth.of(Number(attrs.width)), extra(attrs, ['width'])])
      ).create(blocks(node))
    case 'p':
      return T.Paragraph.withMarks(textBlockMarks(attrs)).create(inline(node.children))
    case 'h1':
    case 'h2':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
      return T.Heading.of(Number(node.name[1]), textBlockMarks(attrs)).create(inline(node.children))
    case 'blockquote':
      return S.Blockquote.withMarks(markSet([extra(attrs)])).create(blocks(node))
    case 'ul':
      return T.BulletList.withMarks(markSet([extra(attrs)])).create((node.children as Element[]).map(item))
    case 'ol':
      return T.OrderedList.of(
        attrs.start === undefined ? 1 : Number(attrs.start),
        markSet([extra(attrs, ['start'])])
      ).create((node.children as Element[]).map(item))
    case 'pre':
      return T.CodeBlock.withMarks(
        markSet([
          attrs.lang !== undefined && T.CodeBlockLanguage.of(attrs.lang),
          attrs.meta !== undefined && S.CodeMeta.of(attrs.meta),
          attrs.wrap !== undefined && S.CodeWrap.of(attrs.wrap),
          extra(attrs, ['lang', 'meta', 'wrap'])
        ])
      ).create(codeContent(node.children))
    case 'hr':
      return T.HorizontalRule.withMarks(markSet([extra(attrs)]))
    case 'table':
      return S.Table.withMarks(
        markSet([
          attrs.widths && S.TableWidths.of(attrs.widths),
          attrs.layout && S.TableLayout.of('full'),
          extra(attrs, ['widths', 'layout'])
        ])
      ).create(
        (node.children as Element[]).map(row =>
          S.TableRow.withMarks(markSet([extra(row.attrs)])).create((row.children as Element[]).map(cell))
        )
      )
    default: {
      const definition = blockDefinitions.find(definition => definition.name === node.name)
      return definition ? definition.import(node, blockImport) : S.UnknownBlock.of(freeze(node))
    }
  }
}

function item(node: Element): Node {
  const { task } = node.attrs
  return S.ListItem.withMarks(markSet([task && S.Task.of(task as 'todo'), extra(node.attrs, ['task'])])).create(
    blocks(node)
  )
}

function cell(node: Element): Node {
  const { align, colspan, rowspan, background } = node.attrs
  return (node.name === 'th' ? S.HeaderCell : S.DataCell)
    .withMarks(
      markSet([
        align && S.Align.of(align as 'left'),
        colspan && T.ColSpan.of(Number(colspan)),
        rowspan && T.RowSpan.of(Number(rowspan)),
        background && S.CellBackground.of(background),
        extra(node.attrs, ['align', 'colspan', 'rowspan', 'background'])
      ])
    )
    .create(blocks(node))
}

type Context = { formats: Mark[]; style: string; link: Pairs | null; comments: readonly string[] }

const joinStyle = (outer: string, inner: string) =>
  !outer.trim() ? inner : !inner.trim() ? outer : `${outer}${/;\s*$/.test(outer) ? '' : ';'} ${inner}`

const contextMarks = (context: Context) =>
  markSet([
    ...context.formats,
    context.style && S.TextStyle.of(context.style),
    context.link && S.Link.of(context.link),
    context.comments.length > 0 && S.Comment.of(context.comments)
  ])

/** Flatten normalized inline content into leaves with mark sets, as N flattens it. */
function inline(
  nodes: readonly PageNode[],
  context: Context = { formats: [], style: '', link: null, comments: [] },
  out: Node[] = []
): Node[] {
  for (const node of nodes) {
    if (node.type === 'text') {
      out.push(Leaf.text(node.value, contextMarks(context)))
      continue
    }
    const plain = Object.keys(node.attrs).length === 0
    const format = Object.hasOwn(S.formats, node.name) ? S.formats[node.name as keyof typeof S.formats] : undefined
    if (format && plain) inline(node.children, { ...context, formats: [...context.formats, format] }, out)
    else if (node.name === 'comment') {
      inline(
        node.children,
        { ...context, comments: [...new Set([...context.comments, ...commentIDs(node.attrs.ids!)])].sort() },
        out
      )
    } else if (node.name === 'span' && Object.keys(node.attrs).every(name => name === 'style')) {
      inline(node.children, { ...context, style: joinStyle(context.style, node.attrs.style ?? '') }, out)
    } else if (node.name === 'a' && node.children.length) {
      inline(node.children, { ...context, link: pairsOf(node.attrs) }, out)
    } else if (node.name === 'br') {
      out.push(
        T.LineBreak.withMarks(
          markSet([
            context.link && S.Link.of(context.link),
            context.comments.length > 0 && S.Comment.of(context.comments),
            extra(node.attrs)
          ])
        )
      )
    } else if (node.name === 'img') {
      out.push(
        T.Image.of(
          node.attrs.src!,
          markSet([
            node.attrs.alt !== undefined && T.ImageAlt.of(node.attrs.alt),
            node.attrs.title !== undefined && S.ImageTitle.of(node.attrs.title),
            context.link && S.Link.of(context.link),
            context.comments.length > 0 && S.Comment.of(context.comments),
            extra(node.attrs, ['src', 'alt', 'title'])
          ])
        )
      )
    } else if (node.name === 'mention') {
      const target: S.MentionTarget =
        node.attrs.page !== undefined ? { page: node.attrs.page } : { principal: node.attrs.principal! }
      out.push(
        S.Mention.of(
          target,
          markSet([
            ...context.formats,
            context.style && S.TextStyle.of(context.style),
            context.comments.length > 0 && S.Comment.of(context.comments),
            extra(node.attrs, ['page', 'principal'])
          ])
        )
      )
    } else out.push(S.InlineElement.of(freeze(node), contextMarks(context)))
  }
  return out
}

// ---------------------------------------------------------------------------
// Document -> page tree

/**
 * The page tree of an editor document. Applies N. An empty placeholder paragraph is not read.
 * Characters that XML 1.0 does not allow, such as pasted control characters or half of a surrogate
 * pair during input, are not read; the document keeps them.
 */
export function readTree(doc: Plot.Doc): Element {
  const content = doc.content.filter(
    node => !(node.isPlot && !node.content.length && S.PagePlaceholder.isInSet(node.marks))
  )
  return normalizeTree(clean(element('page', {}, content.map(blockBack))))
}

function clean(node: Element): Element {
  return element(
    node.name,
    Object.fromEntries(Object.entries(node.attrs).map(([name, value]) => [name, removeInvalidCharacters(value)])),
    node.children.map(child => (child.type === 'text' ? text(removeInvalidCharacters(child.value)) : clean(child)))
  )
}

function textBlockAttrs(node: Plot) {
  const align = markValue(node, S.Align)
  const indent = markValue(node, S.Indent)
  const style = markValue(node, S.BlockStyle)
  return {
    ...attrsBack(node),
    ...(align ? { align } : {}),
    ...(indent ? { indent: String(indent) } : {}),
    ...(style ? { style } : {})
  }
}

function codeBack(node: Plot): PageNode[] {
  return node.content.map(leaf => {
    const value = text(leaf.isText ? (leaf.param as string) : '\n')
    const ids = markValue(leaf, S.Comment)
    return ids?.length ? element('comment', { ids: ids.join(' ') }, [value]) : value
  })
}
const blockRead = { children: (node: Plot) => node.content.map(blockBack), code: codeBack }

function blockBack(node: Node): PageNode {
  const definition = blockDefinitions.find(definition => definition.type === node.type)
  if (definition) return definition.read(node, blockRead)
  if (node.isLeaf) {
    if (is(node, T.HorizontalRule)) return element('hr', attrsBack(node))
    if (is(node, S.UnknownBlock)) return thaw(node.param as S.Frozen)
    throw new Error(`Unexpected block leaf ${node.name}`)
  }
  const children = () => node.content.map(blockBack)
  if (is(node, S.BlockGroup)) return element('block', attrsBack(node), children())
  if (is(node, S.Columns)) return element('columns', attrsBack(node), children())
  if (is(node, S.Column)) {
    const width = markValue(node, S.ColumnWidth)
    return element(
      'column',
      { ...attrsBack(node), ...(width && width !== 1000 ? { width: String(width) } : {}) },
      children()
    )
  }
  if (is(node, T.Paragraph)) return element('p', textBlockAttrs(node), inlineBack(node.content))
  if (is(node, T.Heading)) return element(`h${node.tag.param}`, textBlockAttrs(node), inlineBack(node.content))
  if (is(node, S.Blockquote)) return element('blockquote', attrsBack(node), children())
  if (is(node, T.BulletList)) return element('ul', attrsBack(node), node.content.map(itemBack))
  if (is(node, T.OrderedList)) {
    const start = node.tag.param as number
    return element(
      'ol',
      { ...attrsBack(node), ...(start !== 1 ? { start: String(start) } : {}) },
      node.content.map(itemBack)
    )
  }
  if (is(node, T.CodeBlock)) {
    const lang = markValue(node, T.CodeBlockLanguage)
    const meta = markValue(node, S.CodeMeta)
    const wrap = markValue(node, S.CodeWrap)
    const content = codeBack(node)
    return element(
      'pre',
      {
        ...attrsBack(node),
        ...(lang !== undefined ? { lang } : {}),
        ...(meta !== undefined ? { meta } : {}),
        ...(wrap !== undefined ? { wrap } : {})
      },
      content
    )
  }
  if (is(node, S.Table)) {
    return element(
      'table',
      {
        ...attrsBack(node),
        ...(node.mark(S.TableWidths) ? { widths: node.mark(S.TableWidths)! } : {}),
        ...(node.mark(S.TableLayout) ? { layout: node.mark(S.TableLayout)! } : {})
      },
      node.content.map(row => element('tr', attrsBack(row), (row as Plot).content.map(cellBack)))
    )
  }
  throw new Error(`Unexpected block ${node.name}`)
}

function itemBack(node: Node): PageNode {
  const task = markValue(node, S.Task)
  return element('li', { ...attrsBack(node), ...(task ? { task } : {}) }, (node as Plot).content.map(blockBack))
}

function cellBack(node: Node): PageNode {
  const align = markValue(node, S.Align)
  const colspan = markValue(node, T.ColSpan)
  const rowspan = markValue(node, T.RowSpan)
  return element(
    is(node, S.HeaderCell) ? 'th' : 'td',
    {
      ...attrsBack(node),
      ...(align ? { align } : {}),
      ...(colspan ? { colspan: String(colspan) } : {}),
      ...(rowspan ? { rowspan: String(rowspan) } : {}),
      ...(node.mark(S.CellBackground) ? { background: node.mark(S.CellBackground)! } : {})
    },
    (node as Plot).content.map(blockBack)
  )
}

const formatNames = new Map<unknown, string>(Object.entries(S.formats).map(([name, mark]) => [mark.type, name]))

function inlineBack(nodes: readonly Node[]): PageNode[] {
  return nodes.map(node => {
    let result: PageNode
    if (node.isText) result = text(node.param as string)
    else if (is(node, T.LineBreak)) result = element('br', attrsBack(node))
    else if (is(node, T.Image)) {
      const alt = markValue(node, T.ImageAlt)
      const title = markValue(node, S.ImageTitle)
      result = element('img', {
        ...attrsBack(node),
        src: (node as Leaf).param as string,
        ...(alt !== undefined ? { alt } : {}),
        ...(title !== undefined ? { title } : {})
      })
    } else if (is(node, S.Mention)) {
      const target = (node as Leaf).param as S.MentionTarget
      result = element('mention', {
        ...attrsBack(node),
        ...('page' in target ? { page: target.page } : { principal: target.principal })
      })
    } else if (is(node, S.InlineElement)) result = thaw((node as Leaf).param as S.Frozen)
    else throw new Error(`Unexpected inline node ${node.name}`)
    for (const mark of node.marks) {
      const name = formatNames.get(mark.type)
      if (name) result = element(name, {}, [result])
    }
    const style = markValue(node, S.TextStyle)
    if (style) result = element('span', { style }, [result])
    const link = markValue(node, S.Link)
    if (link) result = element('a', recordOf(link), [result])
    const comments = markValue(node, S.Comment)
    if (comments?.length) result = element('comment', { ids: comments.join(' ') }, [result])
    return result
  })
}
