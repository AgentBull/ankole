import init, { WordEditor } from '@ankole/kernel/word-wasm'
import wasmURL from '@ankole/kernel/word-wasm/ankole_word_wasm_bg.wasm?url'
import type { OfficeChangeSet, OfficeRemoteReport, OfficeSnapshotBase } from '../office/office-collaboration'

export type WordStoryRef = 'body' | { part: number }

export type WordDocPos = {
  path: number[]
  off: number
}

export type PageRect = {
  page: number
  x: number
  y: number
  w: number
  h: number
}

export type WordPageInfo = {
  index: number
  width_pt: number
  height_pt: number
}

export type WordCaretState = {
  story: WordStoryRef
  block: number | null
  editing: boolean
  anchor: WordDocPos
  focus: WordDocPos
  caret_rect: PageRect | null
  selection_rects: PageRect[]
  bold: boolean
  italic: boolean
  underline: boolean
  strike: boolean
  code: boolean
  style: string
  align: 'left' | 'center' | 'right' | 'justify'
  track_changes: boolean
  can_undo: boolean
  can_redo: boolean
  link?: string
}

export type MissingPictureEntry = {
  part: string
  story: string
  reason: string
}

export type WordPresenceSelection = {
  story: WordStoryRef
  block: number | null
  anchor: WordDocPos
  focus: WordDocPos
  editing?: boolean
}

export type WordFindMatch = {
  story: WordStoryRef
  block_index: number
  page_index: number
  snippet: string
  rects: PageRect[]
}

export type WordCommandInfo = {
  id: string
  label: string
  location: string
  shortcut: string
  params: string
  mutates: boolean
}

export type WordRenderedPage = {
  width: number
  height: number
  rgba: Uint8Array
}

export type WordSnapshot = OfficeSnapshotBase & {
  canUndo: boolean
  canRedo: boolean
  editing: boolean
  composing: boolean
  presenceSelection: WordPresenceSelection
  pages: WordPageInfo[]
  caretState: WordCaretState
  missingPictures: MissingPictureEntry[]
  substitutedFonts: string[]
  missingGlyphFonts: string[]
}

export type WordKeyResult = {
  handled: boolean
  requestCommit?: boolean
  snapshot: WordSnapshot
}

type RawKeyResponse = {
  handled?: boolean
  request_commit?: boolean
  state?: WordCaretState
}

/**
 * The Word kernel running in a dedicated Web Worker. One `WordEditor` instance owns confirmed,
 * optimistic, and active session document states, layout cache, personal Undo/Redo, and rasterizer.
 */
export type EngineRequest = { id: number; method: keyof typeof methods; args: unknown[] }
export type EngineResponse = { id: number; ok: unknown } | { id: number; error: { message: string } }
export type EngineMethods = typeof methods

const ready = init({ module_or_path: wasmURL })
let editor: WordEditor | undefined

function opened(current: WordEditor | undefined): WordEditor {
  if (!current) throw new Error('The Word document is not open')
  return current
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function standaloneBytes(bytes: Uint8Array): Uint8Array {
  if (bytes.buffer instanceof ArrayBuffer && bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength) {
    return bytes
  }
  return bytes.slice()
}

function buildSnapshot(ed: WordEditor, clickedLink?: string): WordSnapshot {
  const pages = JSON.parse(ed.pages_info()) as WordPageInfo[]
  const rawCaret = JSON.parse(ed.caret_and_selection()) as WordCaretState
  const caretState = clickedLink && !rawCaret.link ? { ...rawCaret, link: clickedLink } : rawCaret
  const missingPictures = JSON.parse(ed.missing_pictures()) as MissingPictureEntry[]
  const substitutions = JSON.parse(ed.substituted_fonts()) as { requested: string; used: string }[]
  const missingGlyphFonts = JSON.parse(ed.missing_glyph_fonts()) as string[]
  const composing = ed.is_composing()
  return {
    canUndo: caretState.can_undo,
    canRedo: caretState.can_redo,
    editing: caretState.editing,
    composing,
    presenceSelection: {
      story: caretState.story,
      block: caretState.block,
      anchor: caretState.anchor,
      focus: caretState.focus
    },
    pages,
    caretState,
    missingPictures,
    substitutedFonts: substitutions.map(({ requested }) => requested),
    missingGlyphFonts
  }
}

const methods = {
  open(bytes: ArrayBuffer, ops: OfficeChangeSet[], checkpoint?: string | null): WordSnapshot {
    const next = WordEditor.open(new Uint8Array(bytes), JSON.stringify(ops), checkpoint ?? undefined)
    editor?.free()
    editor = next
    next.load_embedded_fonts()
    return buildSnapshot(next)
  },
  addFonts(fontBlobs: Uint8Array[]): WordSnapshot {
    const ed = opened(editor)
    for (const blob of fontBlobs) {
      WordEditor.add_font(blob)
    }
    return buildSnapshot(ed)
  },
  renderPageRgba(pageIndex: number, scale: number): WordRenderedPage {
    const ed = opened(editor)
    const size = ed.page_pixel_size(pageIndex, scale)
    const width = size[0] ?? 1
    const height = size[1] ?? 1
    const rgba = standaloneBytes(ed.render_page_rgba(pageIndex, scale))
    return { width, height, rgba }
  },
  pointerDown(pageIndex: number, xPt: number, yPt: number, clicks: number, shift: boolean, alt: boolean): WordSnapshot {
    const ed = opened(editor)
    const downState = JSON.parse(ed.pointer_down(pageIndex, xPt, yPt, clicks, shift, alt)) as WordCaretState
    return buildSnapshot(ed, downState.link)
  },
  pointerMove(pageIndex: number, xPt: number, yPt: number): WordSnapshot {
    const ed = opened(editor)
    ed.pointer_move(pageIndex, xPt, yPt)
    return buildSnapshot(ed)
  },
  pointerUp(pageIndex: number, xPt: number, yPt: number): WordSnapshot {
    const ed = opened(editor)
    ed.pointer_up(pageIndex, xPt, yPt)
    return buildSnapshot(ed)
  },
  keyEvent(key: string, ctrlOrMeta: boolean, shift: boolean, alt: boolean): WordKeyResult {
    const ed = opened(editor)
    const raw = JSON.parse(ed.key_event(key, ctrlOrMeta, shift, alt)) as RawKeyResponse
    return {
      handled: Boolean(raw.handled),
      ...(raw.request_commit ? { requestCommit: true } : {}),
      snapshot: buildSnapshot(ed)
    }
  },
  insertText(text: string): WordSnapshot {
    const ed = opened(editor)
    ed.insert_text(text)
    return buildSnapshot(ed)
  },
  imePreedit(text: string, start: number, end: number): WordSnapshot {
    const ed = opened(editor)
    ed.ime_preedit(text, start, end)
    return buildSnapshot(ed)
  },
  imeCommit(text: string): WordSnapshot {
    const ed = opened(editor)
    ed.ime_commit(text)
    return buildSnapshot(ed)
  },
  imeCancel(): WordSnapshot {
    const ed = opened(editor)
    ed.ime_cancel()
    return buildSnapshot(ed)
  },
  executeCommand(commandId: string, params: Record<string, unknown> = {}): WordSnapshot {
    const ed = opened(editor)
    ed.execute_command(commandId, JSON.stringify(params))
    return buildSnapshot(ed)
  },
  commitLocalStep(): { op: OfficeChangeSet | null; snapshot: WordSnapshot } {
    const ed = opened(editor)
    const raw = ed.commit_local_step()
    const op = raw ? (JSON.parse(raw) as OfficeChangeSet) : null
    return { op, snapshot: buildSnapshot(ed) }
  },
  applyRemote(
    confirmedOps: OfficeChangeSet[],
    pendingOps: OfficeChangeSet[]
  ): { report: OfficeRemoteReport; snapshot: WordSnapshot } {
    const ed = opened(editor)
    const report = JSON.parse(
      ed.apply_remote(JSON.stringify(confirmedOps), JSON.stringify(pendingOps))
    ) as OfficeRemoteReport
    return { report, snapshot: buildSnapshot(ed) }
  },
  undo(): { op: OfficeChangeSet | null; snapshot: WordSnapshot } {
    const ed = opened(editor)
    const raw = ed.undo()
    const op = raw ? (JSON.parse(raw) as OfficeChangeSet) : null
    return { op, snapshot: buildSnapshot(ed) }
  },
  redo(): { op: OfficeChangeSet | null; snapshot: WordSnapshot } {
    const ed = opened(editor)
    const raw = ed.redo()
    const op = raw ? (JSON.parse(raw) as OfficeChangeSet) : null
    return { op, snapshot: buildSnapshot(ed) }
  },
  blockRects(story: WordStoryRef, blockIndex: number): PageRect[] {
    const ed = opened(editor)
    return JSON.parse(ed.block_rects(JSON.stringify(story), blockIndex)) as PageRect[]
  },
  presenceSelectionRects(selection: Record<string, unknown>): PageRect[] {
    const ed = opened(editor)
    return JSON.parse(ed.presence_selection_rects(JSON.stringify(selection))) as PageRect[]
  },
  find(query: string, matchCase: boolean): WordFindMatch[] {
    const ed = opened(editor)
    return JSON.parse(ed.find(query, matchCase)) as WordFindMatch[]
  },
  selectedClipboard(): { text: string; html: string } {
    const ed = opened(editor)
    return { text: ed.selected_text(), html: ed.selected_html() }
  },
  exportDocx(): Uint8Array {
    return standaloneBytes(opened(editor).export_docx())
  },
  exportPdf(): Uint8Array {
    return standaloneBytes(opened(editor).export_pdf())
  },
  commands(query: string): WordCommandInfo[] {
    const ed = opened(editor)
    return JSON.parse(ed.commands(query)) as WordCommandInfo[]
  }
}

function collectTransferables(method: keyof typeof methods, result: unknown): Transferable[] {
  if (method === 'renderPageRgba') {
    const buf = (result as WordRenderedPage).rgba.buffer
    return buf instanceof ArrayBuffer ? [buf] : []
  }
  if ((method === 'exportDocx' || method === 'exportPdf') && result instanceof Uint8Array) {
    return result.buffer instanceof ArrayBuffer ? [result.buffer] : []
  }
  return []
}

const scope = self as unknown as {
  onmessage: ((event: MessageEvent<EngineRequest>) => void) | null
  postMessage(message: EngineResponse, transfer?: Transferable[]): void
}

// Execute Worker requests sequentially in arrival order after WASM initialization finishes.
let queue: Promise<void> = Promise.resolve()
scope.onmessage = ({ data }) => {
  queue = queue.then(async () => {
    try {
      await ready
      const method = methods[data.method] as (...args: unknown[]) => unknown
      const ok = method(...data.args)
      const transfer = collectTransferables(data.method, ok)
      if (transfer.length > 0) scope.postMessage({ id: data.id, ok }, transfer)
      else scope.postMessage({ id: data.id, ok })
    } catch (error) {
      scope.postMessage({ id: data.id, error: { message: errorMessage(error) } })
    }
  })
}
