import { afterEach, describe, expect, it } from 'bun:test'
import {
  OfficeCollaborationModel,
  type OfficeChangeSet,
  type OfficeChanges,
  type OfficeChannel,
  type OfficeEntry,
  type OfficeNotice,
  type OfficePendingResult,
  type OfficeSnapshotBase,
  type OfficeSyncEngine
} from './office-collaboration'

type TestSnapshot = OfficeSnapshotBase & {
  block: number
  text: string
}

function makeFakeEngine(options?: {
  rebase?: (pending: OfficeChangeSet[], confirmed: OfficeChangeSet[]) => OfficePendingResult[]
  draftConflict?: boolean
  undoOnCommitOnly?: boolean
}) {
  let text = ''
  let committedText = ''
  let block = 0
  let composing = false
  let undoStack: string[] = []
  let redoStack: string[] = []
  let openedCheckpoint: string | null | undefined
  const snap = (): TestSnapshot => ({
    block,
    text,
    canUndo: undoStack.length > 0,
    canRedo: redoStack.length > 0,
    editing: text !== committedText || composing,
    composing,
    presenceSelection: { story: 'body', block }
  })

  const engine: OfficeSyncEngine<TestSnapshot> & {
    typeText(next: string, isComposing?: boolean): TestSnapshot
    moveBlock(nextBlock: number): TestSnapshot
    readonly openedCheckpoint: string | null | undefined
  } = {
    get openedCheckpoint() {
      return openedCheckpoint
    },
    async open(_bytes, _ops, checkpoint) {
      openedCheckpoint = checkpoint
      return snap()
    },
    typeText(next: string, isComposing = false) {
      if (!options?.undoOnCommitOnly && !isComposing && text === committedText) {
        undoStack.push(text)
        redoStack = []
      }
      text = next
      composing = isComposing
      return snap()
    },
    moveBlock(nextBlock: number) {
      block = nextBlock
      return snap()
    },
    async commitLocalStep() {
      if (composing || text === committedText) {
        return { op: null, snapshot: snap() }
      }
      if (options?.undoOnCommitOnly) {
        undoStack.push(committedText)
        redoStack = []
      }
      const op: OfficeChangeSet = { model_version: 1, edits: [{ type: 'block.put', at: block, text }] }
      committedText = text
      return { op, snapshot: snap() }
    },
    async applyRemote(confirmedOps, pendingOps) {
      const results = options?.rebase?.(pendingOps, confirmedOps) ?? pendingOps.map(op => ({ op }))
      const dropped = results.filter(item => 'conflict' in item).length
      const firstConflict = results.find((item): item is { conflict: string } => 'conflict' in item)
      const draftConflict = Boolean(options?.draftConflict && text !== committedText)
      if (draftConflict) {
        text = committedText
        undoStack = []
        redoStack = []
      }
      return {
        report: {
          dropped_pending: dropped,
          draft_conflict: draftConflict,
          conflict_reason: draftConflict ? 'block_changed' : (firstConflict?.conflict ?? null),
          pending_results: results,
          active_block: block
        },
        snapshot: snap()
      }
    },
    async undo() {
      const prev = undoStack.pop()
      if (prev === undefined) return { op: null, snapshot: snap() }
      redoStack.push(text)
      text = prev
      committedText = text
      const op: OfficeChangeSet = { model_version: 1, edits: [{ type: 'block.put', at: block, text }] }
      return { op, snapshot: snap() }
    },
    async redo() {
      const next = redoStack.pop()
      if (next === undefined) return { op: null, snapshot: snap() }
      undoStack.push(text)
      text = next
      committedText = text
      const op: OfficeChangeSet = { model_version: 1, edits: [{ type: 'block.put', at: block, text }] }
      return { op, snapshot: snap() }
    },
    dispose() {}
  }

  return engine
}

function makeFakeChannel(reply?: (event: string, payload: any) => Promise<unknown>) {
  const listeners = new Map<string, Set<(payload: unknown) => void>>()
  const pushes: { event: string; payload: any; at: number }[] = []
  let presence: ReturnType<OfficeChannel['presence']> = []
  let answer = reply ?? (async () => undefined)
  const channel: OfficeChannel = {
    ready: Promise.resolve({}),
    async push<T>(event: string, payload: object) {
      pushes.push({ event, payload, at: Date.now() })
      if (event === 'office:sync') {
        return { revision: (payload as { revision: number }).revision, changes: [], reset_required: false } as T
      }
      if (event === 'office:presence') return {} as T
      return (await answer(event, payload)) as T
    },
    on(event, callback) {
      const set = listeners.get(event) ?? new Set()
      set.add(callback)
      listeners.set(event, set)
      return () => set.delete(callback)
    },
    presence: () => presence,
    close() {}
  }
  return {
    channel,
    pushes,
    applies: () => pushes.filter(p => p.event === 'office:apply'),
    presences: () => pushes.filter(p => p.event === 'office:presence'),
    setAnswer(next: (event: string, payload: any) => Promise<unknown>) {
      answer = next
    },
    emit(event: string, payload: unknown) {
      for (const cb of listeners.get(event) ?? []) cb(payload)
    },
    setPresence(next: ReturnType<OfficeChannel['presence']>) {
      presence = next
      for (const cb of listeners.get('presence') ?? []) cb({})
    }
  }
}

function acknowledge(revision: number, request: any, before: OfficeEntry[] = []): OfficeChanges {
  return {
    revision,
    changes: [
      ...before,
      {
        revision,
        kind: 'op',
        client_id: request.client_id,
        client_seq: request.client_seq,
        op: request.op
      }
    ],
    reset_required: false,
    acknowledged_revision: revision
  }
}

async function until(cond: () => boolean, timeout = 2000) {
  const deadline = Date.now() + timeout
  while (!cond()) {
    if (Date.now() > deadline) throw new Error('condition timed out')
    await Bun.sleep(5)
  }
}

const activeModels: { [Symbol.dispose](): void }[] = []
afterEach(() => {
  for (const m of activeModels.splice(0)) m[Symbol.dispose]()
})

async function openSaveModel(engine: ReturnType<typeof makeFakeEngine>, sock: ReturnType<typeof makeFakeChannel>) {
  const notices: OfficeNotice[] = []
  const model = new OfficeCollaborationModel<TestSnapshot>({
    canEdit: true,
    selfUID: () => 'me',
    connect: async () => sock.channel,
    load: async () => ({
      kind: 'loaded',
      format: 'presentation',
      revision: 0,
      ops: [],
      bytes: new ArrayBuffer(4),
      metadata: null
    }),
    createEngine: () => engine,
    notify: notice => notices.push(notice),
    idleCommitMs: 30
  })
  activeModels.push(model)
  await model.start()
  await until(() => sock.pushes.some(p => p.event === 'office:sync'))
  return { model, notices }
}

describe('OfficeCollaborationModel', () => {
  it('saves the last draft and waits for server acknowledgement of both edits before leaving', async () => {
    const engine = makeFakeEngine()
    const first = Promise.withResolvers<unknown>()
    const second = Promise.withResolvers<unknown>()
    const sock = makeFakeChannel(() => first.promise)
    const { model } = await openSaveModel(engine, sock)

    await model.mutate(async () => ({ result: true, snapshot: engine.typeText('first'), commit: true }))
    await until(() => sock.applies().length === 1)
    await model.mutate(async () => ({ result: true, snapshot: engine.typeText('second') }))
    const saved = model.savePending()
    let finished = false
    void saved.then(() => (finished = true))
    expect(model.savePending()).toBe(saved)

    sock.setAnswer(() => second.promise)
    first.resolve(acknowledge(1, sock.applies()[0]!.payload))
    await until(() => sock.applies().length === 2)
    expect(finished).toBe(false)
    second.resolve(acknowledge(2, sock.applies()[1]!.payload))

    expect(await saved).toBe(true)
    expect(model.revision.value).toBe(2)
    expect(model.pending.value).toBe(0)
  })

  it('keeps unacknowledged edits available for retry when the connection fails', async () => {
    const engine = makeFakeEngine()
    const sock = makeFakeChannel(async () => {
      throw new Error('connection interrupted')
    })
    const { model } = await openSaveModel(engine, sock)
    await model.mutate(async () => ({ result: true, snapshot: engine.typeText('draft') }))

    expect(await model.savePending()).toBe(false)
    expect(model.pending.value).toBe(1)
    expect(model.revision.value).toBe(0)

    sock.setAnswer(async (_event, payload) => acknowledge(1, payload))
    expect(await model.savePending()).toBe(true)
    expect(sock.applies()[1]!.payload).toEqual(sock.applies()[0]!.payload)
  })

  it('reports a rejected change even when removing it empties the send queue', async () => {
    const engine = makeFakeEngine()
    const sock = makeFakeChannel(async () => {
      throw { payload: { reason: 'invalid_operation' } }
    })
    const { model, notices } = await openSaveModel(engine, sock)
    await model.mutate(async () => ({ result: true, snapshot: engine.typeText('rejected') }))

    expect(await model.savePending()).toBe(false)
    await until(() => model.pending.value === 0)
    expect(notices).toEqual([expect.objectContaining({ kind: 'rejected', reason: 'invalid_operation' })])
    expect(model.revision.value).toBe(0)
  })

  it('keeps native composition active across Worker snapshots and re-arms idle saving when it ends', async () => {
    const engine = makeFakeEngine()
    const sock = makeFakeChannel(async (_event, payload) => acknowledge(1, payload))
    const { model } = await openSaveModel(engine, sock)
    await model.mutate(async () => ({ result: true, snapshot: engine.typeText('draft') }))

    model.setExternalComposition(true)
    await model.updateSelection(async () => ({ snapshot: engine.moveBlock(0) }))
    expect(model.composing.value).toBe(true)
    expect(await model.savePending()).toBe(false)
    await Bun.sleep(80)
    expect(sock.applies()).toHaveLength(0)

    model.setExternalComposition(false)
    await until(() => model.revision.value === 1 && model.pending.value === 0)
  })

  it('does not let an earlier acknowledgement release navigation during a new native composition', async () => {
    const engine = makeFakeEngine()
    const first = Promise.withResolvers<unknown>()
    const sock = makeFakeChannel(() => first.promise)
    const { model } = await openSaveModel(engine, sock)
    await model.mutate(async () => ({ result: true, snapshot: engine.typeText('draft') }))
    const saving = model.savePending()
    await until(() => sock.applies().length === 1)

    model.setExternalComposition(true)
    first.resolve(acknowledge(1, sock.applies()[0]!.payload))
    expect(await saving).toBe(false)
    await until(() => model.revision.value === 1 && model.pending.value === 0)
    expect(await model.savePending()).toBe(false)

    sock.setAnswer(async (_event, payload) => acknowledge(2, payload))
    model.setExternalComposition(false)
    void model.mutate(async () => ({ result: true, snapshot: engine.typeText('draft你好') }))
    expect(await model.savePending()).toBe(true)
    expect(model.revision.value).toBe(2)
  })

  it('waits for a queued pointer edit before deciding whether the page has a draft', async () => {
    const engine = makeFakeEngine()
    const sock = makeFakeChannel(async (_event, payload) => acknowledge(1, payload))
    const { model } = await openSaveModel(engine, sock)
    const gesture = Promise.withResolvers<void>()
    void model.updateSelection(async () => {
      await gesture.promise
      return { snapshot: engine.typeText('completed pointer edit') }
    })
    expect(model.pending.value).toBe(0)

    const saved = model.savePending()
    gesture.resolve()
    expect(await saved).toBe(true)
    expect(sock.applies()).toHaveLength(1)
    expect(model.revision.value).toBe(1)
  })

  it('leaves a clean page without waiting for read-only rendering tasks', async () => {
    const { model } = await openSaveModel(makeFakeEngine(), makeFakeChannel())
    const rasterize = Promise.withResolvers<void>()
    const rendering = model.read(() => rasterize.promise)
    try {
      expect(await Promise.race([model.savePending(), Bun.sleep(50).then(() => 'rendering')])).toBe(true)
    } finally {
      rasterize.resolve()
      await rendering
    }
  })

  it('holds uncommitted typing locally, publishes editing presence, and commits after the idle pause outside IME composition', async () => {
    const engine = makeFakeEngine()
    const sock = makeFakeChannel(async (_ev, payload) => acknowledge(1, payload))
    const notices: OfficeNotice[] = []
    const model = new OfficeCollaborationModel<TestSnapshot>({
      canEdit: true,
      selfUID: () => 'me',
      connect: async () => sock.channel,
      load: async () => ({
        kind: 'loaded',
        format: 'word',
        revision: 0,
        ops: [],
        bytes: new ArrayBuffer(4),
        metadata: null
      }),
      createEngine: () => engine,
      notify: n => notices.push(n),
      idleCommitMs: 80
    })
    activeModels.push(model)
    await model.start()
    await until(() => sock.pushes.some(p => p.event === 'office:sync'))

    // While composing via IME, idle commits must NEVER fire.
    await model.mutate(async () => ({ result: true, snapshot: engine.typeText('nihao', true) }))
    expect(model.hasDraft.value).toBe(true)
    expect(model.composing.value).toBe(true)
    await Bun.sleep(130)
    expect(sock.applies()).toHaveLength(0)

    // Completing IME composition starts the idle pause, then commits and clears editing presence.
    await model.mutate(async () => ({ result: true, snapshot: engine.typeText('你好', false) }))
    expect(sock.presences().some(p => p.payload.selection?.editing === true)).toBe(true)
    await until(() => sock.applies().length === 1 && model.pending.value === 0)
    expect(model.revision.value).toBe(1)
    expect(sock.presences().at(-1)?.payload.selection?.editing).toBeUndefined()
    expect(notices).toEqual([])
  })

  it('rebases surviving queued operations and drops conflicting queued operations on foreign broadcast', async () => {
    const shiftedOp: OfficeChangeSet = { model_version: 1, edits: [{ type: 'block.put', at: 2, text: 'shifted' }] }
    const engine = makeFakeEngine({
      rebase: pending =>
        pending.map((op, idx) => (idx === 1 ? { conflict: 'block_changed' } : idx === 2 ? { op: shiftedOp } : { op }))
    })
    const firstHeld = Promise.withResolvers<unknown>()
    const sock = makeFakeChannel(() => firstHeld.promise)
    const notices: OfficeNotice[] = []
    const model = new OfficeCollaborationModel<TestSnapshot>({
      canEdit: true,
      selfUID: () => 'me',
      connect: async () => sock.channel,
      load: async () => ({
        kind: 'loaded',
        format: 'word',
        revision: 0,
        ops: [],
        bytes: new ArrayBuffer(4),
        metadata: null
      }),
      createEngine: () => engine,
      notify: n => notices.push(n),
      idleCommitMs: 5000
    })
    activeModels.push(model)
    await model.start()
    await until(() => sock.pushes.some(p => p.event === 'office:sync'))

    // Commit 3 operations: E0 goes in flight, E1 and E2 wait in queue.
    await model.mutate(async () => ({ result: 1, snapshot: engine.typeText('first'), commit: true }))
    await until(() => sock.applies().length === 1)
    await model.mutate(async () => ({ result: 2, snapshot: engine.typeText('second'), commit: true }))
    await model.mutate(async () => ({ result: 3, snapshot: engine.typeText('third'), commit: true }))

    // Foreign change arrives at rev 1 while E0 is in flight; E1 conflicts and is dropped, E2 shifts to `at: 2`.
    sock.emit('office:changes', {
      revision: 1,
      changes: [{ revision: 1, kind: 'op', client_id: 'peer', client_seq: 1, op: { model_version: 1, edits: [] } }],
      reset_required: false
    })
    await until(() => notices.length === 1)
    expect(notices[0]).toEqual({ kind: 'conflict', reason: 'block_changed' })

    // Now E0 is acknowledged at rev 2, and E2 (rebased to `shiftedOp`) is sent with `base_revision: 2`!
    sock.setAnswer(async (_ev, payload) => acknowledge(3, payload))
    firstHeld.resolve(acknowledge(2, sock.applies()[0]!.payload))
    await until(() => sock.applies().length === 2 && model.pending.value === 0)
    expect(sock.applies()[1]!.payload).toMatchObject({
      base_revision: 2,
      op: shiftedOp
    })
    expect(model.revision.value).toBe(3)
  })

  it('tracks server-verified editing mode on collaborator presence for soft unit locks', async () => {
    const engine = makeFakeEngine()
    const sock = makeFakeChannel()
    const model = new OfficeCollaborationModel<TestSnapshot>({
      canEdit: true,
      selfUID: () => 'me',
      connect: async () => sock.channel,
      load: async () => ({
        kind: 'loaded',
        format: 'presentation',
        revision: 0,
        ops: [],
        bytes: new ArrayBuffer(4),
        metadata: null
      }),
      createEngine: () => engine,
      notify: () => {}
    })
    activeModels.push(model)
    await model.start()

    sock.setPresence([
      { id: 'me', metas: [{ name: 'Me', mode: 'editing', selection: { slide_id: 1, editing: true } }] },
      { id: 'alice', metas: [{ name: 'Alice', mode: 'editing', selection: { slide_id: 2, editing: true } }] },
      { id: 'bob', metas: [{ name: 'Bob', mode: 'viewing', selection: { slide_id: 2 } }] }
    ])

    expect(model.members.value).toHaveLength(2)
    expect(model.members.value.find(m => m.uid === 'alice')?.editing).toBe(true)
    expect(model.members.value.find(m => m.uid === 'bob')?.editing).toBe(false)
  })

  it('passes bootstrap checkpoint sidecars into engine.open', async () => {
    const engine = makeFakeEngine()
    const sock = makeFakeChannel()
    const model = new OfficeCollaborationModel<TestSnapshot>({
      canEdit: true,
      selfUID: () => 'me',
      connect: async () => sock.channel,
      load: async () => ({
        kind: 'loaded',
        format: 'word',
        revision: 4,
        ops: [],
        bytes: new ArrayBuffer(4),
        checkpoint: '{"version":1,"parts":[10,11]}',
        metadata: null
      }),
      createEngine: () => engine,
      notify: () => {}
    })
    activeModels.push(model)
    await model.start()

    expect(engine.openedCheckpoint).toBe('{"version":1,"parts":[10,11]}')
  })

  it('preserves post-commit snapshot state when updateSelection commits a unit draft', async () => {
    const engine = makeFakeEngine({ undoOnCommitOnly: true })
    const sock = makeFakeChannel(async (_event, payload) => acknowledge(1, payload))
    const { model } = await openSaveModel(engine, sock)

    await model.mutate(async () => ({ result: true, snapshot: engine.typeText('block draft') }))
    expect(model.hasDraft.value).toBe(true)
    expect(model.canUndo.value).toBe(false)
    expect(model.hasUnsavedChanges()).toBe(true)

    // Case 1: `outcome.commitBefore` (Word pointer move to a new block).
    const postPointer = await model.updateSelection(async () => ({
      snapshot: engine.moveBlock(1),
      commitBefore: true
    }))
    expect(postPointer?.editing).toBe(false)
    expect(postPointer?.canUndo).toBe(true)
    expect(model.hasDraft.value).toBe(false)
    expect(model.canUndo.value).toBe(true)
    expect(model.snapshot.value?.editing).toBe(false)
    await until(() => model.pending.value === 0)
    expect(model.hasUnsavedChanges()).toBe(false)

    // Case 2: `selectionOptions.commitBefore` (Presentation slide navigation commits before switching slides).
    sock.setAnswer(async (_event, payload) => acknowledge(2, payload))
    await model.mutate(async () => ({ result: true, snapshot: engine.typeText('slide draft') }))
    expect(model.hasDraft.value).toBe(true)
    const postSlideMove = await model.updateSelection(async () => ({ snapshot: engine.moveBlock(2) }), {
      commitBefore: true
    })
    expect(postSlideMove?.block).toBe(2)
    expect(postSlideMove?.editing).toBe(false)
    expect(model.hasDraft.value).toBe(false)
    await until(() => model.pending.value === 0)
    expect(model.revision.value).toBe(2)
  })
})
