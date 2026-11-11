import { afterEach, expect, test } from 'bun:test'
import {
  SpreadsheetModel,
  type Rebased,
  type SheetChannel,
  type SheetChanges,
  type SheetEntry,
  type SpreadsheetEngine,
  type SpreadsheetNotice,
  type SpreadsheetSession
} from './spreadsheet-collaboration'
import type { Rect, SheetInfo, SpreadsheetOp, ValidationFailure, Viewport } from './spreadsheet-grid'

const SHEET: SheetInfo = {
  sheet_id: 1,
  name: 'Sheet1',
  hidden: false,
  tab_color: null,
  freeze: null,
  default_row_height: 20,
  default_col_width: 64,
  show_gridlines: true,
  rows: 3,
  cols: 2
}

type Call = { method: string; args: unknown[] }
type Reply = (event: string, payload: any) => Promise<unknown>

/** A worker stand-in that records calls; tests choose what rebasing and cell inputs return. */
function fakeEngine(
  behaviour: {
    inputs?: (rect: Rect) => string[][]
    rebase?: (pending: SpreadsheetOp[]) => Rebased[]
    viewport?: (rect: Rect) => Viewport
    validate?: (cell: string, input: string) => ValidationFailure | null
  } = {}
) {
  const calls: Call[] = []
  const record = (method: string, ...args: unknown[]) => calls.push({ method, args })
  const engine: SpreadsheetEngine = {
    open: async (bytes, ops) => void record('open', bytes, ops),
    applyLocal: async op => {
      record('applyLocal', op)
      return { op }
    },
    commit: async ops => void record('commit', ops),
    rebuildLocal: async (pending, foreign) => {
      record('rebuildLocal', pending, foreign)
      return behaviour.rebase?.(pending) ?? pending.map(op => ({ op }))
    },
    promote: async () => void record('promote'),
    sheets: async () => [SHEET],
    viewport: async (_sheetID, rect) =>
      behaviour.viewport?.(rect) ?? {
        cells: [],
        styles: [],
        merges: [],
        spills: [],
        rows: [],
        cols: [],
        filter: null,
        tables: [],
        validations: []
      },
    cellInputs: async (_sheetID, rect) =>
      behaviour.inputs?.(rect) ??
      Array.from({ length: rect.r1 - rect.r0 + 1 }, () => Array.from({ length: rect.c1 - rect.c0 + 1 }, () => '')),
    selectionStats: async () => ({ count: 0, numbers: 0, sum: 0, average: null, min: null, max: null }),
    charts: async () => [],
    chartDrawing: async () => [],
    filterValues: async (_sheetID, col) => {
      record('filterValues', col)
      return [{ text: 'a', blank: false, selected: true }]
    },
    validateInput: async (_sheetID, cell, input) => {
      record('validateInput', cell, input)
      return behaviour.validate?.(cell, input) ?? null
    },
    find: async (sheetID, query) => {
      record('find', sheetID, query)
      return [{ sheet_id: 1, cell: 'A1', text: query }]
    },
    formatSnapshot: async (_sheetID, range) => {
      record('formatSnapshot', range)
      return { lines: [], cells: [{ row: 0, col: 0, format: { bold: false } }] }
    },
    copyBlock: async (_sheetID, range) => {
      record('copyBlock', range)
      return { origin: range.split(':')[0]!, rows: [[{ input: '=A1', value: '1', text: '1', format: {} }]] }
    },
    pasteOp: async (block, sheetID, cell, mode) => {
      record('pasteOp', block, cell, mode)
      return { type: 'range.paste', sheet_id: sheetID, range: cell, cells: [[{ input: '=B2' }]] }
    },
    images: async () => [],
    imageData: async () => new Uint8Array(),
    cellPicture: async () => new Uint8Array(),
    functions: async () => [{ name: 'SUM', category: 'math_trig', signature: 'SUM(number1, ...)', description: '' }],
    dispose: () => void record('dispose')
  }
  return { engine, calls, called: (method: string) => calls.filter(call => call.method === method) }
}

/** A page channel stand-in: `reply` answers pushes and `emit` delivers server pushes. */
function fakeChannel(reply: Reply = async () => undefined) {
  const listeners = new Map<string, Set<(payload: unknown) => void>>()
  const pushes: { event: string; payload: any; at: number }[] = []
  let presence: ReturnType<SheetChannel['presence']> = []
  let answer = reply
  const channel: SheetChannel = {
    ready: Promise.resolve({}),
    push: async <T>(event: string, payload: object) => {
      pushes.push({ event, payload, at: Date.now() })
      if (event === 'office:sync') {
        return { revision: (payload as { revision: number }).revision, changes: [], reset_required: false } as T
      }
      return (await answer(event, payload)) as T
    },
    on: (event, callback) => {
      const set = listeners.get(event) ?? new Set()
      set.add(callback)
      listeners.set(event, set)
      return () => set.delete(callback)
    },
    presence: () => presence,
    close: () => {}
  }
  return {
    channel,
    pushes,
    applies: () => pushes.filter(push => push.event === 'office:apply'),
    answer(next: Reply) {
      answer = next
    },
    emit(event: string, payload: unknown) {
      for (const callback of listeners.get(event) ?? []) callback(payload)
    },
    present(next: ReturnType<SheetChannel['presence']>) {
      presence = next
      for (const callback of listeners.get('presence') ?? []) callback({})
    }
  }
}

function rejection(reason: string, details?: unknown) {
  return Object.assign(new Error(reason), { payload: { reason, details } })
}

function entry(revision: number, op: SpreadsheetOp, client = 'other', seq = 1): SheetEntry {
  return { revision, kind: 'op', client_id: client, client_seq: seq, op }
}

/** The acknowledgement the server sends for the request it committed at `revision`. */
function acknowledge(revision: number, request: any, before: SheetEntry[] = []): SheetChanges {
  return {
    revision,
    changes: [...before, entry(revision, request.op, request.client_id, request.client_seq)],
    reset_required: false,
    acknowledged_revision: revision
  }
}

async function until(condition: () => boolean, timeout = 2000) {
  const deadline = Date.now() + timeout
  while (!condition()) {
    if (Date.now() > deadline) throw new Error('condition not reached')
    await Bun.sleep(2)
  }
}

const models: SpreadsheetSession[] = []
afterEach(() => {
  for (const model of models.splice(0)) model[Symbol.dispose]()
})

/** Starts a session and waits for the catch-up sync that follows every bootstrap. */
async function started(
  socket: ReturnType<typeof fakeChannel>,
  engine: SpreadsheetEngine,
  options: { loads?: number[]; canEdit?: boolean; observe?: (model: SpreadsheetSession) => void } = {}
) {
  const notices: SpreadsheetNotice[] = []
  const revisions = [...(options.loads ?? [0])]
  let loads = 0
  const model = new SpreadsheetModel({
    canEdit: options.canEdit ?? true,
    selfUID: () => 'me',
    connect: async () => socket.channel,
    load: async () => {
      loads++
      return {
        kind: 'loaded',
        revision: revisions.shift() ?? 0,
        ops: [],
        bytes: new ArrayBuffer(4),
        unsupported: false
      }
    },
    createEngine: () => engine,
    notify: notice => notices.push(notice)
  })
  models.push(model)
  options.observe?.(model)
  await model.start()
  await until(() => socket.pushes.some(push => push.event === 'office:sync'))
  return { model, notices, loads: () => loads }
}

test('one request is in flight and later edits wait in the queue behind it', async () => {
  const { engine } = fakeEngine()
  const held = Promise.withResolvers<unknown>()
  const socket = fakeChannel(() => held.promise)
  const { model } = await started(socket, engine)
  await model.setCell({ row: 0, col: 0 }, '12')
  await model.setCell({ row: 1, col: 0 }, '=A1*2')
  await until(() => socket.applies().length === 1)
  await Bun.sleep(60)
  expect(socket.applies()).toHaveLength(1)
  expect(model.pending.value).toBe(2)
  const first = socket.applies()[0]!.payload
  expect(first).toMatchObject({ base_revision: 0, client_seq: 1, op: { type: 'cell.set', cell: 'A1', input: '12' } })
  socket.answer(async (_event, payload) => acknowledge(2, payload))
  held.resolve(acknowledge(1, first))
  await until(() => socket.applies().length === 2)
  expect(socket.applies()[1]!.payload).toMatchObject({ base_revision: 1, client_seq: 2, op: { cell: 'A2' } })
  await until(() => model.pending.value === 0)
  expect(model.revision.value).toBe(2)
})

test('an acknowledgement that holds only the own operation commits it and promotes the local document', async () => {
  const { engine, called } = fakeEngine()
  const socket = fakeChannel(async (_event, payload) => acknowledge(1, payload))
  const { model } = await started(socket, engine)
  await model.setCell({ row: 0, col: 0 }, '12')
  await until(() => model.pending.value === 0)
  expect(called('commit').map(call => call.args[0])).toEqual([
    [{ type: 'cell.set', sheet_id: 1, cell: 'A1', input: '12' }]
  ])
  expect(called('promote')).toHaveLength(1)
  expect(called('rebuildLocal')).toHaveLength(0)
  expect(model.revision.value).toBe(1)
})

test('foreign operations in an acknowledgement rebuild the local document and drop a queued edit that conflicts', async () => {
  const deleted = { type: 'line.delete', sheet_id: 1, axis: 'rows', at: 1, count: 1 }
  const { engine, called } = fakeEngine({ rebase: pending => pending.map(() => ({ conflict: 'target_deleted' })) })
  const held = Promise.withResolvers<unknown>()
  const socket = fakeChannel(() => held.promise)
  const { model, notices } = await started(socket, engine)
  await model.setCell({ row: 0, col: 0 }, '12')
  await until(() => socket.applies().length === 1)
  await model.setCell({ row: 1, col: 0 }, 'gone')
  held.resolve(acknowledge(2, socket.applies()[0]!.payload, [entry(1, deleted)]))
  await until(() => notices.length === 1)
  expect(called('rebuildLocal')[0]!.args).toEqual([
    [{ type: 'cell.set', sheet_id: 1, cell: 'A2', input: 'gone' }],
    [deleted]
  ])
  expect(notices[0]).toEqual({
    kind: 'conflict',
    op: { type: 'cell.set', sheet_id: 1, cell: 'A2', input: 'gone' },
    reason: 'target_deleted'
  })
  expect(model.pending.value).toBe(0)
  expect(model.revision.value).toBe(2)
  await Bun.sleep(60)
  expect(socket.applies()).toHaveLength(1)
  // The foreign row delete shifted the coordinates of earlier edits, so personal undo starts over.
  expect(model.canUndo.value).toBe(false)
})

test('office_conflict applies the missed changes and drops the request in flight', async () => {
  const inserted = { type: 'line.insert', sheet_id: 1, axis: 'rows', at: 0, count: 1 }
  const { engine, called } = fakeEngine()
  const socket = fakeChannel(async () => {
    throw rejection('office_conflict', {
      reason: 'overlapping_structural_edit',
      revision: 1,
      changes: [entry(1, inserted)]
    })
  })
  const { model, notices } = await started(socket, engine)
  await model.perform({ type: 'line.delete', sheet_id: 1, axis: 'rows', at: 0, count: 1 })
  await until(() => notices.length === 1)
  expect(called('commit').map(call => call.args[0])).toEqual([[inserted]])
  expect(called('promote')).toHaveLength(1)
  expect(notices[0]).toMatchObject({
    kind: 'conflict',
    reason: 'overlapping_structural_edit',
    op: { type: 'line.delete' }
  })
  expect(model.revision.value).toBe(1)
  expect(model.pending.value).toBe(0)
  expect(socket.applies()).toHaveLength(1)
})

test('reset_required bootstraps again and discards unsent edits', async () => {
  const { engine, called } = fakeEngine()
  const socket = fakeChannel(async () => ({ revision: 9, changes: [], reset_required: true }))
  const { model, notices, loads } = await started(socket, engine, { loads: [0, 9] })
  await model.setCell({ row: 0, col: 0 }, 'lost')
  await until(() => loads() === 2 && model.status.value === 'ready')
  expect(called('open')).toHaveLength(2)
  expect(notices).toEqual([{ kind: 'discarded', count: 1 }])
  expect(model.revision.value).toBe(9)
  expect(model.pending.value).toBe(0)
  socket.emit('office:changes', {
    revision: 10,
    changes: [{ ...entry(10, null as never), kind: 'reset' }],
    reset_required: false
  })
  await until(() => loads() === 3)
})

test('office_busy repeats the same request after 200 ms', async () => {
  const { engine } = fakeEngine()
  let attempts = 0
  const socket = fakeChannel(async (_event, payload) => {
    if (++attempts < 3) throw rejection('office_busy')
    return acknowledge(1, payload)
  })
  const { model } = await started(socket, engine)
  await model.setCell({ row: 0, col: 0 }, '7')
  await until(() => model.pending.value === 0)
  const applies = socket.applies()
  expect(applies).toHaveLength(3)
  expect(new Set(applies.map(push => JSON.stringify(push.payload))).size).toBe(1)
  expect(applies[1]!.at - applies[0]!.at).toBeGreaterThanOrEqual(190)
  expect(applies[2]!.at - applies[1]!.at).toBeGreaterThanOrEqual(190)
})

test('presence updates are throttled to one every 250 ms and blur clears the selection', async () => {
  const { engine } = fakeEngine()
  const socket = fakeChannel()
  const { model } = await started(socket, engine)
  const presence = () => socket.pushes.filter(push => push.event === 'office:presence')
  model.select({ anchor: { row: 0, col: 0 }, focus: { row: 0, col: 1 } })
  await until(() => presence().length === 1)
  for (const row of [1, 2, 3]) model.select({ anchor: { row, col: 0 }, focus: { row, col: 0 } })
  await Bun.sleep(120)
  expect(presence()).toHaveLength(1)
  await until(() => presence().length === 2)
  expect(presence()[1]!.at - presence()[0]!.at).toBeGreaterThanOrEqual(240)
  expect(presence().map(push => push.payload.selection)).toEqual([
    { sheet_id: 1, range: 'A1:B1' },
    { sheet_id: 1, range: 'A4' }
  ])
  model.blur()
  expect(presence().at(-1)!.payload).toEqual({ selection: null })
  socket.present([
    { id: 'me', metas: [{ principal_uid: 'me', name: 'Me', selection: null }] },
    { id: 'peer', metas: [{ principal_uid: 'peer', name: 'Peer', selection: { sheet_id: 1, range: 'B2' } }] }
  ])
  expect(model.members.value.map(member => [member.uid, member.name, member.selections])).toEqual([
    ['peer', 'Peer', [{ sheet_id: 1, range: 'B2' }]]
  ])
})

test('undo restores the previous input of a cell and redo applies the edit again', async () => {
  const { engine, called } = fakeEngine({ inputs: rect => [[rect.r0 === 0 ? 'before' : '']] })
  const socket = fakeChannel(async (_event, payload) => acknowledge(socket.applies().length, payload))
  const { model } = await started(socket, engine)
  await model.setCell({ row: 0, col: 0 }, 'after')
  await model.setCell({ row: 1, col: 0 }, 'new')
  expect(model.canUndo.value).toBe(true)
  await model.undo()
  await model.undo()
  expect(model.canUndo.value).toBe(false)
  expect(model.canRedo.value).toBe(true)
  await model.redo()
  const applied = called('applyLocal').map(call => call.args[0])
  const formats = (range: string) => ({
    type: 'range.restore_formats',
    sheet_id: 1,
    range,
    lines: [],
    cells: [{ row: 0, col: 0, format: { bold: false } }]
  })
  // Typed input can set a number format, so undo puts back the input and then the format.
  expect(applied.slice(2)).toEqual([
    { type: 'range.set_values', sheet_id: 1, range: 'A2', values: [[null]] },
    formats('A2'),
    { type: 'range.set_values', sheet_id: 1, range: 'A1', values: [['before']] },
    formats('A1'),
    { type: 'cell.set', sheet_id: 1, cell: 'A1', input: 'after' }
  ])
  await until(() => model.pending.value === 0)
  expect(socket.applies()).toHaveLength(7)
})

test('a pushed change that skips a revision catches up with office:sync', async () => {
  const { engine, called } = fakeEngine()
  const socket = fakeChannel()
  const { model } = await started(socket, engine)
  const syncs = () => socket.pushes.filter(push => push.event === 'office:sync')
  const before = syncs().length
  socket.emit('office:changes', {
    revision: 3,
    changes: [entry(3, { type: 'cell.set', sheet_id: 1, cell: 'C1', input: '1' })],
    reset_required: false
  })
  await until(() => syncs().length === before + 1)
  expect(syncs().at(-1)!.payload).toEqual({ revision: 0 })
  expect(called('commit')).toHaveLength(0)
  socket.emit('office:changes', {
    revision: 1,
    changes: [entry(1, { type: 'cell.set', sheet_id: 1, cell: 'C1', input: '1' })],
    reset_required: false
  })
  await until(() => model.revision.value === 1)
  expect(called('promote')).toHaveLength(1)
})

test('Enter moves the selection at once, so typing straight on edits the next cell', async () => {
  const { engine, called } = fakeEngine()
  const socket = fakeChannel(async (_event, payload) => acknowledge(socket.applies().length, payload))
  const { model } = await started(socket, engine)
  model.edit({ row: 0, col: 0 }, '12')
  const committed = model.commitEdit('down')
  expect(model.selection.value.anchor).toEqual({ row: 1, col: 0 })
  model.edit(model.selection.value.anchor, '=A1*2')
  await committed
  await model.commitEdit('down')
  expect(called('applyLocal').map(call => (call.args[0] as SpreadsheetOp).cell)).toEqual(['A1', 'A2'])
  expect(model.selection.value.anchor).toEqual({ row: 2, col: 0 })
})

test('Enter stays unsaved through worker reads, local application, metadata refresh and the server acknowledgement', async () => {
  const { engine } = fakeEngine()
  const acknowledged = Promise.withResolvers<unknown>()
  const socket = fakeChannel(() => acknowledged.promise)
  const { model } = await started(socket, engine)
  const reads = Promise.withResolvers<void>()
  const applied = Promise.withResolvers<void>()
  const refreshed = Promise.withResolvers<void>()
  let stage = ''
  engine.cellInputs = async () => {
    stage = 'read'
    await reads.promise
    return [['before']]
  }
  engine.applyLocal = async op => {
    stage = 'apply'
    await applied.promise
    return { op }
  }
  engine.sheets = async () => {
    stage = 'refresh'
    await refreshed.promise
    return [SHEET]
  }
  model.edit({ row: 0, col: 0 }, 'after')
  const committed = model.commitEdit('down')
  expect(model.pending.value).toBeGreaterThan(0)
  await until(() => stage === 'read')
  expect(model.pending.value).toBeGreaterThan(0)
  reads.resolve()
  await until(() => stage === 'apply')
  expect(model.pending.value).toBeGreaterThan(0)
  applied.resolve()
  await until(() => stage === 'refresh')
  expect(model.pending.value).toBeGreaterThan(0)
  refreshed.resolve()
  await committed
  await until(() => socket.applies().length === 1)
  expect(model.pending.value).toBe(1)
  acknowledged.resolve(acknowledge(1, socket.applies()[0]!.payload))
  await until(() => model.pending.value === 0)
})

for (const action of ['format', 'paste', 'clear', 'undo', 'redo'] as const) {
  test(`${action} is unsaved as soon as its local work is requested`, async () => {
    const { engine } = fakeEngine()
    const socket = fakeChannel(async (_event, payload) => acknowledge(socket.applies().length, payload))
    const { model } = await started(socket, engine)
    if (action === 'undo' || action === 'redo') {
      await model.setCell({ row: 0, col: 0 }, 'seed')
      await until(() => model.pending.value === 0)
      if (action === 'redo') {
        await model.undo()
        await until(() => model.pending.value === 0)
      }
    }
    const released = Promise.withResolvers<void>()
    let entered = false
    engine.applyLocal = async op => {
      entered = true
      await released.promise
      return { op }
    }
    const run = {
      format: () => model.perform({ type: 'range.format', sheet_id: 1, range: 'A1', patch: { bold: true } }),
      paste: () => model.setValues({ row: 0, col: 0 }, [['12', '24']]),
      clear: () => model.clearContents(),
      undo: () => model.undo(),
      redo: () => model.redo()
    }[action]()
    expect(model.pending.value).toBeGreaterThan(0)
    await until(() => entered)
    expect(model.pending.value).toBeGreaterThan(0)
    released.resolve()
    await run
    await until(() => model.pending.value === 0)
  })
}

test('failed worker preparation clears the unsaved count', async () => {
  const { engine } = fakeEngine()
  const { model, notices } = await started(fakeChannel(), engine)
  engine.applyLocal = async () => {
    throw new Error('invalid format')
  }
  await model.perform({ type: 'range.format', sheet_id: 1, range: 'A1', patch: { bold: true } })
  expect(model.pending.value).toBe(0)
  expect(notices[0]?.kind).toBe('rejected')
  engine.cellInputs = async () => {
    throw new Error('worker stopped')
  }
  await expect(model.setCell({ row: 0, col: 0 }, 'unsent')).rejects.toThrow('worker stopped')
  expect(model.pending.value).toBe(0)
})

test('a reset discards local work queued behind it before the worker applies it', async () => {
  const { engine, called } = fakeEngine()
  const socket = fakeChannel()
  const { model, notices } = await started(socket, engine, { loads: [0, 9] })
  socket.emit('office:changes', { revision: 9, changes: [], reset_required: true })
  const queued = model.setCell({ row: 0, col: 0 }, 'old workbook edit')
  expect(model.pending.value).toBe(1)
  expect(await queued).toBeUndefined()
  expect(called('applyLocal')).toHaveLength(0)
  expect(model.revision.value).toBe(9)
  expect(model.pending.value).toBe(0)
  expect(notices).toEqual([{ kind: 'discarded', count: 1 }])
})

test('an edit committed while a reset reloads the workbook is discarded with a notice', async () => {
  const { engine, called } = fakeEngine()
  const socket = fakeChannel()
  const { model, notices } = await started(socket, engine, { loads: [0, 9] })
  const reopened = Promise.withResolvers<void>()
  const open = engine.open
  engine.open = async (bytes, ops) => {
    await reopened.promise
    return open(bytes, ops)
  }
  model.edit({ row: 0, col: 0 }, 'typed during reload')
  socket.emit('office:changes', { revision: 9, changes: [], reset_required: true })
  await until(() => model.status.value === 'loading')
  expect(await model.commitEdit('down')).toBeUndefined()
  expect(model.pending.value).toBe(0)
  expect(notices).toEqual([{ kind: 'discarded', count: 1 }])
  reopened.resolve()
  await until(() => model.status.value === 'ready')
  expect(called('applyLocal')).toHaveLength(0)
  expect(model.revision.value).toBe(9)
})

test('disposing during a worker edit clears pending work without sending it later', async () => {
  const { engine } = fakeEngine()
  const socket = fakeChannel()
  const { model } = await started(socket, engine)
  const released = Promise.withResolvers<void>()
  let entered = false
  engine.applyLocal = async op => {
    entered = true
    await released.promise
    return { op }
  }
  const edit = model.setCell({ row: 0, col: 0 }, 'closed tab')
  await until(() => entered)
  model[Symbol.dispose]()
  expect(model.pending.value).toBe(0)
  released.resolve()
  expect(await edit).toBeUndefined()
  expect(model.pending.value).toBe(0)
  expect(socket.applies()).toHaveLength(0)
})

test('a viewer without node_edit reads the workbook but cannot queue edits', async () => {
  const { engine, called } = fakeEngine()
  const socket = fakeChannel()
  const { model } = await started(socket, engine, { canEdit: false })
  expect(model.status.value).toBe('read_only')
  expect(await model.setCell({ row: 0, col: 0 }, 'x')).toBeUndefined()
  expect(called('applyLocal')).toHaveLength(0)
})

test('AutoSum opens a draft over the numbers above, or writes one formula per column below a range', async () => {
  const numbers = (rect: Rect): Viewport => ({
    cells: [2, 3, 4]
      .filter(row => row >= rect.r0 && row <= rect.r1 && rect.c0 === 1)
      .map(row => ({ row, col: 1, text: String(row), kind: 'number', style: 0 })),
    styles: [],
    merges: [],
    spills: [],
    rows: [],
    cols: [],
    filter: null,
    tables: [],
    validations: []
  })
  const { engine, called } = fakeEngine({ viewport: numbers })
  const socket = fakeChannel(async (_event, payload) => acknowledge(socket.applies().length, payload))
  const { model } = await started(socket, engine)
  model.select({ anchor: { row: 5, col: 1 }, focus: { row: 5, col: 1 } })
  await model.autoSum('SUM')
  expect(model.draft.value).toEqual({ sheetID: 1, cell: { row: 5, col: 1 }, text: '=SUM(B3:B5)', caret: 11 })
  model.cancelEdit()
  model.select({ anchor: { row: 0, col: 4 }, focus: { row: 0, col: 4 } })
  await model.autoSum('AVERAGE')
  expect(model.draft.value).toMatchObject({ text: '=AVERAGE()', caret: 9 })
  model.cancelEdit()
  model.select({ anchor: { row: 2, col: 1 }, focus: { row: 4, col: 2 } })
  await model.autoSum('MAX')
  expect(called('applyLocal').at(-1)!.args[0]).toEqual({
    type: 'range.set_values',
    sheet_id: 1,
    range: 'B6:C6',
    values: [['=MAX(B3:B5)', '=MAX(C3:C5)']]
  })
})

test('fills, pastes, and Ctrl+Enter are undoable value edits, and pasting a cut block moves it', async () => {
  const { engine, called } = fakeEngine({ inputs: rect => [[`was ${rect.r0}`]] })
  const socket = fakeChannel(async (_event, payload) => acknowledge(socket.applies().length, payload))
  const { model } = await started(socket, engine)
  await model.fill({ r0: 0, c0: 0, r1: 1, c1: 0 }, { r0: 0, c0: 0, r1: 5, c1: 0 })
  expect(called('applyLocal').at(-1)!.args[0]).toEqual({
    type: 'range.fill',
    sheet_id: 1,
    range: 'A1:A2',
    to: 'A1:A6',
    mode: 'series'
  })
  expect(model.canUndo.value).toBe(true)

  model.select({ anchor: { row: 1, col: 1 }, focus: { row: 1, col: 1 } })
  const copied = await model.copy(true)
  expect(model.copied.value).toEqual({ sheetID: 1, rect: { r0: 1, c0: 1, r1: 1, c1: 1 }, cut: copied!.cut })
  model.select({ anchor: { row: 3, col: 3 }, focus: { row: 3, col: 3 } })
  await model.paste(copied!.block, 'values')
  expect(called('pasteOp').at(-1)!.args.slice(1)).toEqual(['D4', 'values'])
  expect(called('applyLocal').at(-1)!.args[0]).toMatchObject({ type: 'range.paste', range: 'D4' })
  await model.paste(copied!.block, 'all', copied!.cut)
  expect(called('applyLocal').at(-1)!.args[0]).toEqual({
    type: 'range.move',
    sheet_id: 1,
    from: 'B2',
    to_sheet_id: 1,
    to_cell: 'D4'
  })
  expect(model.copied.value).toBeNull()

  model.select({ anchor: { row: 0, col: 2 }, focus: { row: 2, col: 3 } })
  model.edit({ row: 0, col: 2 }, '=A1*2')
  await model.commitToSelection()
  expect(
    called('applyLocal')
      .slice(-3)
      .map(call => call.args[0])
  ).toEqual([
    { type: 'cell.set', sheet_id: 1, cell: 'C1', input: '=A1*2' },
    { type: 'range.fill', sheet_id: 1, range: 'C1', to: 'C1:C3', mode: 'copy' },
    { type: 'range.fill', sheet_id: 1, range: 'C1:C3', to: 'C1:D3', mode: 'copy' }
  ])
})

test('the document version changes once the workbook is ready, so views read while it loaded read it again', async () => {
  const { engine } = fakeEngine()
  let published: number | undefined
  let ready: number | undefined
  await started(fakeChannel(), engine, {
    observe: model => {
      // The page shows the toolbar and the grid as soon as the sheets arrive, before the reads work.
      model.sheets.subscribe(list => {
        if (list.length && published === undefined) published = model.version.peek()
      })
      model.status.subscribe(status => {
        if (status === 'ready') ready = model.version.peek()
      })
    }
  })
  expect(ready).toBeGreaterThan(published!)
})

test('each fill option replaces the fill before it, so formatting only keeps the values from before the fill', async () => {
  let values = ''
  const { engine } = fakeEngine({ inputs: rect => Array.from({ length: rect.r1 - rect.r0 + 1 }, () => [values]) })
  const apply = engine.applyLocal
  engine.applyLocal = async op => {
    if (op.type === 'range.set_values') values = String((op.values as (string | null)[][])[0]![0] ?? '')
    if (op.type === 'range.fill' && op.mode !== 'formats') values = `${String(op.mode)} fill`
    return apply(op)
  }
  const socket = fakeChannel(async (_event, payload) => acknowledge(socket.applies().length, payload))
  const { model } = await started(socket, engine)
  const source = { r0: 0, c0: 0, r1: 1, c1: 0 }
  const target = { r0: 0, c0: 0, r1: 4, c1: 0 }
  await model.fill(source, target)
  await model.refill(source, target, 'copy')
  expect(values).toBe('copy fill')
  await model.refill(source, target, 'series')
  expect(values).toBe('series fill')
  await model.refill(source, target, 'formats')
  expect(values).toBe('')
  // The options replaced one another, so one undo puts the cells back as they were before the drag.
  await model.undo()
  expect(model.canUndo.value).toBe(false)
})

test('the format painter repeats the held formats over the target and lets go unless it is sticky', async () => {
  const { engine, called } = fakeEngine()
  const socket = fakeChannel(async (_event, payload) => acknowledge(socket.applies().length, payload))
  const { model } = await started(socket, engine)
  model.select({ anchor: { row: 0, col: 0 }, focus: { row: 0, col: 0 } })
  await model.pickFormats(false)
  await model.paintFormats({ r0: 4, c0: 1, r1: 5, c1: 3 })
  const [block, cell, mode] = called('pasteOp').at(-1)!.args as [{ rows: unknown[][] }, string, string]
  expect([block.rows.length, block.rows[0]!.length, cell, mode]).toEqual([2, 3, 'B5', 'formats'])
  expect(model.painter.value).toBeNull()
  await model.pickFormats(true)
  await model.paintFormats({ r0: 0, c0: 0, r1: 0, c1: 0 })
  expect(model.painter.value?.sticky).toBe(true)
  model.clearCopied()
  expect(model.painter.value).toBeNull()
})

test('the format painter can accept a target before the Worker finishes reading the source', async () => {
  const { engine, called } = fakeEngine()
  engine.sheets = async () => [SHEET, { ...SHEET, sheet_id: 2, name: 'Another sheet' }]
  const copyBlock = engine.copyBlock
  const read = Promise.withResolvers<void>()
  engine.copyBlock = async (sheetID, range) => {
    await read.promise
    return copyBlock(sheetID, range)
  }
  const socket = fakeChannel(async (_event, payload) => acknowledge(socket.applies().length, payload))
  const { model, notices } = await started(socket, engine)

  const pick = model.pickFormats(false)
  expect(model.painter.value?.sticky).toBe(false)
  const sticky = model.pickFormats(true)
  expect(model.painter.value?.sticky).toBe(true)
  const paint = model.paintFormats({ r0: 0, c0: 1, r1: 0, c1: 1 })
  expect(model.pending.value).toBe(1)
  model.showSheet(2)
  model.clearCopied()
  read.resolve()
  await Promise.all([pick, sticky, paint])

  expect(called('copyBlock')).toHaveLength(1)
  expect(called('applyLocal').at(-1)?.args[0]).toMatchObject({ type: 'range.paste', sheet_id: 1, range: 'B1' })
  expect(model.painter.value).toBeNull()

  const failure = new Error('Cannot copy the source formats')
  engine.copyBlock = async () => {
    throw failure
  }
  await model.pickFormats(false)
  expect(model.painter.value).toBeNull()
  expect(notices).toEqual([{ kind: 'failed', error: failure }])
})

test('a formula draft stays open on another sheet while it waits for a reference and commits on its own sheet', async () => {
  const { engine, called } = fakeEngine()
  engine.sheets = async () => [SHEET, { ...SHEET, sheet_id: 2, name: '汇率' }]
  const socket = fakeChannel(async (_event, payload) => acknowledge(socket.applies().length, payload))
  const { model } = await started(socket, engine)
  model.edit({ row: 0, col: 0 }, '=SUM(')
  model.showSheet(2)
  expect(model.draft.value?.sheetID).toBe(1)
  model.type('=SUM(汇率!B2')
  await model.commitEdit('down')
  expect(model.activeSheetID.value).toBe(1)
  expect(model.selection.value.anchor).toEqual({ row: 1, col: 0 })
  expect(called('applyLocal').at(-1)!.args[0]).toEqual({
    type: 'cell.set',
    sheet_id: 1,
    cell: 'A1',
    input: '=SUM(汇率!B2'
  })
  model.edit({ row: 0, col: 0 }, '=A1')
  model.showSheet(2)
  expect(model.draft.value).toBeNull()
})

test('formats, outlines, merges, and unmerges are undo steps, and other edits end the history', async () => {
  const merged = (rect: Rect): Viewport => ({
    cells: [],
    styles: [],
    merges: rect.r0 <= 1 && rect.c0 <= 1 ? ['B2:C2'] : [],
    spills: [],
    rows: [],
    cols: [],
    filter: null,
    tables: [],
    validations: []
  })
  const { engine, called } = fakeEngine({ viewport: merged })
  const socket = fakeChannel(async (_event, payload) => acknowledge(socket.applies().length, payload))
  const { model } = await started(socket, engine)
  const applied = () => called('applyLocal').map(call => call.args[0] as SpreadsheetOp)

  await model.format({ r0: 0, c0: 0, r1: 1, c1: 1 }, { bold: true })
  expect(called('formatSnapshot').at(-1)!.args).toEqual(['A1:B2'])
  await model.undo()
  expect(applied().at(-1)).toMatchObject({ type: 'range.restore_formats', range: 'A1:B2' })
  await model.redo()
  expect(applied().at(-1)).toEqual({ type: 'range.format', sheet_id: 1, range: 'A1:B2', patch: { bold: true } })

  const outline = ['A1:B1', 'A2:B2', 'A1:A2', 'B1:B2'].map(range => ({
    type: 'range.format',
    range,
    patch: { borders: { top: { style: 'thin' } } }
  }))
  await model.formatEach({ r0: 0, c0: 0, r1: 1, c1: 1 }, outline)
  const before = applied().length
  await model.undo()
  expect(applied().length - before).toBe(1)

  await model.merge({ r0: 1, c0: 0, r1: 1, c1: 1 })
  await model.undo()
  expect(
    applied()
      .slice(-4)
      .map(op => [op.type, op.range])
  ).toEqual([
    ['range.unmerge', 'A2:C2'],
    ['range.merge', 'B2:C2'],
    ['range.set_values', 'A2:C2'],
    ['range.restore_formats', 'A2:C2']
  ])

  await model.unmerge({ r0: 1, c0: 1, r1: 1, c1: 2 })
  await model.undo()
  expect(applied().at(-1)).toEqual({ type: 'range.merge', sheet_id: 1, range: 'B2:C2' })

  expect(model.canUndo.value).toBe(true)
  await model.perform({ type: 'sheet.freeze', sheet_id: 1, rows: 1, cols: 0 })
  expect(model.canUndo.value).toBe(false)
  expect(model.canRedo.value).toBe(false)
})

test('an undo pressed while a merge reads its areas undoes that merge, not the edit before it', async () => {
  const { engine, called } = fakeEngine()
  const socket = fakeChannel(async (_event, payload) => acknowledge(socket.applies().length, payload))
  const { model } = await started(socket, engine)
  await model.format({ r0: 0, c0: 0, r1: 0, c1: 0 }, { font_size: 24 })
  const merging = model.merge({ r0: 2, c0: 0, r1: 2, c1: 1 })
  expect(model.pending.value).toBeGreaterThan(0)
  await Promise.all([merging, model.undo()])
  const types = called('applyLocal').map(call => (call.args[0] as SpreadsheetOp).type)
  expect(types.slice(-4)).toEqual(['range.merge', 'range.unmerge', 'range.set_values', 'range.restore_formats'])
  expect(model.canUndo.value).toBe(true)
})

test('typed input that fails a stop rule is not applied, and a warning rule lets it through with a notice', async () => {
  const { engine, called } = fakeEngine({
    validate: (_cell, input) =>
      input === 'maybe'
        ? { message: '请选择', style: 'stop' }
        : input === 'odd'
          ? { message: '请复核', style: 'warning' }
          : null
  })
  const socket = fakeChannel(async (_event, payload) => acknowledge(socket.applies().length, payload))
  const { model, notices } = await started(socket, engine)
  model.edit({ row: 0, col: 0 }, 'maybe')
  await model.commitEdit('down')
  expect(called('applyLocal')).toHaveLength(0)
  expect(notices).toEqual([{ kind: 'invalid', cell: 'A1', message: '请选择', style: 'stop' }])
  model.edit({ row: 1, col: 0 }, 'odd')
  await model.commitEdit('down')
  expect(called('applyLocal').map(call => (call.args[0] as SpreadsheetOp).cell)).toEqual(['A2'])
  expect(notices.at(-1)).toEqual({ kind: 'invalid', cell: 'A2', message: '请复核', style: 'warning' })
  expect(called('validateInput').map(call => call.args)).toEqual([
    ['A1', 'maybe'],
    ['A2', 'odd']
  ])
})

test('a replace writes the matched cells as one undo step and find reads through the engine', async () => {
  const { engine, called } = fakeEngine()
  const socket = fakeChannel(async (_event, payload) => acknowledge(socket.applies().length, payload))
  const { model } = await started(socket, engine)
  expect(await model.find('total', { formulas: true }, 'workbook')).toEqual([
    { sheet_id: 1, cell: 'A1', text: 'total' }
  ])
  expect(called('find').map(call => call.args)).toEqual([[0, 'total']])
  expect(await model.filterValues(2)).toEqual([{ text: 'a', blank: false, selected: true }])
  await model.replaceCells(1, [
    { cell: 'A1', input: 'sum' },
    { cell: 'C3', input: 'sum' }
  ])
  expect(called('applyLocal').map(call => (call.args[0] as SpreadsheetOp).cell)).toEqual(['A1', 'C3'])
  expect(model.canUndo.value).toBe(true)
  await model.undo()
  const restored = called('applyLocal').at(-1)!.args[0] as SpreadsheetOp
  expect([restored.type, restored.range]).toEqual(['range.set_values', 'A1:C3'])
})
