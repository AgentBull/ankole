import type { SpreadsheetEngine } from '../state/spreadsheet-collaboration'
import type { EngineMethods, EngineRequest, EngineResponse } from './spreadsheet-worker'
// Vite generates this URL export; the worker source itself exports no default.
// oxlint-disable-next-line import/default
import workerSourceURL from './spreadsheet-worker.ts?worker&url'

type Waiting = { resolve(value: unknown): void; reject(error: Error): void }

/** Starts the spreadsheet worker and calls it with one typed request per message. */
export function createSpreadsheetEngine(): SpreadsheetEngine {
  const workerURL = new URL(workerSourceURL, import.meta.url)
  // Phoenix and Vite use different origins in development. A same-origin module
  // worker can import Vite's compiled entry with its normal CORS checks.
  const bootstrapURL =
    workerURL.origin === location.origin
      ? undefined
      : URL.createObjectURL(new Blob([`import ${JSON.stringify(workerURL.href)}`], { type: 'text/javascript' }))
  let worker: Worker
  try {
    worker = new Worker(bootstrapURL ?? workerURL, { type: 'module' })
  } catch (error) {
    if (bootstrapURL) URL.revokeObjectURL(bootstrapURL)
    throw error
  }
  const waiting = new Map<number, Waiting>()
  let next = 0
  const failAll = (error: Error) => {
    for (const request of waiting.values()) request.reject(error)
    waiting.clear()
  }
  worker.onmessage = ({ data }: MessageEvent<EngineResponse>) => {
    const request = waiting.get(data.id)
    waiting.delete(data.id)
    if ('error' in data) request?.reject(new Error(data.error.message))
    else request?.resolve(data.ok)
  }
  worker.onerror = event => failAll(new Error(event.message || 'The spreadsheet worker failed'))
  const call = <K extends keyof EngineMethods>(
    method: K,
    args: Parameters<EngineMethods[K]>,
    transfer: Transferable[] = []
  ) =>
    new Promise<ReturnType<EngineMethods[K]>>((resolve, reject) => {
      const id = ++next
      waiting.set(id, { resolve: value => resolve(value as ReturnType<EngineMethods[K]>), reject })
      worker.postMessage({ id, method, args } satisfies EngineRequest, transfer)
    })
  return {
    open: (bytes, ops) => call('open', [bytes, ops], [bytes]),
    applyLocal: op => call('applyLocal', [op]),
    commit: ops => call('commit', [ops]),
    rebuildLocal: (pending, foreign) => call('rebuildLocal', [pending, foreign]),
    promote: () => call('promote', []),
    sheets: () => call('sheets', []),
    viewport: (sheetID, rect) => call('viewport', [sheetID, rect]),
    cellInputs: (sheetID, rect) => call('cellInputs', [sheetID, rect]),
    selectionStats: (sheetID, range) => call('selectionStats', [sheetID, range]),
    copyBlock: (sheetID, range) => call('copyBlock', [sheetID, range]),
    pasteOp: (block, sheetID, cell, mode) => call('pasteOp', [block, sheetID, cell, mode]),
    formatSnapshot: (sheetID, range) => call('formatSnapshot', [sheetID, range]),
    images: sheetID => call('images', [sheetID]),
    imageData: (sheetID, imageID) => call('imageData', [sheetID, imageID]),
    cellPicture: (sheetID, cell) => call('cellPicture', [sheetID, cell]),
    functions: () => call('functions', []),
    dispose() {
      worker.terminate()
      if (bootstrapURL) URL.revokeObjectURL(bootstrapURL)
      failAll(new Error('The spreadsheet worker stopped'))
    }
  }
}
