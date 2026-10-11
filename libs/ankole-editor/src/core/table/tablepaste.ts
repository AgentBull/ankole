import { Plot, Node, Slice, Token, Schema, ChangeSet } from '../doc'
import { Table, TableRow, RowSpan, ColSpan } from '../types'
import { GardState, Transaction } from '../state'
import { Wordgard } from '../editor'

import { TableMap } from './tablemap'
import { CellSelection } from './cellselection'
import { tableContext, cellTag } from './tablecommands'

function fitSlice(schema: Schema, parent: Plot.Tag, slice: Slice, context: readonly Plot.Tag[]) {
  const wrap = schema.findWrapping(schema.docTag.type, parent.type)
  if (!wrap) return null
  let content = [schema.createAndFill(parent)]
  for (let i = wrap.length - 1; i >= 0; i--) content = [wrap[i]!.create(content)]
  let doc = schema.doc(content)
  const changes = ChangeSet.create(doc, {
    from: wrap.length + 1,
    to: doc.length - wrap.length - 1,
    insert: slice,
    fit: context
  })
  doc = changes.apply(doc)
  const node = doc.length > wrap.length && doc.plotAt(wrap.length)
  return node && node.type == parent.type ? node : null
}

function isTableContent(schema: Schema, type: Node.Type) {
  return type == TableRow.type || schema.matchNode(type, Node.Group.TableCell)
}

// Get a rectangular area of cells from a slice, or null if the outer
// nodes of the slice aren't table cells or rows.
function pastedCells(schema: Schema, slice: Slice, context: readonly Plot.Tag[]) {
  let table: Plot | null = null
  const only = slice.content.length == 1 ? slice.content[0]! : null
  if (only && only.tokenType == Token.Type.Node && only.type == Table.type) {
    table = only as Plot
  } else if (
    context.some(tag => isTableContent(schema, tag.type)) ||
    slice.content.some(tok => tok.tokenType != Token.Type.Close && isTableContent(schema, tok.type))
  ) {
    table = fitSlice(schema, Table, slice, context)
  }
  return (
    table &&
    ensureRectangular(
      schema,
      table.content.map(row => (row as Plot).content)
    )
  )
}

// Compute the width and height of a set of cells, and make sure each
// row has the same number of cells.
function ensureRectangular(schema: Schema, rows: (readonly Node[])[]) {
  const widths: number[] = []
  for (let i = 0; i < rows.length; i++) {
    for (const cell of rows[i]!) {
      const rowSpan = cell.mark(RowSpan) ?? 1,
        colSpan = cell.mark(ColSpan) ?? 1
      for (let r = i; r < i + rowSpan; r++) widths[r] = (widths[r] || 0) + colSpan
    }
  }
  const width = widths.reduce((a, b) => Math.max(a, b))
  for (let r = 0; r < widths.length; r++) {
    if (r >= rows.length) rows[r] = []
    for (let i = widths[r]!; i < width; i++) rows[r] = rows[r]!.concat(schema.createAndFill(cellTag(schema)))
  }
  return { height: rows.length, width, rows }
}

// Clip or extend (repeat) the given set of cells to cover the given
// width and height. Will clip rowspan/colspan cells at the edges when
// they stick out.
function clipCells(
  { width, height, rows }: { width: number; height: number; rows: (readonly Node[])[] },
  newWidth: number,
  newHeight: number
) {
  if (width != newWidth) {
    const added = new Map<number, number>()
    rows = rows.map((row, i) => {
      const cells: Node[] = []
      let size = added.get(i) ?? 0
      let j = 0
      while (size < newWidth) {
        let nextCell = row[j++ % row.length]
        const rowSpan = nextCell!.mark(RowSpan) ?? 1
        let colSpan = nextCell!.mark(ColSpan) ?? 1
        if (size + colSpan > newWidth) {
          colSpan = newWidth - size
          nextCell = nextCell!.withMarks(
            colSpan == 1 ? ColSpan.removeFromSet(nextCell!.marks) : ColSpan.of(colSpan).addToSet(nextCell!.marks)
          )
        }
        for (let k = 1; k < rowSpan; k++) added.set(i + k, (added.get(i + k) ?? 0) + colSpan)
        size += colSpan
        cells.push(nextCell!)
      }
      return cells
    })
  }
  if (height != newHeight) {
    const newRows: (readonly Node[])[] = []
    for (let i = 0; i < newHeight; i++) {
      const nextRow = rows[i % rows.length]!,
        space = newHeight - i
      newRows.push(
        nextRow.map(cell => {
          const rowSpan = cell.mark(RowSpan) ?? 1
          return rowSpan <= space
            ? cell
            : cell.withMarks(space == 1 ? RowSpan.removeFromSet(cell.marks) : RowSpan.of(space).addToSet(cell.marks))
        })
      )
    }
    rows = newRows
  }

  return { height: newHeight, width: newWidth, rows }
}

// Generate changes that extend a table to have at least the given
// width and height.
function growTableHorizontally(schema: Schema, map: TableMap, width: number) {
  const changes: ChangeSet.Spec[] = []
  if (width > map.width) {
    for (let row = 0; row < map.height; row++) {
      const lastCell = (map.table.content[row] as Plot).lastChild
      const fillCell = schema.createAndFill((lastCell || cellTag(schema)).type.default!),
        cells = []
      for (let i = map.width; i < width; i++) cells.push(fillCell)
      changes.push({ from: map.cellInsertionPos(map.width, row), insert: cells })
    }
  }
  return changes
}

function growTableVertically(schema: Schema, map: TableMap, height: number) {
  const changes: ChangeSet.Spec[] = []
  if (height > map.height) {
    const cells: Node[] = []
    for (let i = 0; i < map.width; i++) cells.push(schema.createAndFill(cellTag(schema)))
    const row = TableRow.create(cells),
      rows = []
    for (let i = map.height; i < height; i++) rows.push(row)
    changes.push({ from: map.rowPos(map.height), insert: rows })
  }
  return changes
}

// Make sure the given line doesn't cross any rowspan cells by
// splitting cells that cross it. Return true if something changed.
function isolateVertically(schema: Schema, map: TableMap, startCol: number, endCol: number, row: number) {
  const changes: ChangeSet.Spec[] = []
  if (row == 0 || row == map.height) return changes
  for (let col = startCol; col < endCol;) {
    const pos = map.cellAt(col, row)
    if (pos != null && map.cellAt(col, row - 1) == pos) {
      const node = map.getCell(pos),
        rect = map.cellRect(pos)
      const topRows = row - rect.startRow,
        botRows = rect.endRow - row
      changes.push(
        topRows == 1 ? { from: pos, remove: RowSpan.isInSet(node.marks)! } : { from: pos, add: RowSpan.of(topRows) }
      )
      const split = node.tag.withMarks(
        botRows == 1 ? RowSpan.removeFromSet(node.marks) : RowSpan.of(botRows).addToSet(node.marks)
      )
      changes.push({ from: map.cellInsertionPos(rect.startCol, row), insert: [schema.createAndFill(split)] })
      col = rect.endCol
    } else {
      col++
    }
  }
  return changes
}

// Make sure the given line doesn't cross any colspan cells by
// splitting cells that cross it.
function isolateHorizontally(schema: Schema, map: TableMap, startRow: number, endRow: number, col: number) {
  const changes: ChangeSet.Spec[] = []
  if (col == 0 || col == map.width) return changes
  for (let row = startRow; row < endRow;) {
    const pos = map.cellAt(col, row)
    if (pos != null && map.cellAt(col - 1, row) == pos) {
      const node = map.getCell(pos),
        rect = map.cellRect(pos)
      const topCols = col - rect.startCol,
        botCols = rect.endCol - col
      changes.push(
        topCols == 1 ? { from: pos, remove: ColSpan.isInSet(node.marks)! } : { from: pos, add: ColSpan.of(topCols) }
      )
      const split = node.tag.withMarks(
        botCols == 1 ? ColSpan.removeFromSet(node.marks) : ColSpan.of(botCols).addToSet(node.marks)
      )
      changes.push({ from: map.cellInsertionPos(col, row), insert: [schema.createAndFill(split)] })
      row = rect.endRow
    } else {
      row++
    }
  }
  return changes
}

// Insert the given set of cells (as returned by `pastedCells`) into a
// table, at the position pointed at by rect.
export function insertCells(
  state: GardState,
  map: TableMap,
  startCol: number,
  startRow: number,
  cells: { width: number; height: number; rows: (readonly Node[])[] },
  event: string
): Transaction.Spec {
  const { schema } = state.doc
  const endCol = startCol + cells.width,
    endRow = startRow + cells.height
  let doc = state.doc,
    changeSet: ChangeSet | null = null,
    changes: ChangeSet.Spec[] = []
  function flush() {
    if (changes.length) {
      const newSet = ChangeSet.create(doc, changes)
      doc = newSet.apply(doc)
      changeSet = changeSet ? changeSet.compose(newSet) : newSet
      const table = doc.resolvePlot(map.tablePos)!
      map = TableMap.get(table.node, table.start)
      changes = []
    }
  }

  // Prepare the table to be large enough and not have any cells
  // crossing the boundaries of the rectangle that we want to
  // insert into. Recompute our table map every time something changed.
  if (map.width < endCol) changes = growTableHorizontally(schema, map, endCol)
  else if (endCol < map.width) changes = isolateHorizontally(schema, map, startRow, endRow, endCol)
  flush()
  if (startCol) changes = isolateHorizontally(schema, map, startRow, endRow, startCol)
  flush()
  if (map.height < endRow) changes = growTableVertically(schema, map, endRow)
  else if (endRow < map.height) changes = isolateVertically(schema, map, startCol, endCol, endRow)
  flush()
  if (startRow) changes = isolateVertically(schema, map, startCol, endCol, startRow)
  flush()

  for (let i = 0; i < cells.height; i++) {
    const content = cells.rows[i],
      row = startRow + i
    changes.push({ from: map.cellInsertionPos(startCol, row), to: map.cellInsertionPos(endCol, row), insert: content })
  }
  flush()
  const startCell = map.cellAt(startCol, startRow)
  const endCell = map.cellAt(endCol - 1, endRow - 1)
  const selection =
    startCell == null || endCell == null
      ? undefined
      : CellSelection.between(doc, startCell, endCell + map.getCell(endCell).length)!
  return {
    changes: changeSet!,
    selection,
    userEvent: `${event}.paste`
  }
}

/** @hidden exported for testing */
export function handleTablePaste(state: GardState, slice: Slice, context: readonly Plot.Tag[], drop?: number) {
  if (state.readOnly) return false
  const { schema } = state.doc
  if (drop == null && state.selection instanceof CellSelection) {
    let cells = pastedCells(schema, slice, context)
    if (!cells) {
      const single = fitSlice(schema, cellTag(schema), slice, context)
      if (!single) return false
      cells = { width: 1, height: 1, rows: [[single]] }
    }
    const table = state.sel.from.parent!.parent!,
      map = TableMap.get(table.node, table.start)
    const rect = map.rectBetween(state.selection.anchorCell, state.selection.headCell)
    return insertCells(
      state,
      map,
      rect.startCol,
      rect.startRow,
      clipCells(cells, rect.endCol - rect.startCol, rect.endRow - rect.startRow),
      'paste'
    )
  } else {
    const cx = tableContext(state, drop)
    const cells = cx && pastedCells(schema, slice, context)
    if (!cx || !cells) return false
    const rect = cx.map.cellRect(cx.cells[0]!)
    return insertCells(state, cx.map, rect.startCol, rect.startRow, cells, drop == null ? 'drop' : 'paste')
  }
}

export const tablePasteHandler = Wordgard.pasteHandler.of((wg, _event, slice, context) => {
  const tr = handleTablePaste(wg.state, slice, context)
  return tr && (wg.dispatch(tr), true)
})

export const tableDropHandler = Wordgard.dropHandler.of((wg, _event, pos, move, slice, context) => {
  if (wg.state.readOnly) return false
  const tr = handleTablePaste(wg.state, slice, context, pos)
  if (!tr) return false
  if (move) {
    const clear: ChangeSet.Spec[] = []
    wg.state.doc.iterate(move.from, move.to, (node, pos) => {
      if (wg.state.schema.matchNode(node.type, Node.Group.TableCell)) {
        clear.push({ from: pos + 1, to: pos + node.length - 1, fit: true })
      }
    })
    const tr2 = wg.state.update(Transaction.merge(wg.state, tr, { changes: clear }))
    wg.dispatch(tr2)
  } else {
    wg.dispatch(tr)
  }
  return true
})
