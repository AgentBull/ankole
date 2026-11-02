/**
 * The spreadsheet kernel's view shapes, A1 references, line geometry, and the clipboard codec.
 *
 * Every function here is pure, so the collaboration model, the canvas, and the unit tests share one
 * definition of how rows, columns, and ranges are named and measured.
 */

/** The last row and column that a worksheet can address, one past the largest zero-based index. */
export const MAX_ROWS = 1_048_576
export const MAX_COLS = 16_384

export type CellAddress = { row: number; col: number }
/** A zero-based rectangle with inclusive bounds. */
export type Rect = { r0: number; c0: number; r1: number; c1: number }
/** The anchor stays where the selection started; the focus moves with the pointer or the keyboard. */
export type Selection = { anchor: CellAddress; focus: CellAddress }

/** One canonical operation as the kernel and the page channel exchange it. */
export type SpreadsheetOp = { type: string } & Record<string, unknown>

export type SheetInfo = {
  sheet_id: number
  name: string
  hidden: boolean
  tab_color: string | null
  freeze: [number, number] | null
  default_row_height: number
  default_col_width: number
  show_gridlines: boolean
  rows: number
  cols: number
}

export type RenderBorder = { style: string; color: string | null }
export type RenderStyle = {
  font_name: string
  font_size: number
  bold: boolean
  italic: boolean
  underline: boolean
  strike: boolean
  font_color: string | null
  fill_color: string | null
  h_align: string
  v_align: string
  wrap: boolean
  indent: number
  rotation: number
  borders: {
    left: RenderBorder | null
    right: RenderBorder | null
    top: RenderBorder | null
    bottom: RenderBorder | null
  }
}
export type RenderCell = {
  row: number
  col: number
  text: string
  kind: 'number' | 'text' | 'bool' | 'error'
  style: number
  color?: string
}
export type RenderLine = { index: number; size: number | null; hidden: boolean; style: number | null }
export type Viewport = {
  cells: RenderCell[]
  styles: RenderStyle[]
  merges: string[]
  spills: [string, string][]
  rows: RenderLine[]
  cols: RenderLine[]
}

/** Operations after which earlier coordinates no longer name the same cells. */
const STRUCTURAL = new Set([
  'line.insert',
  'line.delete',
  'cells.insert',
  'cells.delete',
  'range.move',
  'range.sort',
  'sheet.delete'
])

/**
 * A spreadsheet page is a file page whose file name ends in `.xlsx` or `.xlsm`, ignoring case and
 * the ` (n)` that Drive appends to a duplicate name.
 */
export function isSpreadsheetFileName(name: string): boolean {
  return /\.xls[xm](?: \(\d+\))?$/i.test(name)
}

export function isStructural(op: SpreadsheetOp): boolean {
  return STRUCTURAL.has(op.type)
}

export function columnName(col: number): string {
  let name = ''
  for (let n = col + 1; n > 0; n = Math.floor((n - 1) / 26)) name = String.fromCharCode(65 + ((n - 1) % 26)) + name
  return name
}

function columnIndex(letters: string): number {
  let col = 0
  for (const letter of letters.toUpperCase()) col = col * 26 + letter.charCodeAt(0) - 64
  return col - 1
}

export function cellName({ row, col }: CellAddress): string {
  return `${columnName(col)}${row + 1}`
}

export function parseCell(text: string): CellAddress | undefined {
  const match = /^\$?([A-Za-z]{1,3})\$?(\d{1,7})$/.exec(text.trim())
  if (!match) return undefined
  const cell = { row: Number(match[2]) - 1, col: columnIndex(match[1]!) }
  return cell.row >= 0 && cell.row < MAX_ROWS && cell.col < MAX_COLS ? cell : undefined
}

/** Reads `B2:D10`, a single cell, whole columns `A:C`, or whole rows `3:5`. */
export function parseRange(text: string): Rect | undefined {
  const [first, second = first] = text.split(':')
  if (!first) return undefined
  const rows = /^\$?(\d{1,7})$/
  const cols = /^\$?([A-Za-z]{1,3})$/
  if (rows.test(first) && rows.test(second)) {
    const r0 = Number(rows.exec(first)![1]) - 1
    const r1 = Number(rows.exec(second)![1]) - 1
    return normalize({ r0, c0: 0, r1, c1: MAX_COLS - 1 })
  }
  if (cols.test(first) && cols.test(second)) {
    return normalize({
      r0: 0,
      c0: columnIndex(first.replaceAll('$', '')),
      r1: MAX_ROWS - 1,
      c1: columnIndex(second.replaceAll('$', ''))
    })
  }
  const start = parseCell(first)
  const end = parseCell(second)
  return start && end ? normalize({ r0: start.row, c0: start.col, r1: end.row, c1: end.col }) : undefined
}

/** Names whole rows as `3:5` and whole columns as `A:C`, the forms the kernel accepts. */
export function rangeName(rect: Rect): string {
  if (rect.c0 === 0 && rect.c1 === MAX_COLS - 1) return `${rect.r0 + 1}:${rect.r1 + 1}`
  if (rect.r0 === 0 && rect.r1 === MAX_ROWS - 1) return `${columnName(rect.c0)}:${columnName(rect.c1)}`
  const start = cellName({ row: rect.r0, col: rect.c0 })
  return rect.r0 === rect.r1 && rect.c0 === rect.c1 ? start : `${start}:${cellName({ row: rect.r1, col: rect.c1 })}`
}

function normalize(rect: Rect): Rect {
  return {
    r0: Math.min(rect.r0, rect.r1),
    c0: Math.min(rect.c0, rect.c1),
    r1: Math.max(rect.r0, rect.r1),
    c1: Math.max(rect.c0, rect.c1)
  }
}

export function selectionRect({ anchor, focus }: Selection): Rect {
  return normalize({ r0: anchor.row, c0: anchor.col, r1: focus.row, c1: focus.col })
}

export function cellSelection(cell: CellAddress): Selection {
  return { anchor: cell, focus: cell }
}

export function intersect(a: Rect, b: Rect): Rect | undefined {
  const rect = {
    r0: Math.max(a.r0, b.r0),
    c0: Math.max(a.c0, b.c0),
    r1: Math.min(a.r1, b.r1),
    c1: Math.min(a.c1, b.c1)
  }
  return rect.r0 <= rect.r1 && rect.c0 <= rect.c1 ? rect : undefined
}

export function contains(rect: Rect, { row, col }: CellAddress): boolean {
  return row >= rect.r0 && row <= rect.r1 && col >= rect.c0 && col <= rect.c1
}

export function clampCell({ row, col }: CellAddress): CellAddress {
  return { row: Math.min(Math.max(row, 0), MAX_ROWS - 1), col: Math.min(Math.max(col, 0), MAX_COLS - 1) }
}

/**
 * The rows or columns that a line action on `rect` covers. A selection of whole columns covers every
 * row, so a row action there applies to the active cell's row only, and the same holds for columns.
 */
export function selectedLines(rect: Rect, axis: 'rows' | 'cols', active: CellAddress): { start: number; end: number } {
  if (axis === 'rows') {
    return rect.r0 === 0 && rect.r1 === MAX_ROWS - 1
      ? { start: active.row, end: active.row }
      : { start: rect.r0, end: rect.r1 }
  }
  return rect.c0 === 0 && rect.c1 === MAX_COLS - 1
    ? { start: active.col, end: active.col }
    : { start: rect.c0, end: rect.c1 }
}

/**
 * Where a cell lands after another editor's row or column insert or delete on the same sheet. A
 * deleted cell lands on the first line after the deleted block.
 */
export function shiftCell(cell: CellAddress, op: SpreadsheetOp): CellAddress {
  if (op.type !== 'line.insert' && op.type !== 'line.delete') return cell
  const key = op.axis === 'rows' ? 'row' : 'col'
  const at = Number(op.at)
  const count = Number(op.count)
  const index = cell[key]
  if (index < at) return cell
  const moved = op.type === 'line.insert' ? index + count : Math.max(at, index - count)
  return clampCell({ ...cell, [key]: moved })
}

/** The cell or range an operation targets, and the text it typed, for messages to its author. */
export function describeOp(op: SpreadsheetOp): { target: string; input?: string } {
  if (typeof op.cell === 'string') {
    return { target: op.cell, input: typeof op.input === 'string' ? op.input : undefined }
  }
  if (typeof op.range === 'string') return { target: op.range }
  if (op.type === 'line.insert' || op.type === 'line.delete') {
    const start = Number(op.at)
    const end = start + Number(op.count) - 1
    return {
      target: op.axis === 'rows' ? `${start + 1}:${end + 1}` : `${columnName(start)}:${columnName(end)}`
    }
  }
  return { target: typeof op.name === 'string' ? op.name : op.type }
}

/**
 * Sizes of the lines on one axis: a default size and the overrides seen so far. Prefix sums of the
 * overrides turn a line index into a position and back in logarithmic time.
 */
export class LineAxis {
  private overrides = new Map<number, number>()
  private indexes: number[] = []
  private deltas: number[] = [0]
  private stale = false

  constructor(
    readonly defaultSize: number,
    readonly limit: number
  ) {}

  /** Replaces what is known about lines `start..end` with `lines`; unlisted lines take the default size. */
  replace(start: number, end: number, lines: readonly Pick<RenderLine, 'index' | 'size' | 'hidden'>[]) {
    for (const index of this.overrides.keys()) {
      if (index >= start && index <= end) this.overrides.delete(index)
    }
    for (const line of lines) {
      const size = line.hidden ? 0 : (line.size ?? this.defaultSize)
      if (size !== this.defaultSize) this.overrides.set(line.index, size)
    }
    this.stale = true
  }

  size(index: number): number {
    return this.overrides.get(index) ?? this.defaultSize
  }

  /** The position where line `index` starts. */
  offset(index: number): number {
    this.refresh()
    let low = 0
    let high = this.indexes.length
    while (low < high) {
      const middle = (low + high) >> 1
      if (this.indexes[middle]! < index) low = middle + 1
      else high = middle
    }
    return index * this.defaultSize + this.deltas[low]!
  }

  /** The visible line that contains `position`. */
  indexAt(position: number): number {
    let low = 0
    let high = this.limit - 1
    while (low < high) {
      const middle = (low + high + 1) >> 1
      if (this.offset(middle) <= position) low = middle
      else high = middle - 1
    }
    return low
  }

  private refresh() {
    if (!this.stale) return
    this.indexes = [...this.overrides.keys()].sort((a, b) => a - b)
    this.deltas = [0]
    for (const index of this.indexes) {
      this.deltas.push(this.deltas.at(-1)! + this.overrides.get(index)! - this.defaultSize)
    }
    this.stale = false
  }
}

/** Writes rows of cell inputs as tab-separated text that spreadsheet applications paste. */
export function encodeTSV(rows: readonly (readonly string[])[]): string {
  return rows
    .map(row => row.map(value => (/[\t\n\r"]/.test(value) ? `"${value.replaceAll('"', '""')}"` : value)).join('\t'))
    .join('\n')
}

/** Reads tab-separated clipboard text, including quoted values that hold tabs, quotes, or line breaks. */
export function decodeTSV(text: string): string[][] {
  const source = text.replace(/\r\n?/g, '\n')
  const rows: string[][] = []
  let row: string[] = []
  let field = ''
  let quoted = false
  for (let index = 0; index < source.length; index++) {
    const char = source[index]!
    if (quoted) {
      if (char !== '"') field += char
      else if (source[index + 1] === '"') {
        field += '"'
        index++
      } else quoted = false
    } else if (char === '"' && field === '') quoted = true
    else if (char === '\t') {
      row.push(field)
      field = ''
    } else if (char === '\n') {
      row.push(field)
      rows.push(row)
      row = []
      field = ''
    } else field += char
  }
  if (field !== '' || row.length) {
    row.push(field)
    rows.push(row)
  }
  return rows
}

/** Collaborator marks cycle through these colour tokens; a uid always gets the same one. */
const MEMBER_COLORS = [
  '--color-blue-60',
  '--color-teal-60',
  '--color-purple-60',
  '--color-magenta-60',
  '--color-orange-50',
  '--color-green-60',
  '--color-cyan-60',
  '--color-red-60'
]

export function memberColor(uid: string): string {
  let hash = 0
  for (const char of uid) hash = (hash * 31 + char.charCodeAt(0)) >>> 0
  return MEMBER_COLORS[hash % MEMBER_COLORS.length]!
}
