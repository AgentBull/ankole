import init, { PresentationEditor } from '@ankole/kernel/presentation-wasm'
import wasmURL from '@ankole/kernel/presentation-wasm/ankole_presentation_wasm_bg.wasm?url'
import type { OfficeChangeSet, OfficeRemoteReport, OfficeSnapshotBase } from '../office/office-collaboration'

export type PresentationSlideInfo = {
  index: number
  slide_id: number
  title: string
  name: string
  layout_id: number
  hidden: boolean
  notes: string
  comments_count: number
  shapes_count: number
}

export type PresentationTextSelection = {
  shape_id: number
  anchor: [number, number]
  caret: [number, number]
  cell: [number, number] | null
  notes: boolean
}

export type PresentationSelection = {
  slide_id: number | null
  slide_index: number
  editing: boolean
  shapes: number[]
  text_sel: PresentationTextSelection | null
  text_quads: [number, number][][]
  notes: string
  can_undo: boolean
  can_redo: boolean
}

export type PresentationShapeBox = {
  id: number
  x: number
  y: number
  w: number
  h: number
  rot: number
}

export type PresentationFormatState = {
  font: string
  size: number | null
  bold: boolean
  italic: boolean
  underline: boolean
  strike: boolean
  align: string | null
}

export type PresentationSubstitutedFont = {
  requested: string
  substituted: string
}

export type PresentationFindMatch = {
  slide_index: number
  slide_id: number
  shape_id: number | null
  in_notes: boolean
  snippet: string
  char_offset: number
}

export type PresentationCommandInfo = {
  id: string
  label: string
  menu: string[]
  shortcut: string | null
  params: string
}

export type PresentationKeyMods = {
  shift?: boolean
  alt?: boolean
  ctrl?: boolean
  meta?: boolean
}

type ViewPointerEvent = { kind: 'down' | 'drag' | 'up' | 'doubleclick'; x: number; y: number; tol: number }

export type PresentationRenderedSlide = {
  width: number
  height: number
  rgba: Uint8Array
}

export type PresentationSnapshot = OfficeSnapshotBase & {
  slides: PresentationSlideInfo[]
  selection: PresentationSelection
  slideSizePt: { width: number; height: number }
  selectedShapeBoxes: PresentationShapeBox[]
  formatState: PresentationFormatState | null
  warnings: string[]
  substitutedFonts: PresentationSubstitutedFont[]
  missingGlyphFonts: string[]
}

export type PresentationWorkerRequest = {
  id: number
  method: keyof typeof methods
  args: unknown[]
}

export type PresentationWorkerResponse = { id: number; ok: unknown } | { id: number; error: { message: string } }

export type PresentationWorkerMethods = typeof methods

const ready = init({ module_or_path: wasmURL })
let editor: PresentationEditor | undefined
let cachedBoxes: PresentationShapeBox[] = []
let cachedFormat: PresentationFormatState | null = null
let viewPress: { start: ViewPointerEvent; selecting?: boolean } | undefined

function opened(instance: PresentationEditor | undefined): PresentationEditor {
  if (!instance) throw new Error('The presentation is not open')
  return instance
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function detachBytes(bytes: Uint8Array): Uint8Array {
  if (bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength) {
    return bytes
  }
  return bytes.slice()
}

function inspectSelectedBoxes(doc: PresentationEditor, shapeIds: readonly number[]): PresentationShapeBox[] {
  const boxes: PresentationShapeBox[] = []
  for (const id of shapeIds) {
    try {
      const parsed = JSON.parse(doc.execute_command('shape.inspect', JSON.stringify({ id }))) as {
        box?: { x?: number; y?: number; w?: number; h?: number; rot?: number }
      }
      if (parsed.box) {
        boxes.push({
          id,
          x: Number(parsed.box.x ?? 0),
          y: Number(parsed.box.y ?? 0),
          w: Number(parsed.box.w ?? 0),
          h: Number(parsed.box.h ?? 0),
          rot: Number(parsed.box.rot ?? 0)
        })
      }
    } catch {
      // Ignore transient shape lookup failures while selections settle.
    }
  }
  return boxes
}

function inspectFormatState(doc: PresentationEditor, selection: PresentationSelection): PresentationFormatState | null {
  if (selection.shapes.length === 0 && selection.text_sel === null) {
    return null
  }
  try {
    const raw = JSON.parse(doc.execute_command('format.state', '{}')) as {
      font?: unknown
      size?: unknown
      bold?: unknown
      italic?: unknown
      underline?: unknown
      strike?: unknown
      align?: unknown
    }
    return {
      font: typeof raw.font === 'string' ? raw.font : '',
      size: typeof raw.size === 'number' && Number.isFinite(raw.size) ? raw.size : null,
      bold: raw.bold === true,
      italic: raw.italic === true,
      underline: raw.underline === true,
      strike: raw.strike === true,
      align: typeof raw.align === 'string' ? raw.align : null
    }
  } catch {
    return null
  }
}

function buildSnapshot(doc: PresentationEditor, preserveTypingCoalesce = false): PresentationSnapshot {
  const slides = JSON.parse(doc.slides_info()) as PresentationSlideInfo[]
  const selection = JSON.parse(doc.selection_info()) as PresentationSelection
  const ptSize = doc.slide_pixel_size(1.0)
  const slideSizePt = {
    width: ptSize[0] && ptSize[0] > 0 ? ptSize[0] : 960,
    height: ptSize[1] && ptSize[1] > 0 ? ptSize[1] : 540
  }
  const warnings = JSON.parse(doc.warnings()) as string[]
  const substitutedFonts = JSON.parse(doc.substituted_fonts()) as PresentationSubstitutedFont[]
  const missingGlyphFonts = JSON.parse(doc.missing_glyph_fonts()) as string[]

  let selectedShapeBoxes: PresentationShapeBox[]
  let formatState: PresentationFormatState | null
  if (preserveTypingCoalesce) {
    const selectedSet = new Set(selection.shapes)
    selectedShapeBoxes = cachedBoxes.filter(box => selectedSet.has(box.id))
    formatState = selection.shapes.length > 0 || selection.text_sel !== null ? cachedFormat : null
  } else {
    selectedShapeBoxes = inspectSelectedBoxes(doc, selection.shapes)
    formatState = inspectFormatState(doc, selection)
    cachedBoxes = selectedShapeBoxes
    cachedFormat = formatState
  }

  // Only uncommitted document modifications advertise `editing: true` -> `mode: "editing"`
  // over Presence so mere shape or caret focus keeps `mode: "viewing"`.
  const hasChanges = doc.has_local_changes()

  return {
    canUndo: selection.can_undo,
    canRedo: selection.can_redo,
    editing: hasChanges,
    presenceSelection:
      selection.slide_id !== null
        ? {
            slide_id: selection.slide_id,
            slide_index: selection.slide_index,
            shapes: selection.shapes
          }
        : null,
    slides,
    selection,
    slideSizePt,
    selectedShapeBoxes,
    formatState,
    warnings,
    substitutedFonts,
    missingGlyphFonts
  }
}

const methods = {
  open(bytes: ArrayBuffer, ops: OfficeChangeSet[], checkpoint?: string | null): PresentationSnapshot {
    const next = PresentationEditor.open(new Uint8Array(bytes), JSON.stringify(ops), checkpoint ?? undefined)
    editor?.free()
    editor = next
    cachedBoxes = []
    cachedFormat = null
    viewPress = undefined
    next.load_embedded_fonts()
    return buildSnapshot(next)
  },

  addFonts(fontBlobs: Uint8Array[]): PresentationSnapshot {
    const doc = opened(editor)
    for (const blob of fontBlobs) {
      PresentationEditor.add_font(blob)
    }
    return buildSnapshot(doc, true)
  },

  renderSlideRgba(slideIndex: number, scale: number): PresentationRenderedSlide {
    const doc = opened(editor)
    const dims = doc.slide_pixel_size(scale)
    const rgba = detachBytes(doc.render_slide_rgba(slideIndex, scale))
    return {
      width: dims[0] ?? 0,
      height: dims[1] ?? 0,
      rgba
    }
  },

  setActiveSlide(slideIndex: number): PresentationSnapshot {
    const doc = opened(editor)
    viewPress = undefined
    doc.set_active_slide(slideIndex)
    return buildSnapshot(doc)
  },

  pointerEvent(event: Record<string, unknown>): PresentationSnapshot {
    const doc = opened(editor)
    doc.pointer_event(JSON.stringify(event))
    return buildSnapshot(doc)
  },

  viewPointerEvent(event: ViewPointerEvent): PresentationSnapshot {
    const doc = opened(editor)
    const dispatch = (input: ViewPointerEvent | (Omit<ViewPointerEvent, 'kind'> & { kind: 'contextclick' })) =>
      doc.pointer_event(JSON.stringify(input))
    const canSelectText = () => {
      const selection = JSON.parse(doc.selection_info()) as PresentationSelection
      return Boolean(selection.text_sel || doc.selected_text())
    }
    if (event.kind === 'down') {
      viewPress = { start: event }
      dispatch({ ...event, kind: 'contextclick' })
    } else if (event.kind === 'doubleclick') {
      if (canSelectText()) dispatch(event)
    } else if (viewPress) {
      if (event.kind === 'drag' && viewPress.selecting === undefined) {
        const start = viewPress.start
        viewPress.selecting = false
        if (canSelectText()) {
          dispatch({ ...start, kind: 'doubleclick' })
          const hit = JSON.parse(dispatch(start)) as { caret?: [number, number] } | null
          viewPress.selecting = hit?.caret !== undefined
          // End a shape gesture at its origin. A viewer can drag only inside text.
          if (!viewPress.selecting) dispatch({ ...start, kind: 'up' })
        }
      }
      if (viewPress.selecting) dispatch(event)
      if (event.kind === 'up') viewPress = undefined
    }
    return buildSnapshot(doc)
  },

  keyEvent(key: string, mods: PresentationKeyMods): PresentationSnapshot {
    const doc = opened(editor)
    const isPlainChar = !mods.ctrl && !mods.meta && !mods.alt && [...key].length === 1
    if (isPlainChar) {
      const current = JSON.parse(doc.selection_info()) as PresentationSelection
      if (current.text_sel === null && current.shapes.length === 1) {
        doc.execute_command('text.edit', JSON.stringify({ id: current.shapes[0] }))
        doc.execute_command('text.selectAll', '{}')
      }
    }
    doc.key_event(key, JSON.stringify(mods))
    return buildSnapshot(doc, true)
  },

  executeCommand(commandId: string, params: Record<string, unknown>): PresentationSnapshot {
    const doc = opened(editor)
    if (commandId === 'text.insert') {
      const current = JSON.parse(doc.selection_info()) as PresentationSelection
      if (current.text_sel === null && current.shapes.length === 1) {
        doc.execute_command('text.edit', JSON.stringify({ id: current.shapes[0] }))
        doc.execute_command('text.selectAll', '{}')
      }
    }
    doc.execute_command(commandId, JSON.stringify(params))
    return buildSnapshot(doc)
  },

  setSlideNotes(slideId: number, notes: string): PresentationSnapshot {
    const doc = opened(editor)
    doc.set_slide_notes(slideId, notes)
    return buildSnapshot(doc)
  },

  commitLocalStep(): { op: OfficeChangeSet | null; snapshot: PresentationSnapshot } {
    const doc = opened(editor)
    const raw = doc.commit_local_step()
    const op = raw ? (JSON.parse(raw) as OfficeChangeSet) : null
    return { op, snapshot: buildSnapshot(doc) }
  },

  applyRemote(
    confirmedOps: OfficeChangeSet[],
    pendingOps: OfficeChangeSet[]
  ): { report: OfficeRemoteReport; snapshot: PresentationSnapshot } {
    const doc = opened(editor)
    const report = JSON.parse(
      doc.apply_remote(JSON.stringify(confirmedOps), JSON.stringify(pendingOps))
    ) as OfficeRemoteReport
    return { report, snapshot: buildSnapshot(doc) }
  },

  undo(): { op: OfficeChangeSet | null; snapshot: PresentationSnapshot } {
    const doc = opened(editor)
    const raw = doc.undo()
    const op = raw ? (JSON.parse(raw) as OfficeChangeSet) : null
    return { op, snapshot: buildSnapshot(doc) }
  },

  redo(): { op: OfficeChangeSet | null; snapshot: PresentationSnapshot } {
    const doc = opened(editor)
    const raw = doc.redo()
    const op = raw ? (JSON.parse(raw) as OfficeChangeSet) : null
    return { op, snapshot: buildSnapshot(doc) }
  },

  find(query: string, matchCase: boolean): PresentationFindMatch[] {
    return JSON.parse(opened(editor).find(query, matchCase)) as PresentationFindMatch[]
  },

  selectedText(): string {
    return opened(editor).selected_text()
  },

  commands(query: string): PresentationCommandInfo[] {
    return JSON.parse(opened(editor).commands(query)) as PresentationCommandInfo[]
  },

  exportPptx(): Uint8Array {
    return detachBytes(opened(editor).export_pptx())
  },

  exportPdf(): Uint8Array {
    return detachBytes(opened(editor).export_pdf())
  }
}

function transferablesForResult(result: unknown): Transferable[] {
  if (result instanceof Uint8Array && result.buffer instanceof ArrayBuffer) {
    return [result.buffer]
  }
  if (
    typeof result === 'object' &&
    result !== null &&
    'rgba' in result &&
    result.rgba instanceof Uint8Array &&
    result.rgba.buffer instanceof ArrayBuffer
  ) {
    return [result.rgba.buffer]
  }
  return []
}

const scope = self as unknown as {
  onmessage: ((event: MessageEvent<PresentationWorkerRequest>) => void) | null
  postMessage(message: PresentationWorkerResponse, transfer?: Transferable[]): void
}

// Dispatch Worker requests sequentially in arrival order after WASM initialization settles.
let queue: Promise<void> = Promise.resolve()
scope.onmessage = ({ data }) => {
  queue = queue.then(async () => {
    try {
      await ready
      const method = methods[data.method] as (...args: unknown[]) => unknown
      const ok = method(...data.args)
      const transfer = transferablesForResult(ok)
      if (transfer.length > 0) {
        scope.postMessage({ id: data.id, ok }, transfer)
      } else {
        scope.postMessage({ id: data.id, ok })
      }
    } catch (error) {
      scope.postMessage({ id: data.id, error: { message: errorMessage(error) } })
    }
  })
}
