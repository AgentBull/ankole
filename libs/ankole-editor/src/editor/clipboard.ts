/*
 * Copy and paste (SPEC §7.5 Paste and copy).
 *
 * The core writes clipboard HTML from the node shapes and stores the exact slice next to it, so a
 * paste into an editor with this schema loses nothing. Other HTML is read through the parse rules
 * of the schema. This module decides what a copy holds and how pasted content joins the page:
 *
 *  - A copy extends the selection over each fully selected container (quote, callout, list item,
 *    cell, list, table). Cells, rows and list items carry their row, table or list. A cell
 *    selection copies a table of the selected cells.
 *  - Pasted content keeps only text blocks open at its edges. The first block joins the block at
 *    the caret when it is a text block, and the text after the caret joins the last block when that
 *    is a text block. Other blocks are inserted whole.
 *  - Plain text that reads as Markdown beyond plain paragraphs is pasted as page content.
 */
import { Node, Plot, type Leaf, type Pos, type Schema, Slice, Token } from '../core/doc'
import { Wordgard } from '../core/editor'
import { Command, deleteCut } from '../core/command'
import { writeClipboard } from '../core/editor/clipboard'
import { GardSelection, Transaction, type GardState } from '../core/state'
import { CellSelection } from '../core/table'
import * as T from '../core/types'
import { parseMarkdown } from '../document/markdown'
import { element, type Element } from '../document/tree'
import { assetURL, resourceContent, resourceText } from '../document/resources'
import { blocks } from '../blocks'
import { unknownNames, vocabulary } from '../document/vocabulary'
import { recordOf } from './attributes'
import { dispatchStep } from './block-insert'
import { pageDocument } from './convert'
import { BlockSelection } from './block-selection'
import { withoutCommentSlice } from './comments'
import { hostFacet } from './host-context'
import { linkAt } from './links'
import { inheritedMentionMarks } from './mention'
import { Comment, Link, Mention, type MentionTarget } from './schema'
import { wordListHTML } from './word-lists'

// A same-editor cut is a one-use move. The operating-system clipboard contains only an opaque
// token and portable content; another page, a second paste, or undo uses ordinary stripped content.
const cutMime = 'application/x-ankole-cut'
const cuts = new WeakMap<Wordgard, { token: string; slice: Slice }>()

const isOpen = (token: Token): token is Plot.Tag => token.tokenType == Token.Type.Open
const isClose = (token: Token) => token.tokenType == Token.Type.Close

/** The number of plots that the tokens close without opening them: the plots open at the start. */
function closedCount(tokens: readonly Token[]) {
  let open = 0,
    closed = 0
  for (const token of tokens) {
    if (isOpen(token)) open++
    else if (isClose(token)) open ? open-- : closed++
  }
  return closed
}

// ---------------------------------------------------------------------------
// Copy

/**
 * Extend the range over the outermost container whose content it covers at each end. Text blocks
 * are not containers: a fully selected paragraph still pastes into the block at the caret.
 */
function wholeContainers(doc: Plot.Doc, from: number, to: number) {
  const covers = (plot: Pos.Plot) =>
    !plot.node.inlineContent &&
    (from <= plot.start || doc.slice(plot.start, from).every(isOpen)) &&
    (to >= plot.end || doc.slice(to, plot.end).every(isClose))
  let start = from,
    end = to
  for (let plot = doc.resolve(from).parent; plot.parent; plot = plot.parent) if (covers(plot)) start = plot.before
  for (let plot = doc.resolve(to).parent; plot.parent; plot = plot.parent) if (covers(plot)) end = plot.after
  return { from: start, to: end }
}

/** The selected cells, by row, in a copy of their table. */
function selectedCells(doc: Plot.Doc, selection: CellSelection): Slice {
  // Rows by position: equal rows may be one node object.
  const rows = new Map<number, { row: Plot; cells: Node[] }>()
  let table: Pos.Plot | null = null
  for (const { from } of selection.ranges) {
    const cell = doc.resolve(from).parent
    const row = cell.parent!
    table = row.parent!
    const entry = rows.get(row.before) ?? { row: row.node, cells: [] }
    entry.cells.push(cell.node)
    rows.set(row.before, entry)
  }
  const copy = table!.node.tag.create([...rows.values()].map(({ row, cells }) => row.tag.create(cells)))
  return Slice.of([copy])
}

function copySelection(state: GardState): Slice | null {
  const { selection, doc, schema } = state
  if (selection.empty) return null
  if (selection instanceof CellSelection) return selectedCells(doc, selection)
  if (selection instanceof BlockSelection) {
    const slice = selection.toSlice(doc)
    return normalize(schema, slice.content, [], slice.context)
  }
  const { from, to } = wholeContainers(doc, selection.from, selection.to)
  const tokens = doc.slice(from, to)
  const context = doc.contextAt(from)
  // Only the plots that the slice closes are part of the copy. The ones above are parents that a
  // copied row, cell or list item takes along.
  const closed = closedCount(tokens)
  return normalize(schema, tokens, context.slice(0, closed), context.slice(closed))
}

/** A single copied cell contributes its content, whether selected by text, cell or table selection. */
function copied(state: GardState): Slice | null {
  const slice = copySelection(state)
  const table = slice?.content.length === 1 ? slice.content[0] : null
  if (!(table instanceof Plot) || !table.type.hasRole(Node.Role.Table) || table.content.length !== 1) return slice
  const row = table.content[0]
  if (!row?.isPlot || row.content.length !== 1) return slice
  const cell = row.content[0]
  return cell?.isPlot ? edges(cell.content, true, true) : slice
}

// ---------------------------------------------------------------------------
// Paste

type Frame = { tag: Plot.Tag | null; children: Node[] }

/**
 * Rebuild the content as whole nodes, then open only the text blocks at its edges. `context` holds
 * the plots open at the start, innermost first; the ones that the slice does not close are open at
 * its end too. `parents` are the plots above the content: a top-level row, cell or list item, which
 * cannot stand on a page, is wrapped in them.
 */
function normalize(
  schema: Schema,
  tokens: readonly Token[],
  context: readonly Plot.Tag[],
  parents: readonly Plot.Tag[] = []
): Slice {
  const stack: Frame[] = [{ tag: null, children: [] }]
  for (let i = context.length - 1; i >= 0; i--) stack.push({ tag: context[i]!, children: [] })
  const close = () => {
    const { tag, children } = stack.pop()!
    // An open plot that the slice left empty, such as a list, may not allow that.
    if (children.length || tag!.type.canBeEmpty) stack.at(-1)!.children.push(clean(tag!.create(children)))
  }
  for (const token of tokens) {
    if (isOpen(token)) stack.push({ tag: token, children: [] })
    else if (isClose(token)) close()
    else stack.at(-1)!.children.push(clean(token as Node))
  }
  let openEnd = stack.length > 1
  while (stack.length > 1) close()
  let nodes = stack[0]!.children
  let openStart = context.length > 0

  const page = schema.docTag.type
  for (let i = 0; i < parents.length && nodes.length && nodes.every(node => node.isBlock); i++) {
    if (nodes.every(node => schema.canContain(page, node.type))) break
    nodes = [parents[i]!.create(nodes)]
    openStart = openEnd = false
  }

  return edges(nodes, openStart, openEnd)
}

/**
 * Whole nodes as pasted content: only text blocks at the edges are open. A single empty text block
 * stays whole, so that the paste inserts it.
 */
function edges(nodes: readonly Node[], openStart: boolean, openEnd: boolean): Slice {
  const tokens: Token[] = [],
    context: Plot.Tag[] = []
  const single = nodes.length == 1 && nodes[0]!.isPlot && !nodes[0]!.content.length
  nodes.forEach((node, i) => {
    const first = !single && i == 0 && openStart && node.isPlot && node.isTextblock
    const last = !single && i == nodes.length - 1 && openEnd && node.isPlot && node.isTextblock
    if (first) {
      tokens.push(...(node as Plot).content)
      if (!last) tokens.push(Plot.End)
      context.push(node.tag as Plot.Tag)
    } else if (last) {
      tokens.push(node.tag as Plot.Tag, ...(node as Plot).content)
    } else {
      tokens.push(node)
    }
  })
  return Slice.of(tokens, context)
}

const startPattern = vocabulary.ol!.attributes.start!
const spanPattern = vocabulary.td!.attributes.colspan!

/**
 * Keep pasted values inside the page vocabulary where the core's types accept more, and drop the
 * formatting marks of text in code. Discussion anchors remain part of a move.
 */
function clean(node: Node, inCode = false): Node {
  if (node.isLeaf) {
    return inCode && node.marks.length ? node.withMarks(node.marks.filter(mark => mark.type === Comment)) : node
  }
  let tag = node.tag
  if (tag.type == T.OrderedList && !startPattern.test(String(tag.param))) tag = T.OrderedList.of(1, tag.marks)
  const spans = tag.marks.filter(
    mark => (mark.type == T.ColSpan || mark.type == T.RowSpan) && !spanPattern.test(String(mark.value))
  )
  if (spans.length) tag = tag.withMarks(tag.marks.filter(mark => !spans.includes(mark)))
  const code = tag.type.hasRole(Node.Role.Code)
  const content = node.content.map(child => clean(child, code))
  return tag == node.tag && content.every((child, i) => child == node.content[i]) ? node : tag.create(content)
}

// Markdown beyond plain paragraphs: other blocks, formats, links or line breaks.
const hasMarkdown = (page: Element) =>
  page.children.some(
    block => block.type === 'element' && (block.name !== 'p' || block.children.some(node => node.type !== 'text'))
  )

/**
 * Plain text that reads as Markdown beyond plain paragraphs pastes as page content. Plain
 * paragraphs, unknown elements and unreadable Markdown paste as plain text. The core does not ask
 * this parser in code.
 */
function readMarkdown(text: string): Slice | null {
  let page: Element
  try {
    page = parseMarkdown(text)
  } catch {
    return null
  }
  if (!hasMarkdown(page) || unknownNames(page).length) return null
  // Open at both ends, as pasted HTML.
  // The tokens already name their open edges. The parser result does not also carry that context.
  return Slice.of(edges(pageDocument(page).content, true, true).content)
}

function canPasteBarePageMention(state: GardState): boolean {
  if (state.readOnly || !(state.selection instanceof GardSelection.Text) || !state.selection.empty) return false
  const head = state.sel.head
  if (!head.parent.node.isTextblock || head.parent.node.type.hasRole(Node.Role.Code)) return false
  if (T.Code.isInSet(state.sel.activeMarks) || linkAt(state) !== null) return false
  return Boolean(state.facet(hostFacet)?.matchPageUrl)
}

function readBarePageUrl(text: string, state: GardState): Slice | null {
  if (!canPasteBarePageMention(state)) return null
  const trimmed = text.trim()
  if (!trimmed || /\s/.test(trimmed)) return null
  const pageId = state.facet(hostFacet)?.matchPageUrl?.(trimmed)
  if (!pageId) return null
  return Slice.of([Mention.of({ page: pageId }, inheritedMentionMarks(state, state.selection.from))])
}

/**
 * Plain text, as before: one line for each text block. A copied table gives a line for each row,
 * with a tab between cells, as spreadsheets read it.
 */
function plainText(slice: Slice, state: GardState): string {
  const host = state.facet(hostFacet)
  const leafText = (leaf: Leaf): string => {
    if (leaf.type === Mention) {
      const target = leaf.param as MentionTarget
      return host?.mentionText?.(target) ?? `@${'page' in target ? target.page : target.principal}`
    }
    const block = blocks.find(block => block.type === leaf.type)
    if (!block) return ''
    const node = block.read(leaf, { children: () => [], code: () => [] })
    const source = node.name === 'embed' ? 'href' : 'src'
    if (node.attrs[source]) {
      const address = assetURL(node.attrs[source], host?.resolveAsset)
      if (address) {
        node.attrs[source] = typeof document === 'undefined' ? address : new URL(address, document.baseURI).href
      }
    }
    return resourceText(node) ?? ''
  }
  const [table] = slice.content
  const lines = (node: Node) => Slice.of([node]).textContent({ blockSeparator: '\n', leafText })
  if (slice.content.length == 1 && table instanceof Plot && table.type.hasRole(Node.Role.Table)) {
    return table.content
      .map(row => (row as Plot).content.map(cell => lines(cell).replace(/\n/g, ' ')).join('\t'))
      .join('\n')
  }
  return slice.textContent({ blockSeparator: '\n', leafText })
}

/** Keep the exact internal slice while giving other applications real links and images. */
function resourceHTML(html: string, state: GardState): string {
  if (!html.includes('data-resource=') && !html.includes('data-href=')) return html
  const doc = new DOMParser().parseFromString(html, 'text/html')
  for (const wrapper of doc.querySelectorAll('[data-resource], .embed[data-href]')) {
    const attrs = Object.fromEntries(
      Array.from(wrapper.attributes)
        .filter(attr => attr.name.startsWith('data-'))
        .map(attr => [attr.name.slice(5), attr.value])
    )
    const content = resourceContent(element(attrs.resource ?? 'embed', attrs))
    if (!content) continue
    const address = assetURL(content.src, state.facet(hostFacet)?.resolveAsset)
    if (!address) {
      wrapper.textContent = content.title
      continue
    }
    const src = new URL(address, document.baseURI).href
    const rendered = doc.createElement(content.image ? 'img' : 'a')
    rendered.setAttribute(content.image ? 'src' : 'href', src)
    if (content.image) rendered.setAttribute('alt', content.title)
    else rendered.textContent = content.title
    wrapper.replaceChildren(rendered)
  }
  return doc.body.innerHTML
}

export const clipboard: GardState.Extension = [
  Wordgard.domEventHandler('copy', (_event, editor) => {
    cuts.delete(editor)
  }),
  Wordgard.domEventHandler('cut', (event, editor) => {
    if (editor.state.readOnly || !event.clipboardData) return false
    editor.flush()
    const slice = copied(editor.state)
    if (!slice || slice.eq(withoutCommentSlice(slice))) return false
    const before = editor.state.doc
    const token = crypto.randomUUID()
    writeClipboard(editor.state, slice, event.clipboardData)
    event.clipboardData.setData(cutMime, token)
    Command.dispatch(editor, deleteCut)
    if (editor.state.doc !== before) cuts.set(editor, { token, slice })
    return true
  }),
  Wordgard.transactionListener.of((transactions, editor) => {
    if (transactions.some(tr => ['undo', 'redo'].includes(tr.annotation(Transaction.userEvent) ?? ''))) {
      cuts.delete(editor)
    }
  }),
  Wordgard.pasteHandler.of((editor, event) => {
    const cut = cuts.get(editor)
    const data = event instanceof ClipboardEvent ? event.clipboardData : event.dataTransfer
    if (!cut || data?.getData(cutMime) !== cut.token) return false
    cuts.delete(editor)
    const { ranges } = editor.state.selection
    const { to } = ranges[0]!
    editor.dispatch({
      changes: {
        correct: ranges.map(({ from, to }, index) => ({ from, to, insert: index ? [] : cut.slice, fit: true })),
        local: true
      },
      selection: (cx, changes) => GardSelection.near(cx, changes.mapPos(to, 1), -1),
      userEvent: 'move.paste',
      scrollIntoView: true
    })
    return true
  }),
  Wordgard.pasteHandler.of((editor, event, slice) => {
    if (!canPasteBarePageMention(editor.state)) return false
    const data = event instanceof ClipboardEvent ? event.clipboardData : event.dataTransfer
    const html = data?.getData('text/html') ?? ''
    if (!html || html.includes('wg-content') || html.includes('wg-slice') || html.includes('data-mention-')) {
      return false
    }
    if (slice.content.length !== 1 || slice.context.length !== 0) return false
    const first = slice.content[0]
    if (!first || first.tokenType !== Token.Type.Node || !first.isText) return false
    const linkMark = Link.isInSet(first.marks)
    if (!linkMark) return false
    const href = recordOf(linkMark.value).href?.trim() ?? ''
    if (!href || (first as Leaf<string>).param.trim() !== href) return false
    const pageId = editor.state.facet(hostFacet)?.matchPageUrl?.(href)
    if (!pageId) return false
    const from = editor.state.selection.from
    const leaf = Mention.of({ page: pageId }, inheritedMentionMarks(editor.state, from))
    dispatchStep(editor, {
      changes: { from, to: from, insert: [leaf] },
      selection: GardSelection.cursor(from + leaf.length),
      userEvent: 'input.paste',
      scrollIntoView: true
    })
    return true
  }),
  Wordgard.clipboardOutputFilter.of((slice, state) => withoutCommentSlice(copied(state) ?? slice)),
  Wordgard.clipboardOutputHTMLFilter.of(resourceHTML),
  Wordgard.clipboardTextSerializer.of(plainText),
  // Text sources (plain text, Markdown) already choose their edges: they close more plots than
  // they name in the context.
  Wordgard.clipboardInputHTMLFilter.of(wordListHTML),
  Wordgard.clipboardInputFilter.of((slice, state) =>
    withoutCommentSlice(
      closedCount(slice.content) > slice.context.length ? slice : normalize(state.schema, slice.content, slice.context)
    )
  ),
  Wordgard.clipboardTextParser.of((text, state) => readBarePageUrl(text, state) ?? readMarkdown(text))
]
