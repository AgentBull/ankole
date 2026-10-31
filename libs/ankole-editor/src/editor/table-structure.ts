import { type ChangeSet, type Plot } from '../core/doc'
import * as T from '../core/types'
import { Rect, type TableMap } from '../core/table/tablemap'
import { markChange } from './attributes'
import { Align, HeaderCell, TableRow, TableWidths } from './schema'
import { cellsIn, columnWidths, emptyCell, isHeader, type TableContext } from './table-context'

export type StructureAction =
  | 'row_before'
  | 'row_after'
  | 'column_before'
  | 'column_after'
  | 'delete_row'
  | 'delete_column'
  | 'merge'
  | 'split'
export type TableEdit = { changes: ChangeSet.Spec[]; row: number; column: number }

/** Fill only absent cells. Existing content, marks and collaboration positions stay intact. */
export function padTable({ map }: TableContext): ChangeSet.Spec[] {
  const changes: ChangeSet.Spec[] = []
  for (let r = 0; r < map.height; r++) {
    for (let c = 0; c < map.width; c++) {
      if (map.cellAt(c, r) !== null) continue
      const rowCells = map.cellsInRect(new Rect(0, r, map.width, r + 1))
      const header = rowCells.length > 0 && rowCells.every(pos => isHeader(map.getCell(pos)))
      const sample = cellsIn(map, new Rect(c, 0, c + 1, map.height))
        .map(pos => map.getCell(pos).mark(Align))
        .find(Boolean)
      const cell = emptyCell(header)
      changes.push({
        from: map.cellInsertionPos(c, r),
        insert: [sample ? cell.withMarks(Align.of(sample).addToSet(cell.marks)) : cell]
      })
    }
  }
  return changes
}

function span(changes: ChangeSet.Spec[], map: TableContext['map'], pos: number, axis: 'row' | 'column', value: number) {
  const change = markChange(map.getCell(pos), pos, axis === 'row' ? T.RowSpan : T.ColSpan, value > 1 ? value : null)
  if (change) changes.push(change)
}

export function insertAxis(context: TableContext, axis: 'row' | 'column', at: number): TableEdit {
  const { map } = context
  const changes: ChangeSet.Spec[] = []
  const visited = new Set<number>()
  const inserted: Plot[] = []
  const count = axis === 'row' ? map.width : map.height
  for (let i = 0; i < count; i++) {
    const pos = at > 0 ? map.cellAt(axis === 'row' ? i : at - 1, axis === 'row' ? at - 1 : i) : null
    const rect = pos === null ? null : map.cellRect(pos)
    const end = rect ? (axis === 'row' ? rect.endRow : rect.endCol) : 0
    if (pos !== null && end > at) {
      if (!visited.has(pos)) {
        visited.add(pos)
        span(changes, map, pos, axis, end - (axis === 'row' ? rect!.startRow : rect!.startCol) + 1)
      }
      continue
    }
    const sample =
      axis === 'row'
        ? cellsIn(map, new Rect(i, 0, i + 1, map.height))
            .map(p => map.getCell(p).mark(Align))
            .find(Boolean)
        : undefined
    const header =
      axis === 'column' && cellsIn(map, new Rect(0, i, map.width, i + 1)).every(p => isHeader(map.getCell(p)))
    const cell = emptyCell(header)
    const next = sample ? cell.withMarks(Align.of(sample).addToSet(cell.marks)) : cell
    if (axis === 'row') inserted.push(next)
    else changes.push({ from: map.cellInsertionPos(at, i), insert: [next] })
  }
  if (axis === 'row') changes.push({ from: map.rowPos(at), insert: [TableRow.create(inserted)] })
  else if (context.table.node.mark(TableWidths)) {
    const widths = columnWidths(context)
    widths.splice(at, 0, widths[Math.max(0, at - 1)]!)
    changes.push({ from: context.table.before, add: TableWidths.of(widths.join(',')) })
  }
  return { changes, row: axis === 'row' ? at : context.row, column: axis === 'column' ? at : context.column }
}

export function deleteAxis(context: TableContext, axis: 'row' | 'column'): TableEdit {
  const { map, rect } = context
  const start = axis === 'row' ? rect.startRow : rect.startCol
  const end = axis === 'row' ? rect.endRow : rect.endCol
  const changes: ChangeSet.Spec[] = []
  for (const pos of cellsIn(map, new Rect(0, 0, map.width, map.height))) {
    const box = map.cellRect(pos)
    const a = axis === 'row' ? box.startRow : box.startCol
    const b = axis === 'row' ? box.endRow : box.endCol
    const overlap = Math.max(0, Math.min(b, end) - Math.max(a, start))
    if (!overlap) continue
    if (axis === 'column') {
      if (overlap === b - a) changes.push({ from: pos, to: map.cellEnd(pos) })
      else span(changes, map, pos, axis, b - a - overlap)
    } else if (a < start) {
      span(changes, map, pos, axis, b - a - overlap)
    } else if (b > end) {
      // The origin row is removed, but the lower part of this merged cell remains.
      const cell = map.getCell(pos)
      const marks = cell.marks.filter(mark => mark.type !== T.RowSpan)
      const moved = cell.tag.withMarks(b - end > 1 ? T.RowSpan.of(b - end).addToSet(marks) : marks).create(cell.content)
      changes.push({ from: map.cellInsertionPos(box.startCol, end), insert: [moved] })
    }
  }
  if (axis === 'row') changes.push({ from: map.rowPos(start), to: map.rowPos(end) })
  else if (context.table.node.mark(TableWidths)) {
    const widths = columnWidths(context)
    widths.splice(start, end - start)
    changes.push({ from: context.table.before, add: TableWidths.of(widths.join(',')) })
  }
  return {
    changes,
    row: Math.min(rect.startRow, map.height - (axis === 'row' ? end - start : 0) - 1),
    column: Math.min(rect.startCol, map.width - (axis === 'column' ? end - start : 0) - 1)
  }
}

export function mergeCells(context: TableContext): TableEdit | null {
  const { map, rect } = context
  const cells = cellsIn(map, rect)
  if (cells.length < 2 || map.cellsOverlapRectangle(rect)) return null
  const first = cells[0]!
  const changes: ChangeSet.Spec[] = []
  span(changes, map, first, 'row', rect.endRow - rect.startRow)
  span(changes, map, first, 'column', rect.endCol - rect.startCol)
  const empty = (cell: Plot) => {
    const block = cell.content[0]
    return (
      !cell.content.length ||
      (cell.content.length === 1 &&
        block?.isPlot &&
        block.type === T.Paragraph.type &&
        !block.content.length &&
        !block.marks.length)
    )
  }
  const content = cells.slice(1).flatMap(pos => (empty(map.getCell(pos)) ? [] : map.getCell(pos).content))
  if (content.length) {
    changes.push({
      from: empty(map.getCell(first)) ? first + 1 : map.cellEnd(first) - 1,
      to: map.cellEnd(first) - 1,
      insert: content
    })
  }
  for (const pos of cells.slice(1)) changes.push({ from: pos, to: map.cellEnd(pos) })
  return { changes, row: rect.startRow, column: rect.startCol }
}

export function splitCells(context: TableContext): TableEdit | null {
  const { map, rect } = context
  const changes: ChangeSet.Spec[] = []
  for (const pos of cellsIn(map, rect)) {
    const box = map.cellRect(pos)
    if (box.endRow - box.startRow === 1 && box.endCol - box.startCol === 1) continue
    const cell = map.getCell(pos)
    span(changes, map, pos, 'row', 1)
    span(changes, map, pos, 'column', 1)
    const tag = cell.tag.withMarks(cell.marks.filter(mark => mark.type !== T.RowSpan && mark.type !== T.ColSpan))
    for (let r = box.startRow; r < box.endRow; r++) {
      const count = box.endCol - box.startCol - (r === box.startRow ? 1 : 0)
      if (count) {
        changes.push({
          from: r === box.startRow ? map.cellEnd(pos) : map.cellInsertionPos(box.endCol, r),
          insert: Array.from({ length: count }, () => tag.create([T.Paragraph.create([])]))
        })
      }
    }
  }
  return changes.length ? { changes, row: rect.startRow, column: rect.startCol } : null
}

/** Every cell and its logical rectangle, in document order, from one pass over the grid. */
function cellBoxes(map: TableMap): Map<number, Rect> {
  const boxes = new Map<number, Rect>()
  for (let r = 0; r < map.height; r++) {
    for (let c = 0; c < map.width; c++) {
      const pos = map.cellAt(c, r)
      if (pos === null || boxes.has(pos)) continue
      let endCol = c + 1
      let endRow = r + 1
      while (endCol < map.width && map.cellAt(endCol, r) === pos) endCol++
      while (endRow < map.height && map.cellAt(c, endRow) === pos) endRow++
      boxes.set(pos, new Rect(c, r, endCol, endRow))
    }
  }
  return boxes
}

/** A move reorders complete span groups; no merged cell may become discontiguous. */
export function moveAxis(context: TableContext, axis: 'row' | 'column', destination: number): TableEdit | null {
  const { map, rect, rows } = context
  const start = axis === 'row' ? rect.startRow : rect.startCol
  const end = axis === 'row' ? rect.endRow : rect.endCol
  const size = axis === 'row' ? map.height : map.width
  if (destination < 0 || destination > size || (destination >= start && destination <= end)) return null
  const order = Array.from({ length: size }, (_, i) => i)
  const moved = order.splice(start, end - start)
  const target = destination > end ? destination - moved.length : destination
  order.splice(target, 0, ...moved)
  const index: number[] = []
  order.forEach((old, next) => (index[old] = next))
  const boxes = cellBoxes(map)
  for (const box of boxes.values()) {
    const a = axis === 'row' ? box.startRow : box.startCol
    const b = axis === 'row' ? box.endRow : box.endCol
    let first = size
    let last = -1
    for (let i = a; i < b; i++) {
      first = Math.min(first, index[i]!)
      last = Math.max(last, index[i]!)
    }
    if (last - first + 1 !== b - a || order[first] !== a) return null
  }
  const changes: ChangeSet.Spec[] = []
  if (axis === 'row') {
    changes.push(
      { from: map.rowPos(start), to: map.rowPos(end) },
      { from: map.rowPos(destination), insert: rows.slice(start, end) }
    )
  } else {
    const byRow = Array.from({ length: map.height }, (): number[] => [])
    for (const [pos, box] of boxes) if (box.startCol >= start && box.startCol < end) byRow[box.startRow]!.push(pos)
    for (let r = 0; r < map.height; r++) {
      const cells = byRow[r]!
      if (!cells.length) continue
      for (const pos of cells) changes.push({ from: pos, to: map.cellEnd(pos) })
      changes.push({ from: map.cellInsertionPos(destination, r), insert: cells.map(pos => map.getCell(pos)) })
    }
    if (context.table.node.mark(TableWidths)) {
      const widths = columnWidths(context)
      changes.push({ from: context.table.before, add: TableWidths.of(order.map(i => widths[i]).join(',')) })
    }
  }
  return { changes, row: axis === 'row' ? target : rect.startRow, column: axis === 'column' ? target : rect.startCol }
}

export function sortRows(context: TableContext, descending: boolean): TableEdit | null {
  const { map, rows, column } = context
  const cells = cellsIn(map, new Rect(0, 0, map.width, map.height))
  if (cells.some(pos => (map.getCell(pos).mark(T.RowSpan) ?? 1) > 1)) return null
  const first = rows[0]!.content.length > 0 && rows[0]!.content.every(cell => cell.type === HeaderCell.type) ? 1 : 0
  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' })
  const order = rows.slice(first).map((node, i) => ({ node, i: i + first }))
  order.sort((a, b) => {
    const text = (r: number) => {
      const pos = map.cellAt(column, r)
      return pos === null ? '' : map.getCell(pos).textContent()
    }
    return collator.compare(text(a.i), text(b.i)) * (descending ? -1 : 1)
  })
  let start = 0,
    end = order.length
  while (start < end && order[start]!.i === first + start) start++
  if (start === end) return null
  while (end > start && order[end - 1]!.i === first + end - 1) end--
  return {
    changes: [
      {
        from: map.rowPos(first + start),
        to: map.rowPos(first + end),
        insert: order.slice(start, end).map(item => item.node)
      }
    ],
    row: first,
    column
  }
}
