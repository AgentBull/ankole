import type {
  OfficeChangeSet,
  OfficeCollaborationModel,
  OfficeRemoteReport,
  OfficeSyncEngine
} from '../office/office-collaboration'
import type {
  EngineMethods,
  EngineRequest,
  EngineResponse,
  PageRect,
  WordCommandInfo,
  WordFindMatch,
  WordKeyResult,
  WordPageInfo,
  WordRenderedPage,
  WordSnapshot,
  WordStoryRef
} from './word-worker'
// Vite generates this URL export; the worker source itself exports no default.
// oxlint-disable-next-line import/default
import workerSourceURL from './word-worker.ts?worker&url'

export type {
  PageRect,
  WordCommandInfo,
  WordFindMatch,
  WordKeyResult,
  WordPageInfo,
  WordRenderedPage,
  WordSnapshot,
  WordStoryRef
}

export type WordSession = InstanceType<typeof OfficeCollaborationModel<WordSnapshot>>

export const MAX_WORD_PICTURE_BYTES = 2 * 1024 * 1024

export type WordEngine = OfficeSyncEngine<WordSnapshot> & {
  addFonts(fontBlobs: Uint8Array[]): Promise<WordSnapshot>
  renderPageRgba(pageIndex: number, scale: number): Promise<WordRenderedPage>
  pointerDown(
    pageIndex: number,
    xPt: number,
    yPt: number,
    clicks: number,
    shift: boolean,
    alt: boolean
  ): Promise<WordSnapshot>
  pointerMove(pageIndex: number, xPt: number, yPt: number): Promise<WordSnapshot>
  pointerUp(pageIndex: number, xPt: number, yPt: number): Promise<WordSnapshot>
  keyEvent(key: string, ctrlOrMeta: boolean, shift: boolean, alt: boolean): Promise<WordKeyResult>
  insertText(text: string): Promise<WordSnapshot>
  imePreedit(text: string, start: number, end: number): Promise<WordSnapshot>
  imeCommit(text: string): Promise<WordSnapshot>
  imeCancel(): Promise<WordSnapshot>
  executeCommand(commandId: string, params?: Record<string, unknown>): Promise<WordSnapshot>
  commitLocalStep(): Promise<{ op: OfficeChangeSet | null; snapshot: WordSnapshot }>
  applyRemote(
    confirmedOps: OfficeChangeSet[],
    pendingOps: OfficeChangeSet[]
  ): Promise<{ report: OfficeRemoteReport; snapshot: WordSnapshot }>
  undo(): Promise<{ op: OfficeChangeSet | null; snapshot: WordSnapshot }>
  redo(): Promise<{ op: OfficeChangeSet | null; snapshot: WordSnapshot }>
  blockRects(story: WordStoryRef, blockIndex: number): Promise<PageRect[]>
  presenceSelectionRects(selection: Record<string, unknown>): Promise<PageRect[]>
  find(query: string, matchCase: boolean): Promise<WordFindMatch[]>
  selectedClipboard(): Promise<{ text: string; html: string }>
  exportDocx(): Promise<Uint8Array>
  exportPdf(): Promise<Uint8Array>
  commands(query: string): Promise<WordCommandInfo[]>
}

export function sameStoryRef(a: WordStoryRef | undefined, b: WordStoryRef | undefined): boolean {
  if (a === 'body' && b === 'body') return true
  if (typeof a === 'object' && a !== null && typeof b === 'object' && b !== null) {
    return a.part === b.part
  }
  return false
}

export function storyRefKey(story: WordStoryRef): string {
  return story === 'body' ? 'body' : `part:${story.part}`
}

export function bytesToBase64(bytes: Uint8Array): string {
  const chunkSize = 0x8000
  const chunks: string[] = []
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    chunks.push(String.fromCharCode(...bytes.subarray(offset, offset + chunkSize)))
  }
  return btoa(chunks.join(''))
}

type Waiting = { resolve(value: unknown): void; reject(error: Error): void }

/** Starts the Word Web Worker and dispatches one typed request per message. */
export function createWordEngine(): WordEngine {
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
  worker.onerror = event => failAll(new Error(event.message || 'The Word worker failed'))
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
    open: (bytes, ops, checkpoint = null) => call('open', [bytes, ops, checkpoint], [bytes]),
    addFonts: fontBlobs => call('addFonts', [fontBlobs]),
    renderPageRgba: (pageIndex, scale) => call('renderPageRgba', [pageIndex, scale]),
    pointerDown: (pageIndex, xPt, yPt, clicks, shift, alt) =>
      call('pointerDown', [pageIndex, xPt, yPt, clicks, shift, alt]),
    pointerMove: (pageIndex, xPt, yPt) => call('pointerMove', [pageIndex, xPt, yPt]),
    pointerUp: (pageIndex, xPt, yPt) => call('pointerUp', [pageIndex, xPt, yPt]),
    keyEvent: (key, ctrlOrMeta, shift, alt) => call('keyEvent', [key, ctrlOrMeta, shift, alt]),
    insertText: text => call('insertText', [text]),
    imePreedit: (text, start, end) => call('imePreedit', [text, start, end]),
    imeCommit: text => call('imeCommit', [text]),
    imeCancel: () => call('imeCancel', []),
    executeCommand: (commandId, params = {}) => call('executeCommand', [commandId, params]),
    commitLocalStep: () => call('commitLocalStep', []),
    applyRemote: (confirmedOps, pendingOps) => call('applyRemote', [confirmedOps, pendingOps]),
    undo: () => call('undo', []),
    redo: () => call('redo', []),
    blockRects: (story, blockIndex) => call('blockRects', [story, blockIndex]),
    presenceSelectionRects: selection => call('presenceSelectionRects', [selection]),
    find: (query, matchCase) => call('find', [query, matchCase]),
    selectedClipboard: () => call('selectedClipboard', []),
    exportDocx: () => call('exportDocx', []),
    exportPdf: () => call('exportPdf', []),
    commands: query => call('commands', [query]),
    dispose() {
      worker.terminate()
      if (bootstrapURL) URL.revokeObjectURL(bootstrapURL)
      failAll(new Error('The Word worker stopped'))
    }
  }
}
