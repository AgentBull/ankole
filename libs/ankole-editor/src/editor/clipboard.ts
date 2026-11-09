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
import { ChangeSet, Leaf, Node, Plot, type Pos, type Schema, Slice, Token } from '../core/doc'
import { Wordgard } from '../core/editor'
import { Command, deleteCut } from '../core/command'
import { plainTextSlice, readClipboard, readHTML, writeClipboard } from '../core/editor/clipboard'
import { GardSelection, Transaction, type GardState } from '../core/state'
import { CellSelection } from '../core/table'
import * as T from '../core/types'
import { looksLikeMarkdown, parsePastedMarkdown, splitPastedDocumentTitle } from '../document/markdown-paste'
import { element, removeInvalidCharacters, type Element } from '../document/tree'
import { assetURL, resourceContent, resourceText, safeLinkHref, webURL } from '../document/resources'
import { blocks } from '../blocks'
import { InfographicBlock, InfographicView } from '../blocks/infographic'
import { MermaidBlock, MermaidView } from '../blocks/mermaid'
import { unknownNames, vocabulary } from '../document/vocabulary'
import { codeNodes, recordOf } from './attributes'
import { dispatchStep } from './block-insert'
import { codeLanguageState } from './code-block'
import { normalizedPageDocument } from './convert'
import { BlockSelection } from './block-selection'
import { withoutCommentSlice } from './comments'
import { hostFacet } from './host-context'
import { isKnowledge } from './knowledge'
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

function downgradeKnowledgeTag(tag: Plot.Tag): Plot.Tag {
  if (tag.type === MermaidBlock.type) {
    return tag.marks.length ? MermaidBlock.withMarks([]) : tag
  }
  if (tag.type === InfographicBlock.type) {
    return T.CodeBlock.withMarks([T.CodeBlockLanguage.of('infographic')])
  }
  return tag
}

function downgradeKnowledgeNode(node: Node): Node {
  if (node.isLeaf) return node
  const tag = downgradeKnowledgeTag(node.tag)
  const content = node.content.map(downgradeKnowledgeNode)
  return tag === node.tag && content.every((child, i) => child === node.content[i]) ? node : tag.create(content)
}

/**
 * Downgrade cross-page diagram nodes pasted into a knowledge editor so display-only Mermaid marks
 * are stripped and `<infographic>` blocks become `<pre lang="infographic">` preserving source text.
 */
export function downgradeKnowledgeSlice(slice: Slice): Slice {
  const content = slice.content.map((token): Token => {
    if (isOpen(token)) return downgradeKnowledgeTag(token)
    if (isClose(token)) return token
    return downgradeKnowledgeNode(token as Node)
  })
  const context = slice.context.map(downgradeKnowledgeTag)
  return Slice.of(content, context)
}

/**
 * Plain text that reads as Markdown beyond plain paragraphs pastes as page content. Plain
 * paragraphs, unknown elements and unreadable Markdown paste as plain text. Code, diagram and
 * formula blocks stay closed so they never unwrap into inline text or absorb trailing text.
 */
function readMarkdown(text: string, state: GardState): Slice | null {
  const knowledge = isKnowledge(state)
  const page = parsePastedMarkdown(text, knowledge ? 'knowledge' : 'doc')
  if (!page || !hasMarkdown(page) || unknownNames(page).length) return null
  const nodes = normalizedPageDocument(page).content
  const first = nodes[0]
  const last = nodes.at(-1)
  const openStart = Boolean(first?.isPlot && first.isTextblock && !first.type.hasRole(Node.Role.Code))
  const openEnd = Boolean(last?.isPlot && last.isTextblock && !last.type.hasRole(Node.Role.Code))
  return edges(nodes, openStart, openEnd)
}

type VSCodeClipboardMeta = {
  version?: number
  isFromEmptySelection?: boolean
  multicursorText?: string[] | null
  mode?: string
}

const vscodeProseModes = new Set(['', 'markdown', 'mdx', 'plaintext', 'scminput', 'git-commit', 'tex', 'latex'])

const vscodeLanguageAliases: Readonly<Record<string, string>> = {
  typescriptreact: 'tsx',
  javascriptreact: 'jsx',
  shellscript: 'shell',
  'terraform-vars': 'hcl',
  properties: 'ini',
  dockercompose: 'yaml',
  jsonl: 'json'
}

function resolveVSCodeLanguage(mode: string): string | undefined {
  const candidate = vscodeLanguageAliases[mode] ?? mode
  const canonical = codeLanguageState(candidate).canonical
  if (canonical === 'plaintext') return undefined
  if (canonical) return canonical
  return /^[a-z0-9_+#.-]+$/i.test(candidate) ? candidate : undefined
}

function parseVSCodeMetadata(raw: string): VSCodeClipboardMeta | null {
  if (!raw) return null
  try {
    const parsed = JSON.parse(raw)
    return parsed && typeof parsed === 'object' ? (parsed as VSCodeClipboardMeta) : null
  } catch {
    return null
  }
}

function parseIframeAttributes(trimmed: string): { src?: string; title?: string; height?: string } | null {
  if (typeof document !== 'undefined') {
    const dom = readHTML(trimmed)
    if (dom.children.length !== 1 || dom.firstElementChild?.tagName !== 'IFRAME') return null
    for (const node of dom.childNodes) {
      if (node.nodeType === 3 && node.textContent?.trim()) return null
    }
    const iframe = dom.firstElementChild
    return {
      src: iframe.getAttribute('src')?.trim(),
      title: iframe.getAttribute('title')?.trim(),
      height: iframe.getAttribute('height')?.trim()
    }
  }
  const match = /^<iframe\b([^>]*?)(?:\/>|>\s*<\/iframe>)$/i.exec(trimmed)
  if (!match) return null
  const attrSource = match[1]!
  const readAttr = (name: string): string | undefined => {
    const pattern = new RegExp(`(?:^|\\s)${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'=>]+))`, 'i')
    const found = pattern.exec(attrSource)
    return (found?.[1] ?? found?.[2] ?? found?.[3])?.trim()
  }
  return { src: readAttr('src'), title: readAttr('title'), height: readAttr('height') }
}

function readSingleIframeEmbed(text: string, state: GardState): Slice | null {
  if (isKnowledge(state)) return null
  const trimmed = text.trim()
  if (!/^<iframe\b[\s\S]*(?:<\/iframe>|\/?>)$/i.test(trimmed)) return null
  const parsed = parseIframeAttributes(trimmed)
  const href = parsed?.src ? webURL(parsed.src) : null
  if (!href) return null
  const heightPattern = vocabulary.embed!.attributes.height!
  const attrs: Record<string, string> = {
    href,
    ...(parsed?.title ? { title: parsed.title } : {}),
    ...(parsed?.height && heightPattern.test(parsed.height) ? { height: parsed.height } : {})
  }
  return Slice.of(normalizedPageDocument(element('page', {}, [element('embed', attrs)])).content)
}

const richHtmlTags = new Set([
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'ul',
  'ol',
  'li',
  'dl',
  'dt',
  'dd',
  'table',
  'thead',
  'tbody',
  'tfoot',
  'tr',
  'th',
  'td',
  'blockquote',
  'hr',
  'figure',
  'figcaption',
  'details',
  'summary',
  'img',
  'video',
  'audio',
  'picture',
  'svg',
  'iframe',
  'object',
  'embed',
  'strong',
  'b',
  'em',
  'i',
  'u',
  's',
  'del',
  'strike',
  'ins',
  'mark',
  'sub',
  'sup',
  'kbd',
  'code',
  'input'
])

const richHtmlAttrs = new Set([
  'data-resource',
  'data-href',
  'data-mention-page',
  'data-mention-principal',
  'data-callout',
  'data-language',
  'data-align',
  'align',
  'aria-checked'
])

const richInlineStyle =
  /\b(?:font-weight\s*:\s*(?:bold|[6-9]00)|font-style\s*:\s*italic|text-decoration(?:-[a-z]+)?\s*:[^;]*(?:underline|line-through)|text-transform\s*:\s*(?!none\b)[a-z-]+|text-align\s*:\s*(?:center|right|end|justify))\b/i
const highlightedPreClass = /\b(?:language-|lang-|hljs|shiki|prism|highlight)\b/i

function classifyPlainHtmlWrapper(html: string): 'rich' | 'pre' | 'plain' {
  if (/wg-content|wg-slice|data-pm-slice|mso-list|urn:schemas-microsoft-com:office|docs-internal-guid-/i.test(html)) {
    return 'rich'
  }
  if (typeof document !== 'undefined') {
    const dom = readHTML(html)
    let sawPre = false
    const elements = dom.querySelectorAll('*')
    for (let i = 0; i < elements.length; i++) {
      const el = elements[i]!
      const tag = el.tagName.toLowerCase()
      if (richHtmlTags.has(tag)) return 'rich'
      if (tag === 'a' && el.hasAttribute('href')) return 'rich'
      for (let a = 0; a < el.attributes.length; a++) {
        const attrName = el.attributes[a]!.name.toLowerCase()
        if (richHtmlAttrs.has(attrName)) return 'rich'
      }
      const style = el.getAttribute('style')
      if (style && richInlineStyle.test(style)) return 'rich'
      if (tag === 'pre') {
        const cls = el.getAttribute('class') ?? ''
        if (highlightedPreClass.test(cls)) return 'rich'
        sawPre = true
      }
    }
    return sawPre ? 'pre' : 'plain'
  }

  let sawPre = false
  const tagRegex = /<\/?([a-zA-Z][a-zA-Z0-9-]*)(\s[^>]*?)?\/?>/g
  for (const match of html.matchAll(tagRegex)) {
    const tag = match[1]!.toLowerCase()
    const attrs = match[2] ?? ''
    if (richHtmlTags.has(tag)) return 'rich'
    if (tag === 'a' && /\bhref\s*=/i.test(attrs)) return 'rich'
    if (
      /\b(?:data-resource|data-href|data-mention-page|data-mention-principal|data-callout|data-language|data-align|align|aria-checked)\s*=/i.test(
        attrs
      )
    ) {
      return 'rich'
    }
    const styleMatch = /\bstyle\s*=\s*(?:"([^"]*)"|'([^']*)')/i.exec(attrs)
    const styleVal = styleMatch?.[1] ?? styleMatch?.[2] ?? ''
    if (styleVal && richInlineStyle.test(styleVal)) return 'rich'
    if (tag === 'pre') {
      const classMatch = /\bclass\s*=\s*(?:"([^"]*)"|'([^']*)')/i.exec(attrs)
      const classVal = classMatch?.[1] ?? classMatch?.[2] ?? ''
      if (classVal && highlightedPreClass.test(classVal)) return 'rich'
      sawPre = true
    }
  }
  return sawPre ? 'pre' : 'plain'
}

function readSmartClipboardData(data: DataTransfer, state: GardState, targetContext: Pos): Slice | null {
  const html = data.getData('text/html')
  const rawText = data.getData('text/plain') || data.getData('Text')
  if (!rawText) return null
  if (
    html &&
    (html.includes('wg-content') ||
      html.includes('wg-slice') ||
      html.includes('data-pm-slice') ||
      html.includes('data-mention-') ||
      html.includes('data-resource'))
  ) {
    return null
  }
  // Keep bare URLs on the link / page-mention path.
  if (bareWebHref(rawText)) return null

  const iframeSlice = readSingleIframeEmbed(rawText, state)
  if (iframeSlice) return iframeSlice

  const vscodeMeta = parseVSCodeMetadata(data.getData('vscode-editor-data'))
  if (vscodeMeta) {
    const mode = typeof vscodeMeta.mode === 'string' ? vscodeMeta.mode.trim().toLowerCase() : ''
    if (vscodeProseModes.has(mode)) {
      return readMarkdown(rawText, state) ?? plainTextSlice(state, rawText, targetContext)
    }
    let codeText = removeInvalidCharacters(rawText).replace(/\r\n?|\n/g, '\n')
    if (/\n/.test(codeText)) {
      if (codeText.endsWith('\n')) codeText = codeText.slice(0, -1)
      if (mode === 'mermaid') return Slice.of([MermaidBlock.create(codeNodes(codeText))])
      if (mode === 'infographic') return Slice.of([InfographicBlock.create(codeNodes(codeText))])
      const lang = resolveVSCodeLanguage(mode)
      const tag = lang ? T.CodeBlock.withMarks([T.CodeBlockLanguage.of(lang)]) : T.CodeBlock
      return Slice.of([tag.create(codeNodes(codeText))])
    }
    return Slice.of(codeText ? [Leaf.text(codeText, targetContext.marks())] : [])
  }

  if (!html) return null
  const wrapperKind = classifyPlainHtmlWrapper(html)
  if (wrapperKind === 'rich') return null
  if (!looksLikeMarkdown(rawText, { fromPreWrapper: wrapperKind === 'pre' })) return null
  return readMarkdown(rawText, state)
}

export { splitPastedDocumentTitle }

/**
 * Insert pasted text (such as the body portion of a multi-line title paste) at the start of the
 * document in a single undoable transaction, parsing Markdown or links as an ordinary paste does.
 */
export function pasteTextAtDocumentStart(editor: Wordgard, text: string): boolean {
  if (editor.state.readOnly || !text.trim()) return false
  let baseState = editor.state
  let prefixChange: ChangeSet | null = null
  const first = baseState.doc.content[0]
  const hasLeadingEmptyParagraph = first?.isPlot && first.type === T.Paragraph.type && first.content.length === 0
  if (!hasLeadingEmptyParagraph) {
    prefixChange = ChangeSet.create(baseState.doc, {
      from: 0,
      to: 0,
      insert: [T.Paragraph.create([])]
    })
    baseState = baseState.update({ changes: prefixChange }).state
  }
  const targetContext = baseState.doc.resolve(1)
  let slice =
    readSingleIframeEmbed(text, baseState) ??
    readBarePageUrl(text, baseState) ??
    readBareWebUrl(text, baseState) ??
    readMarkdown(text, baseState) ??
    plainTextSlice(baseState, text, targetContext)
  for (const filter of baseState.facet(Wordgard.clipboardInputFilter)) {
    slice = filter(slice, baseState)
  }
  const pasteChange = ChangeSet.create(baseState.doc, {
    correct: { from: 1, to: 1, insert: slice, fit: true },
    local: true
  })
  const combined = prefixChange ? prefixChange.compose(pasteChange) : pasteChange
  const caretAfter = pasteChange.mapPos(1, 1)
  editor.dispatch({
    changes: combined,
    selection: cx => GardSelection.near(cx, caretAfter, -1),
    userEvent: 'input.paste',
    scrollIntoView: true
  })
  editor.focus()
  return true
}

function bareWebHref(text: string): string | null {
  const trimmed = text.trim()
  if (!trimmed || /\s/.test(trimmed) || !webURL(trimmed)) return null
  return safeLinkHref(trimmed) ?? webURL(trimmed)
}

function canLinkSelectedText(state: GardState): boolean {
  if (state.readOnly || !(state.selection instanceof GardSelection.Text) || state.selection.empty) return false
  for (const { from, to } of state.selection.ranges) {
    if (from >= to) return false
    const startBlock = state.doc.resolve(from).textblockParent
    const endBlock = state.doc.resolve(to).textblockParent
    if (!startBlock || !endBlock || startBlock.before !== endBlock.before) return false
    if (startBlock.node.type.hasRole(Node.Role.Code)) return false
    let linkableText = false
    let disallowed = false
    state.doc.iterate(from, to, node => {
      if (node.type.hasRole(Node.Role.Code)) {
        disallowed = true
        return false
      }
      if (node.isLeaf && node.isInline) {
        if (!state.schema.markAllowed(Link, node.type) || T.Code.isInSet(node.marks)) {
          disallowed = true
          return false
        }
        if (node.isText && (node as Leaf<string>).param.trim()) linkableText = true
      }
    })
    if (disallowed || !linkableText) return false
  }
  return true
}

function readBareWebUrl(text: string, state: GardState): Slice | null {
  if (!canAutoLinkCaretPaste(state)) return null
  const href = bareWebHref(text)
  if (!href) return null
  const marks = Link.of([['href', href]]).addToSet(
    state.sel.activeMarks.filter(mark => mark.type !== T.Code.type && mark.type !== Link)
  )
  return Slice.of([Leaf.text(text.trim(), marks)])
}

function canAutoLinkCaretPaste(state: GardState): boolean {
  if (state.readOnly || !(state.selection instanceof GardSelection.Text) || !state.selection.empty) return false
  const head = state.sel.head
  if (!head.parent.node.isTextblock || head.parent.node.type.hasRole(Node.Role.Code)) return false
  if (T.Code.isInSet(state.sel.activeMarks) || linkAt(state) !== null) return false
  return true
}

function isBareUrlHtmlSlice(slice: Slice, expectedUrl: string, expectedHref: string): boolean {
  if (!slice.content.length) return false
  if (!slice.context.every(tag => tag.type === T.Paragraph.type)) return false
  const normalizedExpected = webURL(expectedHref) ?? expectedHref
  const checkTokens = (tokens: readonly Token[]): boolean => {
    for (const token of tokens) {
      if (isOpen(token)) {
        if (token.type !== T.Paragraph.type) return false
        continue
      }
      if (isClose(token)) continue
      const node = token as Node
      if (node.isPlot) {
        if (node.type !== T.Paragraph.type || !checkTokens(node.content)) return false
        continue
      }
      if (!node.isText || T.Code.isInSet(node.marks)) return false
      const linkMark = Link.isInSet(node.marks)
      if (linkMark) {
        const markHref = recordOf(linkMark.value).href?.trim() ?? ''
        const normalizedMarkHref = webURL(markHref) ?? markHref
        if (normalizedMarkHref !== normalizedExpected && markHref !== expectedUrl) return false
      }
    }
    return true
  }
  return checkTokens(slice.content) && slice.textContent().trim() === expectedUrl
}

function canPasteBarePageMention(state: GardState): boolean {
  return canAutoLinkCaretPaste(state) && Boolean(state.facet(hostFacet)?.matchPageUrl)
}

function readBarePageUrl(text: string, state: GardState): Slice | null {
  if (!canPasteBarePageMention(state)) return null
  const trimmed = text.trim()
  if (!trimmed || /\s/.test(trimmed)) return null
  const pageId = state.facet(hostFacet)?.matchPageUrl?.(trimmed)
  if (!pageId) return null
  return Slice.of([Mention.of({ page: pageId }, inheritedMentionMarks(state, state.selection.from))])
}

function clipboardLeafText(leaf: Leaf, state: GardState): string {
  const host = state.facet(hostFacet)
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

const isDiagramOnlyCodeBlock = (node: Node, state: GardState) =>
  !isKnowledge(state) &&
  ((node.type === MermaidBlock.type && node.mark(MermaidView) === 'diagram') ||
    (node.type === InfographicBlock.type && node.mark(InfographicView) === 'diagram'))

/** A single selected code or diagram block whose outer range `[before, after]` is the replacement target. */
function singleCodeBlockTarget(state: GardState): Pos.Plot | null {
  if (state.readOnly) return null
  if (state.selection instanceof BlockSelection) {
    if (state.selection.blocks.length !== 1) return null
    const plot = state.doc.resolvePlot(state.selection.blocks[0]!.before)
    return plot?.node.type.hasRole(Node.Role.Code) ? plot : null
  }
  if (state.selection instanceof GardSelection.Text) {
    if (state.selection.ranges.length !== 1) return null
    const { from, to } = state.selection.ranges[0]!
    if (from >= to) return null
    const plot = state.doc.resolvePlot(from)
    return plot?.node.type.hasRole(Node.Role.Code) && plot.after === to ? plot : null
  }
  return null
}

const isClosedBlockSlice = (slice: Slice) =>
  slice.context.length === 0 &&
  slice.content.length > 0 &&
  slice.content.every(tok => tok.tokenType === Token.Type.Node && tok.isBlock)

function isWholeBlockCopy(data: DataTransfer, slice: Slice, plain: boolean): boolean {
  if (plain || !isClosedBlockSlice(slice)) return false
  const html = data.getData('text/html')
  if (!html.includes('wg-slice')) return false
  return new DOMParser().parseFromString(html, 'text/html').querySelector('[wg-content="true"][wg-slice]') !== null
}

/** Convert a same-editor cut slice into code text and line-break leaves while preserving comment anchors. */
function codeSliceFromCut(slice: Slice, state: GardState): Slice {
  const out: Token[] = []
  const lineBreak = state.schema.lineBreak ?? T.LineBreak
  let started = slice.context.some(tag => tag.isTextblock)
  const openBlock = () => {
    if (started) out.push(lineBreak)
    else started = true
  }
  const visit = (node: Node): void => {
    if (node.isPlot) {
      if (node.isTextblock) openBlock()
      return
    }
    const comments = node.marks.filter(mark => mark.type === Comment)
    if (node.type === T.LineBreak.type) {
      out.push(T.LineBreak.withMarks(comments))
      started = true
      return
    }
    const text = node.isText
      ? (node.param as string)
      : node.type.spec.toText
        ? node.type.spec.toText(node)
        : clipboardLeafText(node, state)
    if (node.isBlock && text) openBlock()
    if (text) {
      out.push(...codeNodes(text.replace(/\r\n?|\n/g, '\n'), comments))
      started = true
    }
  }
  for (const tok of slice.content) {
    if (tok.tokenType === Token.Type.Open) {
      if (tok.isTextblock) openBlock()
    } else if (tok.tokenType === Token.Type.Node) {
      if (tok.isLeaf) visit(tok)
      else {
        tok.iterate(node => {
          visit(node)
        })
      }
    }
  }
  return Slice.of(out)
}

/**
 * Plain text, as before: one line for each text block. A copied table gives a line for each row,
 * with a tab between cells, as spreadsheets read it.
 */
function plainText(slice: Slice, state: GardState): string {
  const leafText = (leaf: Leaf): string => clipboardLeafText(leaf, state)
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
    if (!cut || data?.getData(cutMime) !== cut.token || editor.state.readOnly) return false
    cuts.delete(editor)
    const codeBlock = singleCodeBlockTarget(editor.state)
    if (codeBlock && (editor.inputState.shiftKey || !isClosedBlockSlice(cut.slice))) {
      const codeSlice = codeSliceFromCut(cut.slice, editor.state)
      const diagramOnly = isDiagramOnlyCodeBlock(codeBlock.node, editor.state)
      editor.dispatch({
        changes: {
          correct: { from: codeBlock.start, to: codeBlock.end, insert: codeSlice, fit: true },
          local: true
        },
        selection: (cx, changes) =>
          diagramOnly
            ? BlockSelection.between(cx.doc, codeBlock.before, codeBlock.before)!
            : GardSelection.near(cx, changes.mapPos(codeBlock.end, 1), -1),
        userEvent: 'move.paste',
        scrollIntoView: true
      })
      return true
    }
    const { ranges } = editor.state.selection
    const inCode = ranges.every(
      ({ from, to }) =>
        editor.state.doc.resolve(from).parent.node.type.hasRole(Node.Role.Code) &&
        editor.state.doc.resolve(to).parent.node.type.hasRole(Node.Role.Code)
    )
    const insert = inCode ? codeSliceFromCut(cut.slice, editor.state) : cut.slice
    const { to } = ranges[0]!
    editor.dispatch({
      changes: {
        correct: ranges.map(({ from, to }, index) => ({ from, to, insert: index ? [] : insert, fit: true })),
        local: true
      },
      selection: (cx, changes) => GardSelection.near(cx, changes.mapPos(to, 1), -1),
      userEvent: 'move.paste',
      scrollIntoView: true
    })
    return true
  }),
  Wordgard.pasteHandler.of((editor, event, slice) => {
    const block = singleCodeBlockTarget(editor.state)
    if (!block) return false
    const data = event instanceof ClipboardEvent ? event.clipboardData : event.dataTransfer
    if (!data || isWholeBlockCopy(data, slice, editor.inputState.shiftKey)) return false
    const codeSlice = readClipboard(
      editor.state,
      data,
      editor.state.doc.resolve(block.start),
      editor.inputState.shiftKey
    )
    if (!codeSlice) return false
    const diagramOnly = isDiagramOnlyCodeBlock(block.node, editor.state)
    editor.dispatch({
      changes: { correct: { from: block.start, to: block.end, insert: codeSlice, fit: true }, local: true },
      selection: (cx, changes) =>
        diagramOnly
          ? BlockSelection.between(cx.doc, block.before, block.before)!
          : GardSelection.near(cx, changes.mapPos(block.end, 1), -1),
      userEvent: 'input.paste',
      scrollIntoView: true
    })
    return true
  }),
  Wordgard.pasteHandler.of((editor, event, slice) => {
    if (editor.inputState.shiftKey || !canAutoLinkCaretPaste(editor.state)) return false
    const data = event instanceof ClipboardEvent ? event.clipboardData : event.dataTransfer
    const html = data?.getData('text/html') ?? ''
    if (!html || html.includes('wg-content') || html.includes('wg-slice') || html.includes('data-mention-')) {
      return false
    }
    const rawText = (data?.getData('text/plain') ?? '').trim() || slice.textContent().trim()
    const webHref = bareWebHref(rawText)
    if (!webHref || !isBareUrlHtmlSlice(slice, rawText, webHref)) return false
    const from = editor.state.selection.from
    const pageId = editor.state.facet(hostFacet)?.matchPageUrl?.(rawText)
    if (pageId) {
      const leaf = Mention.of({ page: pageId }, inheritedMentionMarks(editor.state, from))
      dispatchStep(editor, {
        changes: { from, to: from, insert: [leaf] },
        selection: GardSelection.cursor(from + leaf.length),
        userEvent: 'input.paste',
        scrollIntoView: true
      })
      return true
    }
    const marks = Link.of([['href', webHref]]).addToSet(
      editor.state.sel.activeMarks.filter(mark => mark.type !== T.Code.type && mark.type !== Link)
    )
    const leaf = Leaf.text(rawText, marks)
    dispatchStep(editor, {
      changes: { from, to: from, insert: [leaf] },
      selection: GardSelection.cursor(from + leaf.length),
      userEvent: 'input.paste',
      scrollIntoView: true
    })
    return true
  }),
  Wordgard.pasteHandler.of((editor, event, slice) => {
    if (editor.inputState.shiftKey || !canLinkSelectedText(editor.state)) return false
    const data = event instanceof ClipboardEvent ? event.clipboardData : event.dataTransfer
    const html = data?.getData('text/html') ?? ''
    if (html.includes('wg-content') || html.includes('wg-slice') || html.includes('data-mention-')) {
      return false
    }
    const rawText = (data?.getData('text/plain') ?? '').trim()
    const webHref = bareWebHref(rawText)
    if (!webHref) return false
    if (html && slice.content.length > 0 && slice.textContent().trim() !== rawText) return false
    const pageId = editor.state.facet(hostFacet)?.matchPageUrl?.(rawText)
    const href = pageId ? `ankole:page/${pageId}` : webHref
    const mark = Link.of([['href', href]])
    dispatchStep(editor, {
      changes: editor.state.selection.ranges.map(({ from, to }) => ({ from, to, add: mark })),
      selection: GardSelection.cursor(editor.state.selection.to),
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
  Wordgard.clipboardInputFilter.of((slice, state) => {
    const normalized =
      closedCount(slice.content) > slice.context.length ? slice : normalize(state.schema, slice.content, slice.context)
    const stripped = withoutCommentSlice(normalized)
    return isKnowledge(state) ? downgradeKnowledgeSlice(stripped) : stripped
  }),
  Wordgard.clipboardDataParser.of(readSmartClipboardData),
  Wordgard.clipboardTextParser.of(
    (text, state) =>
      readSingleIframeEmbed(text, state) ??
      readBarePageUrl(text, state) ??
      readBareWebUrl(text, state) ??
      readMarkdown(text, state)
  )
]
