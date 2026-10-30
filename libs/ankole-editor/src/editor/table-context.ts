import { Node, type Plot, type Pos } from '../core/doc'
import { GardSelection, type GardState } from '../core/state'
import { CellSelection } from '../core/table'
import { TableMap } from '../core/table/tablemap'
import { Rect } from '../core/table/tablemap'
import * as T from '../core/types'
import { DataCell, HeaderCell, Table, TableWidths } from './schema'

export type TableScope = 'cell' | 'row' | 'column' | 'table'

export function headCell(state: GardState): Pos.Plot | null {
  const head =
    state.selection instanceof CellSelection ? state.doc.resolve(state.selection.headCell + 1) : state.sel.head
  return head.matchingParent(plot => state.schema.matchNode(plot.type, Node.Group.TableCell))
}

/** Logical coordinates come from the core map, including cells spanning several rows or columns. */
export function editableTable(state: GardState) {
  if (state.readOnly) return null
  const cell = headCell(state)
  const selected = state.doc.resolveNode(state.selection.from)
  const table =
    cell?.parent?.parent ?? (selected?.node.type === Table.type ? state.doc.resolve(selected.before + 1).parent : null)
  if (!table) return null
  const map = TableMap.get(table.node, table.start)
  if (!map.width || !map.height) return null
  const selection = state.selection
  let rect = cell
    ? selection instanceof CellSelection
      ? map.rectBetween(selection.anchorCell, selection.headCell)
      : map.cellRect(cell.before)
    : new Rect(0, 0, map.width, map.height)
  // A rectangle touching a merged cell owns the entire cell.
  for (;;) {
    let { startCol, startRow, endCol, endRow } = rect
    for (let r = startRow; r < endRow; r++) {
      for (let c = startCol; c < endCol; c++) {
        const pos = map.cellAt(c, r)
        if (pos === null) continue
        const box = map.cellRect(pos)
        startCol = Math.min(startCol, box.startCol)
        startRow = Math.min(startRow, box.startRow)
        endCol = Math.max(endCol, box.endCol)
        endRow = Math.max(endRow, box.endRow)
      }
    }
    if (startCol === rect.startCol && startRow === rect.startRow && endCol === rect.endCol && endRow === rect.endRow) {
      break
    }
    rect = new Rect(startCol, startRow, endCol, endRow)
  }
  return {
    cell,
    table,
    map,
    rect,
    rows: table.node.content as readonly Plot[],
    width: map.width,
    row: rect.startRow,
    column: rect.startCol
  }
}

export type TableContext = NonNullable<ReturnType<typeof editableTable>>

export function scopeRect({ map, rect }: TableContext, scope: TableScope): Rect {
  return new Rect(
    scope === 'row' || scope === 'table' ? 0 : rect.startCol,
    scope === 'column' || scope === 'table' ? 0 : rect.startRow,
    scope === 'row' || scope === 'table' ? map.width : rect.endCol,
    scope === 'column' || scope === 'table' ? map.height : rect.endRow
  )
}

export function cellsIn(map: TableMap, rect: Rect): number[] {
  const cells = new Set<number>()
  for (let r = rect.startRow; r < rect.endRow; r++) {
    for (let c = rect.startCol; c < rect.endCol; c++) {
      const pos = map.cellAt(c, r)
      if (pos !== null) cells.add(pos)
    }
  }
  return [...cells].sort((a, b) => a - b)
}

export function tableSelection(doc: Plot.Doc, map: TableMap, rect: Rect): GardSelection {
  const cells = cellsIn(map, rect)
  return cells.length
    ? CellSelection.between(doc, cells[0]!, map.cellEnd(cells.at(-1)!))!
    : GardSelection.cursor(map.start)
}

export const isHeader = (node: Plot) => node.type === HeaderCell.type
export const emptyCell = (header = false) => (header ? HeaderCell : DataCell).create([T.Paragraph.create([])])

export function columnWidths(context: Pick<TableContext, 'table' | 'width'>, available = 480): number[] {
  const saved = context.table.node.mark(TableWidths)?.split(',').map(Number) ?? []
  return Array.from(
    { length: context.width },
    (_, i) => saved[i] ?? Math.max(80, Math.round(available / context.width))
  )
}
