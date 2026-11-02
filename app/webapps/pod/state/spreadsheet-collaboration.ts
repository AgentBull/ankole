import { equal, uuidV4 } from '@agentbull/active-support'
import { batch, computed, createModel, effect, signal } from '@preact/signals-react'
import {
  cellName,
  cellSelection,
  clampCell,
  intersect,
  isStructural,
  memberColor,
  MAX_COLS,
  MAX_ROWS,
  parseRange,
  rangeName,
  selectionRect,
  shiftCell,
  type CellAddress,
  type ClipboardBlock,
  type FillMode,
  type FunctionInfo,
  type PasteMode,
  type Rect,
  type RenderImage,
  type Selection,
  type SelectionStats,
  type SheetInfo,
  type SpreadsheetOp,
  type Viewport
} from './spreadsheet-grid'
import { acceptsReference, isFormula } from './spreadsheet-formula'

export type SheetEntry = {
  revision: number
  kind: 'op' | 'reset'
  client_id: string | null
  client_seq: number | null
  op: SpreadsheetOp | null
  created_at?: string
}
export type SheetChanges = {
  revision: number
  changes: SheetEntry[]
  reset_required: boolean
  acknowledged_revision?: number
}
type SheetRequest = { base_revision: number; client_id: string; client_seq: number; op: SpreadsheetOp }

/**
 * The page channel as the model uses it. A rejected `push` carries the server's `{reason, details}`
 * as `payload`. The realtime layer keeps the channel's presence: `presence()` lists it, and the
 * `presence` event fires after every change.
 */
export type SheetChannel = {
  ready: Promise<unknown>
  push<T>(event: string, payload: object): Promise<T>
  on(event: string, callback: (payload: any) => void): () => void
  presence(): { id: string; metas: Record<string, unknown>[] }[]
  close(): void
}

/** A pending operation rebased onto the confirmed document, or why it could not be. */
export type Rebased = { op: SpreadsheetOp } | { conflict: string } | { error: string }

/**
 * The worker that holds the confirmed document (what the server committed) and the local one
 * (confirmed plus this tab's pending operations). Reads always come from the local document.
 */
export type SpreadsheetEngine = {
  open(bytes: ArrayBuffer, ops: SpreadsheetOp[]): Promise<void>
  applyLocal(op: SpreadsheetOp): Promise<{ op: SpreadsheetOp }>
  commit(ops: SpreadsheetOp[]): Promise<void>
  rebuildLocal(pending: SpreadsheetOp[], foreign: SpreadsheetOp[]): Promise<Rebased[]>
  promote(): Promise<void>
  sheets(): Promise<SheetInfo[]>
  viewport(sheetID: number, rect: Rect): Promise<Viewport>
  cellInputs(sheetID: number, rect: Rect): Promise<string[][]>
  selectionStats(sheetID: number, range: string): Promise<SelectionStats>
  copyBlock(sheetID: number, range: string): Promise<ClipboardBlock>
  pasteOp(block: ClipboardBlock, sheetID: number, cell: string, mode: PasteMode): Promise<SpreadsheetOp>
  images(sheetID: number): Promise<RenderImage[]>
  imageData(sheetID: number, imageID: number): Promise<Uint8Array>
  cellPicture(sheetID: number, cell: string): Promise<Uint8Array>
  functions(): Promise<FunctionInfo[]>
  dispose(): void
}

export type SpreadsheetSource =
  | { kind: 'too_large' }
  | { kind: 'loaded'; revision: number; ops: SpreadsheetOp[]; bytes: ArrayBuffer; unsupported: boolean }

/** What the page tells the author about edits the model could not keep. */
export type SpreadsheetNotice =
  | { kind: 'conflict'; op: SpreadsheetOp; reason: string }
  | { kind: 'rejected'; op: SpreadsheetOp; message: string; reason?: string }
  | { kind: 'discarded'; count: number }
  | { kind: 'failed'; error: unknown }
  | { kind: 'revoked' }

export type SpreadsheetOptions = {
  canEdit: boolean
  /** The viewer's own uid, whose presence the member list leaves out; known once the socket connects. */
  selfUID(): string | undefined
  connect(): Promise<SheetChannel>
  load(): Promise<SpreadsheetSource>
  createEngine(): SpreadsheetEngine
  notify(notice: SpreadsheetNotice): void
}

export type SpreadsheetStatus = 'loading' | 'ready' | 'read_only' | 'too_large' | 'error'
export type PresenceSelection = { sheet_id: number; range: string }
export type SpreadsheetMember = { uid: string; name: string; color: string; selections: PresenceSelection[] }
/** The text being typed into one cell, shared by the cell editor and the formula bar. */
/**
 * The cell being edited and its text. `caret`, when set, asks the editors to put the caret there
 * once; a formula draft may stay open on another sheet while its author points at cells there.
 */
export type CellDraft = { sheetID: number; cell: CellAddress; text: string; caret?: number }
/** A picture as an operation carries it: base64 PNG or JPEG bytes. */
export type PictureData = { mime: 'image/png' | 'image/jpeg'; data: string; alt?: string }
export type ImageAnchor = { cell: string; dx: number; dy: number; width: number; height: number }
/** The range this tab copied or cut, which the grid outlines until Escape or a paste of the cut. */
export type CopiedRange = { sheetID: number; rect: Rect; cut?: string }
/** The format painter holds the formats of a copied block until it paints them once, or until Escape. */
export type FormatPainter = { block: ClipboardBlock; sticky: boolean }
export type Direction = 'up' | 'down' | 'left' | 'right'

type UndoRecord = { forward: SpreadsheetOp; inverse: SpreadsheetOp }
type Entry = { op: SpreadsheetOp; undo?: UndoRecord; request?: SheetRequest; busy: number }
type PresenceMeta = { name?: string | null; selection?: PresenceSelection | null }

const SEND_DELAY_MS = 30
const BUSY_DELAY_MS = 200
const BUSY_RETRIES = 5
const RETRY_DELAY_MS = 1000
const PRESENCE_INTERVAL_MS = 250
/** Server replies that end the session's current document; the model loads it again. */
const RELOAD_REASONS = new Set([
  'client_sequence_conflict',
  'forbidden',
  'not_found',
  'invalid_page_type',
  'invalid_spreadsheet',
  'file_too_large'
])

function failureReason(failure: unknown): string | undefined {
  const payload = (failure as { payload?: { reason?: unknown } } | undefined)?.payload
  return typeof payload?.reason === 'string' ? payload.reason : undefined
}

function failureMessage(failure: unknown): string {
  return failure instanceof Error ? failure.message : String(failure)
}

/** The values that restore `rect`: each cell's previous input, with empty cells cleared. */
function restoreOp(sheetID: number, rect: Rect, inputs: string[][]): SpreadsheetOp {
  return {
    type: 'range.set_values',
    sheet_id: sheetID,
    range: rangeName(rect),
    values: inputs.map(row => row.map(input => (input === '' ? null : input)))
  }
}

/**
 * One spreadsheet editing session: the confirmed revision, one request in flight, the local
 * operations queued behind it, presence, and personal undo. The server alone orders commits; the
 * worker engine keeps the local document equal to the confirmed one plus the pending operations.
 */
export const SpreadsheetModel = createModel((options: SpreadsheetOptions) => {
  const status = signal<SpreadsheetStatus>('loading')
  const revision = signal(0)
  const sheets = signal<SheetInfo[]>([])
  const activeSheetID = signal(0)
  const selection = signal<Selection>(cellSelection({ row: 0, col: 0 }))
  const pending = signal(0)
  const members = signal<SpreadsheetMember[]>([])
  const error = signal<unknown>(undefined)
  const revoked = signal(false)
  const unsupported = signal(false)
  /** Increases whenever the local document changes, so cached viewports know they are stale. */
  const version = signal(0)
  const draft = signal<CellDraft | null>(null)
  const canUndo = signal(false)
  const canRedo = signal(false)
  const copied = signal<CopiedRange | null>(null)
  const painter = signal<FormatPainter | null>(null)
  const activeSheet = computed(() => sheets.value.find(sheet => sheet.sheet_id === activeSheetID.value))
  const editable = computed(() => status.value === 'ready')

  const clientID = uuidV4()
  let channel: SheetChannel | undefined
  let engine: SpreadsheetEngine | undefined
  let disposed = false
  let tail: Promise<unknown> = Promise.resolve()
  let inFlight: Entry | undefined
  let queue: Entry[] = []
  const localEdits = new Set<symbol>()
  let sequence = 0
  let pushing = false
  let timer: ReturnType<typeof setTimeout> | undefined
  let undoStack: UndoRecord[] = []
  let redoStack: UndoRecord[] = []
  let syncing = false
  let syncAgain = false
  let presenceTimer: ReturnType<typeof setTimeout> | undefined
  let presenceSentAt = Number.NEGATIVE_INFINITY
  let presenceNext: PresenceSelection | null = null
  let functionList: Promise<FunctionInfo[]> | undefined

  /** Engine work and state transitions run one at a time, in the order they were requested. */
  const serial = <T>(task: () => Promise<T>): Promise<T> => {
    const run = tail.then(task)
    tail = run.catch(() => undefined)
    return run
  }

  const publishCounts = () => {
    batch(() => {
      pending.value = localEdits.size + (inFlight ? 1 : 0) + queue.length
      canUndo.value = undoStack.length > 0
      canRedo.value = redoStack.length > 0
    })
  }

  /**
   * Marks an edit as unsaved before waiting for the worker or earlier local work. While a reset
   * loads the replaced workbook, the editor discards an edit of the old one and tells the author,
   * as it does for the edits the reset dropped.
   */
  const editSerial = (task: () => Promise<SpreadsheetOp | undefined>) => {
    if (disposed) return Promise.resolve(undefined)
    if (status.peek() === 'loading') options.notify({ kind: 'discarded', count: 1 })
    if (status.peek() !== 'ready') return Promise.resolve(undefined)
    const edit = Symbol()
    localEdits.add(edit)
    publishCounts()
    return serial(async () => {
      try {
        if (disposed || !localEdits.has(edit)) return undefined
        return await task()
      } finally {
        localEdits.delete(edit)
        publishCounts()
      }
    })
  }

  const forget = (record: UndoRecord | undefined) => {
    if (!record) return
    undoStack = undoStack.filter(item => item !== record)
    redoStack = redoStack.filter(item => item !== record)
  }

  const clearHistory = () => {
    undoStack = []
    redoStack = []
  }

  const refreshSheets = async () => {
    const list = await engine!.sheets()
    const visible = list.filter(sheet => !sheet.hidden)
    batch(() => {
      sheets.value = list
      if (!visible.some(sheet => sheet.sheet_id === activeSheetID.peek())) {
        activeSheetID.value = visible[0]?.sheet_id ?? list[0]?.sheet_id ?? 0
        selection.value = cellSelection({ row: 0, col: 0 })
      }
      version.value++
    })
  }

  const schedule = (delay = SEND_DELAY_MS) => {
    clearTimeout(timer)
    timer = setTimeout(() => void flush(), delay)
  }

  /** Rebuilds the local document from the confirmed one and keeps the pending operations that still apply. */
  const rebuild = async (foreign: SpreadsheetOp[]) => {
    const entries = [...(inFlight ? [inFlight] : []), ...queue]
    if (!entries.length) {
      await engine!.promote()
      return
    }
    const results = await engine!.rebuildLocal(
      entries.map(entry => entry.op),
      foreign
    )
    results.forEach((result, index) => {
      const entry = entries[index]!
      if ('op' in result) entry.op = result.op
      // The server decides about the request in flight; its reply reports the outcome.
      else if (entry !== inFlight) {
        queue = queue.filter(item => item !== entry)
        forget(entry.undo)
        options.notify(
          'conflict' in result
            ? { kind: 'conflict', op: entry.op, reason: result.conflict }
            : { kind: 'rejected', op: entry.op, message: result.error }
        )
      }
    })
  }

  const load = async () => {
    status.value = 'loading'
    try {
      const source = await options.load()
      if (disposed) return
      if (source.kind === 'too_large') {
        status.value = 'too_large'
        return
      }
      engine ??= options.createEngine()
      await engine.open(source.bytes, source.ops)
      if (disposed) return
      await refreshSheets()
      batch(() => {
        revision.value = source.revision
        unsupported.value = source.unsupported
        error.value = undefined
        status.value = options.canEdit ? 'ready' : 'read_only'
      })
      publishCounts()
      // Changes committed between the bootstrap and the channel join reach this tab here.
      void sync()
    } catch (failure) {
      if (disposed) return
      batch(() => {
        error.value = failure
        status.value = 'error'
      })
    }
  }

  const reset = async () => {
    const discarded = localEdits.size + (inFlight ? 1 : 0) + queue.length
    localEdits.clear()
    inFlight = undefined
    queue = []
    clearTimeout(timer)
    clearHistory()
    publishCounts()
    if (discarded) options.notify({ kind: 'discarded', count: discarded })
    await load()
  }

  const loaded = () => status.peek() === 'ready' || status.peek() === 'read_only'

  /** Applies committed entries that continue this tab's revision; a gap asks for a sync. */
  const receive = async (payload: SheetChanges, sent?: Entry) => {
    if (disposed || !engine || !loaded()) return
    if (payload.reset_required) return reset()
    const fresh = payload.changes
      .filter(entry => entry.revision > revision.peek())
      .sort((a, b) => a.revision - b.revision)
    if (fresh.some((entry, index) => entry.revision !== revision.peek() + index + 1)) {
      void sync()
      return
    }
    if (fresh.some(entry => entry.kind === 'reset' || !entry.op)) return reset()
    try {
      const committed = fresh.map(entry => entry.op!)
      if (committed.length) await engine.commit(committed)
      const request = inFlight?.request
      const own = request
        ? fresh.find(entry => entry.client_id === clientID && entry.client_seq === request.client_seq)
        : undefined
      const acknowledged = inFlight && (own || (sent === inFlight && payload.acknowledged_revision !== undefined))
      const localForm = inFlight?.op
      if (acknowledged) inFlight = undefined
      const foreign = fresh.filter(entry => entry.client_id !== clientID)
      if (foreign.some(entry => isStructural(entry.op!))) clearHistory()
      if (fresh.length) {
        revision.value = fresh.at(-1)!.revision
        followStructure(foreign.map(entry => entry.op!))
      }
      if (fresh.length || acknowledged) {
        if (!inFlight && !queue.length) await engine.promote()
        else if (foreign.length || (own && !equal(own.op, localForm))) {
          await rebuild(foreign.map(entry => entry.op!))
        }
        await refreshSheets()
      }
      publishCounts()
    } catch (failure) {
      // The confirmed document no longer matches the server, so start over from the file.
      options.notify({ kind: 'failed', error: failure })
      return reset()
    }
    if (payload.revision > revision.peek()) void sync()
  }

  /** Keeps the selection and an open cell editor on the same content when another editor moves lines. */
  const followStructure = (ops: SpreadsheetOp[]) => {
    const sheetID = activeSheetID.peek()
    for (const op of ops) {
      if (op.sheet_id !== sheetID) continue
      const current = selection.peek()
      selection.value = { anchor: shiftCell(current.anchor, op), focus: shiftCell(current.focus, op) }
      const editing = draft.peek()
      if (editing?.sheetID === sheetID) draft.value = { ...editing, cell: shiftCell(editing.cell, op) }
    }
  }

  const sync = async () => {
    if (disposed || !channel) return
    if (syncing) {
      syncAgain = true
      return
    }
    syncing = true
    try {
      do {
        syncAgain = false
        await channel.ready
        if (disposed || !loaded()) break
        const reply = await channel.push<SheetChanges>('sheet:sync', { revision: revision.peek() })
        await serial(() => receive(reply))
      } while (syncAgain && !disposed)
    } catch (failure) {
      if (!disposed) error.value = failure
    } finally {
      syncing = false
    }
  }

  const take = async () => {
    if (inFlight) return inFlight
    const next = queue.shift()
    if (!next) return undefined
    next.request = { base_revision: revision.peek(), client_id: clientID, client_seq: ++sequence, op: next.op }
    inFlight = next
    return next
  }

  const flush = async () => {
    if (disposed || pushing || !channel || !loaded()) return
    pushing = true
    let delay: number | undefined = SEND_DELAY_MS
    let sent: Entry | undefined
    try {
      sent = await serial(take)
      if (!sent) return
      const reply = await channel.push<SheetChanges>('sheet:apply', sent.request!)
      await serial(() => receive(reply, sent))
      error.value = undefined
    } catch (failure) {
      delay = sent ? await failed(sent, failure) : RETRY_DELAY_MS
    } finally {
      pushing = false
      if (!disposed && delay !== undefined && (inFlight || queue.length)) schedule(delay)
    }
  }

  /** Decides what a failed request means and returns the delay before the next send. */
  const failed = async (sent: Entry, failure: unknown): Promise<number | undefined> => {
    const reason = failureReason(failure)
    if (reason === 'spreadsheet_busy') {
      sent.busy++
      if (sent.busy <= BUSY_RETRIES) return BUSY_DELAY_MS
      error.value = failure
      return RETRY_DELAY_MS
    }
    if (reason === 'spreadsheet_conflict') {
      const details = (failure as { payload: { details: { reason: string; changes: SheetEntry[] } } }).payload.details
      await serial(() => drop(sent, details.changes, { kind: 'conflict', op: sent.op, reason: details.reason }))
      return SEND_DELAY_MS
    }
    if (reason === 'invalid_operation' || reason === 'invalid_request' || reason === 'spreadsheet_full') {
      await serial(() => drop(sent, [], { kind: 'rejected', op: sent.op, message: failureMessage(failure), reason }))
      return SEND_DELAY_MS
    }
    if (reason && RELOAD_REASONS.has(reason)) {
      if (reason !== 'client_sequence_conflict') options.notify({ kind: 'failed', error: failure })
      await serial(reset)
      return undefined
    }
    // The connection failed or timed out; the same request is safe to repeat.
    error.value = failure
    return RETRY_DELAY_MS
  }

  /** Gives up the request in flight after the server refused it, keeping the queue behind it. */
  const drop = async (sent: Entry, missed: SheetEntry[], notice: SpreadsheetNotice) => {
    if (inFlight !== sent || !engine) return
    const fresh = missed.filter(entry => entry.revision > revision.peek()).sort((a, b) => a.revision - b.revision)
    if (
      fresh.some(
        (entry, index) => entry.kind === 'reset' || !entry.op || entry.revision !== revision.peek() + index + 1
      )
    ) {
      return reset()
    }
    inFlight = undefined
    forget(sent.undo)
    try {
      const foreign = fresh.map(entry => entry.op!)
      if (foreign.length) {
        await engine.commit(foreign)
        revision.value = fresh.at(-1)!.revision
        if (foreign.some(isStructural)) clearHistory()
        followStructure(foreign)
      }
      await rebuild(foreign)
      await refreshSheets()
    } catch (failure) {
      options.notify({ kind: 'failed', error: failure })
      return reset()
    }
    publishCounts()
    options.notify(notice)
  }

  /**
   * Applies a local edit and queues it for the server; the kernel rejects an invalid one at once.
   * Callers run it inside `serial`.
   */
  const applyEdit = async (
    op: SpreadsheetOp,
    record?: (applied: SpreadsheetOp) => UndoRecord | undefined
  ): Promise<SpreadsheetOp | undefined> => {
    if (disposed || !engine || status.peek() !== 'ready') return undefined
    let applied: SpreadsheetOp
    try {
      applied = (await engine.applyLocal(op)).op
    } catch (failure) {
      options.notify({ kind: 'rejected', op, message: failureMessage(failure) })
      return undefined
    }
    if (disposed) return undefined
    queue.push({ op: applied, undo: record?.(applied), busy: 0 })
    if (isStructural(applied)) clearHistory()
    await refreshSheets()
    publishCounts()
    schedule()
    return applied
  }

  /** An edit of cell values whose inverse restores the inputs the cells held before it. */
  const valueEdit = (op: SpreadsheetOp, sheetID: number, rect: Rect | undefined) =>
    editSerial(async () => {
      if (!engine || status.peek() !== 'ready') return undefined
      const before = rect ? await engine.cellInputs(sheetID, rect) : undefined
      return applyEdit(op, applied => {
        if (!rect || !before) return undefined
        const record = { forward: applied, inverse: restoreOp(sheetID, rect, before) }
        undoStack.push(record)
        redoStack = []
        return record
      })
    })

  const replay = (from: 'undo' | 'redo') =>
    editSerial(async () => {
      if (status.peek() !== 'ready') return undefined
      const record = (from === 'undo' ? undoStack : redoStack).pop()
      if (!record) return undefined
      ;(from === 'undo' ? redoStack : undoStack).push(record)
      publishCounts()
      return applyEdit(from === 'undo' ? record.inverse : record.forward)
    })

  const select = (next: Selection) => {
    selection.value = { anchor: clampCell(next.anchor), focus: clampCell(next.focus) }
    if (loaded()) announce({ sheet_id: activeSheetID.peek(), range: rangeName(selectionRect(selection.peek())) })
  }

  const setCell = (cell: CellAddress, input: string, sheetID = activeSheetID.peek()) => {
    const rect = { r0: cell.row, c0: cell.col, r1: cell.row, c1: cell.col }
    return valueEdit({ type: 'cell.set', sheet_id: sheetID, cell: cellName(cell), input }, sheetID, rect)
  }

  /** Applies an operation that personal undo does not cover. */
  const perform = (op: SpreadsheetOp) => editSerial(() => applyEdit(op))

  const fill = (source: Rect, to: Rect, mode: FillMode = 'series') => {
    const sheetID = activeSheetID.peek()
    const op = { type: 'range.fill', sheet_id: sheetID, range: rangeName(source), to: rangeName(to), mode }
    return mode === 'formats' ? perform(op) : valueEdit(op, sheetID, to)
  }

  /** The run of numbers that ends next to `cell`, above it or to its left, as AutoSum picks it. */
  const numberRun = async (sheetID: number, cell: CellAddress, direction: 'up' | 'left') => {
    const up = direction === 'up'
    const end = up ? cell.row - 1 : cell.col - 1
    if (end < 0 || !engine) return undefined
    const start = Math.max(0, end - 999)
    const strip = up
      ? { r0: start, c0: cell.col, r1: end, c1: cell.col }
      : { r0: cell.row, c0: start, r1: cell.row, c1: end }
    const view = await engine.viewport(sheetID, strip)
    const numbers = new Set(
      view.cells.filter(found => found.kind === 'number').map(found => (up ? found.row : found.col))
    )
    if (!numbers.has(end)) return undefined
    let first = end
    while (first > start && numbers.has(first - 1)) first--
    return up ? { r0: first, c0: cell.col, r1: end, c1: cell.col } : { r0: cell.row, c0: first, r1: cell.row, c1: end }
  }

  /** A new floating picture's id: random and high, so two editors never pick the same one in practice. */
  const newImageID = () => 0x0100_0000 + (crypto.getRandomValues(new Uint32Array(1))[0]! % 0x7e00_0000)

  const sendPresence = () => {
    presenceTimer = undefined
    presenceSentAt = Date.now()
    void channel?.push('sheet:presence', { selection: presenceNext }).catch(() => undefined)
  }

  const announce = (next: PresenceSelection | null) => {
    presenceNext = next
    if (next === null) {
      clearTimeout(presenceTimer)
      sendPresence()
      return
    }
    if (presenceTimer) return
    presenceTimer = setTimeout(sendPresence, Math.max(0, presenceSentAt + PRESENCE_INTERVAL_MS - Date.now()))
  }

  const publishMembers = () => {
    const listed = (channel?.presence() ?? []).map(({ id: uid, metas }) => {
      const entries = metas as PresenceMeta[]
      return {
        uid,
        name: entries.at(-1)?.name || uid,
        color: memberColor(uid),
        selections: entries.flatMap(meta => (meta.selection ? [meta.selection] : []))
      }
    })
    members.value = listed.filter(member => member.uid !== options.selfUID())
  }

  const revoke = () => {
    if (revoked.peek()) return
    options.notify({ kind: 'revoked' })
    batch(() => {
      revoked.value = true
      status.value = 'error'
    })
    clearTimeout(timer)
    channel?.close()
    channel = undefined
  }

  const start = async () => {
    try {
      const connected = await options.connect()
      if (disposed) {
        connected.close()
        return
      }
      channel = connected
      connected.on('sheet:changes', payload => void serial(() => receive(payload as SheetChanges)))
      connected.on('presence', publishMembers)
      connected.on('access_revoked', revoke)
      void connected.ready.catch(failure => {
        if (!disposed) error.value = failure
      })
    } catch (failure) {
      batch(() => {
        error.value = failure
        status.value = 'error'
      })
      return
    }
    await serial(load)
  }

  effect(() => () => {
    disposed = true
    localEdits.clear()
    inFlight = undefined
    queue = []
    publishCounts()
    clearTimeout(timer)
    clearTimeout(presenceTimer)
    if (channel) {
      void channel.push('sheet:presence', { selection: null }).catch(() => undefined)
      channel.close()
    }
    engine?.dispose()
  })

  const target = () => ({ sheetID: activeSheetID.peek(), rect: selectionRect(selection.peek()) })

  return {
    status,
    revision,
    sheets,
    activeSheetID,
    activeSheet,
    selection,
    pending,
    members,
    error,
    revoked,
    unsupported,
    version,
    draft,
    canUndo,
    canRedo,
    editable,
    start,
    revoke,
    /** Catches up after the page version moved, for instance after the socket reconnected. */
    sync() {
      if (loaded()) void sync()
    },
    retry() {
      if (status.peek() !== 'error' || revoked.peek()) return
      if (channel) void serial(load)
      else void start()
    },
    viewport(sheetID: number, rect: Rect) {
      return engine && loaded() ? engine.viewport(sheetID, rect) : Promise.resolve(undefined)
    },
    cellInputs(sheetID: number, rect: Rect) {
      return engine && loaded() ? engine.cellInputs(sheetID, rect) : Promise.resolve(undefined)
    },
    select,
    /**
     * Shows another sheet. A formula draft whose caret waits for a reference stays open, so its
     * author can point at cells of that sheet.
     */
    showSheet(sheetID: number, caret?: number) {
      const editing = draft.peek()
      const pointing =
        editing && isFormula(editing.text) && acceptsReference(editing.text, caret ?? editing.text.length)
      batch(() => {
        activeSheetID.value = sheetID
        selection.value = cellSelection({ row: 0, col: 0 })
        if (!pointing) draft.value = null
      })
      if (loaded()) announce({ sheet_id: sheetID, range: 'A1' })
    },
    /** Hides this viewer's selection from collaborators while the grid does not have focus. */
    blur() {
      if (loaded()) announce(null)
    },
    focus() {
      if (loaded()) announce({ sheet_id: activeSheetID.peek(), range: rangeName(selectionRect(selection.peek())) })
    },
    copied,
    painter,
    /**
     * Applies an operation that personal undo does not cover: formats, lines, sheets, and notes.
     * Resolves to the operation as committed locally, with assigned sheet ids filled in.
     */
    perform,
    setCell,
    /** Every function a formula can call, read once from the kernel. */
    functions(): Promise<FunctionInfo[]> {
      if (!engine) return Promise.resolve([])
      functionList ??= engine.functions().catch(failure => {
        functionList = undefined
        throw failure
      })
      return functionList
    },
    /** The count, sum, and average of a rectangle, as the status bar shows them. */
    stats(sheetID: number, rect: Rect): Promise<SelectionStats | undefined> {
      return engine && loaded() ? engine.selectionStats(sheetID, rangeName(rect)) : Promise.resolve(undefined)
    },
    images(sheetID: number): Promise<RenderImage[] | undefined> {
      return engine && loaded() ? engine.images(sheetID) : Promise.resolve(undefined)
    },
    imageData(sheetID: number, imageID: number): Promise<Uint8Array | undefined> {
      return engine && loaded() ? engine.imageData(sheetID, imageID) : Promise.resolve(undefined)
    },
    cellPicture(sheetID: number, cell: CellAddress): Promise<Uint8Array | undefined> {
      return engine && loaded() ? engine.cellPicture(sheetID, cellName(cell)) : Promise.resolve(undefined)
    },
    /**
     * Copies the selection for the clipboard and outlines it. A cut gets a token that a later paste
     * of the same block turns into a move.
     */
    async copy(
      cut: boolean
    ): Promise<{ block: ClipboardBlock; sheetID: number; rect: Rect; cut?: string } | undefined> {
      const { sheetID, rect } = target()
      if (!engine || !loaded()) return undefined
      const block = await engine.copyBlock(sheetID, rangeName(rect))
      const token = cut ? uuidV4() : undefined
      copied.value = { sheetID, rect, cut: token }
      return { block, sheetID, rect, cut: token }
    },
    clearCopied() {
      copied.value = null
      painter.value = null
    },
    /**
     * Pastes a copied block at the top-left of the selection. When it is the block this tab cut,
     * the paste moves the cells instead, so references to them follow.
     */
    async paste(block: ClipboardBlock, mode: PasteMode, cut?: string) {
      const { sheetID, rect } = target()
      const at = { row: rect.r0, col: rect.c0 }
      const source = copied.peek()
      if (cut && source?.cut === cut && mode === 'all') {
        copied.value = null
        return perform({
          type: 'range.move',
          sheet_id: source.sheetID,
          from: rangeName(source.rect),
          to_sheet_id: sheetID,
          to_cell: cellName(at)
        })
      }
      if (!engine || status.peek() !== 'ready') return undefined
      let op: SpreadsheetOp
      try {
        op = await engine.pasteOp(block, sheetID, cellName(at), mode)
      } catch (failure) {
        options.notify({ kind: 'failed', error: failure })
        return undefined
      }
      const pasted = parseRange(String(op.range))
      const applied = mode === 'formats' ? perform(op) : valueEdit(op, sheetID, pasted)
      if (pasted) select({ anchor: at, focus: { row: pasted.r1, col: pasted.c1 } })
      return applied
    },
    /** Takes the selection's formats for the format painter; a sticky painter keeps them for several targets. */
    async pickFormats(sticky: boolean) {
      const { sheetID, rect } = target()
      if (!engine || status.peek() !== 'ready') return
      painter.value = { block: await engine.copyBlock(sheetID, rangeName(rect)), sticky }
    },
    /** Paints the held formats over `rect`, repeating the block to cover it. */
    async paintFormats(rect: Rect) {
      const held = painter.peek()
      if (!held || !engine || status.peek() !== 'ready') return undefined
      if (!held.sticky) painter.value = null
      const height = held.block.rows.length
      const width = held.block.rows[0]?.length ?? 0
      if (!height || !width) return undefined
      const single = rect.r0 === rect.r1 && rect.c0 === rect.c1
      const rows = single ? height : rect.r1 - rect.r0 + 1
      const cols = single ? width : rect.c1 - rect.c0 + 1
      const block = {
        origin: held.block.origin,
        rows: Array.from({ length: rows }, (_, row) =>
          Array.from({ length: cols }, (_, col) => held.block.rows[row % height]![col % width]!)
        )
      }
      const sheetID = activeSheetID.peek()
      const op = await engine.pasteOp(block, sheetID, cellName({ row: rect.r0, col: rect.c0 }), 'formats')
      return perform(op)
    },
    fill,
    /** Ctrl+D and Ctrl+R: copies the first row or column of the selection over the rest, or the line before a single one. */
    fillSelection(direction: 'down' | 'right') {
      const { rect } = target()
      const down = direction === 'down'
      const lines = down ? rect.r1 - rect.r0 : rect.c1 - rect.c0
      if (lines === 0 && (down ? rect.r0 : rect.c0) === 0) return Promise.resolve(undefined)
      const to = lines === 0 ? (down ? { ...rect, r0: rect.r0 - 1 } : { ...rect, c0: rect.c0 - 1 }) : rect
      const source = down ? { ...to, r1: to.r0 } : { ...to, c1: to.c0 }
      return fill(source, to, 'copy')
    },
    /** Clears formats, or contents and formats, of the selection. */
    clear(mode: 'formats' | 'all') {
      const { sheetID, rect } = target()
      const op = { type: 'range.clear', sheet_id: sheetID, range: rangeName(rect), mode }
      return mode === 'formats' ? perform(op) : valueEdit(op, sheetID, rect)
    },
    /**
     * AutoSum and its siblings. On one cell the editor opens with the function over the run of
     * numbers above (or else to the left); on a range it writes one formula per column below it,
     * or after a single row.
     */
    async autoSum(fn: string) {
      const { sheetID, rect } = target()
      if (!engine || status.peek() !== 'ready') return undefined
      const single = rect.r0 === rect.r1 && rect.c0 === rect.c1
      if (!single) {
        if (rect.r0 === rect.r1) {
          const at = { row: rect.r0, col: rect.c1 + 1 }
          return setCell(at, `=${fn}(${rangeName(rect)})`)
        }
        const row = rect.r1 + 1
        if (row >= MAX_ROWS) return undefined
        const values = [
          Array.from({ length: rect.c1 - rect.c0 + 1 }, (_, index) => {
            const col = rect.c0 + index
            return `=${fn}(${rangeName({ r0: rect.r0, c0: col, r1: rect.r1, c1: col })})`
          })
        ]
        return valueEdit(
          {
            type: 'range.set_values',
            sheet_id: sheetID,
            range: rangeName({ r0: row, c0: rect.c0, r1: row, c1: rect.c1 }),
            values
          },
          sheetID,
          { r0: row, c0: rect.c0, r1: row, c1: rect.c1 }
        )
      }
      const cell = { row: rect.r0, col: rect.c0 }
      const run = (await numberRun(sheetID, cell, 'up')) ?? (await numberRun(sheetID, cell, 'left'))
      const argument = run ? rangeName(run) : ''
      const text = `=${fn}(${argument})`
      draft.value = { sheetID, cell, text, caret: text.length - (run ? 0 : 1) }
      return undefined
    },
    /** Inserts a floating picture at `anchor`; the editor names it so later edits can address it. */
    insertImage(anchor: ImageAnchor, picture: PictureData) {
      return perform({
        type: 'image.insert',
        sheet_id: activeSheetID.peek(),
        image_id: newImageID(),
        anchor,
        picture
      })
    },
    updateImage(imageID: number, anchor: ImageAnchor) {
      return perform({ type: 'image.update', sheet_id: activeSheetID.peek(), image_id: imageID, anchor })
    },
    deleteImage(imageID: number) {
      return perform({ type: 'image.delete', sheet_id: activeSheetID.peek(), image_id: imageID })
    },
    /** Puts a picture into a cell; undo writes the cell's earlier input back, which removes the picture. */
    setCellPicture(cell: CellAddress, picture: PictureData | null) {
      const sheetID = activeSheetID.peek()
      const op = { type: 'cell.picture', sheet_id: sheetID, cell: cellName(cell), picture }
      return picture ? valueEdit(op, sheetID, { r0: cell.row, c0: cell.col, r1: cell.row, c1: cell.col }) : perform(op)
    },
    imageToCell(imageID: number, cell: CellAddress) {
      return perform({ type: 'image.to_cell', sheet_id: activeSheetID.peek(), image_id: imageID, cell: cellName(cell) })
    },
    imageFromCell(cell: CellAddress, anchor: ImageAnchor) {
      return perform({
        type: 'image.from_cell',
        sheet_id: activeSheetID.peek(),
        cell: cellName(cell),
        image_id: newImageID(),
        anchor
      })
    },
    /** Pastes a block of typed values with its top-left corner on `anchor`; empty strings clear cells. */
    setValues(anchor: CellAddress, values: string[][]) {
      const width = Math.max(...values.map(row => row.length))
      if (!values.length || !width) return Promise.resolve(undefined)
      const rect = intersect(
        { r0: anchor.row, c0: anchor.col, r1: anchor.row + values.length - 1, c1: anchor.col + width - 1 },
        { r0: 0, c0: 0, r1: MAX_ROWS - 1, c1: MAX_COLS - 1 }
      )!
      const rows = values
        .slice(0, rect.r1 - rect.r0 + 1)
        .map(row => Array.from({ length: rect.c1 - rect.c0 + 1 }, (_, index) => (row[index] ? row[index] : null)))
      const sheetID = activeSheetID.peek()
      return valueEdit(
        { type: 'range.set_values', sheet_id: sheetID, range: rangeName(rect), values: rows },
        sheetID,
        rect
      )
    },
    /** Clears the selected contents; undo restores the cells that held content, within the used area. */
    clearContents() {
      const { sheetID, rect } = target()
      const sheet = activeSheet.peek()
      const used =
        sheet && sheet.rows && sheet.cols
          ? intersect(rect, { r0: 0, c0: 0, r1: sheet.rows - 1, c1: sheet.cols - 1 })
          : undefined
      return valueEdit(
        { type: 'range.clear', sheet_id: sheetID, range: rangeName(rect), mode: 'contents' },
        sheetID,
        used
      )
    },
    undo() {
      return replay('undo')
    },
    redo() {
      return replay('redo')
    },
    /** Tab-separated inputs of the selection, for the clipboard. */
    async copyText() {
      const { sheetID, rect } = target()
      const sheet = activeSheet.peek()
      const bounded = sheet
        ? intersect(rect, { r0: 0, c0: 0, r1: Math.max(sheet.rows, 1) - 1, c1: Math.max(sheet.cols, 1) - 1 })
        : undefined
      const inputs = bounded && engine ? await engine.cellInputs(sheetID, bounded) : undefined
      return inputs ?? [['']]
    },
    /**
     * Where Ctrl+arrow lands: the last filled cell of a filled run, or else the next filled cell,
     * or else the edge of the used area.
     */
    async dataEdge(from: CellAddress, direction: Direction) {
      const sheet = activeSheet.peek()
      if (!engine || !sheet) return from
      const vertical = direction === 'up' || direction === 'down'
      const step = direction === 'down' || direction === 'right' ? 1 : -1
      const index = vertical ? from.row : from.col
      const used = vertical ? sheet.rows : sheet.cols
      const end = (vertical ? MAX_ROWS : MAX_COLS) - 1
      const at = (line: number) => (vertical ? { ...from, row: line } : { ...from, col: line })
      if (step > 0 && index >= used - 1) return at(end)
      if (step < 0 && index === 0) return from
      const limit = step > 0 ? used - 1 : 0
      const strip = vertical
        ? { r0: Math.min(index, limit), c0: from.col, r1: Math.max(index, limit), c1: from.col }
        : { r0: from.row, c0: Math.min(index, limit), r1: from.row, c1: Math.max(index, limit) }
      const view = await engine.viewport(activeSheetID.peek(), strip)
      const filled = new Set(view.cells.filter(cell => cell.text !== '').map(cell => (vertical ? cell.row : cell.col)))
      let line = index
      if (filled.has(line) && filled.has(line + step)) {
        while (line !== limit && filled.has(line + step)) line += step
        return at(line)
      }
      do line += step
      while (line !== limit && !filled.has(line))
      return filled.has(line) ? at(line) : at(step > 0 ? end : 0)
    },
    /** Opens the cell editor on `cell` with `text`; the formula bar shows the same draft. */
    edit(cell: CellAddress, text: string, caret?: number) {
      draft.value = { sheetID: activeSheetID.peek(), cell, text, caret }
    },
    type(text: string, caret?: number) {
      const current = draft.peek()
      if (current) draft.value = { ...current, text, caret }
    },
    cancelEdit() {
      draft.value = null
    },
    /**
     * Commits the draft with `cell.set` and moves the selection like Enter or Tab. The selection
     * moves before the edit is applied, so the next keystroke already types into the next cell.
     */
    commitEdit(move?: Direction) {
      const current = draft.peek()
      if (!current) return Promise.resolve(undefined)
      batch(() => {
        draft.value = null
        // A formula that pointed at another sheet commits on its own sheet, which shows again.
        if (current.sheetID !== activeSheetID.peek()) {
          activeSheetID.value = current.sheetID
          selection.value = cellSelection(current.cell)
        }
      })
      if (move) {
        const [rows, cols] = { up: [-1, 0], down: [1, 0], left: [0, -1], right: [0, 1] }[move]
        select(cellSelection(clampCell({ row: current.cell.row + rows!, col: current.cell.col + cols! })))
      }
      if (!sheets.peek().some(sheet => sheet.sheet_id === current.sheetID)) return Promise.resolve(undefined)
      return setCell(current.cell, current.text, current.sheetID)
    },
    /**
     * Ctrl+Enter: commits the draft into every selected cell. A formula is written into the
     * selection's first cell and filled over the rest, so relative references follow each cell.
     */
    async commitToSelection() {
      const current = draft.peek()
      const { rect } = target()
      if (!current) return undefined
      const single = rect.r0 === rect.r1 && rect.c0 === rect.c1
      const corner = { row: rect.r0, col: rect.c0 }
      if (single || current.sheetID !== activeSheetID.peek()) return this.commitEdit()
      draft.value = null
      await setCell(corner, current.text)
      const column = { ...rect, c1: rect.c0 }
      if (rect.r1 > rect.r0) await fill({ ...column, r1: rect.r0 }, column, 'copy')
      if (rect.c1 > rect.c0) await fill(column, rect, 'copy')
      return undefined
    }
  }
})

/** A presence selection as a rectangle on its sheet. */
export function presenceRect(selection: PresenceSelection): Rect | undefined {
  return parseRange(selection.range)
}

export type SpreadsheetSession = InstanceType<typeof SpreadsheetModel>
