import init, { functions as listFunctions, paste_op, Spreadsheet } from '@ankole/kernel/spreadsheet-wasm'
import wasmURL from '@ankole/kernel/spreadsheet-wasm/ankole_spreadsheet_wasm_bg.wasm?url'
import type { Rebased } from '../state/spreadsheet-collaboration'
import {
  cellName,
  type ChartPrim,
  type ClipboardBlock,
  type FilterValue,
  type FindMatch,
  type FindOptions,
  type FormatSnapshot,
  type FunctionInfo,
  type PasteMode,
  type Rect,
  type RenderChart,
  type RenderImage,
  type SelectionStats,
  type SheetInfo,
  type SpreadsheetOp,
  type ValidationFailure,
  type Viewport
} from '../state/spreadsheet-grid'

/**
 * The spreadsheet kernel in a Web Worker. `confirmed` is the document the server committed;
 * `local` is `confirmed` plus this tab's pending operations, and every read comes from it.
 */
export type EngineRequest = { id: number; method: keyof typeof methods; args: unknown[] }
export type EngineResponse = { id: number; ok: unknown } | { id: number; error: { message: string } }
export type EngineMethods = typeof methods

const CONFLICTS = new Set([
  'target_deleted',
  'overlapping_structural_edit',
  'sheet_deleted',
  'concurrent_sort_or_merge'
])
const ready = init({ module_or_path: wasmURL })
let confirmed: Spreadsheet | undefined
let local: Spreadsheet | undefined

function opened(document: Spreadsheet | undefined): Spreadsheet {
  if (!document) throw new Error('The spreadsheet is not open')
  return document
}

function replaceLocal(next: Spreadsheet) {
  local?.free()
  local = next
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

const methods = {
  open(bytes: ArrayBuffer, ops: SpreadsheetOp[]): void {
    const next = Spreadsheet.open(new Uint8Array(bytes), JSON.stringify(ops))
    confirmed?.free()
    confirmed = next
    replaceLocal(next.fork())
  },
  applyLocal(op: SpreadsheetOp): { op: SpreadsheetOp } {
    return JSON.parse(opened(local).apply(JSON.stringify(op)))
  },
  commit(ops: SpreadsheetOp[]): void {
    for (const op of ops) opened(confirmed).apply(JSON.stringify(op))
  },
  rebuildLocal(pending: SpreadsheetOp[], foreign: SpreadsheetOp[]): Rebased[] {
    replaceLocal(opened(confirmed).fork())
    const prior = JSON.stringify(foreign)
    return pending.map(op => {
      try {
        return { op: JSON.parse(opened(local).apply_rebased(JSON.stringify(op), prior)).op }
      } catch (error) {
        const reason = message(error)
        return CONFLICTS.has(reason) ? { conflict: reason } : { error: reason }
      }
    })
  },
  promote(): void {
    replaceLocal(opened(confirmed).fork())
  },
  sheets(): SheetInfo[] {
    return JSON.parse(opened(local).sheets())
  },
  viewport(sheetID: number, rect: Rect): Viewport {
    return JSON.parse(opened(local).viewport(sheetID, rect.r0, rect.c0, rect.r1, rect.c1))
  },
  selectionStats(sheetID: number, range: string): SelectionStats {
    return JSON.parse(opened(local).selection_stats(sheetID, range))
  },
  copyBlock(sheetID: number, range: string): ClipboardBlock {
    return JSON.parse(opened(local).copy_block(sheetID, range))
  },
  pasteOp(block: ClipboardBlock, sheetID: number, cell: string, mode: PasteMode): SpreadsheetOp {
    return JSON.parse(paste_op(JSON.stringify(block), sheetID, cell, mode))
  },
  formatSnapshot(sheetID: number, range: string): FormatSnapshot {
    return JSON.parse(opened(local).format_snapshot(sheetID, range))
  },
  images(sheetID: number): RenderImage[] {
    return JSON.parse(opened(local).images(sheetID))
  },
  imageData(sheetID: number, imageID: number): Uint8Array {
    return opened(local).image_data(sheetID, imageID)
  },
  cellPicture(sheetID: number, cell: string): Uint8Array {
    return opened(local).cell_picture(sheetID, cell)
  },
  charts(sheetID: number): RenderChart[] {
    return JSON.parse(opened(local).charts(sheetID))
  },
  chartDrawing(sheetID: number, chartID: number, width: number, height: number): ChartPrim[] {
    return JSON.parse(opened(local).chart_drawing(sheetID, chartID, width, height))
  },
  functions(): FunctionInfo[] {
    return JSON.parse(listFunctions())
  },
  filterValues(sheetID: number, col: number): FilterValue[] {
    return JSON.parse(opened(local).filter_values(sheetID, col))
  },
  validateInput(sheetID: number, cell: string, input: string): ValidationFailure | null {
    return JSON.parse(opened(local).validate_input(sheetID, cell, input))
  },
  /** `sheetID` 0 searches every sheet. */
  find(sheetID: number, query: string, options: FindOptions): FindMatch[] {
    return JSON.parse(opened(local).find(sheetID, query, JSON.stringify(options)))
  },
  cellInputs(sheetID: number, rect: Rect): string[][] {
    const document = opened(local)
    const rows: string[][] = []
    for (let row = rect.r0; row <= rect.r1; row++) {
      const values: string[] = []
      for (let col = rect.c0; col <= rect.c1; col++) values.push(document.cell_input(sheetID, cellName({ row, col })))
      rows.push(values)
    }
    return rows
  }
}

const scope = self as unknown as {
  onmessage: ((event: MessageEvent<EngineRequest>) => void) | null
  postMessage(message: EngineResponse): void
}
// Requests run one at a time in arrival order, after the module has loaded.
let queue: Promise<void> = Promise.resolve()
scope.onmessage = ({ data }) => {
  queue = queue.then(async () => {
    try {
      await ready
      const method = methods[data.method] as (...args: unknown[]) => unknown
      scope.postMessage({ id: data.id, ok: method(...data.args) })
    } catch (error) {
      scope.postMessage({ id: data.id, error: { message: message(error) } })
    }
  })
}
