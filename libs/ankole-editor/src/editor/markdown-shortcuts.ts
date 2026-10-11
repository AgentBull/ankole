/*
 * Typing shortcuts (SPEC §7.5 Typing shortcuts). A Markdown block marker converts its paragraph when
 * the space after it is typed, a code fence converts on Enter, and an inline format converts when
 * its closing marker is typed. The page's Markdown syntax (SPEC §4.1) decides what a marker is. In
 * addition, a paragraph that holds only a typed `[] ` becomes a to-do item, `" ` or `| ` a quote,
 * and `---` a divider with an empty paragraph after it.
 *
 * Only typed text converts: a paste or a deletion does not, and a composition converts when it
 * ends. Each conversion is its own undo step, so undo right after it gives back the typed characters.
 */
import type { PhrasingContent, Root } from 'mdast'
import { fromMarkdown } from 'mdast-util-from-markdown'
import { gfmFromMarkdown } from 'mdast-util-gfm'
import { gfm } from 'micromark-extension-gfm'
import { mdxMd } from 'micromark-extension-mdx-md'
import { Command, enter } from '../core/command'
import { Leaf, Mark, Node, Token, type Pos } from '../core/doc'
import { Wordgard } from '../core/editor'
import { history } from '../core/history'
import { GardSelection, GardState, Transaction } from '../core/state'
import * as T from '../core/types'
import { turnInto } from './block-actions'
import { blockInsertion, compose, isContainer, isListItem, wrapTextblock } from './block-insert'
import * as S from './schema'

// The page syntax without tags: a typed `<` is text.
const syntax = [gfm(), mdxMd(), { disable: { null: ['gfmFootnoteDefinition', 'gfmFootnoteCall'] } }]
const parse = (text: string): Root => fromMarkdown(text, { extensions: syntax, mdastExtensions: [gfmFromMarkdown()] })

const shortcut = (spec: Transaction.Spec): Transaction.Spec => ({
  ...spec,
  annotations: history.isolate.of(true),
  userEvent: 'input.shortcut'
})

/** A paragraph whose block markers convert: a paragraph in the page, a quote, a callout or a table cell. */
function shortcutParagraph(block: Pos.Plot) {
  return block.node.type === T.Paragraph.type && !!block.parent && isContainer(block.parent)
}

/** The text of a textblock from its start to `pos`, when one text leaf holds all of it. */
function leadingText(block: Pos.Plot, pos: number): string | null {
  const first = block.node.firstChild
  if (!first?.isText || pos > block.start + first.length) return null
  return (first as Leaf<string>).param.slice(0, pos - block.start)
}

const headingMarker = /^ {0,3}(#{1,6}) $/
const quoteMarker = /^ {0,3}> $/
const bulletMarker = /^ {0,3}[-+*] $/
const numberMarker = /^ {0,3}(\d{1,9})[.)] $/
const checkMarker = /^\[([ xX])\] $/

/**
 * The conversion after a typed space or `-` at `state`'s caret, for a block marker before the
 * caret. The marker is deleted and the paragraph changes its type.
 */
function blockShortcut(state: GardState, typed: string): Transaction.Spec | null {
  const head = state.sel.head
  const block = head.parent
  if (!block.node.isTextblock || !block.parent) return null
  const before = leadingText(block, head.pos)
  if (before === null) return null
  const whole = before.length === block.node.contentLength ? before : null
  const marker = { changes: { from: block.start, to: head.pos } }
  const then = (next: (state: GardState) => Transaction.Spec | null) => compose(state, marker, next)
  // A checkbox at the start of a bullet item makes it a to-do item.
  const check = checkMarker.exec(before)
  const item = block.index === 0 && isListItem(block.parent) ? block.parent : null
  if (
    typed === ' ' &&
    check &&
    item &&
    item.parent?.node.type === T.BulletList.type &&
    !S.Task.isInSet(item.node.marks)
  ) {
    const task = { from: item.before, add: S.Task.of(check[1] === ' ' ? 'todo' : 'done') }
    // An item that holds only the checkbox becomes an empty item, as a typed `[] ` makes one.
    if (whole !== null && !block.node.marks.length && item.node.content.length === 1) {
      return { changes: [task, { from: block.before, to: block.after }], selection: GardSelection.cursor(item.start) }
    }
    return then(() => ({ changes: task }))
  }
  if (!shortcutParagraph(block)) return null
  if (typed === '-') return whole === '---' ? then(next => blockInsertion(next, T.HorizontalRule)) : null
  if (typed !== ' ') return null
  if (whole === '[] ' || check) {
    return then(next => turnInto(next, { kind: 'list', list: 'check', done: !!check && check[1] !== ' ' }))
  }
  if (whole === '" ' || whole === '| ' || quoteMarker.test(before)) {
    return then(next => {
      const textblock = next.sel.head.parent
      return { changes: wrapTextblock(next, textblock, S.Blockquote) }
    })
  }
  const heading = headingMarker.exec(before)
  if (heading) return then(next => turnInto(next, { kind: 'text', tag: T.Heading.of(heading[1]!.length) }))
  if (bulletMarker.test(before)) return then(next => turnInto(next, { kind: 'list', list: 'bullet' }))
  const number = numberMarker.exec(before)
  if (number) return then(next => turnInto(next, { kind: 'list', list: 'number', start: Number(number[1]) }))
  return null
}

/** A paragraph that holds only a code fence becomes a code block when Enter is pressed at its end. */
export function fenceShortcut(state: GardState): Transaction.Spec | null {
  if (!state.selection.isCursor || state.readOnly) return null
  const head = state.sel.head
  const block = head.parent
  if (!shortcutParagraph(block) || head.pos !== block.end) return null
  const text = leadingText(block, head.pos)
  if (!text || !/^ {0,3}(`{3,}|~{3,})/.test(text)) return null
  const code = parse(text).children[0]
  if (code?.type !== 'code' || code.value) return null
  return compose(state, { changes: { from: block.start, to: block.end } }, next =>
    turnInto(next, { kind: 'code', lang: code.lang ?? undefined, meta: code.meta ?? undefined })
  )
}

const triggers = new Set(['*', '_', '`', '~', ')'])

/** Whether `text` can hold an inline format that `typed`, its last character, closes. */
function mayClose(text: string, typed: string) {
  return typed === ')' ? text.lastIndexOf('](') > 0 : text.lastIndexOf(typed, text.length - 2) !== -1
}

/** The inline format that ends at the end of `text`. */
function closedFormat(text: string): PhrasingContent | null {
  const last = parse(text).children.at(-1)
  if (last?.type !== 'paragraph') return null
  const node = last.children.at(-1)
  const start = node?.position?.start.offset
  if (!node || start === undefined || node.position?.end.offset !== text.length) return null
  if (!['emphasis', 'strong', 'delete', 'inlineCode', 'link'].includes(node.type)) return null
  // While `**bold*` is typed, `*bold*` closes. Wait for the longer marker.
  if (start > 0 && text[start - 1] === text[start] && triggers.has(text[start]!)) return null
  return node
}

const linkMark = (url: string, title: string | null | undefined) =>
  S.Link.of(title ? [['href', url] as const, ['title', title] as const] : [['href', url] as const])

/** Leaves for formatted Markdown text. Null for content that has no leaves here, such as an image. */
function leaves(node: PhrasingContent, marks: Mark.Set): Node[] | null {
  const inner = (mark: Mark) => {
    const result: Node[] = []
    for (const child of (node as { children: PhrasingContent[] }).children) {
      const part = leaves(child, mark.addToSet(marks))
      if (!part) return null
      result.push(...part)
    }
    return result
  }
  switch (node.type) {
    case 'text':
      return node.value ? [Leaf.text(node.value, marks)] : []
    case 'inlineCode':
      return [Leaf.text(node.value, T.Code.addToSet(marks))]
    case 'emphasis':
      return inner(T.Emphasis)
    case 'strong':
      return inner(T.Strong)
    case 'delete':
      return inner(T.Strikethrough)
    case 'link':
      return S.Link.isInSet(marks) ? null : inner(linkMark(node.url, node.title))
    default:
      return null
  }
}

/** The conversion after a typed closing marker of an inline format, in a text that is not code. */
function inlineShortcut(state: GardState, typed: string): Transaction.Spec | null {
  const head = state.sel.head
  if (!triggers.has(typed) || !head.parent.node.inlineContent || head.parent.node.type.hasRole(Node.Role.Code)) {
    return null
  }
  const before = head.nodeBefore
  if (!before?.isText || T.Code.isInSet(before.marks)) return null
  const text = (before as Leaf<string>).param
  if (!mayClose(text, typed)) return null
  const node = closedFormat(text)
  const insert = node && leaves(node, before.marks)
  if (!node || !insert) return null
  const from = head.pos - text.length + node.position!.start.offset!
  return {
    changes: { from, to: head.pos, insert },
    // Text typed next has the marks that the text had before the format.
    selection: (_cx, changes) => GardSelection.Text.create({ anchor: changes.mapPos(head.pos, 1), marks: before.marks })
  }
}

/** The one character that a typing transaction inserted at the caret, if it inserted exactly that. */
function typedCharacter(tr: Transaction): string | null {
  let typed: string | null = null
  let count = 0
  tr.changes.iterChanges((_fromA, _toA, _fromB, toB, inserted) => {
    count++
    const token = inserted.content.length === 1 ? inserted.content[0]! : null
    if (token?.tokenType === Token.Type.Node && token.isText && toB === tr.state.selection.head) {
      typed = (token as Leaf<string>).param
    }
  })
  return count === 1 && typed !== null && [...(typed as string)].length === 1 ? typed : null
}

/** The conversion for a character typed right before the caret. */
const conversion = (state: GardState, typed: string) =>
  state.readOnly || !state.selection.isCursor ? null : (blockShortcut(state, typed) ?? inlineShortcut(state, typed))

const typing = Transaction.appender.of((trs, state) => {
  const tr = trs.at(-1)
  if (!tr || !tr.isUserEvent('input.type') || tr.isUserEvent('input.type.compose')) return null
  const typed = typedCharacter(tr)
  const spec = typed && conversion(state, typed)
  return spec ? shortcut(spec) : null
})

// A composition, such as a dead key, commits its text without plain typing. When the committed
// text is right before the caret, check its last character once the core has ended the composition.
const composed = Wordgard.domEventObserver('compositionend', (event, wg) => {
  const typed = [...event.data].at(-1)
  if (typed) {
    queueMicrotask(() => {
      const before = wg.state.sel.head.nodeBefore
      if (wg.composing || !wg.dom.isConnected || !before?.isText) return
      if (!(before as Leaf<string>).param.endsWith(event.data)) return
      const spec = conversion(wg.state, typed)
      if (spec) wg.dispatch(shortcut(spec))
    })
  }
})

const fence = GardState.prec.highest(
  Command.handler(enter, wg => {
    const spec = fenceShortcut(wg.state)
    return spec ? shortcut(spec) : false
  })
)

/** The typing shortcuts. */
export const markdownShortcuts: GardState.Extension = [typing, composed, fence]
