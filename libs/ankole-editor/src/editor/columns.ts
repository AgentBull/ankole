import { type Node, type Plot, type Pos } from '../core/doc'
import { type Wordgard } from '../core/editor'
import { GardSelection, type GardState, type Transaction } from '../core/state'
import { blockContent, blockRemovalRange, blockRemovalRanges, targetAt, unitAt } from './block-target'
import { compose, isList, splitInsert } from './block-insert'
import { BlockSelection } from './block-selection'
import { Column, Columns, ColumnWidth } from './schema'
import { markValue } from './attributes'
import { Embed } from '../blocks/embed'
import * as T from '../core/types'

/** Text crosses columns in document order; table rows keep their geometric navigation. */
export function columnLineMotion(wg: Wordgard, moved: GardSelection, forward: boolean): GardSelection {
  const { state } = wg
  const block = state.sel.head.textblockParent
  if (!block || state.doc.resolve(moved.head).textblockParent?.before === block.before) return moved
  const column = (node: Pos.Node) => {
    for (let parent: Pos.Node | null = node; parent; parent = parent.parent) {
      if (parent.node.type === Column.type) return parent.before
    }
    return null
  }
  const fromColumn = column(block)
  if (fromColumn === column(state.doc.resolve(moved.head).parent)) return moved
  let target: Pos.Node | null = null
  state.doc.iterate(forward ? block.after : 0, forward ? state.doc.length : block.before, (node, pos) => {
    if (forward && target) return false
    if (node.type === Embed.type) return false
    if ((node.isPlot && node.isTextblock) || (node.isBlock && state.isAtom(node.type))) {
      target = state.doc.resolveNode(pos)
      return false
    }
  })
  if (!target) return moved
  const next = target as Pos.Node
  if (fromColumn === column(next)) return moved
  if (!next.node.isPlot || !next.node.isTextblock) return GardSelection.node(next.before, next.node, moved.goalColumn)
  const text = next as Pos.Plot
  const edge = forward ? text.start : text.end
  const rect = wg.coordsForElement(text.before)!
  const line = wg.coordsAtPos(edge, forward ? 1 : -1)
  const editor = wg.contentDOM.getBoundingClientRect()
  const origin = wg.coordsAtPos(state.selection.head, state.selection.headSide)
  const goal = moved.goalColumn ?? (state.textLTR ? origin.left - editor.left : editor.right - origin.left)
  const x = state.textLTR ? editor.left + goal : editor.right - goal
  const found = wg.posAtCoords({
    x: Math.max(rect.left + 0.2, Math.min(rect.right - 0.2, x)),
    y: (line.top + line.bottom) / 2
  })
  return GardSelection.cursor(Math.max(text.start, Math.min(text.end, found.pos)), found.side, goal)
}

/** Resize an adjacent pair without changing the combined width of that pair. */
export function columnResize(state: GardState, left: number, right: number, weight: number): Transaction.Spec | null {
  const a = state.doc.resolveNode(left)
  const b = state.doc.resolveNode(right)
  if (state.readOnly || a?.node.type !== Column.type || b?.node.type !== Column.type || a.after !== b.before) {
    return null
  }
  const total = (markValue(a.node, ColumnWidth) ?? 1000) + (markValue(b.node, ColumnWidth) ?? 1000)
  const value = Math.min(9999, total - 1, Math.max(1, total - 9999, Math.round(weight)))
  return {
    changes: [
      { from: left, add: ColumnWidth.of(value) },
      { from: right, add: ColumnWidth.of(total - value) }
    ],
    userEvent: 'column.resize'
  }
}

function content(units: readonly Pos.Node[]): Node[] {
  const nodes = blockContent(units)
  return isList(units[0]!.parent!.node) && nodes.every(node => node.type === units[0]!.node.type)
    ? [units[0]!.parent!.node.tag.create(nodes)]
    : nodes
}

function putRow(state: GardState, target: Pos.Node, row: Plot, selectedColumn: number): Transaction.Spec {
  const selection =
    (at: number): Transaction.Spec['selection'] =>
    cx => {
      const column = row.content[selectedColumn]!
      const before = at + 2 + row.content.slice(0, selectedColumn).reduce((n, col) => n + col.length, 0)
      return BlockSelection.between(
        cx.doc,
        before,
        before + column.length - 2 - (column.isPlot ? column.lastChild!.length : 0)
      )!
    }
  const range = blockRemovalRange([target])
  if (state.schema.canContain(state.doc.resolve(range.from).parent.node.type, row.type)) {
    return { changes: { ...range, insert: [row] }, selection: selection(range.from) }
  }
  const removed = state.update({ changes: { correct: { ...range, fit: true }, local: true } })
  return compose(state, { changes: removed.changes }, next => {
    const insertion = splitInsert(next.doc, removed.changes.mapPos(target.before, -1), [row], false)
    return { changes: insertion.changes, selection: selection(insertion.at) }
  })
}

/** The insertion menu puts the current block in the first column and focuses its text. */
export function columnInsertion(state: GardState, count: number): Transaction.Spec | null {
  const target = unitAt(state.doc, state.selection.head, state.selection.headSide)
  if (!target || state.readOnly) return null
  const columns = [Column.create(content([target]))]
  for (let i = 1; i < count; i++) columns.push(Column.create([T.Paragraph.create([])]))
  return {
    ...compose(state, putRow(state, target, Columns.create(columns), 0), next => ({
      selection: GardSelection.near(next, next.selection.from + 1, 1)
    })),
    userEvent: 'block.insert'
  }
}

/** Drop complete blocks beside a target, creating a row or adding to its containing row. */
export function columnDrop(
  state: GardState,
  positions: readonly number[],
  targetPos: number,
  side: -1 | 1
): Transaction.Spec | null {
  if (state.readOnly || !positions.length) return null
  const first = targetAt(state.doc, positions[0]!)
  const last = targetAt(state.doc, positions.at(-1)!)
  if (
    !first ||
    !last ||
    positions.some(pos => {
      const unit = targetAt(state.doc, pos)
      return unit && targetPos >= unit.before && targetPos < unit.after
    })
  ) {
    return null
  }
  const units = positions.map(pos => targetAt(state.doc, pos))
  if (units.some((unit, index) => !unit || (index > 0 && unit.before < units[index - 1]!.after))) return null
  if (!targetAt(state.doc, targetPos)) return null
  const nodes = content(units as Pos.Node[])
  const removed = state.update({
    changes: { correct: blockRemovalRanges(units as Pos.Node[]).map(range => ({ ...range, fit: true })), local: true }
  })
  const target = targetAt(removed.state.doc, removed.changes.mapPos(targetPos, 1))
  if (!target) return null
  return {
    ...compose(state, { changes: removed.changes }, next => {
      let column = target.parent
      while (column?.parent && column.node.type !== Column.type) column = column.parent
      if (column?.node.type === Column.type) {
        const at = side < 0 ? column.before : column.after
        return {
          changes: { from: at, insert: [Column.create(nodes)] },
          selection: cx =>
            BlockSelection.between(cx.doc, at + 1, at + 1 + nodes.slice(0, -1).reduce((n, node) => n + node.length, 0))!
        }
      }
      const columns = [Column.create(content([target])), Column.create(nodes)]
      if (side < 0) columns.reverse()
      return putRow(next, target, Columns.create(columns), side < 0 ? 0 : 1)
    }),
    userEvent: 'block.move'
  }
}
