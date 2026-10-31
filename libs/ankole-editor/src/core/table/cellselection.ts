import { GardState, GardSelection, Transaction } from '../state'
import { Decoration, Wordgard } from '../editor'
import { Node, Plot, Pos, Slice, ChangeSet, ValidationError, Leaf } from '../doc'
import { Command, insertText, moveByUnit, moveByLine, moveByWord, moveToLineSide } from '../command'

import { TableMap } from './tablemap'

const cellSelectionDeco = GardState.Field.define<Decoration.Point.Set>({
  create: getCellDeco,
  update: (deco, tr) => {
    return tr.docChanged || tr.selection ? getCellDeco(tr.state) : deco
  },
  provide: f => Decoration.Point.source.of(s => s.field(f))
})

const selectedCell = Decoration.Point.attributes({ class: 'wg-selected-cell' })

function getCellDeco(state: GardState): Decoration.Point.Set {
  if (!(state.selection instanceof CellSelection)) return Decoration.Point.none
  return Decoration.Point.set(state.selection.ranges.map(({ from }) => [selectedCell, from - 1]))
}

const tableSelectionFilter = GardState.prec.low(
  Transaction.extender.of(tr => {
    const normalized = CellSelection.normalize(tr.newSelection, tr.newDoc)
    return normalized ? { selection: normalized } : null
  })
)

type Dir = 'left' | 'right' | 'forward' | 'backward' | 'up' | 'down'

function resolveDir(dir: 'left' | 'right', state: GardState): 'forward' | 'backward' {
  const block = state.sel.head.textblockParent
  return (dir == 'right') == (block ? state.textblockLTR(block.node) : state.textLTR) ? 'forward' : 'backward'
}

function cursorCommand(wg: Wordgard, { dir, extend }: { dir: Dir; extend?: boolean }) {
  const { state } = wg,
    { selection } = state
  if (!(selection instanceof CellSelection)) return false
  let newSel
  if (!extend) {
    newSel = GardSelection.near(state, selection.replacementRange!.from, 1)
  } else {
    if (dir == 'left' || dir == 'right') dir = resolveDir(dir, state)
    newSel = selection.moveHead(state.doc, dir)
    if (!newSel) {
      const forward = dir == 'forward' || dir == 'down'
      const table = state.sel.from.parent!.parent!
      const next = GardSelection.near(state, forward ? table.after : table.before, forward ? 1 : -1)
      newSel = GardSelection.range(forward ? table.before : table.after, next.head, next.headSide)
    }
  }
  wg.dispatch({
    selection: newSel,
    scrollIntoView: true,
    userEvent: 'select'
  })
  return true
}

function moveToRowSide(wg: Wordgard, { dir }: { dir: 'left' | 'right' | 'forward' | 'backward'; extend?: boolean }) {
  const { state } = wg
  let { selection } = state
  if (!(selection instanceof CellSelection)) return false
  if (dir == 'left' || dir == 'right') dir = resolveDir(dir, state)
  for (;;) {
    const next: CellSelection | null = (selection as CellSelection).moveHead(state.doc, dir)
    if (!next) break
    selection = next
  }
  if (selection != state.selection) {
    wg.dispatch({
      selection,
      scrollIntoView: true,
      userEvent: 'select'
    })
  }
  return true
}

// Typing, pasting, or composing over selected cells puts the input in the first cell (the
// replacement range) and empties the other cells, so that the table keeps its rows and columns.
function replaceCells(selection: CellSelection, insert: Slice | readonly Leaf[], userEvent: string): Transaction.Spec {
  const first = selection.replacementRange
  return {
    changes: {
      correct: selection.ranges.map((range, index) => ({ ...range, insert: index ? [] : insert, fit: true })),
      local: true
    },
    selection: (cx, changes) => GardSelection.near(cx, changes.mapPos(first.to, 1), -1),
    scrollIntoView: true,
    userEvent
  }
}

const cellSelectionInput: GardState.Extension = [
  Command.handler(insertText, ({ state }, input) =>
    state.selection instanceof CellSelection && !state.readOnly
      ? replaceCells(state.selection, input.insert ? [Leaf.text(input.insert)] : [], input.userEvent)
      : false
  ),
  Wordgard.pasteHandler.of((wg, _event, slice) => {
    const { selection } = wg.state
    if (!(selection instanceof CellSelection) || wg.state.readOnly) return false
    wg.dispatch(replaceCells(selection, slice, 'input.paste'))
    return true
  }),
  // Runs before the core composition observer, so that the composition starts in the emptied
  // first cell with the caret at its end.
  Wordgard.domEventObserver('compositionstart', (_event, wg) => {
    const { selection } = wg.state
    if (selection instanceof CellSelection && !wg.state.readOnly) {
      wg.dispatch(replaceCells(selection, [], 'input.type.compose.start'))
    }
  })
]

const cellSelectionTripleClick = Wordgard.mouseSelectionStyle.of((wg, event) => {
  if (event.detail == 3) {
    const pos = wg.state.doc.resolve(wg.posAtCoords({ x: event.clientX, y: event.clientY }).pos)
    const cell = pos.matchingParent(n => wg.state.schema.matchNode(n.type, Node.Group.TableCell))
    if (cell) {
      let from = cell.before,
        to = cell.after
      return {
        get() {
          return CellSelection.between(wg.state.doc, from, to) || GardSelection.near(wg.state, from, 1)
        },
        update(update) {
          from = update.changes.mapPos(from, 1)
          to = Math.max(from, update.changes.mapPos(to, -1))
        }
      }
    }
  }
  return null
})

/**
 * A cell selection is a custom selection type that, instead of
 * spanning the range between two document positions, spans the
 * rectangle between two cells in the same table. It comes with
 * extensions that make sure it is drawn in a recognizeable way,
 * automatically created when a selection crosses cell boundaries,
 * and adjusted appropriately in response to keyboard and mouse
 * actions.
 */
export class CellSelection extends GardSelection {
  private constructor(
    anchor: number,
    head: number,
    /**
     * The position directly in front of the cell that acts as this
     * selection's anchor.
     */
    readonly anchorCell: number,
    /**
     * The position directly in front of the cell acting as the
     * selection head.
     */
    readonly headCell: number,
    /** @internal */
    readonly _ranges: readonly { from: number; to: number }[]
  ) {
    super(anchor, head)
  }

  get ranges() {
    return this._ranges
  }

  // The first cell, as for a block selection: the DOM selection, typing, pasting, and composing use it.
  get replacementRange() {
    return this._ranges[0]!
  }

  get domSelection() {
    const { from, to } = this.replacementRange
    return { anchor: from, anchorSide: 1, head: to, headSide: -1 } as const
  }

  toSlice(doc: Plot.Doc) {
    const base = doc.resolve(this.anchorCell),
      table = base.parent!.parent!
    const map = TableMap.get(table.node, table.start)
    const rect = map.rectBetween(this.anchorCell, this.headCell)
    const rows: Plot[] = []
    const added = new Set<number>()
    for (let row = rect.startRow; row < rect.endRow; row++) {
      const rowContent: Plot[] = []
      for (let col = rect.startCol; col < rect.endCol; col++) {
        const cell = map.cellAt(col, row)
        if (cell == null || added.has(cell)) continue
        added.add(cell)
        rowContent.push(map.getCell(cell))
      }
      rows.push((table.node.content[row] as Plot).tag.create(rowContent))
    }
    return Slice.of(rows, [table.node.tag])
  }

  eq(other: GardSelection) {
    return other instanceof CellSelection && other.anchor == this.anchor && other.head == this.head
  }

  map(changes: ChangeSet, cx: GardSelection.Context, assoc: -1 | 1 = -1) {
    let fromPos = changes.mapPos(this.from, 1),
      toPos = changes.mapPos(this.to, -1)
    const from = cx.doc.resolve(fromPos),
      to = cx.doc.resolve(toPos)
    const after = from.nodeAfter,
      before = to.nodeBefore
    if (after && after.type.hasRole(Node.Role.Table)) fromPos += 2
    else if (after && after.type.hasRole(Node.Role.TableRow)) fromPos++
    if (before && before.type.hasRole(Node.Role.Table)) toPos -= 2
    else if (before && before.type.hasRole(Node.Role.TableRow)) toPos--
    return (
      (this.from == this.anchor
        ? CellSelection.between(cx.doc, fromPos, toPos)
        : CellSelection.between(cx.doc, toPos, fromPos)) || GardSelection.near(cx, changes.mapPos(this.head), assoc)
    )
  }

  /**
   * Move the head cell in the given direction, returning a new cell
   * selection if the selection can be extended that way.
   */
  moveHead(doc: Plot.Doc, dir: 'up' | 'down' | 'forward' | 'backward'): CellSelection | null {
    const head = doc.resolve(this.head),
      inv = this.head < this.anchor
    const headPos = this.head - (inv ? 0 : head.nodeBefore!.length)
    const table = head.parent!.parent!,
      map = TableMap.get(table.node, table.start),
      rect = map.cellRect(headPos)
    const anchorPos = inv ? map.nearestCell(this.anchor, -1)!.from : this.anchor
    const col = dir == 'backward' ? rect.startCol - 1 : dir == 'forward' ? rect.endCol : rect.startCol
    const row = dir == 'up' ? rect.startRow - 1 : dir == 'down' ? rect.endRow : rect.startRow
    if (col < 0 || col >= map.width || row < 0 || row >= map.height) return null
    const newHead = map.cellAt(col, row)
    if (newHead == null) return null
    return newHead >= anchorPos
      ? CellSelection.between(doc, anchorPos, map.cellEnd(newHead))
      : CellSelection.between(doc, newHead, map.cellEnd(anchorPos))
  }

  /**
   * Create a table selection between the given points. They should
   * point before and after the first and last cell of the selection
   * (`anchor` may be before or after `head`, as long as the lower
   * sits before a cell and the higher after a cell). Returns `null`
   * if the given range does not wrap a range of cells in a single
   * table.
   */
  static between(doc: Plot.Doc, anchor: number, head: number) {
    const from = doc.resolve(Math.min(anchor, head)),
      to = doc.resolve(Math.max(anchor, head))
    const fromCell = from.nodeAfter,
      toCell = to.nodeBefore,
      table = from.parent?.parent
    if (
      anchor == head ||
      !fromCell ||
      !doc.schema.matchNode(fromCell.type, Node.Group.TableCell) ||
      !toCell ||
      !doc.schema.matchNode(toCell.type, Node.Group.TableCell) ||
      !table ||
      table.start > to.pos ||
      table.end < to.pos
    ) {
      return null
    }
    const toPos = to.pos - toCell.length
    const map = TableMap.get(table.node, table.start)
    const cells = map.cellsInRect(map.rectBetween(from.pos, toPos))
    let anchorCell = anchor,
      headCell = head
    if (anchor > head) anchorCell -= toCell.length
    else headCell -= toCell.length
    return new CellSelection(
      anchor,
      head,
      anchorCell,
      headCell,
      cells.map(pos => ({ from: pos + 1, to: map.cellEnd(pos) - 1 }))
    )
  }

  /**
   * Given a selection, this returns null if that selection is valid
   * (is a cell selection, or a selection that starts and ends outside
   * of tables, or in the same table cell). Otherwise, it will expand a
   * selection within a single table to a cell selection, or expand a
   * selection that crosses table boundaries to cover the entire table(s).
   */
  static normalize(sel: GardSelection, doc: Plot.Doc): GardSelection | null {
    if (sel instanceof CellSelection) return null
    let { from, to } = sel,
      modified = false
    for (
      let parent: Pos.Plot | null = doc.resolve(sel.from).parent, cell: Pos.Plot | null = null;
      parent;
      parent = parent.parent
    ) {
      if (doc.schema.matchNode(parent.node.type, Node.Group.TableCell)) cell = parent
      if (parent.node.type.hasRole(Node.Role.Table)) {
        if (to > parent.end) {
          // Move out of a partially covered table
          from = parent.before
          modified = true
        } else if (!cell || to > cell.end) {
          // A schema can allow a cursor in an empty row or table. It
          // stays a cursor.
          if (sel.empty && !doc.resolve(from).parent.node.content.length) return null
          // Inside this table, but not in same cell
          const map = TableMap.get(parent.node, parent.start)
          const start = map.nearestCell(from, 1)
          let end = map.nearestCell(to, -1)
          if (!start || !end) return null
          if (start.from > end.from) end = start
          return sel.anchor < sel.head
            ? CellSelection.between(doc, start.from, end.to)!
            : CellSelection.between(doc, end.to, start.from)!
        }
      }
    }
    for (let parent: Pos.Plot | null = doc.resolve(sel.to).parent; parent; parent = parent.parent) {
      if (parent.node.type.hasRole(Node.Role.Table) && from < parent.start) {
        to = parent.after
        modified = true
      }
    }
    return !modified ? null : sel.anchor < sel.head ? GardSelection.range(from, to) : GardSelection.range(to, from)
  }

  /** This object can be used as an extension to enable cell selection. */
  static extension: GardState.Extension = [
    GardSelection.define<CellSelection, { anchor: number; head: number }>(
      'cell',
      CellSelection as any,
      sel => ({ anchor: sel.anchor, head: sel.head }),
      (doc, json) => {
        if (!json || typeof json.anchor != 'number' || typeof json.head != 'number') {
          throw new ValidationError('Invalid JSON data for CellSelection')
        }
        const sel = CellSelection.between(doc, json.anchor, json.head)
        if (!sel) throw new ValidationError("Cell selection from JSON doesn't span actual cells")
        return sel
      }
    ),
    cellSelectionDeco,
    tableSelectionFilter,
    Command.handler(moveByUnit, cursorCommand),
    Command.handler(moveByWord, cursorCommand),
    Command.handler(moveByLine, cursorCommand),
    Command.handler(moveToLineSide, moveToRowSide),
    cellSelectionInput,
    cellSelectionTripleClick
  ]
}
