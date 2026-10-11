// Because working with row and column-spanning cells is not quite
// trivial, this code builds up a descriptive structure for a given
// table node. The structures are cached with the (persistent) table
// nodes as key, so that they only have to be recomputed when the
// content of the table changes.
//
// This does mean that they have to store table-relative, not
// document-relative positions. So code that uses them will typically
// compute the start position of the table and offset positions passed
// to or gotten from this structure by that amount.

import { Node, Plot } from '../doc'
import { ColSpan, RowSpan } from '../types'

export class Rect {
  constructor(
    readonly startCol: number,
    readonly startRow: number,
    readonly endCol: number, // Not inclusive
    readonly endRow: number
  ) {}
}

type Problem =
  | { type: 'collision'; pos: number }
  | { type: 'missing'; row: number; n: number }
  | { type: 'overlong_rowspan'; pos: number; n: number }

class MapData {
  constructor(
    readonly table: Plot,
    readonly width: number,
    readonly height: number,
    readonly map: number[],
    readonly problems: Problem[] | null,
    readonly cellEnds: Map<number, number>
  ) {}
}

const cache = new WeakMap<Plot, MapData>()

/**
 * A table map describes the structore of a given table. To avoid
 * recomputing them all the time, they are cached per table node. To
 * be able to do that, positions saved in the map are relative to the
 * start of the table, rather than the start of the document.
 */
export class TableMap {
  constructor(
    readonly start: number,
    readonly data: MapData
  ) {}

  get width() {
    return this.data.width
  }
  get height() {
    return this.data.height
  }
  get table() {
    return this.data.table
  }
  get tablePos() {
    return this.start - 1
  }

  /** Find the dimensions of the cell at the given position. */
  cellRect(pos: number) {
    const localPos = pos - this.start,
      { map, width, height } = this.data
    for (let i = 0; i < map.length; i++) {
      if (map[i] == localPos) {
        const startCol = i % width,
          startRow = (i / width) | 0
        let endCol = startCol + 1,
          endRow = startRow + 1
        for (let j = 1; endCol < width && map[i + j] == localPos; j++) endCol++
        for (let j = 1; endRow < height && map[i + width * j] == localPos; j++) endRow++
        return new Rect(startCol, startRow, endCol, endRow)
      }
    }
    throw new RangeError(`No cell with offset ${pos} found`)
  }

  /** The cell nearest to the given position. Null when the table has no cells. */
  nearestCell(pos: number, bias: -1 | 1) {
    const localPos = pos - this.start
    let after = -1
    let before = -1
    const { map, cellEnds } = this.data
    for (let i = 0; i < map.length; i++) {
      const cellPos = map[i]!
      if (cellPos > 0) {
        if (cellPos >= localPos && (after < 0 || after > cellPos)) after = cellPos!
        if (cellPos < localPos && before < cellPos) before = cellPos!
      }
    }
    if (before < 0 && after < 0) return null
    if (before > -1) {
      const beforeEnd = cellEnds.get(before)!
      if (beforeEnd > localPos || after < 0 || bias < 0) {
        return { from: before + this.start, to: beforeEnd + this.start }
      }
    }
    return { from: after + this.start, to: cellEnds.get(after)! + this.start }
  }

  cellEnd(pos: number) {
    const end = this.data.cellEnds.get(pos - this.start)
    if (end == null) throw new Error(`No cell with offset ${pos} found`)
    return end + this.start
  }

  /** Get the rectangle spanning the two given cells. */
  rectBetween(a: number, b: number) {
    const { startCol: startColA, endCol: endColA, startRow: startRowA, endRow: endRowA } = this.cellRect(a)
    const { startCol: startColB, endCol: endColB, startRow: startRowB, endRow: endRowB } = this.cellRect(b)
    return new Rect(
      Math.min(startColA, startColB),
      Math.min(startRowA, startRowB),
      Math.max(endColA, endColB),
      Math.max(endRowA, endRowB)
    )
  }

  /**
   * Return the position of all cells that have their top start
   * corner in the given rectangle.
   */
  cellsInRect(rect: Rect) {
    const result: number[] = [],
      { map, width } = this.data
    for (let row = rect.startRow; row < rect.endRow; row++) {
      for (let col = rect.startCol; col < rect.endCol; col++) {
        const index = row * width + col,
          pos = map[index]!
        if (
          pos > 0 &&
          result.indexOf(pos + this.start) < 0 &&
          (col != rect.startCol || !col || map[index - 1] != pos) &&
          (row != rect.startRow || !row || map[index - width] != pos)
        ) {
          result.push(pos + this.start)
        }
      }
    }
    return result
  }

  /**
   * Return the position of the cell that occupies the position at the
   * given row and column (which must be in bounds for the table).
   */
  cellAt(col: number, row: number) {
    const { width, map } = this.data,
      pos = map[col + row * width]
    // Rows can be shorter than the table. Their missing cells are 0.
    return pos ? pos + this.start : null
  }

  /**
   * Get the position at the start of the given row (which may be
   * `width` to query the position after the last row).
   */
  rowPos(row: number) {
    let { start } = this
    const { table } = this.data
    for (let r = 0; r < row; r++) start += table.content[r]!.length
    return start
  }

  /**
   * Get the position where a cell would have to be inserted to
   * appear at the given column and row.
   */
  cellInsertionPos(col: number, row: number) {
    const { width, map } = this.data
    for (let scan = col; ; scan++) {
      if (scan == width) return this.rowPos(row + 1) - 1
      const index = scan + row * width,
        pos = map[index]
      if (pos && (!row || (pos != map[index - width] && (!col || pos != map[index - 1])))) return pos + this.start
    }
  }

  /** Get the node for the cell at the given position. */
  getCell(pos: number): Plot {
    const found = this.data.table.plotAt(pos - this.start)
    if (!found) throw new Error('Invalid cell position')
    return found
  }

  cellsOverlapRectangle(rect: Rect) {
    const { width, height, map } = this.data
    let indexTop = rect.startRow * width + rect.startCol,
      indexBefore = indexTop
    let indexBottom = (rect.endRow - 1) * width + rect.endCol,
      indexAfter = indexTop + (rect.endCol - rect.startCol - 1)
    for (let i = rect.startRow; i < rect.endRow; i++) {
      if (
        (rect.startCol > 0 && sameCell(map[indexBefore]!, map[indexBefore - 1]!)) ||
        (rect.endCol < width && sameCell(map[indexAfter]!, map[indexAfter + 1]!))
      ) {
        return true
      }
      indexBefore += width
      indexAfter += width
    }
    for (let i = rect.startCol; i < rect.endCol; i++) {
      if (
        (rect.startRow > 0 && sameCell(map[indexTop]!, map[indexTop - width]!)) ||
        (rect.endRow < height && sameCell(map[indexBottom]!, map[indexBottom + width]!))
      ) {
        return true
      }
      indexTop++
      indexBottom++
    }
    return false
  }

  /** Find the table map for the given table node. */
  static get(table: Plot, start: number): TableMap {
    let data = cache.get(table)
    if (!data) cache.set(table, (data = computeMap(table)))
    return new TableMap(start, data)
  }
}

function sameCell(a: number, b: number) {
  return a != 0 && a == b
}

// Compute a table map.
function computeMap(table: Plot) {
  if (!table.type.hasRole(Node.Role.Table)) throw new RangeError(`Not a table node: ${table.type.name}`)
  const first = table.content[0] as Plot | undefined
  let width = first ? first.content.reduce((w, c) => w + (c.mark(ColSpan) ?? 1), 0) : 0
  const height = table.content.length
  let map: number[] = [],
    problems: Problem[] | null = null
  for (let i = 0, e = width * height; i < e; i++) map[i] = 0
  const cellEnd = new Map<number, number>()

  for (let row = 0, pos = 0; row < height; row++) {
    const rowNode = table.content[row] as Plot
    let mapPos = row * width
    pos++
    for (let i = 0, col = 0; ; i++) {
      while (mapPos < map.length && map[mapPos] != 0) mapPos++
      if (i == rowNode.content.length) break
      const cellNode = rowNode.content[i]!
      cellEnd.set(pos, pos + cellNode.length)
      const colSpan = cellNode.mark(ColSpan) ?? 1,
        rowSpan = cellNode.mark(RowSpan) ?? 1
      const exceed = col + colSpan - width
      if (exceed > 0) {
        map = growMap(map, width, height, exceed)
        width += exceed
        mapPos += row * exceed
      }
      for (let h = 0; h < rowSpan; h++) {
        if (h + row >= height) {
          ;(problems || (problems = [])).push({ type: 'overlong_rowspan', pos, n: rowSpan - h })
          break
        }
        const start = mapPos + h * width
        let collided = 0
        for (let w = 0; w < colSpan; w++) {
          if (map[start + w] == 0) map[start + w] = pos
          else collided++
        }
        if (collided) (problems || (problems = [])).push({ type: 'collision', pos })
      }
      mapPos += colSpan
      col += colSpan
      pos += cellNode.length
    }
    pos++
  }
  for (let row = 0, i = 0; row < height; row++) {
    let missing = 0
    for (let col = 0; col < width; col++) if (map[i++] == 0) missing++
    if (missing) (problems || (problems = [])).push({ type: 'missing', row, n: missing })
  }

  return new MapData(table, width, height, map, problems, cellEnd)
}

function growMap(map: number[], width: number, height: number, count: number) {
  const newMap: number[] = []
  for (let row = 0, i = 0; row < height; row++) {
    for (let col = 0; col < width; col++) newMap.push(map[i++]!)
    for (let j = 0; j < count; j++) newMap.push(0)
  }
  return newMap
}
