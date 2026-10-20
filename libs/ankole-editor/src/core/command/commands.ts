import { Plot, Mark, Leaf, Token, ChangeSet } from '../doc'
import { GardSelection, GardState, Transaction } from '../state'
import { type Wordgard } from '../editor'
import { Alignment, Direction, Emphasis, Strong, Underline } from '../types'
import { Command } from './command'
import {
  joinForward,
  joinBackward,
  liftEmptyBlock,
  enterInCode,
  deleteSelection,
  deleteEmptyPlot,
  deleteForward,
  deleteBackward,
  splitTextblock,
  joinListItems,
  canAddMarkInRange,
  selectedTextblocks
} from './helper'
import { findClusterBreak } from '@marijn/find-cluster-break'

/**
 * This command handles text input. To selectively override the
 * behavior of text input, provide a handler that, when the
 * conditions that it requires apply, handles the input and returns
 * true. `userEvent` will generally be one of `"input.type"`,
 * `"input.type.compose"` (text inserted as part as a composition),
 * or `"input.type.compose.start"` (initial text created by a started
 * composition).
 */
export const insertText: Command.Pure<{ from: number; to: number; insert: string; userEvent: string }> = (
  { state },
  { from, to, insert, userEvent }
) => {
  if (state.readOnly) return false
  const { selection } = state
  const marks =
    (from == selection.from && to == selection.to && state.sel.activeMarks) ||
    state.doc.resolve(from).marks(state.doc.resolve(to))
  return {
    changes: { from, to, insert: [Leaf.Text.of(insert, marks)], fit: true },
    scrollIntoView: true,
    selection: (cx, changes) => GardSelection.near(cx, changes.mapPos(to, 1), -1),
    userEvent
  }
}

/**
 * Command to insert a line break. The default handler will, if the
 * schema defines a {@link Node.Role.LineBreak line break} node and
 * the selection's parent node allows that, insert such a node.
 * Otherwise, in nodes marked as
 * {@link Plot.Spec.preserveWhitespace whitespace-preserving}, this
 * will insert a line break.
 */
export const insertLineBreak: Command.Pure = ({ state }) => {
  if (state.readOnly) return false
  const { doc, sel } = state
  const brk = doc.schema.lineBreak,
    parent = sel.from.parent.node.type
  const { from, to } = state.selection.replacementRange
  const insertBreak = brk && doc.schema.canContain(parent, brk.type)
  if (!(insertBreak || (parent.preserveWhitespace && sel.to.parent.start == sel.from.parent.start))) return false
  const insert = insertBreak ? brk!.withMarks(state.sel.activeMarks) : Leaf.text('\n', state.sel.activeMarks)
  const changes = ChangeSet.create(state.doc, { from, to, insert: [insert], fit: true })
  const pos = changes.findInserted(t => (insertBreak ? t.type == brk!.type : t.isText))
  return {
    changes,
    selection: GardSelection.cursor(pos == null ? from : pos + 1, -1),
    scrollIntoView: true,
    userEvent: insertBreak ? 'insert.linebreak' : 'input'
  }
}

/**
 * The command that handles enter presses. The default handler will,
 * if the selection is not in an inline context, insert an empty
 * default textblock in its position. Otherwise it first tries {@link
 * enterInCode}, then {@link liftEmptyBlock}, and finally {@link
 * splitTextblock}.
 */
export const enter: Command.Pure = ({ state }) => {
  if (state.readOnly) return false
  const { sel, doc } = state

  // When not in an inline context, try to create new empty textblock
  if (!sel.head.parent.node.inlineContent || !sel.anchor.parent.node.inlineContent) {
    const { from, to } = sel.replacementRange
    const wrap = doc.schema.findWrapping(from.parent.node.type, Leaf.Text)
    if (!wrap) return false
    let content: Plot[] = []
    for (let i = wrap.length - 1; i >= 0; i--) content = [wrap[i]!.create(content)]
    const changes = ChangeSet.create(state.doc, { from: from.pos, to: to.pos, insert: content, fit: true })
    const placed = content.length ? changes.findInserted(t => t == content[0]!.tag) : null
    return {
      changes,
      selection: placed != null ? cx => GardSelection.near(cx, placed + wrap.length, -1) : undefined,
      scrollIntoView: true,
      userEvent: 'insert.textblock'
    }
  }

  return enterInCode(state) || liftEmptyBlock(state) || splitTextblock(state)
}

/**
 * Delete the selection, or the unit after or before the selection.
 * If that unit is the start or end of a textblock, this will try to
 * join that textblock to the next one. Otherwise, if it is a
 * character or leaf node, that is deleted. If none of that is
 * possible and the cursor is in an empty textblock, this will delete
 * the textblock.
 *
 * When deleting backward at the start of a list item that has a
 * sibling before it, this command will try to join those list items.
 */
export const deleteUnit: Command.Pure<'forward' | 'backward'> = ({ state }, dir) => {
  if (state.readOnly) return false
  return (
    deleteSelection(state) ||
    (dir == 'forward'
      ? joinForward(state) || deleteForward(state) || deleteEmptyPlot(state, 1)
      : joinListItems(state) || joinBackward(state) || deleteBackward(state) || deleteEmptyPlot(state, -1))
  )
}

/**
 * Delete the selection, or the word next to it. Will behave like
 * {@link deleteUnit}, except that, when deleting text, it will
 * delete an entire word.
 */
export const deleteWord: Command.Pure<'forward' | 'backward'> = ({ state }, dir) => {
  if (state.readOnly) return false
  return (
    deleteSelection(state) ||
    (dir == 'forward'
      ? joinForward(state) || deleteForward(state, true) || deleteEmptyPlot(state, 1)
      : joinListItems(state) || joinBackward(state) || deleteBackward(state, true) || deleteEmptyPlot(state, -1))
  )
}

/**
 * Delete to the end or start of the line. Stops at line wrapping
 * points.
 */
export const deleteToLineEnd: Command<'forward' | 'backward'> = (wg, dir) => {
  if (wg.state.readOnly) return false
  const tr = deleteSelection(wg.state)
  const { selection } = wg.state
  if (tr) return tr
  if (!(selection instanceof GardSelection.Text)) return false
  const end = wg.moveToLineBoundary(selection, dir == 'forward')
  if (!end || end.head == selection.head) return false
  return {
    changes: {
      correct: dir == 'forward' ? { from: selection.head, to: end.head } : { from: end.head, to: selection.head }
    },
    scrollIntoView: true,
    userEvent: `delete.${dir}`
  }
}

const addToKillBuffer = Transaction.Effect.define<readonly Token[]>()

const killBuffer = GardState.Field.define<{ content: readonly Token[]; active: boolean }>({
  create() {
    return { content: [], active: false }
  },
  update(value, tr) {
    const add = tr.effects.find(e => e.is(addToKillBuffer))
    if (add) return { content: value.active ? value.content.concat(add.value) : add.value, active: true }
    return !value.active || tr.annotation(Transaction.remote) || !(tr.docChanged || tr.selection)
      ? value
      : { content: value.content, active: false }
  }
})

function killText(state: GardState, from: number, to: number) {
  const add = addToKillBuffer.of(state.doc.slice(from, to))
  return state.field(killBuffer, false) ? [add] : [GardState.appendConfig.of(killBuffer), add]
}

/**
 * Delete an explicit document range, such as a browser input event's target range. The current
 * selection maps through the deletion. Handlers can apply the document's rules to the range.
 */
export const deleteRange: Command.Pure<{ from: number; to: number; userEvent: string }> = (
  { state },
  { from, to, userEvent }
) => {
  if (state.readOnly || from >= to) return false
  return { changes: { from, to, fit: true }, scrollIntoView: true, userEvent }
}

/**
 * Delete the selection after a cut has written it to the clipboard.
 * The cut event dispatches this command, so that extensions can
 * change how a cut deletes.
 */
export const deleteCut: Command.Pure = ({ state }) => {
  if (state.readOnly || state.selection.empty) return false
  return {
    changes: state.selection.ranges.map(r => ({ from: r.from, to: r.to, fit: true })),
    selection: (cx, changes) => GardSelection.near(cx, changes.mapPos(state.selection.from, -1), 1),
    scrollIntoView: true,
    userEvent: 'delete.cut'
  }
}

/**
 * Command similar to forward `deleteToLineEnd` for macOS's Ctrl-k
 * binding. If there's no content left on the line, this will delete
 * the node (generally a line break) after the cursor of, if at end
 * of textblock, join it to the next textblock.
 *
 * Content deleted by this command is added to a ‘kill buffer’, and
 * can be reinserted with {@link yankKilled}. Multiple kill actions
 * in sequence will accumulate the deleted content in the buffer.
 * Doing anything else and then running this command again will reset
 * the buffer to hold only the newly killed content.
 */
export const killToLineEnd: Command = wg => {
  const { state } = wg,
    { selection } = state
  if (state.readOnly || !(selection instanceof GardSelection.Text)) return false
  const end = wg.moveToLineBoundary(selection, true)
  if (!end) return false
  if (end.head > selection.head) {
    return {
      changes: { correct: { from: selection.head, to: end.head } },
      scrollIntoView: true,
      effects: killText(state, selection.head, end.head),
      userEvent: 'delete.forward'
    }
  }
  const join = joinForward(state)
  if (join) {
    let joinEnd: number | undefined
    state.doc.iterate(state.sel.head.textblockParent!.after, state.doc.length, (node, pos) => {
      if (joinEnd != null) return false
      if (node.isPlot && node.isTextblock) joinEnd = pos + 1
    })
    return Transaction.merge(state, join, {
      effects: joinEnd == null ? undefined : killText(state, selection.head, joinEnd!)
    })
  }
  const next = state.sel.head.nodeAfter
  if (next) {
    return {
      changes: { correct: { from: selection.head, to: selection.head + next.length } },
      scrollIntoView: true,
      effects: killText(state, selection.head, selection.head + next.length),
      userEvent: 'delete.forward'
    }
  }
  return false
}

/**
 * Insert the content killed by the most recent {@link killToLineEnd}
 * command (or sequence thereof) at the cursor position.
 */
export const yankKilled: Command = wg => {
  const { state } = wg
  const buffer = wg.state.field(killBuffer, false)
  if (!buffer || !buffer.content.length || !(state.selection instanceof GardSelection.Text)) return false
  const { selection } = state
  return {
    changes: { correct: { from: selection.from, to: selection.to, insert: buffer.content } },
    scrollIntoView: true,
    selection: (cx, changes) => GardSelection.near(cx, changes.mapPos(selection.from, 1)),
    userEvent: 'input.yank'
  }
}

/**
 * Delete the selection, or if that is empty, the line around the
 * cursor.
 */
export const deleteLine: Command = wg => {
  if (wg.state.readOnly) return false
  const tr = deleteSelection(wg.state)
  const { selection } = wg.state
  if (tr) return tr
  if (!(selection instanceof GardSelection.Text)) return false
  const start = wg.moveToLineBoundary(selection, false),
    end = wg.moveToLineBoundary(selection, true)
  if (!start || !end || start.head >= end.head) return false
  return {
    changes: { correct: { from: start.head, to: end.head } },
    scrollIntoView: true,
    userEvent: 'delete.line'
  }
}

/** Swap the characters before and after the cursor. */
export const transposeChars: Command.Pure = ({ state }) => {
  if (state.readOnly || !state.selection.isCursor) return false
  const { sel } = state
  const head = state.selection.head
  const before = sel.head.nodeBefore,
    after = sel.head.nodeAfter
  if (!before || !before.is(Leaf.Text) || !after || !after.is(Leaf.Text)) return false
  const lenBefore = before.param.length - findClusterBreak(before.param, before.param.length, false)
  const lenAfter = findClusterBreak(after.param, 0)
  return {
    changes: [
      { from: head - lenBefore, to: head },
      { from: head + lenAfter, insert: [Leaf.text(before.param.slice(before.param.length - lenBefore))] }
    ],
    selection: GardSelection.cursor(head + lenAfter, -1),
    scrollIntoView: true,
    userEvent: 'transpose'
  }
}

/**
 * Toggle the given mark. If there is no selection, it is added to
 * the cursor's active marks, or removed if it is already in there.
 * Otherwise, if any selected content allows for the mark to be
 * added, it is added. If not, remove the mark from the selection.
 */
export const toggleMark: Command.Pure<Mark> = ({ state }, mark) => {
  if (state.readOnly) return false
  const { selection, doc } = state
  if (selection instanceof GardSelection.Text && selection.empty) {
    const selMarks = selection.marks || state.sel.head.marks(),
      add = !mark.isInSet(selMarks)
    const newMarks = add ? mark.addToSet(selMarks) : mark.removeFromSet(selMarks)
    return {
      selection: GardSelection.Text.create({
        anchor: selection.anchor,
        headSide: selection.headSide,
        goalColumn: selection.goalColumn,
        marks: newMarks
      }),
      userEvent: add ? 'mark.add' : 'mark.remove'
    }
  } else if (selection.ranges.some(r => canAddMarkInRange(doc, r.from, r.to, mark))) {
    return {
      changes: selection.ranges.map(r => ({ from: r.from, to: r.to, add: mark })),
      userEvent: 'mark.add'
    }
  } else {
    return {
      changes: selection.ranges.map(r => ({ from: r.from, to: r.to, remove: mark })),
      userEvent: 'mark.remove'
    }
  }
}

/**
 * Toggle emphasis. The default implementation uses the {@link
 * Emphasis} mark.
 */
export const toggleEmphasis: Command.Pure = target => toggleMark(target, Emphasis)

/**
 * Toggle strong emphasis. The default implementation uses the {@link
 * Strong} mark.
 */
export const toggleStrong: Command.Pure = target => toggleMark(target, Strong)

/**
 * Toggle underlining. The default implementation uses the {@link
 * Underline} mark.
 */
export const toggleUnderline: Command.Pure = target => toggleMark(target, Underline)

/**
 * Set the selected textblocks to the given alignment. `"left"` and
 * `"right"` will be normalized to `"start"` or `"end"` depending on
 * the editor's text direction. The default implementation uses the
 * {@link Alignment} mark.
 */
export const setAlignment: Command.Pure<null | 'start' | 'end' | 'center' | 'left' | 'right'> = ({ state }, align) => {
  const { schema } = state.doc
  if (state.readOnly || !schema.has(Alignment)) return false
  if (align == 'start') align = null
  if (align == 'left' || align == 'right') align = ltrAtCursor(state) == (align == 'left') ? null : 'end'
  const changes: ChangeSet.Spec[] = []
  for (const block of selectedTextblocks(state)) {
    const cur = block.node.tag.mark(Alignment)
    if (cur != align && schema.markAllowed(Alignment, block.node.type)) {
      changes.push(
        align ? { from: block.before, add: Alignment.of(align) } : { from: block.before, remove: Alignment.of(cur!) }
      )
    }
  }
  if (!changes.length) return false
  return {
    changes,
    userEvent: 'mark.set.alignment'
  }
}

/**
 * Set the text direction for the selected textblocks. `null` will
 * remove an explicit direction mark, defaulting the blocks back to
 * the editor's base direction. The default implementation uses the
 * {@link Direction} mark.
 */
export const setDirection: Command.Pure<null | 'ltr' | 'rtl' | 'auto'> = ({ state }, dir) => {
  const { schema } = state.doc
  if (state.readOnly || !schema.has(Direction)) return false
  const changes: ChangeSet.Spec[] = []
  for (const block of selectedTextblocks(state)) {
    const cur = block.node.tag.mark(Direction)
    if (cur != dir && schema.markAllowed(Direction, block.node.type)) {
      changes.push(
        dir ? { from: block.before, add: Direction.of(dir) } : { from: block.before, remove: Direction.of(cur!) }
      )
    }
  }
  if (!changes.length) return false
  return {
    changes,
    userEvent: 'mark.set.direction'
  }
}

function setSelection(selection: GardSelection): Transaction.Spec {
  return {
    selection: selection,
    scrollIntoView: true,
    userEvent: 'select'
  }
}

function ltrAtCursor(state: GardState) {
  const block = state.sel.head.textblockParent
  return block ? state.textblockLTR(block.node) : state.textLTR
}

function isForward(dir: 'left' | 'right' | 'forward' | 'backward', state: GardState) {
  return dir == 'forward' ? true : dir == 'backward' ? false : (dir == 'right') == ltrAtCursor(state)
}

function asTextSel(sel: GardSelection, forward: boolean): GardSelection.Text {
  if (sel instanceof GardSelection.Text) {
    return sel.directional
      ? sel
      : forward
        ? GardSelection.range(sel.from, sel.to)
        : GardSelection.range(sel.to, sel.from)
  }
  const { from, to } = sel.replacementRange
  return forward ? GardSelection.range(from, to) : GardSelection.range(to, from)
}

function extendSel(base: GardSelection, head: GardSelection.Text) {
  return GardSelection.range(base.anchor, head.head, head.headSide, head.goalColumn)
}

/**
 * Move the selection head one unit (text cluster, atomic node, or
 * node boundary) in the indicated direction. When `extend` is true,
 * keep the selection anchor in place. The default handler moves
 * visually through bidirectional text, so when going left, the
 * motion will go back in left-to-right text, and
 * forward in right-to-left text.
 */
export const moveByUnit: Command.Pure<{ dir: 'left' | 'right' | 'forward' | 'backward'; extend?: boolean }> = (
  { state },
  { dir, extend }
) => {
  const forward = isForward(dir, state),
    selection = asTextSel(state.selection, forward)
  if (!selection.empty && !extend) {
    return setSelection(GardSelection.near(state, forward ? selection.to : selection.from, forward ? -1 : 1))
  } else {
    let next: GardSelection | null = selection.nextNormalCursor(state, forward)
    if (!next) return false
    if (!extend) {
      state.doc.iterate(Math.min(selection.head, next.head), Math.max(selection.head, next.head), (node, pos) => {
        if (node.type.isSelectable && state.isAtom(node.type)) next = GardSelection.node(pos, node)
        if (node.isPlot) return !node.type.isolating
      })
    }
    return setSelection(extend ? extendSel(selection, next as GardSelection.Text) : next)
  }
}

/**
 * Move the selection head one word in the indicated direction. Keep
 * the anchor in place if `extend` is true. The default handler moves
 * visually.
 */
export const moveByWord: Command.Pure<{ dir: 'left' | 'right'; extend?: boolean }> = ({ state }, { dir, extend }) => {
  const forward = (dir == 'right') == ltrAtCursor(state)
  const selection = asTextSel(state.selection, forward)
  const moved = selection.skipWord(state, forward)
  return moved ? setSelection(extend ? extendSel(selection, moved) : moved) : false
}

function nextVertical(wg: Wordgard, sel: GardSelection, forward: boolean, distance?: number, allowNode?: boolean) {
  const next = wg.moveVertically(sel, forward, distance, allowNode)
  if (next) return next
  const end = (forward ? GardSelection.atEnd : GardSelection.atStart)(wg.state)
  return end.head == wg.state.selection.head ? null : end
}

/**
 * Move the selection head one line up or down. When `extend` is
 * true, keep the anchor in place.
 */
export const moveByLine: Command<{ dir: 'up' | 'down'; extend?: boolean }> = (wg, { dir, extend }) => {
  const { state } = wg
  let { selection } = state
  const forward = dir == 'down'
  if (selection instanceof GardSelection.Node) {
    const next = !extend && GardSelection.near(state, forward ? selection.to : selection.from, forward ? -1 : 1)
    if (next && !state.doc.resolve(next.head).parent.node.inlineContent) {
      return setSelection(GardSelection.cursor(next.head, next.headSide, selection.goalColumn))
    }
    selection = GardSelection.cursor(forward ? selection.to : selection.from, undefined, selection.goalColumn)
  } else {
    selection = asTextSel(state.selection, forward)
  }
  const moved = nextVertical(wg, selection, forward, undefined, !extend)
  return moved ? setSelection(extend ? extendSel(selection, moved as GardSelection.Text) : moved) : false
}

function pageHeight(wg: Wordgard) {
  let marginTop = 0,
    marginBottom = 0
  for (const source of wg.state.facet((wg.constructor as typeof Wordgard).coveredMargins)) {
    const margins = source(wg)
    if (margins?.top) marginTop = Math.max(margins?.top, marginTop)
    if (margins?.bottom) marginBottom = Math.max(margins?.bottom, marginBottom)
  }
  return Math.max(
    10,
    Math.min(
      wg.scrollDOM.clientHeight - marginTop - marginBottom,
      (wg.dom.ownerDocument.defaultView || window).innerHeight
    ) - 10
  )
}

/**
 * Move the selection head one page up or down. Extend the selection
 * when the `extend` flag is true.
 */
export const moveByPage: Command<{ dir: 'up' | 'down'; extend?: boolean }> = (wg, { dir, extend }) => {
  const { state } = wg
  const forward = dir == 'down',
    selection = asTextSel(state.selection, forward)
  const moved =
    selection.empty || extend
      ? nextVertical(wg, selection, forward, pageHeight(wg), !extend)
      : forward
        ? GardSelection.cursor(selection.to, -1)
        : GardSelection.cursor(selection.from, 1)
  return moved ? setSelection(extend ? extendSel(selection, moved as GardSelection.Text) : moved) : false
}

/**
 * Move to the indicated side of the current line. Will stop at line
 * wrap points. `"left"` and `"right"` will be interpreted based on
 * the editor's text direction.
 */
export const moveToLineSide: Command<{
  dir: 'left' | 'right' | 'forward' | 'backward'
  extend?: boolean
}> = (wg, { dir, extend }) => {
  const forward = isForward(dir, wg.state),
    selection = asTextSel(wg.state.selection, forward)
  const pos = wg.moveToLineBoundary(selection, forward)
  return pos
    ? setSelection(extend ? extendSel(selection, pos) : pos)
    : extend || selection.empty
      ? false
      : setSelection(GardSelection.near(wg.state, forward ? selection.to : selection.from))
}

/**
 * Move to the start or end of the textblock that has the selection
 * head.
 */
export const moveToTextblockSide: Command<{
  dir: 'left' | 'right' | 'forward' | 'backward'
  extend?: boolean
}> = (wg, { dir, extend }) => {
  const { state } = wg
  const block = state.sel.head.textblockParent
  if (!block) return false
  const forward = isForward(dir, wg.state)
  const pos = forward ? GardSelection.atEnd(state, block) : GardSelection.atStart(state, block)
  return setSelection(extend ? extendSel(asTextSel(wg.state.selection, forward), pos) : pos)
}

/** Move to the start or end of the document. */
export const moveToDocSide: Command.Pure<{ side: 'start' | 'end'; extend?: boolean }> = (target, { side, extend }) => {
  const { state } = target
  const pos = side == 'start' ? GardSelection.atStart(state) : GardSelection.atEnd(state)
  if (state.selection.empty && pos.head == state.selection.head) return false
  return setSelection(extend ? extendSel(asTextSel(state.selection, side == 'end'), pos) : pos)
}

/** Select the entire document. */
export const selectAll: Command.Pure = ({ state }) => {
  return {
    selection: GardSelection.range(0, state.doc.length),
    userEvent: 'select.all'
  }
}

/**
 * Undo an edit. Does not have a default handler, but a handler is
 * added by the history extension.
 */
export const undo: Command = () => false

/** Redo an edit. Does not have a default handler. */
export const redo: Command = () => false
