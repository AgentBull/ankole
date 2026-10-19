/*
 * Block structure and block insertion at the caret (SPEC §7.5 block type table: quote, callout,
 * divider and embed).
 *
 * A container holds blocks that are edited one by one: the page, a quote, a callout and a table
 * cell. A list item also holds blocks, but it belongs to its list. Block definitions import this
 * module, so it does not import the schema or the block definitions.
 */
import { Node, Plot, type ChangeSet, type Pos, type Schema, type Token } from '../core/doc'
import type { Wordgard } from '../core/editor'
import { history } from '../core/history'
import { GardSelection, Transaction, type GardState } from '../core/state'
import * as T from '../core/types'
import { Attrs } from './attributes'

export const isList = (node: Node): node is Plot => node.isPlot && node.type.hasRole(Node.Role.List)

/** Whether the plot is a list item: a child of a list. */
export const isListItem = (plot: Pos.Plot) => !!plot.parent && isList(plot.parent.node)

/** Whether the plot is a container: the page, a quote, a callout or a table cell. */
export function isContainer(plot: Pos.Plot): boolean {
  if (plot.node.inlineContent || isListItem(plot)) return false
  return plot.node.isDoc || plot.doc.schema.canContain(plot.node.type, T.Paragraph.type)
}

/** Whether the node is a container that a new block can hold, such as a quote or a callout. */
const holdsBlocks = (node: Node, schema: Schema): node is Plot =>
  node.isPlot && !node.inlineContent && schema.canContain(node.type, T.Paragraph.type)

/**
 * The nearest container around `pos`, and its child that holds `pos`. The child is null when `pos`
 * is between the blocks of the container.
 */
function placeOf(doc: Plot.Doc, pos: number): { container: Pos.Plot; block: Pos.Plot | null } {
  let inner: Pos.Plot | null = null
  for (let plot: Pos.Plot | null = doc.resolve(pos).parent; plot; inner = plot, plot = plot.parent) {
    if (isContainer(plot)) return { container: plot, block: inner }
  }
  throw new Error('The document is not a container')
}

/** An empty copy of a block, for the part after a split at its end. */
function emptyCopy(node: Node): Node | null {
  if (!node.isPlot) return null
  if (node.isTextblock) return node.tag.split(true).create([])
  const item = node.lastChild
  if (isList(node) && item?.isPlot) return node.tag.split(true).create([item.tag.split(true).create([])])
  return null
}

/**
 * Changes that insert `nodes` at `pos`. The blocks around `pos` split there, up to the nearest
 * container: a list splits at the item. A part that would be empty is not made, except after the
 * end of the last block of a container: there an empty copy follows, so that the caret has a place.
 * `at` is the position of the first inserted node in the new document.
 */
function splitInsert(doc: Plot.Doc, pos: number, nodes: readonly Node[]): { changes: ChangeSet.Spec; at: number } {
  const { container, block } = placeOf(doc, pos)
  if (!block) return { changes: { from: pos, insert: nodes }, at: pos }
  const inBlock = (plot: Pos.Plot) => !!plot.parent && plot.before >= block.before
  // Move out of the plots that the cut is at the start or the end of.
  let cut = doc.resolve(pos)
  while (inBlock(cut.parent) && !cut.inText) {
    if (cut.index == 0) cut = doc.resolve(cut.parent.before)
    else if (cut.index == cut.parent.node.content.length) cut = doc.resolve(cut.parent.after)
    else break
  }
  if (cut.pos == block.before) return { changes: { from: cut.pos, insert: nodes }, at: cut.pos }
  if (cut.pos == block.after) {
    const copy = block.after == container.end ? emptyCopy(block.node) : null
    return { changes: { from: cut.pos, insert: copy ? [...nodes, copy] : nodes }, at: cut.pos }
  }
  const close: Token[] = [],
    open: Token[] = []
  for (let plot = cut.parent; inBlock(plot); plot = plot.parent!) {
    close.push(Plot.End)
    open.unshift(plot.node.tag.split(false))
  }
  return { changes: { from: cut.pos, insert: [...close, ...nodes, ...open] }, at: cut.pos + close.length }
}

/**
 * Changes that put a textblock into a container, as a paragraph with the alignment, indent, style
 * and other attributes of the textblock. The text stays in place, so positions in it map.
 */
export function wrapTextblock(state: GardState, textblock: Pos.Plot, container: Plot.Tag): ChangeSet.Spec {
  const paragraph = state.schema.withMarksFrom(textblock.node.tag, T.Paragraph)
  return [
    { from: textblock.before, to: textblock.start, insert: [container, paragraph] },
    { from: textblock.end, to: textblock.after, insert: [Plot.End, Plot.End] }
  ]
}

/**
 * Insert a block at the caret (SPEC §7.5). A container such as a quote or a callout takes the
 * paragraph, heading or code block at the caret, and the caret moves to its end. A leaf block such
 * as a divider replaces an empty paragraph without other attributes, and an empty paragraph
 * follows it. Elsewhere the block at the caret splits at the caret and the new block goes between
 * the parts: the caret moves into a new container, or after a new leaf block.
 */
export function blockInsertion(state: GardState, node: Node): Transaction.Spec {
  const { schema } = state
  const head = state.sel.head
  const textblock = head.textblockParent
  const inContainer = !!textblock?.parent && isContainer(textblock.parent)
  if (holdsBlocks(node, schema)) {
    if (textblock && inContainer) {
      const end = textblock.end + 1
      return {
        changes: wrapTextblock(state, textblock, node.tag),
        selection: cx => GardSelection.near(cx, end, -1)
      }
    }
    const filled = node.content.length ? node : node.tag.create([T.Paragraph.create([])])
    const { changes, at } = splitInsert(state.doc, head.pos, [filled])
    return { changes, selection: cx => GardSelection.near(cx, at + 2, 1) }
  }
  if (
    textblock &&
    inContainer &&
    textblock.node.type == T.Paragraph.type &&
    !textblock.node.content.length &&
    !Attrs.isInSet(textblock.node.marks)
  ) {
    const after = textblock.before + node.length + 1
    return {
      changes: { from: textblock.before, to: textblock.after, insert: [node, T.Paragraph.create([])] },
      selection: cx => GardSelection.near(cx, after, 1)
    }
  }
  const { changes, at } = splitInsert(state.doc, head.pos, [node])
  return { changes, selection: cx => GardSelection.near(cx, at + node.length, 1) }
}

/**
 * The spec of `first` followed by the spec that `next` computes for the state after `first`. The
 * corrections that `first` causes are part of the result, so that positions in `next` stay valid.
 */
export function compose(
  state: GardState,
  first: Transaction.Spec,
  next: (state: GardState) => Transaction.Spec | null
): Transaction.Spec {
  const tr = state.update(first)
  const second = next(tr.state)
  if (!second) return first
  return Transaction.merge(
    state,
    { changes: tr.changes, selection: tr.selection ?? undefined },
    { ...second, sequential: true }
  )
}

/** Dispatch an edit as one undo step. */
export function dispatchStep(wg: Wordgard, spec: Transaction.Spec) {
  const annotations = ([] as Transaction.Annotation<unknown>[]).concat(spec.annotations ?? [], history.isolate.of(true))
  wg.dispatch({ ...spec, annotations, scrollIntoView: true })
}

// An edit that the next block insertion of an editor applies first (see `withLeadingEdit`).
const leading = new WeakMap<Wordgard, Transaction.Spec>()

/**
 * Run `f`, which inserts a block through a block definition. The insertion applies `edit` first, in
 * the same transaction, so that both are one undo step: for example the deletion of a slash query,
 * or a new paragraph for the block. When `f` inserts no block, `edit` applies alone.
 */
export function withLeadingEdit(wg: Wordgard, edit: Transaction.Spec, f: () => void) {
  leading.set(wg, edit)
  try {
    f()
  } finally {
    if (leading.get(wg) === edit) {
      leading.delete(wg)
      dispatchStep(wg, { ...edit, userEvent: 'block.insert' })
    }
  }
}

/** Insert a block at the caret as one undo step. See `blockInsertion`. */
export function insertBlock(wg: Wordgard, node: Node) {
  const edit = leading.get(wg)
  leading.delete(wg)
  const spec = edit ? compose(wg.state, edit, state => blockInsertion(state, node)) : blockInsertion(wg.state, node)
  dispatchStep(wg, { ...spec, userEvent: 'block.insert' })
  wg.focus()
}
