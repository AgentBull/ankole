/*
 * Links. A typed address becomes a link when a space or Enter follows it (SPEC §7.5 Typed URLs).
 * The link form (SPEC §7.6) reads, sets and removes links with the commands here, for example
 * `Command.dispatch(editor, setLink, { href })`. Each command is one undo step.
 */
import { Command, enter } from '../core/command'
import { Node, type ChangeSet, type Leaf, type Mark, type Pos } from '../core/doc'
import { history } from '../core/history'
import { GardState, Transaction } from '../core/state'
import * as T from '../core/types'
import { pairsOf, recordOf, type Pairs } from './attributes'
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

/** Link attributes with a new address and title. A title of '' removes the title. */
function linkValue(base: Pairs, target: LinkTarget): Pairs {
  const attrs: Record<string, string> = { ...recordOf(base), href: target.href }
  if (target.title !== undefined) attrs.title = target.title
  if (!attrs.title) delete attrs.title
  return pairsOf(attrs)
}

const step = (spec: { changes: ChangeSet.Spec; userEvent: string }): Transaction.Spec => ({
  ...spec,
  annotations: history.isolate.of(true)
})

/**
 * Link the selection to `target`. A caret in a link, or a selection inside one link, changes that
 * whole link and keeps its other attributes. A caret outside a link does nothing.
 */
export const setLink: Command.Pure<LinkTarget> = ({ state }, target) => {
  if (state.readOnly || !target.href) return false
  const found = linksInSelection(state)
  const { from, to } = state.selection
  const inside = found.length === 1 && found[0]!.from <= from && to <= found[0]!.to ? found[0]! : null
  if (inside) {
    const mark = S.Link.of(linkValue(inside.mark.value, target))
    return step({ changes: { from: inside.from, to: inside.to, add: mark }, userEvent: 'mark.add' })
  }
  if (state.selection.empty) return false
  const mark = S.Link.of(linkValue([], target))
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

/** Typed addresses become links. */
export const links: GardState.Extension = [onSpace, onEnter]
