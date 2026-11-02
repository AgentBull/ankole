import type { SpreadsheetEngine } from '../state/spreadsheet-collaboration'
import type { EngineMethods, EngineRequest, EngineResponse } from './spreadsheet-worker'

type Waiting = { resolve(value: unknown): void; reject(error: Error): void }

/** Starts the spreadsheet worker and calls it with one typed request per message. */
export function createSpreadsheetEngine(): SpreadsheetEngine {
  const worker = new Worker(new URL('./spreadsheet-worker.ts', import.meta.url), { type: 'module' })
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
    dispose() {
      worker.terminate()
      failAll(new Error('The spreadsheet worker stopped'))
    }
  }
}
