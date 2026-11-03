import { t } from 'i18next'
import {
  Button,
  ContextMenu,
  ContextMenuContent,
  ContextMenuTrigger,
  Dialog,
  DialogContent,
  DialogTitle,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  Popover,
  PopoverContent,
  PopoverTitle,
  PopoverTrigger,
  toast
} from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import { RiArrowDownSLine } from '@remixicon/react'
import { useEffect, useRef, useState, type KeyboardEvent, type PointerEvent, type RefObject } from 'react'
import { acceptsReference, formulaReferences, isFormula, referenceText, splice } from '../state/spreadsheet-formula'
import {
  cellName,
  cellSelection,
  clampCell,
  columnName,
  contains,
  filterColumnsWith,
  fillTarget,
  intersect,
  LineAxis,
  MAX_COLS,
  MAX_ROWS,
  parseCell,
  parseRange,
  rangeName,
  selectedLines,
  selectionRect,
  rgba,
  type CellAddress,
  type ChartPrim,
  type FillMode,
  type FilterValue,
  type Rect,
  type RenderCell,
  type RenderChart,
  type RenderFilter,
  type RenderImage,
  type RenderStyle,
  type RenderTable,
  type RenderValidation,
  type Rgba,
  type SheetInfo,
  type Viewport
} from '../state/spreadsheet-grid'
import { presenceRect, type Direction, type SpreadsheetSession } from '../state/spreadsheet-collaboration'
import { FORMULA_BAR_ATTRIBUTE, SpreadsheetCellEditor } from './spreadsheet-cell-editor'
import { SpreadsheetCellMenu, type MenuKind } from './spreadsheet-cell-menu'
import { insertPicture, pasteFromClipboard } from './spreadsheet-clipboard-actions'
import { SpreadsheetFilterPopover } from './spreadsheet-filter-popover'
import type { FindMode } from './spreadsheet-find-dialog'
import { displaySize, downloadPicture, pictureType } from './spreadsheet-pictures'

const HEADER_WIDTH = 48
const HEADER_HEIGHT = 24
/** Lines fetched beyond the visible ones, so short scrolls paint from the cache. */
const ROW_MARGIN = 20
const COL_MARGIN = 5
/** Rows and columns the scrollable area extends past the last visible one. */
const ROW_RUNWAY = 50
const COL_RUNWAY = 10
const RESIZE_SLOP = 4
const POINTS_TO_PIXELS = 96 / 72
/** The fill handle's size, and how far from it a press still grabs it. */
const FILL_HANDLE = 7
const HANDLE_SLOP = 4
/** The corner handles of a selected floating picture. */
const IMAGE_HANDLE = 8
const MIN_IMAGE_SIZE = 16
/** The filter button in a header cell, and the dropdown arrow beside a cell with a list. */
const FILTER_BUTTON = 14
const DROPDOWN_WIDTH = 16
const NOTE_MARK = 6
/** Icon set colours from the lowest rank to the highest. */
const ICON_COLORS = ['#DA1E28', '#F1C21B', '#24A148']
/** Colours of the references a formula draft names, in order. */
const REFERENCE_COLORS = [
  '--color-blue-60',
  '--color-red-60',
  '--color-green-60',
  '--color-purple-60',
  '--color-orange-50',
  '--color-teal-60'
]

/** A cell with the style the grid paints it in: a table's or a conditional format's look when it has one. */
type FrameCell = { cell: RenderCell; style: RenderStyle }
/** The cells the worker returned for one sheet version, with the rectangles they cover. */
type Frame = {
  sheetID: number
  version: number
  rects: Rect[]
  cells: Map<number, FrameCell>
  merges: Rect[]
  spills: Rect[]
  rowStyles: Map<number, RenderStyle>
  colStyles: Map<number, RenderStyle>
  filter: { range: Rect; filter: RenderFilter } | undefined
  tables: { rect: Rect; table: RenderTable }[]
  validations: { rect: Rect; rule: RenderValidation }[]
}
type Corner = 'nw' | 'ne' | 'sw' | 'se'
type Hit =
  | { kind: 'corner' }
  | { kind: 'cols'; col: number; resize?: number }
  | { kind: 'rows'; row: number; resize?: number }
  | { kind: 'cell'; cell: CellAddress }
  | { kind: 'fill' }
  | { kind: 'image'; image: RenderImage; corner?: Corner }
  | { kind: 'filter'; col: number; box: CellBox }
  | { kind: 'dropdown'; cell: CellAddress; box: CellBox; rule: RenderValidation }
type Drag =
  | { kind: 'select'; anchor: CellAddress; lines?: 'rows' | 'cols' }
  | { kind: 'resize'; axis: 'rows' | 'cols'; index: number; origin: number; size: number; current: number }
  | { kind: 'fill'; source: Rect; target?: Rect }
  | {
      kind: 'image'
      image: RenderImage
      corner?: Corner
      origin: { x: number; y: number }
      start: CellBox
      current: CellBox
    }
  | { kind: 'point'; anchor: CellAddress }
/** The reference that pointing inserted into a formula draft, which the next press or drag replaces. */
type Pointed = { start: number; end: number; anchor: CellAddress }
/** The picture bitmaps decoded so far, by fingerprint; `null` while one loads or after it failed. */
type Bitmaps = Map<string, ImageBitmap | null>
type Tokens = Record<
  | 'background'
  | 'text'
  | 'grid'
  | 'header'
  | 'headerText'
  | 'headerActive'
  | 'divider'
  | 'selection'
  | 'focus'
  | 'spill',
  string
> & { font: string }
export type CellBox = { x: number; y: number; width: number; height: number }

const cellKey = (row: number, col: number) => row * MAX_COLS + col

function readTokens(element: Element): Tokens {
  const style = getComputedStyle(element)
  const token = (name: string) => style.getPropertyValue(name).trim()
  return {
    background: token('--background'),
    text: token('--foreground'),
    grid: token('--border'),
    header: token('--background-secondary'),
    headerText: token('--fg-secondary'),
    headerActive: token('--accent'),
    divider: token('--border-strong'),
    selection: token('--selection'),
    focus: token('--color-blue-60'),
    spill: token('--color-blue-50'),
    font: token('--font-sans') || 'sans-serif'
  }
}

/** The CSS font for a cell style: its own family first, then the UI stack, which covers Chinese text. */
function cellFont(style: RenderStyle | undefined, fallback: string): { font: string; size: number } {
  const size = Math.max(6, (style?.font_size ?? 11) * POINTS_TO_PIXELS)
  const family = style?.font_name ? `"${style.font_name.replaceAll('"', '')}", ${fallback}` : fallback
  return { font: `${style?.italic ? 'italic ' : ''}${style?.bold ? 'bold ' : ''}${size}px ${family}`, size }
}

function alignment(cell: RenderCell, style: RenderStyle): 'left' | 'center' | 'right' {
  if (style.h_align === 'left' || style.h_align === 'right') return style.h_align
  if (style.h_align === 'center' || style.h_align === 'center_across') return 'center'
  if (cell.kind === 'number' || cell.kind === 'error') return 'right'
  return cell.kind === 'bool' ? 'center' : 'left'
}

const borderWidths: Record<string, number> = {
  medium: 2,
  medium_dashed: 2,
  medium_dash_dot: 2,
  medium_dash_dot_dot: 2,
  thick: 3,
  double: 3
}
const borderDashes: Record<string, number[]> = {
  dashed: [4, 2],
  medium_dashed: [6, 3],
  dotted: [1, 2],
  hair: [1, 1],
  dash_dot: [4, 2, 1, 2],
  medium_dash_dot: [6, 3, 2, 3],
  dash_dot_dot: [4, 2, 1, 2, 1, 2],
  medium_dash_dot_dot: [6, 3, 2, 3, 2, 3],
  slant_dash_dot: [6, 2, 2, 2]
}

function wrapLines(context: CanvasRenderingContext2D, text: string, width: number): string[] {
  const lines: string[] = []
  for (const paragraph of text.split('\n')) {
    let line = ''
    for (const char of paragraph) {
      if (line && context.measureText(line + char).width > width) {
        lines.push(line)
        line = char === ' ' ? '' : char
      } else line += char
    }
    lines.push(line)
  }
  return lines
}

/**
 * The grid: a high-DPI canvas over a native scroll area. The canvas paints the cached viewport of
 * the local document and asks the worker for a new one only when the visible area leaves it.
 */
export function SpreadsheetCanvas({
  model,
  pageID,
  inputRef: input,
  onFind
}: {
  model: SpreadsheetSession
  pageID: string
  inputRef: RefObject<HTMLTextAreaElement | null>
  onFind(mode: FindMode): void
}) {
  useSignals()
  const container = useRef<HTMLDivElement>(null)
  const scroller = useRef<HTMLDivElement>(null)
  const spacer = useRef<HTMLDivElement>(null)
  const canvas = useRef<HTMLCanvasElement>(null)
  const frame = useRef<Frame | undefined>(undefined)
  const axes = useRef(new Map<number, { rows: LineAxis; cols: LineAxis }>())
  const fetching = useRef('')
  const extent = useRef({ sheetID: 0, rows: 0, cols: 0 })
  const drag = useRef<Drag | undefined>(undefined)
  const scheduled = useRef(0)
  const [menu, setMenu] = useState<MenuKind>('cells')
  const images = useRef<{ sheetID: number; version: number; list: RenderImage[] } | undefined>(undefined)
  const imagesKey = useRef('')
  const charts = useRef<{ sheetID: number; version: number; list: RenderChart[] } | undefined>(undefined)
  const chartsKey = useRef('')
  /** Chart drawings by chart, document version, and box size; `null` while one is being laid out. */
  const drawings = useRef(new Map<string, ChartPrim[] | null>())
  const bitmaps = useRef<Bitmaps>(new Map())
  const pointed = useRef<Pointed | undefined>(undefined)
  const fillOptions = useRef<HTMLDivElement>(null)
  const [selectedImage, setSelectedImage] = useState<RenderImage>()
  const selectedImageRef = useRef<RenderImage | undefined>(undefined)
  const [filled, setFilled] = useState<{ source: Rect; target: Rect }>()
  const filledRef = useRef(filled)
  const [viewing, setViewing] = useState<{ url: string; alt: string }>()
  const [filterMenu, setFilterMenu] = useState<{ col: number; box: CellBox; values?: FilterValue[] }>()
  const [dropdown, setDropdown] = useState<{ cell: CellAddress; box: CellBox; rule: RenderValidation }>()
  const copied = model.copied.value
  const painter = model.painter.value
  const sheet = model.activeSheet.value
  const editable = model.editable.value
  const sheetID = model.activeSheetID.value
  const version = model.version.value
  const selection = model.selection.value
  const members = model.members.value
  const draft = model.draft.value

  const geometry = (info: SheetInfo) => {
    let entry = axes.current.get(info.sheet_id)
    if (
      !entry ||
      entry.rows.defaultSize !== info.default_row_height ||
      entry.cols.defaultSize !== info.default_col_width
    ) {
      entry = {
        rows: new LineAxis(info.default_row_height, MAX_ROWS),
        cols: new LineAxis(info.default_col_width, MAX_COLS)
      }
      axes.current.set(info.sheet_id, entry)
    }
    return entry
  }

  /** Screen positions for the current scroll offset: frozen lines stay put and the rest scroll. */
  const layout = () => {
    const info = model.activeSheet.peek()
    const element = scroller.current
    if (!info || !element) return undefined
    const { rows, cols } = geometry(info)
    const [frozenRows, frozenCols] = info.freeze ?? [0, 0]
    const frozenHeight = rows.offset(frozenRows)
    const frozenWidth = cols.offset(frozenCols)
    const top = element.scrollTop
    const left = element.scrollLeft
    const width = element.clientWidth
    const height = element.clientHeight
    // Scrolled lines start right after the frozen ones, so only they move with the scroll offset.
    const rowY = (row: number) => HEADER_HEIGHT + rows.offset(row) - (row < frozenRows ? 0 : top)
    const colX = (col: number) => HEADER_WIDTH + cols.offset(col) - (col < frozenCols ? 0 : left)
    const firstRow = Math.max(frozenRows, rows.indexAt(frozenHeight + top))
    const lastRow = rows.indexAt(frozenHeight + top + Math.max(0, height - HEADER_HEIGHT - frozenHeight))
    const firstCol = Math.max(frozenCols, cols.indexAt(frozenWidth + left))
    const lastCol = cols.indexAt(frozenWidth + left + Math.max(0, width - HEADER_WIDTH - frozenWidth))
    const rowAt = (y: number) => rows.indexAt(y - HEADER_HEIGHT + (y - HEADER_HEIGHT < frozenHeight ? 0 : top))
    const colAt = (x: number) => cols.indexAt(x - HEADER_WIDTH + (x - HEADER_WIDTH < frozenWidth ? 0 : left))
    return {
      info,
      rows,
      cols,
      frozenRows,
      frozenCols,
      frozenHeight,
      frozenWidth,
      width,
      height,
      rowY,
      colX,
      rowAt,
      colAt,
      firstRow,
      lastRow,
      firstCol,
      lastCol
    }
  }
  type Layout = NonNullable<ReturnType<typeof layout>>

  /**
   * The screen box of a rectangle. A part that has scrolled under the frozen panes is cut off, and
   * the box may be empty when the whole rectangle has.
   */
  const box = (view: Layout, rect: Rect): CellBox => {
    const frozenTop = rect.r0 < view.frozenRows
    const frozenLeft = rect.c0 < view.frozenCols
    const y = Math.max(view.rowY(rect.r0), frozenTop ? HEADER_HEIGHT : HEADER_HEIGHT + view.frozenHeight)
    const x = Math.max(view.colX(rect.c0), frozenLeft ? HEADER_WIDTH : HEADER_WIDTH + view.frozenWidth)
    const bottom = Math.min(
      Math.max(
        view.rowY(rect.r1) + view.rows.size(rect.r1),
        frozenTop ? HEADER_HEIGHT + view.rows.offset(Math.min(rect.r1 + 1, view.frozenRows)) : 0
      ),
      view.height + 1
    )
    const right = Math.min(
      Math.max(
        view.colX(rect.c1) + view.cols.size(rect.c1),
        frozenLeft ? HEADER_WIDTH + view.cols.offset(Math.min(rect.c1 + 1, view.frozenCols)) : 0
      ),
      view.width + 1
    )
    return { x, y, width: right - x, height: bottom - y }
  }

  const shown = (area: CellBox) => area.width > 0 && area.height > 0

  const requestPaint = () => {
    if (scheduled.current) return
    scheduled.current = requestAnimationFrame(() => {
      scheduled.current = 0
      paint()
    })
  }

  /** Fetches the visible rectangle plus a margin, one rectangle per frozen pane, in one round trip. */
  const fetchVisible = (view: Layout) => {
    const id = view.info.sheet_id
    const current = model.version.peek()
    const main = {
      r0: Math.max(view.frozenRows, view.firstRow - ROW_MARGIN),
      c0: Math.max(view.frozenCols, view.firstCol - COL_MARGIN),
      r1: Math.min(MAX_ROWS - 1, view.lastRow + ROW_MARGIN),
      c1: Math.min(MAX_COLS - 1, view.lastCol + COL_MARGIN)
    }
    const visible = { r0: view.firstRow, c0: view.firstCol, r1: view.lastRow, c1: view.lastCol }
    const rects = [main]
    if (view.frozenRows) rects.push({ r0: 0, c0: main.c0, r1: view.frozenRows - 1, c1: main.c1 })
    if (view.frozenCols) rects.push({ r0: main.r0, c0: 0, r1: main.r1, c1: view.frozenCols - 1 })
    if (view.frozenRows && view.frozenCols) {
      rects.push({ r0: 0, c0: 0, r1: view.frozenRows - 1, c1: view.frozenCols - 1 })
    }
    const cached = frame.current
    if (
      cached?.sheetID === id &&
      cached.version === current &&
      cached.rects.length === rects.length &&
      contains(cached.rects[0]!, { row: visible.r0, col: visible.c0 }) &&
      contains(cached.rects[0]!, { row: visible.r1, col: visible.c1 })
    ) {
      return
    }
    const key = `${id}:${rects.map(rangeName).join(',')}:${current}`
    if (fetching.current === key) return
    fetching.current = key
    void Promise.all(rects.map(rect => model.viewport(id, rect)))
      .then(views => {
        if (fetching.current !== key) return
        fetching.current = ''
        if (views.some(item => !item)) return
        const info = model.activeSheet.peek()
        if (!info || info.sheet_id !== id) return
        frame.current = buildFrame(id, current, rects, views as Viewport[], geometry(info))
        requestPaint()
      })
      .catch(() => {
        if (fetching.current === key) fetching.current = ''
      })
  }

  const paint = () => {
    const element = canvas.current
    const view = layout()
    if (!element || !view || !container.current) return
    const ratio = window.devicePixelRatio || 1
    if (element.width !== Math.round(view.width * ratio) || element.height !== Math.round(view.height * ratio)) {
      element.width = Math.round(view.width * ratio)
      element.height = Math.round(view.height * ratio)
      element.style.width = `${view.width}px`
      element.style.height = `${view.height}px`
    }
    const context = element.getContext('2d')
    if (!context) return
    context.setTransform(ratio, 0, 0, ratio, 0, 0)
    const tokens = readTokens(container.current)
    growExtent(view)
    fetchVisible(view)
    context.fillStyle = tokens.background
    context.fillRect(0, 0, view.width, view.height)
    const cached = frame.current?.sheetID === view.info.sheet_id ? frame.current : undefined
    const scrollRows = { from: view.firstRow, to: view.lastRow }
    const scrollCols = { from: view.firstCol, to: view.lastCol }
    const frozenRows = { from: 0, to: view.frozenRows - 1 }
    const frozenCols = { from: 0, to: view.frozenCols - 1 }
    const mainTop = HEADER_HEIGHT + view.frozenHeight
    const mainLeft = HEADER_WIDTH + view.frozenWidth
    const regions = [
      { rows: scrollRows, cols: scrollCols, clip: [mainLeft, mainTop, view.width - mainLeft, view.height - mainTop] },
      { rows: frozenRows, cols: scrollCols, clip: [mainLeft, HEADER_HEIGHT, view.width - mainLeft, view.frozenHeight] },
      { rows: scrollRows, cols: frozenCols, clip: [HEADER_WIDTH, mainTop, view.frozenWidth, view.height - mainTop] },
      { rows: frozenRows, cols: frozenCols, clip: [HEADER_WIDTH, HEADER_HEIGHT, view.frozenWidth, view.frozenHeight] }
    ]
    for (const region of regions) {
      if (region.rows.to < region.rows.from || region.cols.to < region.cols.from) continue
      context.save()
      context.beginPath()
      context.rect(...(region.clip as [number, number, number, number]))
      context.clip()
      paintCells(context, view, tokens, cached, region.rows, region.cols)
      context.restore()
    }
    fetchImages(view)
    fetchCharts(view)
    paintImages(context, view, tokens)
    paintCharts(context, view, tokens)
    paintOverlays(context, view, tokens)
    paintDropdownArrow(context, view, tokens)
    paintHeaders(context, view, tokens)
    placeEditor(view, cached)
    placeFillOptions(view)
  }

  const selectImage = (image: RenderImage | undefined) => {
    selectedImageRef.current = image
    setSelectedImage(image)
  }

  const showFillOptions = (next: { source: Rect; target: Rect } | undefined) => {
    filledRef.current = next
    setFilled(next)
  }

  /** Fetches the floating pictures of the shown sheet whenever the local document changes. */
  const fetchImages = (view: Layout) => {
    const id = view.info.sheet_id
    const current = model.version.peek()
    if (images.current?.sheetID === id && images.current.version === current) return
    const key = `${id}:${current}`
    if (imagesKey.current === key) return
    imagesKey.current = key
    void model
      .images(id)
      .then(list => {
        if (imagesKey.current !== key) return
        imagesKey.current = ''
        if (!list) return
        images.current = { sheetID: id, version: current, list }
        const selected = selectedImageRef.current
        if (selected) selectImage(list.find(image => image.image_id === selected.image_id))
        requestPaint()
      })
      .catch(() => {
        if (imagesKey.current === key) imagesKey.current = ''
      })
  }

  /** Fetches the charts of the shown sheet whenever the local document changes; their drawings are laid out again. */
  const fetchCharts = (view: Layout) => {
    const id = view.info.sheet_id
    const current = model.version.peek()
    if (charts.current?.sheetID === id && charts.current.version === current) return
    const key = `${id}:${current}`
    if (chartsKey.current === key) return
    chartsKey.current = key
    void model
      .charts(id)
      .then(list => {
        if (chartsKey.current !== key) return
        chartsKey.current = ''
        if (!list) return
        charts.current = { sheetID: id, version: current, list }
        drawings.current.clear()
        requestPaint()
      })
      .catch(() => {
        if (chartsKey.current === key) chartsKey.current = ''
      })
  }

  /** A chart's drawing at a box size. The first request lays it out and the grid paints again once it arrives. */
  const drawing = (sheetID: number, version: number, chart: RenderChart, width: number, height: number) => {
    const key = `${sheetID}:${chart.chart_id}:${version}:${width}x${height}`
    const cache = drawings.current
    if (cache.has(key)) return cache.get(key) ?? undefined
    cache.set(key, null)
    void model
      .chartDrawing(sheetID, chart.chart_id, width, height)
      .then(prims => {
        if (!prims || !cache.has(key)) return
        cache.set(key, prims)
        requestPaint()
      })
      .catch(() => cache.delete(key))
    return undefined
  }

  /** Charts over the cells, each clipped to the pane its anchor cell belongs to. */
  const paintCharts = (context: CanvasRenderingContext2D, view: Layout, tokens: Tokens) => {
    const sheetID = view.info.sheet_id
    const list = charts.current?.sheetID === sheetID ? charts.current.list : []
    const version = charts.current?.version ?? 0
    const mainTop = HEADER_HEIGHT + view.frozenHeight
    const mainLeft = HEADER_WIDTH + view.frozenWidth
    for (const chart of list) {
      const cell = parseCell(chart.cell) ?? { row: 0, col: 0 }
      const area = {
        x: view.colX(cell.col) + chart.dx,
        y: view.rowY(cell.row) + chart.dy,
        width: Math.round(chart.width),
        height: Math.round(chart.height)
      }
      if (area.width < 1 || area.height < 1) continue
      if (area.x > view.width || area.y > view.height || area.x + area.width < HEADER_WIDTH) continue
      const top = cell.row < view.frozenRows ? HEADER_HEIGHT : mainTop
      const left = cell.col < view.frozenCols ? HEADER_WIDTH : mainLeft
      context.save()
      context.beginPath()
      context.rect(left, top, view.width - left, view.height - top)
      context.clip()
      context.fillStyle = tokens.background
      context.fillRect(area.x, area.y, area.width, area.height)
      const prims = drawing(sheetID, version, chart, area.width, area.height)
      if (prims) paintPrims(context, prims, area.x, area.y, tokens.font)
      else {
        context.strokeStyle = tokens.divider
        context.lineWidth = 1
        context.strokeRect(area.x + 0.5, area.y + 0.5, area.width - 1, area.height - 1)
      }
      context.restore()
    }
  }

  /** Paints a chart's primitives with their origin at `(x, y)`. */
  const paintPrims = (context: CanvasRenderingContext2D, prims: ChartPrim[], x: number, y: number, family: string) => {
    context.save()
    context.translate(x, y)
    const stroke = (edge: [Rgba, number] | null) => {
      if (!edge || edge[1] <= 0) return
      context.strokeStyle = rgba(edge[0])
      context.lineWidth = edge[1]
      context.stroke()
    }
    for (const prim of prims) {
      if ('Rect' in prim) {
        const { x: px, y: py, w, h, fill, stroke: edge, radius } = prim.Rect
        context.beginPath()
        if (radius > 0) context.roundRect(px, py, w, h, radius)
        else context.rect(px, py, w, h)
        if (fill) {
          context.fillStyle = rgba(fill)
          context.fill()
        }
        stroke(edge)
      } else if ('Line' in prim) {
        const { pts, color, width, dash } = prim.Line
        if (!pts.length) continue
        context.beginPath()
        context.setLineDash(dash ? [3, 2] : [])
        context.moveTo(pts[0]![0], pts[0]![1])
        for (const [px, py] of pts.slice(1)) context.lineTo(px, py)
        stroke([color, width])
        context.setLineDash([])
      } else if ('Polygon' in prim) {
        const { pts, fill, stroke: edge } = prim.Polygon
        if (!pts.length) continue
        context.beginPath()
        context.moveTo(pts[0]![0], pts[0]![1])
        for (const [px, py] of pts.slice(1)) context.lineTo(px, py)
        context.closePath()
        context.fillStyle = rgba(fill)
        context.fill()
        stroke(edge)
      } else if ('Wedge' in prim) {
        // Angles count clockwise from 12 o'clock; the canvas counts from 3 o'clock.
        const { cx, cy, r_outer, r_inner, a0, a1, fill, stroke: edge } = prim.Wedge
        const start = a0 - Math.PI / 2
        const end = a1 - Math.PI / 2
        context.beginPath()
        context.arc(cx, cy, r_outer, start, end)
        if (r_inner > 0) context.arc(cx, cy, r_inner, end, start, true)
        else context.lineTo(cx, cy)
        context.closePath()
        context.fillStyle = rgba(fill)
        context.fill()
        stroke(edge)
      } else if ('Circle' in prim) {
        const { cx, cy, r, fill, stroke: edge } = prim.Circle
        context.beginPath()
        context.arc(cx, cy, r, 0, Math.PI * 2)
        if (fill) {
          context.fillStyle = rgba(fill)
          context.fill()
        }
        stroke(edge)
      } else if ('Text' in prim) {
        const { x: px, y: py, text, size, color, bold, align, valign, rotation } = prim.Text
        context.save()
        context.translate(px, py)
        if (rotation) context.rotate(rotation)
        context.font = `${bold ? 'bold ' : ''}${size}px ${family}`
        context.fillStyle = rgba(color)
        context.textAlign = align === 'Left' ? 'left' : align === 'Right' ? 'right' : 'center'
        context.textBaseline = valign === 'Top' ? 'top' : valign === 'Bottom' ? 'bottom' : 'middle'
        context.fillText(text, 0, 0)
        context.restore()
      }
    }
    context.restore()
  }

  /** A picture's decoded bitmap. The first request loads it and the grid paints again once it arrives. */
  const bitmap = (key: string, load: () => Promise<Uint8Array | undefined>) => {
    const cache = bitmaps.current
    if (cache.has(key)) return cache.get(key) ?? undefined
    cache.set(key, null)
    void load()
      .then(bytes =>
        bytes ? createImageBitmap(new Blob([bytes as BlobPart], { type: pictureType(bytes) })) : undefined
      )
      .then(decoded => {
        if (!decoded) return
        cache.set(key, decoded)
        requestPaint()
      })
      .catch(() => undefined)
    return undefined
  }

  const anchorCell = (image: RenderImage) => parseCell(image.cell) ?? { row: 0, col: 0 }

  /** Where a floating picture sits on screen. */
  const imageBox = (view: Layout, image: RenderImage): CellBox => {
    const cell = anchorCell(image)
    return {
      x: view.colX(cell.col) + image.dx,
      y: view.rowY(cell.row) + image.dy,
      width: image.width,
      height: image.height
    }
  }

  /** The anchor that puts a picture's top-left corner at the top-left of `area`. */
  const anchorAt = (view: Layout, area: CellBox) => {
    const x = Math.max(area.x, HEADER_WIDTH)
    const y = Math.max(area.y, HEADER_HEIGHT)
    const cell = { row: view.rowAt(y), col: view.colAt(x) }
    return {
      cell: cellName(cell),
      dx: Math.max(0, Math.round(x - view.colX(cell.col))),
      dy: Math.max(0, Math.round(y - view.rowY(cell.row))),
      width: Math.round(area.width),
      height: Math.round(area.height)
    }
  }

  const imageCorners = (area: CellBox): [Corner, number, number][] => [
    ['nw', area.x, area.y],
    ['ne', area.x + area.width, area.y],
    ['sw', area.x, area.y + area.height],
    ['se', area.x + area.width, area.y + area.height]
  ]

  /** Floating pictures over the cells, each clipped to the pane its anchor cell belongs to. */
  const paintImages = (context: CanvasRenderingContext2D, view: Layout, tokens: Tokens) => {
    const list = images.current?.sheetID === view.info.sheet_id ? images.current.list : []
    const moving = drag.current?.kind === 'image' ? drag.current : undefined
    const mainTop = HEADER_HEIGHT + view.frozenHeight
    const mainLeft = HEADER_WIDTH + view.frozenWidth
    for (const image of list) {
      const cell = anchorCell(image)
      const area = moving?.image.image_id === image.image_id ? moving.current : imageBox(view, image)
      const top = cell.row < view.frozenRows ? HEADER_HEIGHT : mainTop
      const left = cell.col < view.frozenCols ? HEADER_WIDTH : mainLeft
      context.save()
      context.beginPath()
      context.rect(left, top, view.width - left, view.height - top)
      context.clip()
      const decoded = bitmap(`image:${image.digest}`, () => model.imageData(view.info.sheet_id, image.image_id))
      if (decoded) context.drawImage(decoded, area.x, area.y, area.width, area.height)
      else {
        context.fillStyle = tokens.header
        context.fillRect(area.x, area.y, area.width, area.height)
      }
      if (selectedImageRef.current?.image_id === image.image_id) {
        context.strokeStyle = tokens.focus
        context.lineWidth = 2
        context.strokeRect(area.x, area.y, area.width, area.height)
        if (model.editable.peek()) {
          for (const [, x, y] of imageCorners(area)) {
            context.fillStyle = '#ffffff'
            context.fillRect(x - IMAGE_HANDLE / 2, y - IMAGE_HANDLE / 2, IMAGE_HANDLE, IMAGE_HANDLE)
            context.strokeRect(x - IMAGE_HANDLE / 2, y - IMAGE_HANDLE / 2, IMAGE_HANDLE, IMAGE_HANDLE)
          }
        }
      }
      context.restore()
    }
  }

  /** A cell picture, fitted inside its cell with its proportions kept. */
  const paintPicture = (context: CanvasRenderingContext2D, picture: ImageBitmap, area: CellBox) => {
    const padding = 2
    const scale = Math.min((area.width - padding * 2) / picture.width, (area.height - padding * 2) / picture.height)
    if (!(scale > 0)) return
    const width = picture.width * scale
    const height = picture.height * scale
    context.drawImage(picture, area.x + (area.width - width) / 2, area.y + (area.height - height) / 2, width, height)
  }

  /** The fill handle's centre: the bottom-right corner of the selection. */
  const fillHandle = (view: Layout) => {
    const rect = selectionRect(model.selection.peek())
    if (rect.r1 === MAX_ROWS - 1 && rect.c1 === MAX_COLS - 1) return undefined
    const area = box(view, rect)
    if (!shown(area)) return undefined
    return { x: area.x + area.width - 1, y: area.y + area.height - 1 }
  }

  /** Keeps the fill options button at the end of the last fill while it shows. */
  const placeFillOptions = (view: Layout) => {
    const element = fillOptions.current
    const current = filledRef.current
    if (!element) return
    const area = current && current.target ? box(view, current.target) : undefined
    if (!area || !shown(area)) {
      element.style.display = 'none'
      return
    }
    element.style.display = ''
    element.style.left = `${Math.min(area.x + area.width + 2, view.width - 32)}px`
    element.style.top = `${Math.min(area.y + area.height + 2, view.height - 28)}px`
  }

  const growExtent = (view: Layout) => {
    const current =
      extent.current.sheetID === view.info.sheet_id ? extent.current : { sheetID: view.info.sheet_id, rows: 0, cols: 0 }
    const rows = Math.min(MAX_ROWS, Math.max(current.rows, view.info.rows, view.lastRow + ROW_RUNWAY))
    const cols = Math.min(MAX_COLS, Math.max(current.cols, view.info.cols, view.lastCol + COL_RUNWAY))
    extent.current = { sheetID: view.info.sheet_id, rows, cols }
    if (spacer.current) {
      spacer.current.style.height = `${HEADER_HEIGHT + view.rows.offset(rows)}px`
      spacer.current.style.width = `${HEADER_WIDTH + view.cols.offset(cols)}px`
    }
  }

  const paintCells = (
    context: CanvasRenderingContext2D,
    view: Layout,
    tokens: Tokens,
    cached: Frame | undefined,
    rows: { from: number; to: number },
    cols: { from: number; to: number }
  ) => {
    const visibleRows: number[] = []
    const visibleCols: number[] = []
    for (let row = rows.from; row <= rows.to; row++) if (view.rows.size(row) > 0) visibleRows.push(row)
    for (let col = cols.from; col <= cols.to; col++) if (view.cols.size(col) > 0) visibleCols.push(col)
    const area: Rect = { r0: rows.from, c0: cols.from, r1: rows.to, c1: cols.to }
    const merges = (cached?.merges ?? []).filter(merge => intersect(merge, area))
    const merged = (row: number, col: number) => merges.find(merge => contains(merge, { row, col }))
    // Fills: whole-row and whole-column formats first, then cells.
    const left = view.colX(cols.from)
    const right = view.colX(cols.to) + view.cols.size(cols.to)
    const top = view.rowY(rows.from)
    const bottom = view.rowY(rows.to) + view.rows.size(rows.to)
    for (const row of visibleRows) {
      const fill = cached?.rowStyles.get(row)?.fill_color
      if (!fill) continue
      context.fillStyle = fill
      context.fillRect(left, view.rowY(row), right - left, view.rows.size(row))
    }
    for (const col of visibleCols) {
      const fill = cached?.colStyles.get(col)?.fill_color
      if (!fill) continue
      context.fillStyle = fill
      context.fillRect(view.colX(col), top, view.cols.size(col), bottom - top)
    }
    for (const row of visibleRows) {
      for (const col of visibleCols) {
        const fill = cached?.cells.get(cellKey(row, col))?.style.fill_color
        if (!fill || merged(row, col)) continue
        context.fillStyle = fill
        context.fillRect(view.colX(col), view.rowY(row), view.cols.size(col), view.rows.size(row))
      }
    }
    for (const row of visibleRows) {
      for (const col of visibleCols) {
        const bar = cached?.cells.get(cellKey(row, col))?.cell.cf?.bar
        if (!bar || merged(row, col)) continue
        const x = view.colX(col) + 1
        const y = view.rowY(row) + 2
        const width = Math.max(0, (view.cols.size(col) - 2) * bar.fraction)
        const height = Math.max(0, view.rows.size(row) - 4)
        if (bar.gradient) {
          const gradient = context.createLinearGradient(x, y, x + width, y)
          gradient.addColorStop(0, bar.color)
          gradient.addColorStop(1, `${bar.color}33`)
          context.fillStyle = gradient
        } else context.fillStyle = bar.color
        context.fillRect(x, y, width, height)
      }
    }
    if (view.info.show_gridlines) {
      context.strokeStyle = tokens.grid
      context.lineWidth = 1
      context.beginPath()
      for (const row of visibleRows) {
        const y = Math.round(view.rowY(row) + view.rows.size(row)) - 0.5
        context.moveTo(left, y)
        context.lineTo(right, y)
      }
      for (const col of visibleCols) {
        const x = Math.round(view.colX(col) + view.cols.size(col)) - 0.5
        context.moveTo(x, top)
        context.lineTo(x, bottom)
      }
      context.stroke()
    }
    for (const row of visibleRows) {
      for (const col of visibleCols) {
        const picture = cached?.cells.get(cellKey(row, col))?.cell.picture
        if (!picture || merged(row, col)) continue
        const decoded = bitmap(`cell:${picture}`, () => model.cellPicture(view.info.sheet_id, { row, col }))
        if (decoded) {
          paintPicture(context, decoded, {
            x: view.colX(col),
            y: view.rowY(row),
            width: view.cols.size(col),
            height: view.rows.size(row)
          })
        }
      }
    }
    for (const merge of merges) {
      const area = box(view, merge)
      if (!shown(area)) continue
      const anchor = cached?.cells.get(cellKey(merge.r0, merge.c0))
      context.fillStyle = anchor?.style.fill_color ?? tokens.background
      context.fillRect(area.x, area.y, area.width - 1, area.height - 1)
      if (anchor?.cell.text) paintText(context, tokens, anchor, area)
    }
    for (const row of visibleRows) {
      for (const col of visibleCols) {
        const entry = cached?.cells.get(cellKey(row, col))
        if (!entry?.cell.text || entry.cell.cf?.hide_value || merged(row, col)) continue
        const cellBox = {
          x: view.colX(col),
          y: view.rowY(row),
          width: view.cols.size(col),
          height: view.rows.size(row)
        }
        paintText(context, tokens, entry, overflow(view, cached!, entry, cellBox, cols, merged))
      }
    }
    if (cached) paintExtras(context, view, tokens, cached, visibleRows, visibleCols, merged)
    for (const row of visibleRows) {
      for (const col of visibleCols) {
        const style = cached?.cells.get(cellKey(row, col))?.style
        if (style) {
          paintBorders(context, style, view.colX(col), view.rowY(row), view.cols.size(col), view.rows.size(row))
        }
      }
    }
    context.strokeStyle = tokens.spill
    context.setLineDash([3, 2])
    for (const spill of cached?.spills ?? []) {
      const outline = intersect(spill, area) ? box(view, spill) : undefined
      if (outline && shown(outline)) {
        context.strokeRect(outline.x + 0.5, outline.y + 0.5, outline.width - 2, outline.height - 2)
      }
    }
    context.setLineDash([])
  }

  /** The box of the filter button in the header cell of column `col`, inside the cell's lower-right corner. */
  const filterButtonBox = (view: Layout, row: number, col: number): CellBox => {
    const width = view.cols.size(col)
    const height = view.rows.size(row)
    const size = Math.min(FILTER_BUTTON, Math.max(0, height - 2), Math.max(0, width - 2))
    return { x: view.colX(col) + width - size - 1, y: view.rowY(row) + height - size - 1, width: size, height: size }
  }

  /** The box of the dropdown arrow, which sits just right of a cell that offers a list. */
  const dropdownBox = (view: Layout, cell: CellAddress): CellBox => ({
    x: view.colX(cell.col) + view.cols.size(cell.col),
    y: view.rowY(cell.row),
    width: DROPDOWN_WIDTH,
    height: view.rows.size(cell.row)
  })

  const inside = (area: CellBox, x: number, y: number) =>
    x >= area.x && x <= area.x + area.width && y >= area.y && y <= area.y + area.height

  /** The list validation that covers `cell`, when its cells offer a dropdown. */
  const dropdownRule = (cell: CellAddress): RenderValidation | undefined =>
    frame.current?.validations.find(entry => entry.rule.dropdown && contains(entry.rect, cell))?.rule

  const paintTriangle = (context: CanvasRenderingContext2D, x: number, y: number, size: number, down: boolean) => {
    context.beginPath()
    if (down) {
      context.moveTo(x - size, y - size / 2)
      context.lineTo(x + size, y - size / 2)
      context.lineTo(x, y + size / 2)
    } else {
      context.moveTo(x - size, y + size / 2)
      context.lineTo(x + size, y + size / 2)
      context.lineTo(x, y - size / 2)
    }
    context.closePath()
    context.fill()
  }

  /** An icon from a conditional format's set, drawn from its rank colour and a shape by set family. */
  const paintIcon = (context: CanvasRenderingContext2D, set: string, index: number, area: CellBox) => {
    const count = Math.min(5, Math.max(3, Number(set[0]) || 3))
    const rank = index / Math.max(1, count - 1)
    const color = ICON_COLORS[rank < 0.34 ? 0 : rank < 0.67 ? 1 : 2]!
    const size = Math.min(12, area.height - 4)
    const x = area.x + 3 + size / 2
    const y = area.y + area.height / 2
    context.fillStyle = color
    if (set.includes('Arrows')) {
      if (rank < 0.34) paintTriangle(context, x, y, size / 2, true)
      else if (rank < 0.67) context.fillRect(x - size / 2, y - 1.5, size, 3)
      else paintTriangle(context, x, y, size / 2, false)
      return
    }
    if (set.includes('Flags')) {
      context.fillRect(x - size / 2, y - size / 2, 2, size)
      context.fillRect(x - size / 2, y - size / 2, size, size / 2)
      return
    }
    if (set.includes('Stars')) {
      context.beginPath()
      for (let point = 0; point < 10; point++) {
        const radius = point % 2 ? size / 4 : size / 2
        const angle = -Math.PI / 2 + (point * Math.PI) / 5
        context.lineTo(x + Math.cos(angle) * radius, y + Math.sin(angle) * radius)
      }
      context.closePath()
      context.fill()
      return
    }
    context.beginPath()
    context.arc(x, y, size / 2, 0, Math.PI * 2)
    context.fill()
    if (set.includes('Symbols')) {
      context.fillStyle = '#FFFFFF'
      context.font = `bold ${Math.round(size * 0.8)}px sans-serif`
      context.textAlign = 'center'
      context.textBaseline = 'middle'
      context.fillText(rank < 0.34 ? '✕' : rank < 0.67 ? '!' : '✓', x, y + 0.5)
    }
  }

  /** Icons, note marks, and filter buttons, over the cell text. */
  const paintExtras = (
    context: CanvasRenderingContext2D,
    view: Layout,
    tokens: Tokens,
    cached: Frame,
    visibleRows: number[],
    visibleCols: number[],
    merged: (row: number, col: number) => Rect | undefined
  ) => {
    for (const row of visibleRows) {
      for (const col of visibleCols) {
        const entry = cached.cells.get(cellKey(row, col))
        if (!entry || merged(row, col)) continue
        const area = { x: view.colX(col), y: view.rowY(row), width: view.cols.size(col), height: view.rows.size(row) }
        const icon = entry.cell.cf?.icon
        if (icon) paintIcon(context, icon.set, icon.index, area)
        if (entry.cell.note) {
          context.fillStyle = ICON_COLORS[0]!
          context.beginPath()
          context.moveTo(area.x + area.width - NOTE_MARK - 1, area.y)
          context.lineTo(area.x + area.width - 1, area.y)
          context.lineTo(area.x + area.width - 1, area.y + NOTE_MARK)
          context.closePath()
          context.fill()
        }
      }
    }
    const filter = cached.filter
    if (!filter || !visibleRows.includes(filter.range.r0)) return
    const filtered = new Set(filter.filter.columns.map(column => column.col))
    for (const col of visibleCols) {
      if (col < filter.range.c0 || col > filter.range.c1) continue
      const area = filterButtonBox(view, filter.range.r0, col)
      if (area.width < 6) continue
      const active = filtered.has(col)
      context.fillStyle = active ? tokens.focus : tokens.background
      context.fillRect(area.x, area.y, area.width, area.height)
      context.strokeStyle = active ? tokens.focus : tokens.divider
      context.lineWidth = 1
      context.strokeRect(area.x + 0.5, area.y + 0.5, area.width - 1, area.height - 1)
      context.fillStyle = active ? '#FFFFFF' : tokens.headerText
      paintTriangle(context, area.x + area.width / 2, area.y + area.height / 2, area.width / 4, true)
    }
  }

  /** The arrow beside the active cell when its validation offers a list. */
  const paintDropdownArrow = (context: CanvasRenderingContext2D, view: Layout, tokens: Tokens) => {
    const cell = model.selection.peek().anchor
    if (!model.editable.peek() || model.draft.peek() || !dropdownRule(cell)) return
    const area = dropdownBox(view, cell)
    if (area.x < HEADER_WIDTH || area.y < HEADER_HEIGHT || area.height <= 0) return
    context.fillStyle = tokens.background
    context.fillRect(area.x, area.y, area.width, area.height)
    context.strokeStyle = tokens.divider
    context.lineWidth = 1
    context.strokeRect(area.x + 0.5, area.y + 0.5, area.width - 1, area.height - 1)
    context.fillStyle = tokens.headerText
    paintTriangle(context, area.x + area.width / 2, area.y + area.height / 2, 3.5, true)
  }

  /** Left-aligned text runs into empty cells on its right, and right-aligned text into empty cells on its left. */
  const overflow = (
    view: Layout,
    cached: Frame,
    entry: FrameCell,
    cellBox: CellBox,
    cols: { from: number; to: number },
    merged: (row: number, col: number) => Rect | undefined
  ): CellBox & { clip?: CellBox } => {
    if (entry.style.wrap || entry.cell.kind !== 'text') return cellBox
    const align = alignment(entry.cell, entry.style)
    if (align === 'center') return cellBox
    const step = align === 'left' ? 1 : -1
    let col = entry.cell.col
    const free = (next: number) =>
      next >= cols.from &&
      next <= cols.to &&
      !cached.cells.get(cellKey(entry.cell.row, next))?.cell.text &&
      !merged(entry.cell.row, next)
    while (free(col + step)) col += step
    if (col === entry.cell.col) return cellBox
    const edge = view.colX(col) + (step > 0 ? view.cols.size(col) : 0)
    const clip =
      step > 0
        ? { ...cellBox, width: edge - cellBox.x }
        : { ...cellBox, x: edge, width: cellBox.x + cellBox.width - edge }
    return { ...cellBox, clip }
  }

  const paintText = (
    context: CanvasRenderingContext2D,
    tokens: Tokens,
    entry: FrameCell,
    area: CellBox & { clip?: CellBox }
  ) => {
    const { cell, style } = entry
    const { font, size } = cellFont(style, tokens.font)
    const clip = area.clip ?? area
    context.save()
    context.beginPath()
    context.rect(clip.x, clip.y, clip.width - 1, clip.height - 1)
    context.clip()
    context.font = font
    context.fillStyle = cell.color ?? style.font_color ?? tokens.text
    const align = alignment(cell, style)
    const indent = style.indent * 8
    const padding = 3
    const lineHeight = size * 1.25
    const lines = style.wrap
      ? wrapLines(context, cell.text, area.width - padding * 2 - indent)
      : [cell.text.replaceAll('\n', ' ')]
    const textHeight = lines.length * lineHeight
    const top =
      style.v_align === 'top'
        ? area.y + padding
        : style.v_align === 'center'
          ? area.y + (area.height - textHeight) / 2
          : area.y + area.height - padding - textHeight
    context.textBaseline = 'middle'
    context.textAlign = align
    const x =
      align === 'left'
        ? area.x + padding + indent
        : align === 'right'
          ? area.x + area.width - padding - indent
          : area.x + area.width / 2
    lines.forEach((line, index) => {
      const y = top + lineHeight * index + lineHeight / 2
      context.fillText(line, x, y)
      if (!style.underline && !style.strike) return
      const width = context.measureText(line).width
      const start = align === 'left' ? x : align === 'right' ? x - width : x - width / 2
      context.fillRect(start, style.underline ? y + size / 2 : y, width, 1)
      if (style.underline && style.strike) context.fillRect(start, y, width, 1)
    })
    context.restore()
  }

  const paintBorders = (
    context: CanvasRenderingContext2D,
    style: RenderStyle,
    x: number,
    y: number,
    width: number,
    height: number
  ) => {
    const sides = [
      [style.borders.top, x, y, x + width, y],
      [style.borders.bottom, x, y + height, x + width, y + height],
      [style.borders.left, x, y, x, y + height],
      [style.borders.right, x + width, y, x + width, y + height]
    ] as const
    for (const [border, x0, y0, x1, y1] of sides) {
      if (!border) continue
      context.strokeStyle = border.color ?? '#000000'
      context.lineWidth = borderWidths[border.style] ?? 1
      context.setLineDash(borderDashes[border.style] ?? [])
      context.beginPath()
      context.moveTo(Math.round(x0) - 0.5, Math.round(y0) - 0.5)
      context.lineTo(Math.round(x1) - 0.5, Math.round(y1) - 0.5)
      context.stroke()
    }
    context.setLineDash([])
  }

  const paintOverlays = (context: CanvasRenderingContext2D, view: Layout, tokens: Tokens) => {
    const style = getComputedStyle(container.current!)
    context.save()
    context.beginPath()
    context.rect(HEADER_WIDTH, HEADER_HEIGHT, view.width - HEADER_WIDTH, view.height - HEADER_HEIGHT)
    context.clip()
    for (const member of model.members.peek()) {
      const color = style.getPropertyValue(member.color).trim()
      for (const selected of member.selections) {
        const rect = selected.sheet_id === view.info.sheet_id ? presenceRect(selected) : undefined
        const area = rect && box(view, rect)
        if (!area || !shown(area)) continue
        context.strokeStyle = color
        context.lineWidth = 2
        context.strokeRect(area.x + 1, area.y + 1, area.width - 2, area.height - 2)
        context.font = `11px ${tokens.font}`
        const label = member.name
        const labelWidth = context.measureText(label).width + 8
        context.fillStyle = color
        context.fillRect(area.x, Math.max(HEADER_HEIGHT, area.y - 16), labelWidth, 16)
        context.fillStyle = '#ffffff'
        context.textAlign = 'left'
        context.textBaseline = 'middle'
        context.fillText(label, area.x + 4, Math.max(HEADER_HEIGHT, area.y - 16) + 8)
      }
    }
    // The references a formula draft names, each in its own colour.
    const editing = model.draft.peek()
    if (editing && isFormula(editing.text)) {
      formulaReferences(editing.text).forEach((reference, index) => {
        const here = reference.sheet
          ? reference.sheet.toLowerCase() === view.info.name.toLowerCase()
          : editing.sheetID === view.info.sheet_id
        const area = here ? box(view, reference.rect) : undefined
        if (!area || !shown(area)) return
        const color = style.getPropertyValue(REFERENCE_COLORS[index % REFERENCE_COLORS.length]!).trim()
        context.globalAlpha = 0.12
        context.fillStyle = color
        context.fillRect(area.x, area.y, area.width, area.height)
        context.globalAlpha = 1
        context.strokeStyle = color
        context.lineWidth = 2
        context.strokeRect(area.x + 1, area.y + 1, area.width - 2, area.height - 2)
      })
    }
    const source = model.copied.peek()
    const copiedArea = source?.sheetID === view.info.sheet_id ? box(view, source.rect) : undefined
    if (copiedArea && shown(copiedArea)) {
      context.strokeStyle = tokens.focus
      context.lineWidth = 2
      context.setLineDash([5, 3])
      context.strokeRect(copiedArea.x + 1, copiedArea.y + 1, copiedArea.width - 2, copiedArea.height - 2)
      context.setLineDash([])
    }
    const filling = drag.current?.kind === 'fill' ? drag.current.target : undefined
    const preview = filling && box(view, filling)
    if (preview && shown(preview)) {
      context.strokeStyle = tokens.headerText
      context.lineWidth = 1
      context.setLineDash([4, 3])
      context.strokeRect(preview.x + 0.5, preview.y + 0.5, preview.width - 1, preview.height - 1)
      context.setLineDash([])
    }
    const rect = selectionRect(model.selection.peek())
    const area = box(view, rect)
    const active = model.selection.peek().anchor
    const activeArea = box(
      view,
      mergedArea(active) ?? { r0: active.row, c0: active.col, r1: active.row, c1: active.col }
    )
    if (!shown(area)) {
      context.restore()
      return
    }
    context.globalAlpha = 0.45
    context.fillStyle = tokens.selection
    context.beginPath()
    context.rect(area.x, area.y, area.width, area.height)
    context.rect(activeArea.x, activeArea.y, activeArea.width, activeArea.height)
    context.fill('evenodd')
    context.globalAlpha = 1
    context.strokeStyle = tokens.focus
    context.lineWidth = 2
    context.strokeRect(area.x + 0.5, area.y + 0.5, area.width - 2, area.height - 2)
    const handle = model.editable.peek() && !editing && !selectedImageRef.current ? fillHandle(view) : undefined
    if (handle) {
      context.fillStyle = '#ffffff'
      context.fillRect(handle.x - FILL_HANDLE / 2 - 1, handle.y - FILL_HANDLE / 2 - 1, FILL_HANDLE + 2, FILL_HANDLE + 2)
      context.fillStyle = tokens.focus
      context.fillRect(handle.x - FILL_HANDLE / 2, handle.y - FILL_HANDLE / 2, FILL_HANDLE, FILL_HANDLE)
    }
    context.restore()
  }

  const mergedArea = (cell: CellAddress) => frame.current?.merges.find(merge => contains(merge, cell))

  const paintHeaders = (context: CanvasRenderingContext2D, view: Layout, tokens: Tokens) => {
    const rect = selectionRect(model.selection.peek())
    context.fillStyle = tokens.header
    context.fillRect(0, 0, view.width, HEADER_HEIGHT)
    context.fillRect(0, 0, HEADER_WIDTH, view.height)
    context.font = `12px ${tokens.font}`
    context.textAlign = 'center'
    context.textBaseline = 'middle'
    context.strokeStyle = tokens.grid
    context.lineWidth = 1
    const columnPass = (from: number, to: number, clipLeft: number) => {
      context.save()
      context.beginPath()
      context.rect(clipLeft, 0, view.width - clipLeft, HEADER_HEIGHT)
      context.clip()
      for (let col = from; col <= to; col++) {
        const width = view.cols.size(col)
        if (!width) continue
        const x = view.colX(col)
        context.fillStyle = col >= rect.c0 && col <= rect.c1 ? tokens.headerActive : tokens.header
        context.fillRect(x, 0, width, HEADER_HEIGHT)
        context.fillStyle = tokens.headerText
        context.fillText(columnName(col), x + width / 2, HEADER_HEIGHT / 2)
        context.beginPath()
        context.moveTo(Math.round(x + width) - 0.5, 0)
        context.lineTo(Math.round(x + width) - 0.5, HEADER_HEIGHT)
        context.stroke()
      }
      context.restore()
    }
    const rowPass = (from: number, to: number, clipTop: number) => {
      context.save()
      context.beginPath()
      context.rect(0, clipTop, HEADER_WIDTH, view.height - clipTop)
      context.clip()
      for (let row = from; row <= to; row++) {
        const height = view.rows.size(row)
        if (!height) continue
        const y = view.rowY(row)
        context.fillStyle = row >= rect.r0 && row <= rect.r1 ? tokens.headerActive : tokens.header
        context.fillRect(0, y, HEADER_WIDTH, height)
        context.fillStyle = tokens.headerText
        context.fillText(String(row + 1), HEADER_WIDTH / 2, y + height / 2)
        context.beginPath()
        context.moveTo(0, Math.round(y + height) - 0.5)
        context.lineTo(HEADER_WIDTH, Math.round(y + height) - 0.5)
        context.stroke()
      }
      context.restore()
    }
    columnPass(view.firstCol, view.lastCol, HEADER_WIDTH + view.frozenWidth)
    columnPass(0, view.frozenCols - 1, HEADER_WIDTH)
    rowPass(view.firstRow, view.lastRow, HEADER_HEIGHT + view.frozenHeight)
    rowPass(0, view.frozenRows - 1, HEADER_HEIGHT)
    context.strokeStyle = tokens.divider
    context.beginPath()
    context.moveTo(0, HEADER_HEIGHT - 0.5)
    context.lineTo(view.width, HEADER_HEIGHT - 0.5)
    context.moveTo(HEADER_WIDTH - 0.5, 0)
    context.lineTo(HEADER_WIDTH - 0.5, view.height)
    context.stroke()
    // Frozen panes end at a heavier line, so the boundary stays visible while the rest scrolls.
    context.lineWidth = 2
    context.beginPath()
    if (view.frozenRows) {
      const y = HEADER_HEIGHT + view.frozenHeight - 1
      context.moveTo(0, y)
      context.lineTo(view.width, y)
    }
    if (view.frozenCols) {
      const x = HEADER_WIDTH + view.frozenWidth - 1
      context.moveTo(x, 0)
      context.lineTo(x, view.height)
    }
    context.stroke()
    context.lineWidth = 1
    const resizing = drag.current?.kind === 'resize' ? drag.current : undefined
    if (resizing) {
      context.strokeStyle = tokens.focus
      context.beginPath()
      if (resizing.axis === 'cols') {
        const x = view.colX(resizing.index) + resizing.current
        context.moveTo(x, 0)
        context.lineTo(x, view.height)
      } else {
        const y = view.rowY(resizing.index) + resizing.current
        context.moveTo(0, y)
        context.lineTo(view.width, y)
      }
      context.stroke()
    }
  }

  /** Keeps the cell editor over the active cell, with the cell's font and fill. */
  const placeEditor = (view: Layout, cached: Frame | undefined) => {
    const element = input.current
    if (!element) return
    const current = model.draft.peek()
    const cell = current?.cell ?? model.selection.peek().anchor
    const area = box(view, mergedArea(cell) ?? { r0: cell.row, c0: cell.col, r1: cell.row, c1: cell.col })
    const style = cached?.cells.get(cellKey(cell.row, cell.col))?.style
    const tokens = readTokens(container.current!)
    element.style.left = `${area.x}px`
    element.style.top = `${area.y}px`
    element.style.minWidth = `${Math.max(area.width, 24)}px`
    element.style.minHeight = `${Math.max(area.height, 18)}px`
    element.style.maxWidth = `${Math.max(view.width - area.x, 80)}px`
    element.style.font = cellFont(style, tokens.font).font
    element.style.color = style?.font_color ?? tokens.text
    element.style.background = style?.fill_color ?? tokens.background
  }

  const hitTest = (x: number, y: number): Hit | undefined => {
    const view = layout()
    if (!view) return undefined
    if (x < HEADER_WIDTH && y < HEADER_HEIGHT) return { kind: 'corner' }
    if (y < HEADER_HEIGHT) {
      const col = view.colAt(x)
      const start = view.colX(col)
      const end = start + view.cols.size(col)
      const resize = end - x <= RESIZE_SLOP ? col : x - start <= RESIZE_SLOP && col > 0 ? col - 1 : undefined
      return { kind: 'cols', col, resize }
    }
    if (x < HEADER_WIDTH) {
      const row = view.rowAt(y)
      const start = view.rowY(row)
      const end = start + view.rows.size(row)
      const resize = end - y <= RESIZE_SLOP ? row : y - start <= RESIZE_SLOP && row > 0 ? row - 1 : undefined
      return { kind: 'rows', row, resize }
    }
    const list = images.current?.sheetID === view.info.sheet_id ? images.current.list : []
    const selected = selectedImageRef.current
    if (selected && model.editable.peek()) {
      const area = imageBox(view, selected)
      const corner = imageCorners(area).find(
        ([, cx, cy]) => Math.abs(cx - x) <= IMAGE_HANDLE && Math.abs(cy - y) <= IMAGE_HANDLE
      )
      if (corner) return { kind: 'image', image: selected, corner: corner[0] }
    }
    // The picture painted last is on top, so it takes the press.
    for (const image of [...list].reverse()) {
      const area = imageBox(view, image)
      if (x >= area.x && x <= area.x + area.width && y >= area.y && y <= area.y + area.height) {
        return { kind: 'image', image }
      }
    }
    const filter = frame.current?.sheetID === view.info.sheet_id ? frame.current.filter : undefined
    if (filter) {
      const col = view.colAt(x)
      if (col >= filter.range.c0 && col <= filter.range.c1 && view.rowAt(y) === filter.range.r0) {
        const area = filterButtonBox(view, filter.range.r0, col)
        if (inside(area, x, y)) return { kind: 'filter', col, box: area }
      }
    }
    if (model.editable.peek() && !model.draft.peek()) {
      const anchor = model.selection.peek().anchor
      const rule = dropdownRule(anchor)
      const area = rule && dropdownBox(view, anchor)
      if (rule && area && inside(area, x, y)) return { kind: 'dropdown', cell: anchor, box: area, rule }
    }
    const handle = model.editable.peek() && !model.draft.peek() && !selected ? fillHandle(view) : undefined
    if (
      handle &&
      Math.abs(handle.x - x) <= FILL_HANDLE / 2 + HANDLE_SLOP &&
      Math.abs(handle.y - y) <= FILL_HANDLE / 2 + HANDLE_SLOP
    ) {
      return { kind: 'fill' }
    }
    return { kind: 'cell', cell: { row: view.rowAt(y), col: view.colAt(x) } }
  }

  /** The formula input that holds the caret, when a formula draft is open there. */
  const formulaInput = (): HTMLTextAreaElement | HTMLInputElement | undefined => {
    const active = document.activeElement
    if (active === input.current) return input.current ?? undefined
    return active instanceof HTMLInputElement && active.hasAttribute(FORMULA_BAR_ATTRIBUTE) ? active : undefined
  }

  /**
   * Pointing: while a formula waits for an operand, a press on a cell types its reference into the
   * draft, and dragging widens it to a range. A press right after a pointed reference replaces it.
   */
  const pointAt = (cell: CellAddress, extend: boolean): boolean => {
    const editing = model.draft.peek()
    const field = formulaInput()
    const view = layout()
    if (!editing || !field || !view || !isFormula(editing.text)) return false
    const caret = field.selectionStart ?? editing.text.length
    const last = pointed.current?.end === caret ? pointed.current : undefined
    if (!last && !acceptsReference(editing.text, caret)) return false
    const anchor = extend && last ? last.anchor : cell
    const rect = {
      r0: Math.min(anchor.row, cell.row),
      c0: Math.min(anchor.col, cell.col),
      r1: Math.max(anchor.row, cell.row),
      c1: Math.max(anchor.col, cell.col)
    }
    const sheet = editing.sheetID === view.info.sheet_id ? undefined : view.info.name
    const start = last ? last.start : caret
    const next = splice(editing.text, start, last ? last.end : caret, referenceText(rect, sheet))
    pointed.current = { start, end: next.caret, anchor }
    model.type(next.text, next.caret)
    field.focus({ preventScroll: true })
    return true
  }

  const local = (event: { clientX: number; clientY: number }) => {
    const bounds = scroller.current!.getBoundingClientRect()
    return { x: event.clientX - bounds.left, y: event.clientY - bounds.top }
  }

  const selectLines = (axis: 'rows' | 'cols', from: number, to: number) => {
    model.select(
      axis === 'rows'
        ? { anchor: { row: from, col: 0 }, focus: { row: to, col: MAX_COLS - 1 } }
        : { anchor: { row: 0, col: from }, focus: { row: MAX_ROWS - 1, col: to } }
    )
  }

  const onPointerDown = (event: PointerEvent<HTMLDivElement>) => {
    if (event.button !== 0) return
    const { x, y } = local(event)
    if (x > scroller.current!.clientWidth || y > scroller.current!.clientHeight) return
    const hit = hitTest(x, y)
    if (!hit) return
    event.preventDefault()
    if (hit.kind === 'cell' && pointAt(hit.cell, event.shiftKey)) {
      drag.current = { kind: 'point', anchor: pointed.current!.anchor }
      scroller.current!.setPointerCapture(event.pointerId)
      return
    }
    pointed.current = undefined
    if (model.draft.peek()) void model.commitEdit()
    input.current?.focus({ preventScroll: true })
    showFillOptions(undefined)
    const view = layout()!
    if (hit.kind === 'filter') {
      const col = hit.col
      setFilterMenu({ col, box: hit.box })
      void model.filterValues(col).then(values => {
        setFilterMenu(menu => (menu && menu.col === col ? { ...menu, values: values ?? [] } : menu))
      })
      return
    }
    if (hit.kind === 'dropdown') {
      setDropdown({ cell: hit.cell, box: hit.box, rule: hit.rule })
      return
    }
    if (hit.kind === 'image') {
      selectImage(hit.image)
      if (model.editable.peek()) {
        const area = imageBox(view, hit.image)
        drag.current = {
          kind: 'image',
          image: hit.image,
          corner: hit.corner,
          origin: { x, y },
          start: area,
          current: area
        }
        scroller.current!.setPointerCapture(event.pointerId)
      }
      requestPaint()
      return
    }
    selectImage(undefined)
    if (hit.kind === 'fill') {
      drag.current = { kind: 'fill', source: selectionRect(model.selection.peek()) }
      scroller.current!.setPointerCapture(event.pointerId)
    } else if (hit.kind === 'corner') {
      model.select({ anchor: { row: 0, col: 0 }, focus: { row: MAX_ROWS - 1, col: MAX_COLS - 1 } })
    } else if ((hit.kind === 'cols' || hit.kind === 'rows') && hit.resize !== undefined && editable) {
      const axis = hit.kind
      const size = axis === 'cols' ? view.cols.size(hit.resize) : view.rows.size(hit.resize)
      drag.current = { kind: 'resize', axis, index: hit.resize, origin: axis === 'cols' ? x : y, size, current: size }
      scroller.current!.setPointerCapture(event.pointerId)
    } else if (hit.kind === 'cols' || hit.kind === 'rows') {
      const index = hit.kind === 'cols' ? hit.col : hit.row
      const current = selectionRect(model.selection.peek())
      const anchor = event.shiftKey ? (hit.kind === 'cols' ? current.c0 : current.r0) : index
      selectLines(hit.kind, anchor, index)
      drag.current = {
        kind: 'select',
        lines: hit.kind,
        anchor: hit.kind === 'cols' ? { row: 0, col: anchor } : { row: anchor, col: 0 }
      }
      scroller.current!.setPointerCapture(event.pointerId)
    } else if (hit.kind === 'cell') {
      const anchor = event.shiftKey ? model.selection.peek().anchor : hit.cell
      model.select({ anchor, focus: hit.cell })
      drag.current = { kind: 'select', anchor }
      scroller.current!.setPointerCapture(event.pointerId)
    }
    requestPaint()
  }

  /** The note of the cell under the pointer, or the message its validation shows. */
  const tooltipFor = (hit: Hit): string => {
    if (hit.kind === 'filter') return t('pod.spreadsheet.filter_button', { column: columnName(hit.col) })
    if (hit.kind !== 'cell') return ''
    const note = frame.current?.cells.get(cellKey(hit.cell.row, hit.cell.col))?.cell.note
    if (note) return note
    const rule = frame.current?.validations.find(entry => contains(entry.rect, hit.cell))?.rule
    if (!rule?.input_message) return ''
    return rule.input_title ? `${rule.input_title}\n${rule.input_message}` : rule.input_message
  }

  const cursorFor = (hit: Hit | undefined) => {
    if (!hit) return 'default'
    if (hit.kind === 'image') {
      if (!editable) return 'pointer'
      return hit.corner === 'nw' || hit.corner === 'se' ? 'nwse-resize' : hit.corner ? 'nesw-resize' : 'move'
    }
    if (hit.kind === 'fill') return 'crosshair'
    if (hit.kind === 'filter' || hit.kind === 'dropdown') return 'pointer'
    if (editable && hit.kind === 'cols' && hit.resize !== undefined) return 'col-resize'
    if (editable && hit.kind === 'rows' && hit.resize !== undefined) return 'row-resize'
    if (hit.kind === 'cell') return model.painter.peek() ? 'copy' : 'cell'
    return 'default'
  }

  /** The box a picture takes while a corner drags; the corner keeps the picture's proportions. */
  const resized = (start: CellBox, corner: Corner, dx: number, dy: number): CellBox => {
    const ratio = start.height / Math.max(start.width, 1)
    const grow =
      corner === 'se'
        ? Math.max(dx, dy / ratio)
        : corner === 'nw'
          ? Math.max(-dx, -dy / ratio)
          : corner === 'ne'
            ? Math.max(dx, -dy / ratio)
            : Math.max(-dx, dy / ratio)
    const width = Math.max(MIN_IMAGE_SIZE, start.width + grow)
    const height = Math.max(MIN_IMAGE_SIZE, width * ratio)
    return {
      x: corner === 'nw' || corner === 'sw' ? start.x + start.width - width : start.x,
      y: corner === 'nw' || corner === 'ne' ? start.y + start.height - height : start.y,
      width,
      height
    }
  }

  const onPointerMove = (event: PointerEvent<HTMLDivElement>) => {
    const { x, y } = local(event)
    const current = drag.current
    if (!current) {
      const hit = hitTest(x, y)
      scroller.current!.style.cursor = cursorFor(hit)
      scroller.current!.title = hit ? tooltipFor(hit) : ''
      return
    }
    if (current.kind === 'resize') {
      current.current = Math.max(4, current.size + (current.axis === 'cols' ? x : y) - current.origin)
      requestPaint()
      return
    }
    if (current.kind === 'image') {
      const dx = x - current.origin.x
      const dy = y - current.origin.y
      current.current = current.corner
        ? resized(current.start, current.corner, dx, dy)
        : { ...current.start, x: current.start.x + dx, y: current.start.y + dy }
      requestPaint()
      return
    }
    const view = layout()
    if (!view) return
    const cell = clampCell({ row: view.rowAt(Math.max(y, HEADER_HEIGHT)), col: view.colAt(Math.max(x, HEADER_WIDTH)) })
    if (current.kind === 'point') {
      pointAt(cell, true)
      requestPaint()
      return
    }
    if (current.kind === 'fill') {
      current.target = fillTarget(current.source, cell)
      requestPaint()
      return
    }
    if (current.lines === 'rows') selectLines('rows', current.anchor.row, cell.row)
    else if (current.lines === 'cols') selectLines('cols', current.anchor.col, cell.col)
    else model.select({ anchor: current.anchor, focus: cell })
  }

  const onPointerUp = (event: PointerEvent<HTMLDivElement>) => {
    const current = drag.current
    drag.current = undefined
    if (scroller.current?.hasPointerCapture(event.pointerId)) scroller.current.releasePointerCapture(event.pointerId)
    if (current?.kind === 'select' && model.painter.peek()) {
      void model.paintFormats(selectionRect(model.selection.peek()))
      return
    }
    if (current?.kind === 'fill') {
      if (current.target) {
        const filled = { source: current.source, target: current.target }
        model.select({
          anchor: { row: filled.target.r0, col: filled.target.c0 },
          focus: { row: filled.target.r1, col: filled.target.c1 }
        })
        void model.fill(filled.source, filled.target, 'series').then(applied => {
          if (applied) showFillOptions(filled)
        })
      }
      requestPaint()
      return
    }
    if (current?.kind === 'image') {
      const view = layout()
      const moved =
        current.current.x !== current.start.x ||
        current.current.y !== current.start.y ||
        current.current.width !== current.start.width
      if (view && moved) void model.updateImage(current.image.image_id, anchorAt(view, current.current))
      requestPaint()
      return
    }
    if (current?.kind !== 'resize') return
    const rect = selectionRect(model.selection.peek())
    const lines = selectedLines(rect, current.axis, model.selection.peek().anchor)
    const whole =
      current.axis === 'cols' ? rect.r0 === 0 && rect.r1 === MAX_ROWS - 1 : rect.c0 === 0 && rect.c1 === MAX_COLS - 1
    const spans = whole && current.index >= lines.start && current.index <= lines.end
    if (Math.round(current.current) !== Math.round(current.size)) {
      void model.perform({
        type: 'line.resize',
        sheet_id: model.activeSheetID.peek(),
        axis: current.axis,
        start: spans ? lines.start : current.index,
        end: spans ? lines.end : current.index,
        size_px: Math.round(current.current)
      })
    }
    requestPaint()
  }

  /**
   * Double-clicking the fill handle fills down as far as the data next to the selection reaches,
   * in the column on its left or else on its right.
   */
  const fillDown = async () => {
    const rect = selectionRect(model.selection.peek())
    const neighbours = [rect.c0 - 1, rect.c1 + 1].filter(col => col >= 0 && col < MAX_COLS)
    for (const col of neighbours) {
      const below = await model.viewport(model.activeSheetID.peek(), {
        r0: rect.r1 + 1,
        c0: col,
        r1: rect.r1 + 1,
        c1: col
      })
      if (!below?.cells.some(cell => cell.text !== '')) continue
      const edge = await model.dataEdge({ row: rect.r1 + 1, col }, 'down')
      const target = { ...rect, r1: edge.row }
      model.select({ anchor: { row: rect.r0, col: rect.c0 }, focus: { row: target.r1, col: rect.c1 } })
      const applied = await model.fill(rect, target, 'series')
      if (applied) showFillOptions({ source: rect, target })
      return
    }
    toast.info(t('pod.spreadsheet.fill_range_unknown'))
  }

  /** Re-fills the last fill in another mode; formats only first restores the values the fill replaced. */
  const refill = async (mode: FillMode) => {
    const last = filledRef.current
    if (!last) return
    if (mode === 'formats') await model.undo()
    await model.fill(last.source, last.target, mode)
  }

  /** Shows a picture full size in a dialog. */
  const openViewer = async (load: () => Promise<Uint8Array | undefined>, alt: string) => {
    const bytes = await load()
    if (!bytes) return
    setViewing({ url: URL.createObjectURL(new Blob([bytes as BlobPart], { type: pictureType(bytes) })), alt })
  }

  /** A cell picture lifted out of its cell keeps its own size, up to 400 pixels. */
  const liftPicture = async (cell: CellAddress) => {
    const bytes = await model.cellPicture(model.activeSheetID.peek(), cell)
    if (!bytes) return
    const decoded = await createImageBitmap(new Blob([bytes as BlobPart], { type: pictureType(bytes) }))
    const size = displaySize(decoded.width, decoded.height)
    decoded.close()
    await model.imageFromCell(cell, { cell: cellName(cell), dx: 0, dy: 0, ...size })
  }

  const startEditing = async (cell: CellAddress) => {
    if (!model.editable.peek()) return
    const inputs = await model.cellInputs(model.activeSheetID.peek(), {
      r0: cell.row,
      c0: cell.col,
      r1: cell.row,
      c1: cell.col
    })
    model.edit(cell, inputs?.[0]?.[0] ?? '')
    input.current?.focus({ preventScroll: true })
  }

  const scrollTo = (cell: CellAddress) => {
    const view = layout()
    const element = scroller.current
    if (!view || !element) return
    if (cell.row >= view.frozenRows) {
      const top = view.rows.offset(cell.row) - view.frozenHeight
      const bottom = top + view.rows.size(cell.row)
      const visible = view.height - HEADER_HEIGHT - view.frozenHeight
      if (top < element.scrollTop) element.scrollTop = top
      else if (bottom > element.scrollTop + visible) element.scrollTop = bottom - visible
    }
    if (cell.col >= view.frozenCols) {
      const left = view.cols.offset(cell.col) - view.frozenWidth
      const right = left + view.cols.size(cell.col)
      const visible = view.width - HEADER_WIDTH - view.frozenWidth
      if (left < element.scrollLeft) element.scrollLeft = left
      else if (right > element.scrollLeft + visible) element.scrollLeft = right - visible
    }
  }

  const moveTo = (cell: CellAddress, extend: boolean) => {
    const target = clampCell(cell)
    model.select(extend ? { anchor: model.selection.peek().anchor, focus: target } : cellSelection(target))
    scrollTo(target)
  }

  /** Keyboard navigation and commands while no cell is being edited. Returns whether it handled the key. */
  const navigate = (event: KeyboardEvent<HTMLTextAreaElement>): boolean => {
    const view = layout()
    if (!view) return false
    const command = event.metaKey || event.ctrlKey
    const { anchor, focus } = model.selection.peek()
    const from = event.shiftKey ? focus : anchor
    const page = Math.max(1, view.lastRow - view.firstRow)
    const arrows: Record<string, Direction> = {
      ArrowUp: 'up',
      ArrowDown: 'down',
      ArrowLeft: 'left',
      ArrowRight: 'right'
    }
    const direction = arrows[event.key]
    // Moving the selection leaves a selected picture, so Delete then clears cells, not the picture.
    if (selectedImageRef.current && !['Delete', 'Backspace', 'Escape'].includes(event.key)) selectImage(undefined)
    if (direction) {
      if (command) {
        void model.dataEdge(from, direction).then(cell => moveTo(cell, event.shiftKey))
      } else {
        const [rows, cols] = { up: [-1, 0], down: [1, 0], left: [0, -1], right: [0, 1] }[direction]
        moveTo({ row: from.row + rows!, col: from.col + cols! }, event.shiftKey)
      }
      return true
    }
    switch (event.key) {
      case 'Tab':
        moveTo({ row: anchor.row, col: anchor.col + (event.shiftKey ? -1 : 1) }, false)
        return true
      case 'Enter':
        moveTo({ row: anchor.row + (event.shiftKey ? -1 : 1), col: anchor.col }, false)
        return true
      case 'Home':
        moveTo(command ? { row: 0, col: 0 } : { row: from.row, col: 0 }, event.shiftKey)
        return true
      case 'End':
        moveTo(
          command
            ? { row: Math.max(view.info.rows - 1, 0), col: Math.max(view.info.cols - 1, 0) }
            : { row: from.row, col: Math.max(view.info.cols - 1, 0) },
          event.shiftKey
        )
        return true
      case 'PageDown':
        moveTo({ row: from.row + page, col: from.col }, event.shiftKey)
        return true
      case 'PageUp':
        moveTo({ row: from.row - page, col: from.col }, event.shiftKey)
        return true
      case 'Delete':
      case 'Backspace': {
        const image = selectedImageRef.current
        if (image && model.editable.peek()) {
          selectImage(undefined)
          void model.deleteImage(image.image_id)
        } else if (model.editable.peek()) void model.clearContents()
        return true
      }
      case 'F2':
        void startEditing(anchor)
        return true
      case 'Escape':
        if (selectedImageRef.current) selectImage(undefined)
        else model.clearCopied()
        showFillOptions(undefined)
        requestPaint()
        return true
    }
    if (!command) return false
    const key = event.key.toLowerCase()
    if (key === 'f' || key === 'h') {
      onFind(key === 'f' ? 'find' : 'replace')
      return true
    }
    if (model.editable.peek() && (key === 'd' || key === 'r')) {
      void model.fillSelection(key === 'd' ? 'down' : 'right')
      return true
    }
    if (model.editable.peek() && key === '\\') {
      void model.clear('formats')
      return true
    }
    if (model.editable.peek() && event.code === 'KeyV' && event.altKey) {
      void pasteFromClipboard(model, pageID, 'formats')
      return true
    }
    if (key === 'a') {
      model.select({ anchor: { row: 0, col: 0 }, focus: { row: MAX_ROWS - 1, col: MAX_COLS - 1 } })
      return true
    }
    if ((key === 'z' && event.shiftKey) || key === 'y') {
      void model.redo()
      return true
    }
    if (key === 'z') {
      void model.undo()
      return true
    }
    return false
  }

  /** Inserts as many lines as the selection covers, before or after it, or deletes the selected lines. */
  const lineAction = (axis: 'rows' | 'cols', type: 'line.insert' | 'line.delete', after = false) => {
    const lines = selectedLines(selectionRect(model.selection.peek()), axis, model.selection.peek().anchor)
    void model.perform({
      type,
      sheet_id: model.activeSheetID.peek(),
      axis,
      at: type === 'line.insert' && after ? lines.end + 1 : lines.start,
      count: lines.end - lines.start + 1
    })
  }

  const resizeAction = (axis: 'rows' | 'cols', size: 'hidden' | 'unhide' | 'auto') => {
    const lines = selectedLines(selectionRect(model.selection.peek()), axis, model.selection.peek().anchor)
    void model.perform({ type: 'line.resize', sheet_id: model.activeSheetID.peek(), axis, ...lines, size_px: size })
  }

  useEffect(() => {
    requestPaint()
  }, [sheet, version, selection, members, draft, editable, copied, painter, selectedImage, filled])

  // Any other change of the selection or the document ends the offer to fill differently.
  useEffect(() => {
    const last = filledRef.current
    if (!last) return
    const rect = selectionRect(selection)
    if (
      rect.r0 !== last.target.r0 ||
      rect.c0 !== last.target.c0 ||
      rect.r1 !== last.target.r1 ||
      rect.c1 !== last.target.c1
    ) {
      showFillOptions(undefined)
    }
  }, [selection])

  useEffect(() => {
    selectImage(undefined)
    showFillOptions(undefined)
  }, [sheetID])

  useEffect(
    () => () => {
      for (const decoded of bitmaps.current.values()) decoded?.close()
      bitmaps.current.clear()
    },
    []
  )

  useEffect(() => {
    const element = container.current
    if (!element) return
    const observer = new ResizeObserver(() => requestPaint())
    observer.observe(element)
    return () => {
      observer.disconnect()
      cancelAnimationFrame(scheduled.current)
      scheduled.current = 0
    }
  }, [])

  useEffect(() => {
    frame.current = undefined
    scroller.current?.scrollTo({ top: 0, left: 0 })
  }, [sheetID])

  const activePicture = () => {
    const anchor = model.selection.peek().anchor
    return frame.current?.cells.get(cellKey(anchor.row, anchor.col))?.cell.picture ? anchor : undefined
  }

  /** The actions of the picture the context menu opened on: a floating one, or the active cell's. */
  const pictureActions = () => {
    const sheet = model.activeSheetID.peek()
    if (menu === 'image' && selectedImage) {
      const image = selectedImage
      return {
        convert: () => {
          selectImage(undefined)
          void model.imageToCell(image.image_id, anchorCell(image))
        },
        view: () => void openViewer(() => model.imageData(sheet, image.image_id), image.alt),
        download: () =>
          void model
            .imageData(sheet, image.image_id)
            .then(bytes => bytes && downloadPicture(bytes, image.alt || t('pod.spreadsheet.picture'))),
        remove: () => {
          selectImage(undefined)
          void model.deleteImage(image.image_id)
        }
      }
    }
    const cell = menu === 'picture' ? activePicture() : undefined
    if (!cell) return undefined
    return {
      convert: () => void liftPicture(cell),
      view: () => void openViewer(() => model.cellPicture(sheet, cell), cellName(cell)),
      download: () =>
        void model.cellPicture(sheet, cell).then(bytes => bytes && downloadPicture(bytes, cellName(cell))),
      remove: () => void model.setCellPicture(cell, null)
    }
  }

  return (
    <div ref={container} className="relative min-h-0 flex-1 overflow-hidden">
      <ContextMenu disabled={!editable}>
        <ContextMenuTrigger
          ref={scroller}
          role="grid"
          aria-label={t('pod.spreadsheet.grid_label', { sheet: sheet?.name ?? '' })}
          className="absolute inset-0 overflow-auto outline-none select-none"
          onScroll={requestPaint}
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
          onPointerCancel={onPointerUp}
          onDoubleClick={event => {
            const { x, y } = local(event)
            const hit = hitTest(x, y)
            if (hit?.kind === 'fill') void fillDown()
            else if (hit?.kind === 'image') {
              void openViewer(() => model.imageData(model.activeSheetID.peek(), hit.image.image_id), hit.image.alt)
            } else if (hit?.kind === 'cell') void startEditing(hit.cell)
          }}
          onDragOver={event => {
            if (editable && [...event.dataTransfer.items].some(item => item.type.startsWith('image/'))) {
              event.preventDefault()
              event.dataTransfer.dropEffect = 'copy'
            }
          }}
          onDrop={event => {
            const file = [...event.dataTransfer.files].find(item => item.type.startsWith('image/'))
            if (!file || !editable) return
            event.preventDefault()
            const { x, y } = local(event)
            const hit = hitTest(x, y)
            if (hit?.kind === 'cell') model.select(cellSelection(hit.cell))
            void insertPicture(model, file, 'cell')
          }}
          onContextMenuCapture={event => {
            const { x, y } = local(event)
            const hit = hitTest(x, y)
            const rect = selectionRect(model.selection.peek())
            if (hit?.kind === 'image') {
              selectImage(hit.image)
              setMenu('image')
              return
            }
            selectImage(undefined)
            if (hit?.kind === 'rows') {
              if (hit.row < rect.r0 || hit.row > rect.r1 || rect.c1 !== MAX_COLS - 1) {
                selectLines('rows', hit.row, hit.row)
              }
              setMenu('rows')
            } else if (hit?.kind === 'cols') {
              if (hit.col < rect.c0 || hit.col > rect.c1 || rect.r1 !== MAX_ROWS - 1) {
                selectLines('cols', hit.col, hit.col)
              }
              setMenu('cols')
            } else {
              if (hit?.kind === 'cell' && !contains(rect, hit.cell)) model.select(cellSelection(hit.cell))
              setMenu(activePicture() ? 'picture' : 'cells')
            }
          }}>
          <div ref={spacer} aria-hidden />
        </ContextMenuTrigger>
        <ContextMenuContent aria-label={t('pod.spreadsheet.cell_actions')} className="min-w-52">
          <SpreadsheetCellMenu
            kind={menu}
            model={model}
            pageID={pageID}
            onLines={lineAction}
            onResize={resizeAction}
            picture={pictureActions()}
          />
        </ContextMenuContent>
      </ContextMenu>
      <canvas ref={canvas} aria-hidden className="pointer-events-none absolute top-0 left-0" />
      <SpreadsheetCellEditor model={model} pageID={pageID} inputRef={input} navigate={navigate} />
      {filterMenu && (
        <div
          className="absolute z-10"
          style={{ left: filterMenu.box.x, top: filterMenu.box.y + filterMenu.box.height }}>
          <Popover
            open
            onOpenChange={open => {
              if (!open) setFilterMenu(undefined)
            }}>
            <PopoverTrigger
              render={<button type="button" aria-hidden tabIndex={-1} className="block size-px opacity-0" />}
            />
            <PopoverContent align="start" className="w-auto p-3">
              <SpreadsheetFilterPopover
                column={columnName(filterMenu.col)}
                values={filterMenu.values}
                onApply={criterion => {
                  const filter = frame.current?.filter
                  if (filter) {
                    void model.perform({
                      type: 'filter.set',
                      sheet_id: model.activeSheetID.peek(),
                      range: filter.filter.range,
                      columns: filterColumnsWith(filter.filter, filterMenu.col, criterion)
                    })
                  }
                  setFilterMenu(undefined)
                  input.current?.focus({ preventScroll: true })
                }}
                onClose={() => setFilterMenu(undefined)}
              />
            </PopoverContent>
          </Popover>
        </div>
      )}
      {dropdown && (
        <div className="absolute z-10" style={{ left: dropdown.box.x, top: dropdown.box.y + dropdown.box.height }}>
          <Popover
            open
            onOpenChange={open => {
              if (!open) setDropdown(undefined)
            }}>
            <PopoverTrigger
              render={<button type="button" aria-hidden tabIndex={-1} className="block size-px opacity-0" />}
            />
            <PopoverContent align="end" className="w-56 gap-1 p-2">
              <PopoverTitle className="px-2">
                {t('pod.spreadsheet.validation_dropdown', { cell: cellName(dropdown.cell) })}
              </PopoverTitle>
              <div className="max-h-56 overflow-y-auto">
                {dropdown.rule.items.map(item => (
                  <button
                    key={item}
                    type="button"
                    className="block w-full truncate rounded-control px-2 py-1 text-left text-sm hover:bg-background-secondary focus-visible:outline-offset-1"
                    onClick={() => {
                      void model.setCell(dropdown.cell, item)
                      setDropdown(undefined)
                      input.current?.focus({ preventScroll: true })
                    }}>
                    {item}
                  </button>
                ))}
              </div>
            </PopoverContent>
          </Popover>
        </div>
      )}
      <div ref={fillOptions} className="absolute z-10" style={{ display: 'none' }}>
        {filled && (
          <DropdownMenu>
            <DropdownMenuTrigger
              render={
                <Button
                  size="icon-xs"
                  variant="outline"
                  aria-label={t('pod.spreadsheet.fill_options')}
                  title={t('pod.spreadsheet.fill_options')}
                />
              }>
              <RiArrowDownSLine />
            </DropdownMenuTrigger>
            <DropdownMenuContent align="start" aria-label={t('pod.spreadsheet.fill_options')}>
              <DropdownMenuItem onClick={() => void refill('copy')}>{t('pod.spreadsheet.fill_copy')}</DropdownMenuItem>
              <DropdownMenuItem onClick={() => void refill('series')}>
                {t('pod.spreadsheet.fill_series')}
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => void refill('formats')}>
                {t('pod.spreadsheet.fill_formats')}
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        )}
      </div>
      <Dialog
        open={Boolean(viewing)}
        onOpenChange={open => {
          if (open || !viewing) return
          URL.revokeObjectURL(viewing.url)
          setViewing(undefined)
        }}>
        <DialogContent className="max-w-[min(90vw,1200px)]">
          <DialogTitle>{viewing?.alt || t('pod.spreadsheet.picture')}</DialogTitle>
          {viewing && <img src={viewing.url} alt={viewing.alt} className="max-h-[75vh] w-full object-contain" />}
        </DialogContent>
      </Dialog>
    </div>
  )
}

function buildFrame(
  sheetID: number,
  version: number,
  rects: Rect[],
  views: Viewport[],
  axes: { rows: LineAxis; cols: LineAxis }
): Frame {
  const frame: Frame = {
    sheetID,
    version,
    rects,
    cells: new Map(),
    merges: [],
    spills: [],
    rowStyles: new Map(),
    colStyles: new Map(),
    filter: undefined,
    tables: [],
    validations: []
  }
  const merges = new Map<string, Rect>()
  const spills = new Map<string, Rect>()
  const tables = new Map<string, RenderTable>()
  const validations = new Map<string, RenderValidation>()
  views.forEach((view, index) => {
    const rect = rects[index]!
    axes.rows.replace(rect.r0, rect.r1, view.rows)
    axes.cols.replace(rect.c0, rect.c1, view.cols)
    for (const cell of view.cells) {
      frame.cells.set(cellKey(cell.row, cell.col), { cell, style: view.styles[cell.look ?? cell.style]! })
    }
    const filterRange = view.filter && parseRange(view.filter.range)
    if (view.filter && filterRange) frame.filter = { range: filterRange, filter: view.filter }
    for (const table of view.tables) tables.set(table.range, table)
    for (const rule of view.validations) validations.set(rule.range, rule)
    for (const line of view.rows) if (line.style !== null) frame.rowStyles.set(line.index, view.styles[line.style]!)
    for (const line of view.cols) if (line.style !== null) frame.colStyles.set(line.index, view.styles[line.style]!)
    for (const merge of view.merges) {
      const parsed = parseRange(merge)
      if (parsed) merges.set(merge, parsed)
    }
    for (const [, spill] of view.spills) {
      const parsed = parseRange(spill)
      if (parsed) spills.set(spill, parsed)
    }
  })
  frame.merges = [...merges.values()]
  frame.spills = [...spills.values()]
  for (const [range, table] of tables) {
    const rect = parseRange(range)
    if (rect) frame.tables.push({ rect, table })
  }
  for (const [range, rule] of validations) {
    const rect = parseRange(range)
    if (rect) frame.validations.push({ rect, rule })
  }
  return frame
}
