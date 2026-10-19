/*
 * Keys at block boundaries (SPEC §7.5 Delete and Enter, §7.6 Tab and Shift+Tab).
 *
 * The rules are functions from an editor state to a transaction spec. Command handlers run them for
 * the core's deleting commands and for Enter, so the keys, the Apple text editing keys and the
 * deleting input events of the browser all follow the same rules. A rule returns an empty spec when
 * the key leaves the page unchanged, and false when the core's command should run instead.
 */
import {
  Command,
  deleteCut,
  deleteRange,
  deleteSelection,
  deleteToLineEnd,
  deleteUnit,
  deleteWord,
  enter,
  killToLineEnd,
  moveByLine,
  selectedTextblocks
} from '../core/command'
import { ChangeSet, Leaf, Plot, Pos, type Node } from '../core/doc'
import { KeyBinding, Wordgard } from '../core/editor'
import { GardSelection, GardState, Transaction } from '../core/state'
import * as T from '../core/types'
import { Callout } from '../blocks/callout'
import { Embed } from '../blocks/embed'
import { isList } from './block-insert'
import {
  childAt,
  enterListItem,
  isItem,
  liftChanges,
  moveOutOfItem,
  removeItemHead,
  sinkChanges,
  unwrapItem
} from './lists'
import * as S from './schema'

/** Backward deletion by character or word (`char`), or to the line start (`line`). */
export type DeleteMode = 'char' | 'line'

/** Paragraphs and headings take at most this indent (SPEC §7.6). */
const maxIndent = 49

const isQuote = (node: Node) => node.type == S.Blockquote.type
const isCallout = (node: Node) => node.type == Callout.type
const isCell = (node: Node) => node.type == S.DataCell.type || node.type == S.HeaderCell.type

/** A block that can hold a paragraph: a list item, a quote, a callout or a table cell. */
const holdsText = (state: GardState, node: Node) =>
  node.isPlot && !node.inlineContent && state.schema.canContain(node.type, T.Paragraph.type)

/**
 * The block whose start (`side` -1) or end (1) holds the caret: a text block, or an empty block
 * that holds the caret itself and can hold text, such as an empty list item.
 */
function caretBlock(state: GardState, side: -1 | 1): Pos.Plot | null {
  const { head } = state.sel
  if (!head.parent.node.inlineContent) {
    return head.parent.parent && !head.parent.node.content.length && holdsText(state, head.parent.node)
      ? head.parent
      : null
  }
  const block = head.textblockParent
  return block && (side < 0 ? head.isAtStart(block) : head.isAtEnd(block)) ? block : null
}

/** A caret between blocks next to a block leaf, such as a divider or an embed. */
function besideLeaf(state: GardState, side: -1 | 1) {
  const { head } = state.sel
  const node = side < 0 ? head.nodeBefore : head.nodeAfter
  return !head.parent.node.inlineContent && !!node && node.isLeaf && node.isBlock
}

/**
 * The last place for text in `node`: its last text block, or an empty block that can hold one.
 * Leaf blocks such as dividers and embeds have none.
 */
function lastTextPlace(state: GardState, node: Pos.Node): Pos.Plot | null {
  if (!(node instanceof Pos.Plot)) return null
  if (node.node.isTextblock) return node
  if (!node.node.content.length) return holdsText(state, node.node) ? node : null
  for (let i = node.node.content.length - 1; i >= 0; i--) {
    const found = lastTextPlace(state, childAt(state.doc, node, i))
    if (found) return found
  }
  return null
}

/** The first place for text in `node`, or `stop` at a table: deleting forward does not enter tables. */
function firstTextPlace(state: GardState, node: Pos.Node): Pos.Plot | null | 'stop' {
  if (!(node instanceof Pos.Plot)) return null
  if (node.node.type == S.Table.type) return 'stop'
  if (node.node.isTextblock) return node
  if (!node.node.content.length) return holdsText(state, node.node) ? node : null
  for (let i = 0; i < node.node.content.length; i++) {
    const found = firstTextPlace(state, childAt(state.doc, node, i))
    if (found) return found
  }
  return null
}

/** The nearest place for text before `node`. The search leaves lists, but no other block. */
function previousTextPlace(state: GardState, node: Pos.Node): Pos.Plot | null {
  for (let current: Pos.Node | null = node; current?.parent;) {
    const parent: Pos.Plot = current.parent
    for (let i = current.index - 1; i >= 0; i--) {
      const found = lastTextPlace(state, childAt(state.doc, parent, i))
      if (found) return found
    }
    current = isList(parent.node) || isItem(parent.node) ? parent : null
  }
  return null
}

/** Inline content as it fits in `target`: a code block keeps only plain text and line breaks. */
function fitText(content: readonly Node[], target: Plot): Node[] {
  if (target.type != T.CodeBlock.type) return [...content]
  return content.flatMap((node): Node[] =>
    node.isText ? [Leaf.text(node.param as string)] : node.type == T.LineBreak.type ? [T.LineBreak] : []
  )
}

/**
 * Changes that remove `block`, with the lists, list items, quotes and callouts that it leaves
 * empty. The first block of a list item leaves the item's other blocks at their level.
 */
function removeBlock(state: GardState, block: Pos.Plot): ChangeSet.Spec {
  const parent = block.parent!
  if (isItem(parent.node) && block.index == 0) {
    const changes = removeItemHead(state.doc, parent)
    if (changes) return changes
  }
  let node: Pos.Node = block
  for (let up = node.parent!; up.parent && up.node.content.length == 1; up = up.parent!) {
    if (!isList(up.node) && !isItem(up.node) && !isQuote(up.node) && !isCallout(up.node)) break
    node = up
  }
  return { from: node.before, to: node.after }
}

/**
 * Join `source` to `target`, which comes before it: the text of `source` goes to the end of
 * `target`, and `source` goes. A target text block keeps its type; an empty target block gets a
 * paragraph. The caret goes to the join.
 */
function join(state: GardState, target: Pos.Plot, source: Pos.Plot, userEvent: string): Transaction.Spec {
  const text = source.node.inlineContent ? fitText(source.node.content, target.node) : []
  const intoBlock = target.node.isTextblock
  const at = intoBlock ? target.end : target.start
  const changes: ChangeSet.Spec[] = []
  if (intoBlock) changes.push({ from: at, insert: text })
  else if (text.length) changes.push({ from: at, insert: [T.Paragraph.create(text)] })
  changes.push(removeBlock(state, source))
  const inParagraph = !intoBlock && text.length > 0
  return {
    changes,
    selection: (_cx, set) => GardSelection.cursor(set.mapPos(at, -1) + (inParagraph ? 1 : 0)),
    scrollIntoView: true,
    userEvent
  }
}

/** Join `source` to the nearest text before `from`. Without text before it, nothing changes. */
function joinBackward(state: GardState, source: Pos.Plot, from: Pos.Node): Transaction.Spec {
  const target = previousTextPlace(state, from)
  return target ? join(state, target, source, 'join.backward') : {}
}

/** The blocks of a quote take its place. An empty quote becomes an empty paragraph. */
function unwrapQuote(quote: Pos.Plot): Transaction.Spec {
  return {
    changes: quote.node.content.length
      ? [
          { from: quote.before, to: quote.start },
          { from: quote.end, to: quote.after }
        ]
      : { from: quote.before, to: quote.after, insert: [T.Paragraph.create()] },
    ...(!quote.node.content.length && { selection: GardSelection.cursor(quote.before + 1) }),
    scrollIntoView: true,
    userEvent: 'unwrap'
  }
}

/**
 * Deleting a selection whose ends are in the same callout deletes only its content: the callout
 * stays, with an empty paragraph when nothing else is left (SPEC §7.5 Callouts). The core's
 * deletion could remove the whole callout when the selection covers all of its text. An explicit
 * range follows the same rule and leaves the current selection to map through the deletion.
 */
export function deleteInCallout(state: GardState, range?: { from: number; to: number }): Transaction.Spec | false {
  if (state.readOnly || (!range && !(state.selection instanceof GardSelection.Text))) return false
  const from = range ? state.doc.resolve(range.from) : state.sel.from
  const to = range ? state.doc.resolve(range.to) : state.sel.to
  if (from.pos >= to.pos) return false
  const callout = from.matchingParent(isCallout)
  if (!callout || to.matchingParent(isCallout)?.pos != callout.pos) return false
  const changes = ChangeSet.create(state.doc, { correct: { from: from.pos, to: to.pos }, local: true })
  const empty = !(changes.apply(state.doc).nodeAt(callout.before) as Plot).content.length
  return {
    changes: empty
      ? ChangeSet.create(state.doc, { from: callout.start, to: callout.end, insert: [T.Paragraph.create()] })
      : changes,
    selection: range
      ? undefined
      : (cx, set) => GardSelection.near(cx, empty ? callout.start + 1 : set.mapPos(from.pos, -1), 1),
    scrollIntoView: true,
    userEvent: 'delete.selection'
  }
}

/**
 * Deleting backward with the caret at the start of a block (SPEC §7.5, first table). `char` is
 * Backspace, Ctrl+H and word deletion; `line` is deletion to the line start.
 */
export function deleteBackward(state: GardState, mode: DeleteMode): Transaction.Spec | false {
  if (state.readOnly || !state.selection.isCursor) return false
  const block = caretBlock(state, -1)
  if (!block) return besideLeaf(state, -1) ? {} : false
  const parent = block.parent!
  const textblock = block.node.isTextblock
  // A list item, or a block that starts one, stands for the item.
  const item = isItem(block.node) ? block : isItem(parent.node) && block.index == 0 ? parent : null
  if (item) {
    if (mode == 'char') return unwrapItem(item)
    const list = item.parent!
    if (isItem(list.parent!.node)) {
      return {
        changes: liftChanges(state.doc, list, item.index, item.index),
        scrollIntoView: true,
        userEvent: 'lift.list'
      }
    }
    return joinBackward(state, block, item)
  }
  if (isItem(parent.node)) return moveOutOfItem(parent, block.index)
  const indent = textblock ? block.node.tag.mark(S.Indent) : undefined
  if (indent) return indentChange(block, indent, -1)!
  // The quote, callout or table cell whose first text holds the caret. An empty one holds it itself.
  const container = !textblock ? block : block.index == 0 && parent.parent ? parent : null
  if (container) {
    if (isQuote(container.node) && mode == 'char') return unwrapQuote(container)
    if (isQuote(container.node) || isCallout(container.node)) return joinBackward(state, block, container)
    return {}
  }
  // The first block of the page. The core removes it when it is empty and another block follows; the
  // only block of the page stays.
  if (!parent.parent && block.index == 0) return parent.node.content.length > 1 ? false : {}
  return joinBackward(state, block, block)
}

/**
 * Deleting forward with the caret at the end of a block (SPEC §7.5, second table): Delete, Ctrl+D,
 * Ctrl+K, word deletion and deletion to the line end. The next text joins the block. Leaf blocks
 * stay, the search stops at a table, and nothing leaves a table cell.
 */
export function deleteForward(state: GardState): Transaction.Spec | false {
  if (state.readOnly || !state.selection.isCursor) return false
  const block = caretBlock(state, 1)
  if (!block) return besideLeaf(state, 1) ? {} : false
  let node: Pos.Node = block
  while (node.isLast) {
    const parent = node.parent!
    if (!parent.parent || isCell(parent.node)) return {}
    node = parent
  }
  const parent = node.parent!
  for (let i = node.index + 1; i < parent.node.content.length; i++) {
    const found = firstTextPlace(state, childAt(state.doc, parent, i))
    if (found == 'stop') return {}
    if (found) return join(state, block, found, 'join.forward')
  }
  return {}
}

/** Enter in a heading: the text after the caret becomes a paragraph; at the start or end, an empty paragraph goes before or after. */
function enterHeading(state: GardState, block: Pos.Plot): Transaction.Spec {
  const { head } = state.selection
  const base = { scrollIntoView: true, userEvent: 'split.textblock' }
  if (head == block.start && block.node.content.length) {
    return { ...base, changes: { from: block.before, insert: [T.Paragraph.create()] } }
  }
  if (head == block.end) {
    return {
      ...base,
      changes: { from: block.after, insert: [T.Paragraph.create()] },
      selection: GardSelection.cursor(block.after + 1)
    }
  }
  return {
    ...base,
    changes: { from: head, insert: [Plot.End, T.Paragraph] },
    selection: GardSelection.cursor(head + 2)
  }
}

/**
 * Enter in a paragraph of a quote: the text after the caret leaves the quote as a paragraph, and the
 * blocks after it in the quote form a new quote after that paragraph. At the start of the quote's
 * first, non-empty paragraph, an empty paragraph goes before the quote.
 */
function enterQuote(state: GardState, block: Pos.Plot, quote: Pos.Plot): Transaction.Spec {
  const { head } = state.selection
  const base = { scrollIntoView: true, userEvent: 'split.textblock' }
  if (block.index == 0 && head == block.start && block.node.content.length) {
    return { ...base, changes: { from: quote.before, insert: [T.Paragraph.create()] } }
  }
  const paragraph = block.node.tag.split(head == block.end)
  const changes: ChangeSet.Spec[] = [
    // A paragraph that keeps no text goes, and so does a quote that keeps no blocks.
    head > block.start
      ? { from: head, insert: [Plot.End, Plot.End, paragraph] }
      : block.index > 0
        ? { from: block.before, to: block.start, insert: [Plot.End, paragraph] }
        : { from: quote.before, to: block.start, insert: [paragraph] },
    block.isLast ? { from: quote.end, to: quote.after } : { from: block.after, insert: [quote.node.tag] }
  ]
  return { ...base, changes, selection: (_cx, set) => GardSelection.cursor(set.mapPos(head, 1)) }
}

/** Enter in the last, empty paragraph of a callout that holds other blocks moves the paragraph after the callout. */
function enterCallout(block: Pos.Plot, callout: Pos.Plot): Transaction.Spec | false {
  if (block.node.content.length || !block.isLast || callout.node.content.length < 2) return false
  return {
    changes: { from: block.before, to: callout.after, insert: [Plot.End, block.node] },
    selection: GardSelection.cursor(block.before + 2),
    scrollIntoView: true,
    userEvent: 'split.textblock'
  }
}

/**
 * Enter (SPEC §7.5): headings, paragraphs in quotes and callouts, and list items have their own
 * rules. A selection goes first. Elsewhere the core's command splits the block.
 */
export function enterBlock(state: GardState): Transaction.Spec | false {
  const { selection } = state
  if (state.readOnly || !(selection instanceof GardSelection.Text)) return false
  if (!selection.empty) {
    const removed = deleteSelection(state)
    const rest = removed && enterBlock(state.update(removed).state)
    return rest ? Transaction.merge(state, removed, { ...rest, sequential: true }) : false
  }
  const { head } = state.sel
  const block = head.parent.node.inlineContent ? head.textblockParent : null
  if (block?.node.type == T.Heading) return enterHeading(state, block)
  if (block?.node.type == T.Paragraph.type) {
    const parent = block.parent!
    if (isQuote(parent.node)) return enterQuote(state, block, parent)
    if (isCallout(parent.node)) return enterCallout(block, parent)
  }
  return enterListItem(state)
}

/** A change of the indent of a paragraph or heading by `dir`, or null at the limits. */
function indentChange(block: Pos.Plot, indent: number, dir: 1 | -1): Transaction.Spec | null {
  const next = indent + dir
  if (next < 0 || next > Math.max(indent, maxIndent)) return null
  return {
    changes: { from: block.before, ...(next ? { add: S.Indent.of(next) } : { remove: S.Indent.of(indent) }) },
    scrollIntoView: true,
    userEvent: dir > 0 ? 'indent' : 'outdent'
  }
}

/**
 * Tab (`dir` 1) and Shift+Tab (-1) anywhere in a block (SPEC §7.6): list items change their level,
 * paragraphs and headings their indent, and a code block takes a tab character. Table cells are
 * left to the table handlers.
 */
export const indent: Command.Pure<1 | -1> = ({ state }, dir) => {
  if (state.readOnly) return false
  const { sel } = state
  const inCell = (pos: Pos) => !!pos.matchingParent(plot => isCell(plot))
  if (inCell(sel.from) || inCell(sel.to)) return false
  const code = sel.from.textblockParent
  if (code?.node.type == T.CodeBlock.type && sel.to.textblockParent?.pos == code.pos) {
    if (dir < 0) return {}
    return {
      changes: { from: sel.from.pos, to: sel.to.pos, insert: [Leaf.text('\t')] },
      selection: GardSelection.cursor(sel.from.pos + 1),
      scrollIntoView: true,
      userEvent: 'input.type'
    }
  }
  const changes: ChangeSet.Spec[] = []
  const items: Pos.Plot[] = []
  const blocks = selectedTextblocks(state)
  if (!blocks.length && isItem(sel.head.parent.node)) items.push(sel.head.parent)
  for (const block of blocks) {
    const parent = block.parent!
    if (isItem(parent.node)) {
      if (!items.some(item => item.pos == parent.pos)) items.push(parent)
    } else if (block.node.type == T.Paragraph.type || block.node.type == T.Heading) {
      const change = indentChange(block, block.node.tag.mark(S.Indent) ?? 0, dir)
      if (change) changes.push(change.changes!)
    }
  }
  // Nested items move with the items that hold them. Neighbouring items move together.
  const groups: { list: Pos.Plot; first: number; last: number }[] = []
  for (const item of items) {
    if (items.some(other => other.before < item.before && item.after <= other.after)) continue
    const list = item.parent!,
      group = groups.at(-1)
    if (group && group.list.pos == list.pos && group.last + 1 == item.index) group.last = item.index
    else groups.push({ list, first: item.index, last: item.index })
  }
  for (const { list, first, last } of groups) {
    const change =
      dir > 0
        ? sinkChanges(state.doc, list, first, last)
        : isItem(list.parent!.node)
          ? liftChanges(state.doc, list, first, last)
          : null
    if (change) changes.push(change)
  }
  if (!changes.length) return false
  return { changes, scrollIntoView: true, userEvent: dir > 0 ? 'indent' : 'outdent' }
}

// The deleting input events of the browser, for example from a soft keyboard, by direction.
const deletingInput: Record<string, [-1 | 1, DeleteMode]> = {
  deleteContentBackward: [-1, 'char'],
  deleteWordBackward: [-1, 'char'],
  deleteSoftLineBackward: [-1, 'line'],
  deleteHardLineBackward: [-1, 'line'],
  deleteContentForward: [1, 'char'],
  deleteWordForward: [1, 'char'],
  deleteSoftLineForward: [1, 'line'],
  deleteHardLineForward: [1, 'line']
}

/**
 * A deleting input event at a block boundary. The core runs the deleting commands for these events,
 * except when the event's range reaches past the caret: a soft keyboard deletes across the boundary
 * of two blocks. Such a range still follows the rules when it ends at the caret.
 */
function deletingInputEvent(event: InputEvent, wg: Wordgard): boolean {
  const kind = deletingInput[event.inputType]
  if (!kind || !event.cancelable || wg.composing) return false
  const [side, mode] = kind
  const range = event.getTargetRanges()[0]
  if (range) {
    const { head } = wg.state.selection
    try {
      const pos =
        side < 0
          ? wg.posAtDOM(range.endContainer, range.endOffset)
          : wg.posAtDOM(range.startContainer, range.startOffset)
      if (pos != head) return false
    } catch {
      return false
    }
  }
  const spec = side < 0 ? deleteBackward(wg.state, mode) : deleteForward(wg.state)
  if (!spec) return false
  wg.dispatch(spec)
  return true
}

/**
 * Ctrl+K on Apple platforms deletes to the line end, or at a block end joins the next text, like
 * Delete. The deleted text does not go to a kill ring, so Ctrl+Y does not insert it again.
 */
const deleteToLineEndWithoutKill: Command = wg =>
  !wg.state.readOnly &&
  (deleteInCallout(wg.state) ||
    deleteSelection(wg.state) ||
    deleteForward(wg.state) ||
    deleteToLineEnd(wg, 'forward') ||
    deleteUnit(wg, 'forward'))

/**
 * Up and Down go past an embed (SPEC §7.5 Embeds). Where the core's motion
 * selects one, the motion goes on from beside it. With nothing past it, the caret stays.
 */
const lineMotion: Command<{ dir: 'up' | 'down'; extend?: boolean }> = (wg, param) => {
  if (param.extend) return false
  const moved = moveByLine(wg, param)
  if (typeof moved == 'boolean') return moved
  const forward = param.dir == 'down'
  let selection = moved.selection as GardSelection | null
  while (selection instanceof GardSelection.Node && selection.node.type == Embed.type) {
    const beside = GardSelection.cursor(forward ? selection.to : selection.from, forward ? 1 : -1, selection.goalColumn)
    selection = wg.moveVertically(beside, forward, undefined, true)
  }
  return selection ? { ...moved, selection } : true
}

/** The deleting keys and input events: a selection in a callout, then the block boundary rules. */
const deleting =
  (mode: DeleteMode): Command<'forward' | 'backward'> =>
  ({ state }, dir) =>
    deleteInCallout(state) || (dir == 'backward' ? deleteBackward(state, mode) : deleteForward(state))

/** Backspace, Delete, Enter, Tab and Up and Down at block boundaries, and the deletion of a cut. */
export const blockKeys: GardState.Extension = [
  Command.handler(deleteRange, ({ state }, range) => {
    const spec = deleteInCallout(state, range)
    return spec && { ...spec, userEvent: range.userEvent }
  }),
  Command.handler(deleteUnit, deleting('char')),
  Command.handler(deleteCut, ({ state }) => {
    const spec = deleteInCallout(state)
    return spec && { ...spec, userEvent: 'delete.cut' }
  }),
  Command.handler(deleteWord, deleting('char')),
  Command.handler(deleteToLineEnd, deleting('line')),
  Command.handler(killToLineEnd, deleteToLineEndWithoutKill),
  Command.handler(enter, wg => enterBlock(wg.state)),
  Command.handler(moveByLine, lineMotion),
  KeyBinding.of({ key: 'Tab', run: Command.bind(indent, 1), shift: Command.bind(indent, -1) }),
  Wordgard.domEventHandler('beforeinput', deletingInputEvent)
]
