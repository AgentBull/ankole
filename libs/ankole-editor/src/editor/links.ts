/*
 * Links. A typed address becomes a link when a space or Enter follows it (SPEC §7.5 Typed URLs).
 * The link form (SPEC §7.6) reads, sets and removes links with the commands here, for example
 * `Command.dispatch(editor, setLink, { href })`. Each command is one undo step.
 */
import { Command, enter } from '../core/command'
import { Leaf, Node, type ChangeSet, type Mark, type Pos } from '../core/doc'
import { Wordgard } from '../core/editor'
import { history } from '../core/history'
import { GardSelection, GardState, Transaction } from '../core/state'
import * as T from '../core/types'
import { pairsOf, recordOf, type Pairs } from './attributes'
import { editorHost, openLinkHref } from './host-context'
import * as S from './schema'

/** A link: its address and title, and the range of its text. */
export type LinkInfo = { href: string; title: string | undefined; from: number; to: number }

/** A link to set. A title of `undefined` keeps the title of a link that the command changes. */
export type LinkTarget = { href: string; title?: string }

type Found = { mark: Mark<Pairs>; from: number; to: number }

/** The range of the link `mark` on the leaf at `index` of `block`, with the adjacent leaves of the same link. */
function extent(block: Pos.Plot, index: number, mark: Mark<Pairs>): Found {
  const { content } = block.node
  let first = index
  let last = index
  while (first > 0 && mark.isInSet(content[first - 1]!.marks)) first--
  while (last < content.length - 1 && mark.isInSet(content[last + 1]!.marks)) last++
  let from = block.start
  for (let i = 0; i < first; i++) from += content[i]!.length
  let to = from
  for (let i = first; i <= last; i++) to += content[i]!.length
  return { mark, from, to }
}

/** The link at a caret: in the leaf that holds it, else right before it, else right after it. */
function linkAtCaret(state: GardState): Found | null {
  const head = state.sel.head
  const block = head.parent
  if (!block.node.inlineContent) return null
  const indexes = head.inText ? [head.index] : [head.index - 1, head.index]
  for (const index of indexes) {
    const leaf = block.node.content[index]
    const mark = leaf && S.Link.isInSet(leaf.marks)
    if (mark) return extent(block, index, mark)
  }
  return null
}

/** The links that the selection touches, in document order. */
function linksInSelection(state: GardState): Found[] {
  if (state.selection.empty) {
    const found = linkAtCaret(state)
    return found ? [found] : []
  }
  const result: Found[] = []
  for (const { from, to } of state.selection.ranges) {
    state.doc.iterate(from, to, (node, pos) => {
      const mark = node.isLeaf ? S.Link.isInSet(node.marks) : null
      if (!mark || result.some(found => found.from <= pos && pos < found.to)) return
      const at = state.doc.resolve(pos)
      result.push(extent(at.parent, at.index, mark))
    })
  }
  return result
}

const infoOf = ({ mark, from, to }: Found): LinkInfo => {
  const attrs = recordOf(mark.value)
  return { href: attrs.href ?? '', title: attrs.title, from, to }
}

/** The link to edit at the selection: the link at the caret, or the first link in the selection. */
export function linkAt(state: GardState): LinkInfo | null {
  const [found] = linksInSelection(state)
  return found ? infoOf(found) : null
}

/** Return the single link covering `[range.from, range.to]` when every inline leaf in `range` belongs to that link. */
export function singleLinkInRange(state: GardState, range: { from: number; to: number }): LinkInfo | null {
  if (range.from >= range.to) return null
  const found: Found[] = []
  let unlinkedLeaf = false
  state.doc.iterate(range.from, range.to, (node, pos) => {
    if (!node.isLeaf || !node.isInline) return
    const mark = S.Link.isInSet(node.marks)
    if (!mark) {
      unlinkedLeaf = true
      return false
    }
    if (!found.some(item => item.from <= pos && pos < item.to)) {
      const at = state.doc.resolve(pos)
      found.push(extent(at.parent, at.index, mark))
    }
  })
  if (unlinkedLeaf || found.length !== 1) return null
  const single = found[0]!
  return single.from <= range.from && range.to <= single.to ? infoOf(single) : null
}

/** The link covering or immediately adjacent to `pos`, used for pointer hover resolution. */
export function linkAtPos(state: GardState, pos: number): LinkInfo | null {
  if (pos < 0 || pos > state.doc.length) return null
  const at = state.doc.resolve(pos)
  const block = at.parent
  if (!block.node.inlineContent) return null
  const indexes = at.inText ? [at.index] : [at.index, at.index - 1]
  for (const index of indexes) {
    const leaf = block.node.content[index]
    const mark = leaf && S.Link.isInSet(leaf.marks)
    if (mark) return infoOf(extent(block, index, mark))
  }
  return null
}

function inlineMarksForLink(state: GardState, pos: number, linkMark: Mark<Pairs>): readonly Mark[] {
  const at = state.doc.resolve(pos)
  const block = at.parent
  const leaf = block.node.inlineContent
    ? at.inText
      ? block.node.content[at.index]
      : (block.node.content[at.index] ?? block.node.content[at.index - 1])
    : undefined
  const kept = leaf ? leaf.marks.filter(mark => mark.type !== S.Link && mark.type !== T.Code.type) : []
  return linkMark.addToSet(kept)
}

function linkMarkAt(state: GardState, pos: number): Mark<Pairs> | null {
  const at = state.doc.resolve(pos)
  const block = at.parent
  if (!block.node.inlineContent) return null
  const leaf = at.inText
    ? block.node.content[at.index]
    : (block.node.content[at.index] ?? block.node.content[at.index - 1])
  return (leaf && S.Link.isInSet(leaf.marks)) ?? null
}

/** Update the link at `range`, optionally replacing its visible text in the same undo step. */
export function updateLinkAt(
  editor: Wordgard,
  range: { from: number; to: number },
  target: LinkTarget & { text?: string },
  options?: { addToHistory?: boolean; keepSelectionOutsideRange?: boolean }
): boolean {
  const { state } = editor
  const href = S.safeLinkHref(target.href)
  if (state.readOnly || !href || range.from < 0 || range.to > state.doc.length || range.from > range.to) return false
  const normalizedTarget = href === target.href ? target : { ...target, href }
  const existing = linkAtPos(state, range.from)
  const sameLink = existing && existing.from === range.from && existing.to === range.to
  const baseMark = sameLink ? linkMarkAt(state, range.from) : null
  const mark = S.Link.of(linkValue(baseMark?.value ?? [], normalizedTarget))
  const annotations = options?.addToHistory === false ? Transaction.addToHistory.of(false) : history.isolate.of(true)
  if (target.text !== undefined) {
    const singleLine = target.text.replace(/\r?\n/g, ' ')
    if (!singleLine.trim()) return false
    const marks = inlineMarksForLink(state, range.from, mark)
    const moveSelection =
      !options?.keepSelectionOutsideRange ||
      (state.selection instanceof GardSelection.Text &&
        state.selection.from >= range.from &&
        state.selection.to <= range.to)
    editor.dispatch({
      changes: { from: range.from, to: range.to, insert: [Leaf.text(singleLine, marks)] },
      ...(moveSelection ? { selection: GardSelection.cursor(range.from + singleLine.length) } : {}),
      annotations,
      userEvent: 'mark.add'
    })
    return true
  }
  if (range.from === range.to) return false
  editor.dispatch({ changes: { from: range.from, to: range.to, add: mark }, annotations, userEvent: 'mark.add' })
  return true
}

/** Remove any link marks covering `range` as one undo step. */
export function removeLinkAt(editor: Wordgard, range: { from: number; to: number }): boolean {
  const { state } = editor
  if (state.readOnly || range.from >= range.to) return false
  const found: Found[] = []
  state.doc.iterate(range.from, range.to, (node, pos) => {
    const mark = node.isLeaf ? S.Link.isInSet(node.marks) : null
    if (!mark || found.some(item => item.from <= pos && pos < item.to)) return
    const at = state.doc.resolve(pos)
    found.push(extent(at.parent, at.index, mark))
  })
  if (!found.length) return false
  editor.dispatch(
    step({
      changes: found.map(({ mark, from, to }) => ({ from, to, remove: mark })),
      userEvent: 'mark.remove'
    })
  )
  return true
}

/** Link attributes with a new address and title. A title of '' removes the title. */
function linkValue(base: Pairs, target: LinkTarget): Pairs {
  const attrs: Record<string, string> = { ...recordOf(base), href: target.href }
  if (target.title !== undefined) attrs.title = target.title
  if (!attrs.title) delete attrs.title
  return pairsOf(attrs)
}

const step = (spec: { changes: ChangeSet.Spec; selection?: GardSelection; userEvent: string }): Transaction.Spec => ({
  ...spec,
  annotations: history.isolate.of(true)
})

/**
 * Link the selection to `target`. A caret in a link, or a selection inside one link, changes that
 * whole link and keeps its other attributes. A caret outside a link does nothing.
 */
export const setLink: Command.Pure<LinkTarget> = ({ state }, target) => {
  const href = S.safeLinkHref(target.href)
  if (state.readOnly || !href) return false
  const normalizedTarget = href === target.href ? target : { ...target, href }
  const found = linksInSelection(state)
  const { from, to } = state.selection
  const inside = found.length === 1 && found[0]!.from <= from && to <= found[0]!.to ? found[0]! : null
  if (inside) {
    const mark = S.Link.of(linkValue(inside.mark.value, normalizedTarget))
    return step({ changes: { from: inside.from, to: inside.to, add: mark }, userEvent: 'mark.add' })
  }
  if (state.selection.empty) return false
  const mark = S.Link.of(linkValue([], normalizedTarget))
  return step({
    changes: state.selection.ranges.map(({ from, to }) => ({ from, to, add: mark })),
    userEvent: 'mark.add'
  })
}

/** Remove the links that the selection touches, or the link at the caret. */
export const removeLink: Command.Pure = ({ state }) => {
  const found = linksInSelection(state)
  if (state.readOnly || !found.length) return false
  return step({
    changes: found.map(({ mark, from, to }) => ({ from, to, remove: mark })),
    userEvent: 'mark.remove'
  })
}

// SPEC §7.5: a typed address starts at the start of its text or after whitespace, and does not end
// with punctuation.
const typedAddress = /(?:^|\s)((?:https?:\/\/|www\.)[^\s<>]*[^\s<>.,;:!?'")\]])$/

/** The link for an address that ends at `pos`, typed in text that is not code and not a link. */
export function addressLink(state: GardState, pos: number): Transaction.Spec | null {
  const at = state.doc.resolve(pos)
  const before = at.nodeBefore
  if (!before?.isText || at.parent.node.type.hasRole(Node.Role.Code)) return null
  if (T.Code.isInSet(before.marks) || S.Link.isInSet(before.marks)) return null
  const match = typedAddress.exec((before as Leaf<string>).param)
  if (!match) return null
  const address = match[1]!
  const href = address.startsWith('www.') ? `http://${address}` : address
  return step({
    changes: { from: pos - address.length, to: pos, add: S.Link.of([['href', href]]) },
    userEvent: 'mark.add'
  })
}

// A typed space after an address. The space is the last character of plain typing.
const onSpace = Transaction.appender.of((trs, state) => {
  const tr = trs.at(-1)
  if (!tr || !tr.isUserEvent('input.type') || tr.isUserEvent('input.type.compose')) return null
  const { selection } = state
  if (!selection.isCursor || state.readOnly || selection.head < 1) return null
  const space = state.doc.resolve(selection.head).nodeBefore
  if (!space?.isText || !(space as Leaf<string>).param.endsWith(' ')) return null
  let inserted = 0
  tr.changes.iterChanges((_fromA, _toA, fromB, toB) => (inserted += toB - fromB))
  return inserted === 1 ? addressLink(state, selection.head - 1) : null
})

// Enter after an address links it first, then lets the other Enter handlers run.
const onEnter = GardState.prec.highest(
  Command.handler(enter, wg => {
    const { state } = wg
    const spec = state.selection.isCursor && !state.readOnly ? addressLink(state, state.selection.head) : null
    if (spec) wg.dispatch(spec)
    return false
  })
)

const onClick = Wordgard.domEventHandler('click', (event, wg) => {
  if (event.defaultPrevented || event.button !== 0) return false
  if ((event.target as Element | null)?.closest('.editor-mention')) return false
  const link = (event.target as Element | null)?.closest('a[href]')
  if (!link) return false
  const href = (link.getAttribute('href') ?? '').trim()
  if (href.startsWith('ankole:page/') && editorHost(wg)) return false
  if (!wg.state.readOnly && !event.metaKey && !event.ctrlKey) return false
  event.preventDefault()
  openLinkHref(wg, href)
  return true
})

/** Typed addresses become links, and external links open on modifier click or in read-only mode. */
export const links: GardState.Extension = [onSpace, onEnter, onClick]
