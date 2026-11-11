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
  /** The cell's own style, which the toolbar reflects. */
  style: number
  /** The style the grid paints when a table style or a conditional format changes the cell's own. */
  look?: number
  color?: string
  /** The fingerprint of the picture the cell holds, which the grid paints instead of text. */
  picture?: string
  /** The note on the cell. */
  note?: string
  /** The data bar or icon a conditional format adds. */
  cf?: RenderCf
}
export type RenderBar = { fraction: number; color: string; gradient: boolean }
export type RenderIcon = { set: string; index: number }
export type RenderCf = { bar?: RenderBar; icon?: RenderIcon; hide_value?: boolean }
export type RenderFilterColumn = { col: number; values: string[]; blanks: boolean; custom: boolean }
/** The sheet's filter: its range with the header row, and the criteria of its filtered columns. */
export type RenderFilter = { range: string; columns: RenderFilterColumn[] }
export type RenderTable = {
  name: string
  range: string
  header_row: boolean
  totals_row: boolean
  filter_button: boolean
}
export type ValidationKind = 'any' | 'whole' | 'decimal' | 'list' | 'date' | 'time' | 'text_length' | 'custom'
export type ValidationOperator =
  | 'between'
  | 'not_between'
  | 'equal'
  | 'not_equal'
  | 'greater'
  | 'less'
  | 'greater_or_equal'
  | 'less_or_equal'
/** One range of a validation rule, with the entries its dropdown offers. */
export type RenderValidation = {
  range: string
  kind: ValidationKind
  dropdown: boolean
  items: string[]
  input_title: string
  input_message: string
}
/** The rule that `validation.set` writes over a range. */
export type ValidationRule = {
  kind: ValidationKind
  operator?: ValidationOperator
  formula1?: string
  formula2?: string
  allow_blank?: boolean
  show_dropdown?: boolean
  input_message?: string
  error_message?: string
}
/** One value a filter column offers, and whether the current criteria show it. */
export type FilterValue = { text: string; blank: boolean; selected: boolean }
/** Why typed input fails a cell's validation; `stop` rejects it, the other styles let it through. */
export type ValidationFailure = { message: string; style: 'stop' | 'warning' | 'information' }
export type FindOptions = { match_case?: boolean; whole_cell?: boolean; formulas?: boolean }
export type FindMatch = { sheet_id: number; cell: string; text: string }
/** A floating picture: its top-left corner `dx`, `dy` pixels into `cell`, and its size in pixels. */
export type RenderImage = {
  image_id: number
  cell: string
  dx: number
  dy: number
  width: number
  height: number
  mime: string
  alt: string
  digest: string
}
export type SelectionStats = {
  count: number
  numbers: number
  sum: number
  average: number | null
  min: number | null
  max: number | null
}
export type FunctionInfo = { name: string; category: string; signature: string; description: string }
export type ClipboardCell = { input: string; value: string; text: string; format: Record<string, unknown> }
/** A block that the kernel copied, with the cell it came from so a paste can move references. */
export type ClipboardBlock = { origin: string; rows: ClipboardCell[][] }
export type PasteMode = 'all' | 'values' | 'formulas' | 'formats'
/** The formats of a range that `range.restore_formats` puts back, as the kernel read them. */
export type FormatSnapshot = {
  lines: { offset: number; format: Record<string, unknown> }[]
  cells: { row: number; col: number; format: Record<string, unknown> }[]
}
export type FillMode = 'series' | 'copy' | 'values' | 'formats'
export type RenderLine = { index: number; size: number | null; hidden: boolean; style: number | null }
export type Viewport = {
  cells: RenderCell[]
  styles: RenderStyle[]
  merges: string[]
  spills: [string, string][]
  rows: RenderLine[]
  cols: RenderLine[]
  filter: RenderFilter | null
  tables: RenderTable[]
  validations: RenderValidation[]
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

/**
 * The range that dragging the fill handle of `source` to `pointer` fills: the source extended along
 * the axis the pointer left it by the most, or `undefined` while the pointer stays inside.
 */
export function fillTarget(source: Rect, pointer: CellAddress): Rect | undefined {
  const below = pointer.row - source.r1
  const above = source.r0 - pointer.row
  const right = pointer.col - source.c1
  const left = source.c0 - pointer.col
  const vertical = Math.max(below, above)
  const horizontal = Math.max(right, left)
  if (vertical <= 0 && horizontal <= 0) return undefined
  if (vertical >= horizontal) {
    return below > 0 ? { ...source, r1: pointer.row } : { ...source, r0: pointer.row }
  }
  return right > 0 ? { ...source, c1: pointer.col } : { ...source, c0: pointer.col }
}

/** The cell or range an operation targets, and the text it typed, for messages to its author. */
export function describeOp(op: SpreadsheetOp): { target: string; input?: string } {
  if (typeof op.cell === 'string') {
    return { target: op.cell, input: typeof op.input === 'string' ? op.input : undefined }
  }
  if (typeof op.range === 'string') return { target: op.range }
  const anchor = op.anchor as { cell?: unknown } | undefined
  if (typeof anchor?.cell === 'string') return { target: anchor.cell }
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

/**
 * The `columns` of a `filter.set` that keeps every other column's value list and gives column
 * `col` the criterion `criterion`, or none. A custom or top-N criterion from the file cannot be
 * expressed as a value list, so editing any column drops it and that column shows every row.
 */
export function filterColumnsWith(
  filter: RenderFilter,
  col: number,
  criterion: { values: string[]; blanks: boolean } | null
): { col: string; values: string[]; blanks?: boolean }[] {
  const kept = filter.columns
    .filter(column => column.col !== col && !column.custom)
    .map(column => ({ col: columnName(column.col), values: column.values, ...(column.blanks ? { blanks: true } : {}) }))
  if (criterion) {
    kept.push({ col: columnName(col), values: criterion.values, ...(criterion.blanks ? { blanks: true } : {}) })
  }
  return kept.sort((a, b) => columnIndex(a.col) - columnIndex(b.col))
}

/**
 * The input that replaces every occurrence of `query` in `input` with `replacement`, as a replace
 * does, or `undefined` when `input` holds no occurrence. A whole-cell replace needs the whole input
 * to equal the query.
 */
export function replaceText(
  input: string,
  query: string,
  replacement: string,
  options: Pick<FindOptions, 'match_case' | 'whole_cell'> = {}
): string | undefined {
  if (!query) return undefined
  const same = (a: string, b: string) => (options.match_case ? a === b : a.toLowerCase() === b.toLowerCase())
  if (options.whole_cell) return same(input, query) ? replacement : undefined
  const haystack = options.match_case ? input : input.toLowerCase()
  const needle = options.match_case ? query : query.toLowerCase()
  if (!haystack.includes(needle)) return undefined
  let result = ''
  let from = 0
  for (let at = haystack.indexOf(needle, from); at !== -1; at = haystack.indexOf(needle, from)) {
    result += input.slice(from, at) + replacement
    from = at + needle.length
  }
  return result + input.slice(from)
}

/** A chart to paint over the grid, anchored like a floating picture. */
export type RenderChart = {
  chart_id: number
  cell: string
  dx: number
  dy: number
  width: number
  height: number
  kind: string
  title: string | null
}
export type Rgba = [number, number, number, number]
/** A stroke: its colour and width. */
export type ChartStroke = [Rgba, number] | null
/** One drawing primitive of a chart, in pixels from the chart's top-left corner. */
export type ChartPrim =
  | { Rect: { x: number; y: number; w: number; h: number; fill: Rgba | null; stroke: ChartStroke; radius: number } }
  | { Line: { pts: [number, number][]; color: Rgba; width: number; dash: boolean } }
  | { Polygon: { pts: [number, number][]; fill: Rgba; stroke: ChartStroke } }
  | {
      Wedge: {
        cx: number
        cy: number
        r_outer: number
        r_inner: number
        a0: number
        a1: number
        fill: Rgba
        stroke: ChartStroke
      }
    }
  | { Circle: { cx: number; cy: number; r: number; fill: Rgba | null; stroke: ChartStroke } }
  | {
      Text: {
        x: number
        y: number
        text: string
        size: number
        color: Rgba
        bold: boolean
        align: 'Left' | 'Center' | 'Right'
        valign: 'Top' | 'Middle' | 'Bottom'
        rotation: number
      }
    }

export function rgba([r, g, b, a]: Rgba): string {
  return `rgba(${r}, ${g}, ${b}, ${(a / 255).toFixed(3)})`
}
