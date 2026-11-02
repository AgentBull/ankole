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
import type { Rect, SheetInfo, SpreadsheetOp } from './spreadsheet-grid'

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
  behaviour: { inputs?: (rect: Rect) => string[][]; rebase?: (pending: SpreadsheetOp[]) => Rebased[] } = {}
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
    viewport: async () => ({ cells: [], styles: [], merges: [], spills: [], rows: [], cols: [] }),
    cellInputs: async (_sheetID, rect) =>
      behaviour.inputs?.(rect) ??
      Array.from({ length: rect.r1 - rect.r0 + 1 }, () => Array.from({ length: rect.c1 - rect.c0 + 1 }, () => '')),
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
      if (event === 'sheet:sync') {
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
    applies: () => pushes.filter(push => push.event === 'sheet:apply'),
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
  options: { loads?: number[]; canEdit?: boolean } = {}
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
  await model.start()
  await until(() => socket.pushes.some(push => push.event === 'sheet:sync'))
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

test('spreadsheet_conflict applies the missed changes and drops the request in flight', async () => {
  const inserted = { type: 'line.insert', sheet_id: 1, axis: 'rows', at: 0, count: 1 }
  const { engine, called } = fakeEngine()
  const socket = fakeChannel(async () => {
    throw rejection('spreadsheet_conflict', {
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
  socket.emit('sheet:changes', {
    revision: 10,
    changes: [{ ...entry(10, null as never), kind: 'reset' }],
    reset_required: false
  })
  await until(() => loads() === 3)
})

test('spreadsheet_busy repeats the same request after 200 ms', async () => {
  const { engine } = fakeEngine()
  let attempts = 0
  const socket = fakeChannel(async (_event, payload) => {
    if (++attempts < 3) throw rejection('spreadsheet_busy')
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
  const presence = () => socket.pushes.filter(push => push.event === 'sheet:presence')
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
  expect(applied.slice(2)).toEqual([
    { type: 'range.set_values', sheet_id: 1, range: 'A2', values: [[null]] },
    { type: 'range.set_values', sheet_id: 1, range: 'A1', values: [['before']] },
    { type: 'cell.set', sheet_id: 1, cell: 'A1', input: 'after' }
  ])
  await until(() => model.pending.value === 0)
  expect(socket.applies()).toHaveLength(5)
})

test('a pushed change that skips a revision catches up with sheet:sync', async () => {
  const { engine, called } = fakeEngine()
  const socket = fakeChannel()
  const { model } = await started(socket, engine)
  const syncs = () => socket.pushes.filter(push => push.event === 'sheet:sync')
  const before = syncs().length
  socket.emit('sheet:changes', {
    revision: 3,
    changes: [entry(3, { type: 'cell.set', sheet_id: 1, cell: 'C1', input: '1' })],
    reset_required: false
  })
  await until(() => syncs().length === before + 1)
  expect(syncs().at(-1)!.payload).toEqual({ revision: 0 })
  expect(called('commit')).toHaveLength(0)
  socket.emit('sheet:changes', {
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

test('a viewer without node_edit reads the workbook but cannot queue edits', async () => {
  const { engine, called } = fakeEngine()
  const socket = fakeChannel()
  const { model } = await started(socket, engine, { canEdit: false })
  expect(model.status.value).toBe('read_only')
  expect(await model.setCell({ row: 0, col: 0 }, 'x')).toBeUndefined()
  expect(called('applyLocal')).toHaveLength(0)
})
