import { uuidV4 } from '@agentbull/active-support'
import { batch, computed, createModel, effect, signal } from '@preact/signals-react'
import { createClientConfig, InternalAPIError } from '../../common/internal-api-client'
import { requestErrorCode } from '../../common/request-errors'
import { podOffice } from '../api/generated/sdk.gen'
import { fileURL } from '../content-api'
import { memberColor } from '../state/spreadsheet-grid'
import type { OfficeFormat } from './office-files'

export type OfficeChangeSet = Record<string, unknown>

export type OfficeEntry = {
  revision: number
  kind: 'op' | 'reset'
  client_id: string | null
  client_seq: number | null
  op: OfficeChangeSet | null
  created_at?: string
}

export type OfficeChanges = {
  revision: number
  changes: OfficeEntry[]
  reset_required: boolean
  acknowledged_revision?: number
}

export type OfficeChannel = {
  ready: Promise<unknown>
  push<T>(event: string, payload: object): Promise<T>
  on(event: string, callback: (payload: any) => void): () => void
  presence(): { id: string; metas: Record<string, unknown>[] }[]
  close(): void
}

export type OfficePendingResult = { op: OfficeChangeSet } | { conflict: string }

export type OfficeRemoteReport = {
  dropped_pending: number
  draft_conflict: boolean
  conflict_reason: string | null
  pending_results?: OfficePendingResult[]
  active_block?: number | null
  active_slide_id?: number | null
}

export type OfficeSnapshotBase = {
  canUndo: boolean
  canRedo: boolean
  editing: boolean
  composing?: boolean
  presenceSelection: Record<string, unknown> | null
}

export type OfficeSyncEngine<TSnapshot extends OfficeSnapshotBase> = {
  open(bytes: ArrayBuffer, ops: OfficeChangeSet[], checkpoint?: string | null): Promise<TSnapshot>
  commitLocalStep(): Promise<{ op: OfficeChangeSet | null; snapshot: TSnapshot }>
  applyRemote(
    confirmedOps: OfficeChangeSet[],
    pendingOps: OfficeChangeSet[]
  ): Promise<{ report: OfficeRemoteReport; snapshot: TSnapshot }>
  undo(): Promise<{ op: OfficeChangeSet | null; snapshot: TSnapshot }>
  redo(): Promise<{ op: OfficeChangeSet | null; snapshot: TSnapshot }>
  dispose(): void
}

export type OfficeSource =
  | { kind: 'too_large' }
  | {
      kind: 'loaded'
      format: OfficeFormat
      revision: number
      ops: OfficeChangeSet[]
      bytes: ArrayBuffer
      checkpoint?: string | null
      metadata: Record<string, unknown> | null
    }

export type OfficeNotice =
  | { kind: 'conflict'; reason: string }
  | { kind: 'rejected'; message: string; reason?: string }
  | { kind: 'discarded'; count: number }
  | { kind: 'failed'; error: unknown }
  | { kind: 'revoked' }

export type OfficeStatus = 'loading' | 'ready' | 'read_only' | 'too_large' | 'error'

export type OfficeMemberSelection = {
  mode: string
  selection: Record<string, unknown>
}

export type OfficeMember = {
  uid: string
  name: string
  color: string
  editing: boolean
  selections: OfficeMemberSelection[]
}

export type OfficeCollaborationOptions<TSnapshot extends OfficeSnapshotBase> = {
  canEdit: boolean
  selfUID(): string | undefined
  connect(): Promise<OfficeChannel>
  load(): Promise<OfficeSource>
  createEngine(): OfficeSyncEngine<TSnapshot>
  notify(notice: OfficeNotice): void
  idleCommitMs?: number
}

export type OfficeNavigationSession = {
  savePending(): Promise<boolean>
  hasUnsavedChanges(): boolean
}

type OfficeRequest = {
  base_revision: number
  client_id: string
  client_seq: number
  op: OfficeChangeSet
}

type QueueEntry = {
  op: OfficeChangeSet
  request?: OfficeRequest
  busy: number
}

type PresenceMeta = {
  name?: string | null
  mode?: string | null
  selection?: Record<string, unknown> | null
}

const transport = createClientConfig({}).fetch!
const BOOTSTRAP_ATTEMPTS = 3
const SEND_DELAY_MS = 30
const BUSY_DELAY_MS = 200
const BUSY_RETRIES = 5
const RETRY_DELAY_MS = 1000
const PRESENCE_INTERVAL_MS = 250
export const DEFAULT_IDLE_COMMIT_MS = 2000

const RELOAD_REASONS = new Set([
  'client_sequence_conflict',
  'forbidden',
  'not_found',
  'invalid_page_type',
  'invalid_office_file',
  'file_too_large'
])

function errorCode(error: unknown): string | undefined {
  return error instanceof InternalAPIError ? requestErrorCode(error.payload) : undefined
}

function failureReason(failure: unknown): string | undefined {
  const payload = (failure as { payload?: { reason?: unknown } } | undefined)?.payload
  return typeof payload?.reason === 'string' ? payload.reason : undefined
}

function failureMessage(failure: unknown): string {
  return failure instanceof Error ? failure.message : String(failure)
}

/**
 * Bootstraps an Office Page via `GET /api/v2/pod/pages/:id/office` and downloads the exact pinned
 * blob digest paired with its uncompacted operation tail, retrying when compaction races the fetch.
 */
export async function loadOfficeBootstrap(pageID: string): Promise<OfficeSource> {
  for (let attempt = 1; ; attempt++) {
    let bootstrap: Awaited<ReturnType<typeof podOffice>>
    try {
      bootstrap = await podOffice({ path: { id: pageID } })
    } catch (error) {
      if (errorCode(error) === 'file_too_large') return { kind: 'too_large' }
      throw error
    }
    try {
      const response = await transport(fileURL(pageID, bootstrap.file.path, bootstrap.file.sha256), {
        credentials: 'same-origin'
      })
      return {
        kind: 'loaded',
        format: bootstrap.format,
        revision: bootstrap.revision,
        ops: bootstrap.ops.map(entry => (entry.op ?? {}) as OfficeChangeSet),
        bytes: await response.arrayBuffer(),
        checkpoint: bootstrap.checkpoint ?? null,
        metadata: (bootstrap.metadata as Record<string, unknown> | null | undefined) ?? null
      }
    } catch (error) {
      if (attempt < BOOTSTRAP_ATTEMPTS && errorCode(error) === 'manifest_changed') continue
      throw error
    }
  }
}

export function inertOfficeChannel(): OfficeChannel {
  return {
    ready: Promise.resolve({}),
    push: async <T>(_event: string, payload: object) => {
      const revision =
        typeof (payload as { revision?: unknown }).revision === 'number'
          ? (payload as { revision: number }).revision
          : 0
      return { revision, changes: [], reset_required: false } as T
    },
    on: () => () => {},
    presence: () => [],
    close: () => {}
  }
}

/**
 * Shared collaborative session model for ChangeSet-driven Office Pages (Word and Presentation).
 * Serializes Worker tasks, tracks uncommitted drafts and IME composition, schedules unit-boundary
 * and idle commits, rebases pending edits against server broadcasts, and publishes soft unit locks
 * over `office:presence`.
 */
export const OfficeCollaborationModel = createModel(
  <TSnapshot extends OfficeSnapshotBase>(options: OfficeCollaborationOptions<TSnapshot>) => {
    const status = signal<OfficeStatus>('loading')
    const revision = signal(0)
    const snapshot = signal<TSnapshot | undefined>(undefined)
    const metadata = signal<Record<string, unknown> | null>(null)
    const pending = signal(0)
    const hasDraft = signal(false)
    const composing = signal(false)
    const canUndo = signal(false)
    const canRedo = signal(false)
    const members = signal<OfficeMember[]>([])
    const error = signal<unknown>(undefined)
    const revoked = signal(false)
    const version = signal(0)
    const editable = computed(() => status.value === 'ready')

    const clientID = uuidV4()
    const idleCommitMs = options.idleCommitMs ?? DEFAULT_IDLE_COMMIT_MS
    let channel: OfficeChannel | undefined
    let engine: OfficeSyncEngine<TSnapshot> | undefined
    let disposed = false
    let tail: Promise<unknown> = Promise.resolve()
    let inFlight: QueueEntry | undefined
    let queue: QueueEntry[] = []
    const localEdits = new Set<symbol>()
    let selectionTasks = 0
    let sequence = 0
    let pushing = false
    let sendTimer: ReturnType<typeof setTimeout> | undefined
    let idleTimer: ReturnType<typeof setTimeout> | undefined
    let presenceTimer: ReturnType<typeof setTimeout> | undefined
    let presenceSentAt = Number.NEGATIVE_INFINITY
    let presenceNext: Record<string, unknown> | null = null
    let lastAnnouncedEditing = false
    let externalComposition = false
    let saveAttempt: PromiseWithResolvers<boolean> | undefined
    let syncing = false
    let syncAgain = false

    const serial = <T>(task: () => Promise<T>): Promise<T> => {
      const run = tail.then(task)
      tail = run.catch(() => undefined)
      return run
    }

    const loaded = () => status.peek() === 'ready' || status.peek() === 'read_only'

    const finishSave = (saved: boolean) => {
      const attempt = saveAttempt
      saveAttempt = undefined
      attempt?.resolve(saved)
    }

    const notify = (notice: OfficeNotice) => {
      finishSave(false)
      options.notify(notice)
    }

    const publishCounts = () => {
      const count = localEdits.size + (hasDraft.peek() ? 1 : 0) + (inFlight ? 1 : 0) + queue.length
      pending.value = count
      if (count === 0 && !composing.peek()) finishSave(true)
    }

    const clearIdleTimer = () => {
      if (idleTimer !== undefined) {
        clearTimeout(idleTimer)
        idleTimer = undefined
      }
    }

    const scheduleIdleCommit = () => {
      clearIdleTimer()
      if (disposed || status.peek() !== 'ready' || !hasDraft.peek() || composing.peek()) return
      idleTimer = setTimeout(() => {
        idleTimer = undefined
        if (!disposed && status.peek() === 'ready' && hasDraft.peek() && !composing.peek()) {
          void commitNow()
        }
      }, idleCommitMs)
    }

    const applySnapshotState = (next: TSnapshot, bumpVersion = true) => {
      const nextEditing = Boolean(next.editing) && options.canEdit
      const nextComposing = externalComposition || Boolean(next.composing)
      batch(() => {
        snapshot.value = next
        hasDraft.value = nextEditing
        composing.value = nextComposing
        canUndo.value = next.canUndo
        canRedo.value = next.canRedo
        if (bumpVersion) version.value++
      })
      publishCounts()
      if (nextEditing && !nextComposing) {
        scheduleIdleCommit()
      } else {
        clearIdleTimer()
      }
      if (loaded()) {
        const payload = next.presenceSelection
          ? {
              ...next.presenceSelection,
              ...(nextEditing ? { editing: true } : {})
            }
          : null
        announcePresence(payload, nextEditing !== lastAnnouncedEditing)
        lastAnnouncedEditing = nextEditing
      }
    }

    const sendPresence = () => {
      presenceTimer = undefined
      presenceSentAt = Date.now()
      void channel?.push('office:presence', { selection: presenceNext }).catch(() => undefined)
    }

    const announcePresence = (next: Record<string, unknown> | null, immediate = false) => {
      presenceNext = next
      if (next === null || immediate) {
        clearTimeout(presenceTimer)
        presenceTimer = undefined
        sendPresence()
        return
      }
      if (presenceTimer) return
      presenceTimer = setTimeout(sendPresence, Math.max(0, presenceSentAt + PRESENCE_INTERVAL_MS - Date.now()))
    }

    const publishMembers = () => {
      const listed = (channel?.presence() ?? []).map(({ id: uid, metas }) => {
        const entries = metas as PresenceMeta[]
        const selections: OfficeMemberSelection[] = entries.flatMap(meta =>
          meta.selection
            ? [
                {
                  mode: meta.mode === 'editing' ? 'editing' : 'viewing',
                  selection: meta.selection
                }
              ]
            : []
        )
        return {
          uid,
          name: entries.at(-1)?.name || uid,
          color: memberColor(uid),
          editing: selections.some(item => item.mode === 'editing'),
          selections
        }
      })
      members.value = listed.filter(member => member.uid !== options.selfUID())
    }

    const scheduleFlush = (delay = SEND_DELAY_MS) => {
      clearTimeout(sendTimer)
      sendTimer = setTimeout(() => void flush(), delay)
    }

    const reconcilePendingQueue = (entries: QueueEntry[], results: OfficePendingResult[] | undefined) => {
      if (!results) return
      results.forEach((result, index) => {
        const entry = entries[index]
        if (!entry) return
        if ('op' in result) {
          entry.op = result.op
        } else if (entry !== inFlight) {
          queue = queue.filter(item => item !== entry)
          notify({ kind: 'conflict', reason: result.conflict })
        }
      })
    }

    const load = async () => {
      status.value = 'loading'
      clearIdleTimer()
      try {
        const source = await options.load()
        if (disposed) return
        if (source.kind === 'too_large') {
          status.value = 'too_large'
          return
        }
        engine ??= options.createEngine()
        const initial = await engine.open(source.bytes, source.ops, source.checkpoint ?? null)
        if (disposed) return
        batch(() => {
          revision.value = source.revision
          metadata.value = source.metadata
          error.value = undefined
          status.value = options.canEdit ? 'ready' : 'read_only'
        })
        applySnapshotState(initial, true)
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
      clearIdleTimer()
      const discarded = localEdits.size + (hasDraft.peek() ? 1 : 0) + (inFlight ? 1 : 0) + queue.length
      finishSave(false)
      localEdits.clear()
      hasDraft.value = false
      composing.value = externalComposition
      inFlight = undefined
      queue = []
      clearTimeout(sendTimer)
      publishCounts()
      if (discarded) notify({ kind: 'discarded', count: discarded })
      await load()
    }

    const receive = async (payload: OfficeChanges, sent?: QueueEntry) => {
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
        const request = inFlight?.request
        const own = request
          ? fresh.find(entry => entry.client_id === clientID && entry.client_seq === request.client_seq)
          : undefined
        const acknowledged = Boolean(
          inFlight && (own || (sent === inFlight && payload.acknowledged_revision !== undefined))
        )
        if (acknowledged) inFlight = undefined

        if (fresh.length || acknowledged) {
          const entries = [...(inFlight ? [inFlight] : []), ...queue]
          const { report, snapshot: nextSnap } = await engine.applyRemote(
            fresh.map(entry => entry.op!),
            entries.map(entry => entry.op)
          )
          if (fresh.length) {
            revision.value = fresh.at(-1)!.revision
          }
          reconcilePendingQueue(entries, report.pending_results)
          if (report.draft_conflict) {
            notify({
              kind: 'conflict',
              reason: report.conflict_reason ?? 'conflict'
            })
          }
          applySnapshotState(nextSnap, true)
        } else {
          publishCounts()
        }
      } catch (failure) {
        notify({ kind: 'failed', error: failure })
        return reset()
      }

      if (payload.revision > revision.peek()) void sync()
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
          const reply = await channel.push<OfficeChanges>('office:sync', { revision: revision.peek() })
          await serial(() => receive(reply))
        } while (syncAgain && !disposed)
      } catch (failure) {
        if (!disposed) {
          error.value = failure
          finishSave(false)
        }
      } finally {
        syncing = false
      }
    }

    const take = async () => {
      if (inFlight) return inFlight
      const next = queue.shift()
      if (!next) return undefined
      next.request = {
        base_revision: revision.peek(),
        client_id: clientID,
        client_seq: ++sequence,
        op: next.op
      }
      inFlight = next
      return next
    }

    const flush = async () => {
      if (disposed || pushing || !channel || !loaded()) return
      pushing = true
      let delay: number | undefined = SEND_DELAY_MS
      let sent: QueueEntry | undefined
      try {
        sent = await serial(take)
        if (!sent) return
        const reply = await channel.push<OfficeChanges>('office:apply', sent.request!)
        await serial(() => receive(reply, sent))
        error.value = undefined
      } catch (failure) {
        delay = sent ? await failed(sent, failure) : RETRY_DELAY_MS
      } finally {
        pushing = false
        if (!disposed && delay !== undefined && (inFlight || queue.length)) scheduleFlush(delay)
      }
    }

    const drop = async (sent: QueueEntry, missed: OfficeEntry[], notice: OfficeNotice) => {
      if (inFlight !== sent || !engine) return
      finishSave(false)
      const fresh = missed.filter(entry => entry.revision > revision.peek()).sort((a, b) => a.revision - b.revision)
      if (
        fresh.some(
          (entry, index) => entry.kind === 'reset' || !entry.op || entry.revision !== revision.peek() + index + 1
        )
      ) {
        return reset()
      }
      inFlight = undefined
      try {
        const remaining = [...queue]
        const { report, snapshot: nextSnap } = await engine.applyRemote(
          fresh.map(entry => entry.op!),
          remaining.map(entry => entry.op)
        )
        if (fresh.length) {
          revision.value = fresh.at(-1)!.revision
        }
        reconcilePendingQueue(remaining, report.pending_results)
        if (report.draft_conflict) {
          notify({
            kind: 'conflict',
            reason: report.conflict_reason ?? 'conflict'
          })
        }
        applySnapshotState(nextSnap, true)
      } catch (failure) {
        notify({ kind: 'failed', error: failure })
        return reset()
      }
      notify(notice)
    }

    const failed = async (sent: QueueEntry, failure: unknown): Promise<number | undefined> => {
      const reason = failureReason(failure)
      if (reason === 'office_busy') {
        sent.busy++
        if (sent.busy <= BUSY_RETRIES) return BUSY_DELAY_MS
        error.value = failure
        if (inFlight === sent) finishSave(false)
        return RETRY_DELAY_MS
      }
      if (reason === 'office_conflict') {
        const details = (failure as { payload?: { details?: { reason?: string; changes?: OfficeEntry[] } } }).payload
          ?.details
        await serial(() =>
          drop(sent, details?.changes ?? [], {
            kind: 'conflict',
            reason: details?.reason ?? 'conflict'
          })
        )
        return SEND_DELAY_MS
      }
      if (reason === 'invalid_operation' || reason === 'invalid_request' || reason === 'office_full') {
        await serial(() =>
          drop(sent, [], {
            kind: 'rejected',
            message: failureMessage(failure),
            reason
          })
        )
        return SEND_DELAY_MS
      }
      if (reason && RELOAD_REASONS.has(reason)) {
        if (reason !== 'client_sequence_conflict') notify({ kind: 'failed', error: failure })
        await serial(reset)
        return undefined
      }
      error.value = failure
      if (inFlight === sent) finishSave(false)
      return RETRY_DELAY_MS
    }

    const editSerial = <T>(task: (eng: OfficeSyncEngine<TSnapshot>) => Promise<T | undefined>) => {
      if (disposed) return Promise.resolve(undefined)
      if (status.peek() === 'loading') notify({ kind: 'discarded', count: 1 })
      if (status.peek() !== 'ready') return Promise.resolve(undefined)
      const edit = Symbol()
      localEdits.add(edit)
      publishCounts()
      return serial(async () => {
        try {
          if (disposed || !engine || !localEdits.has(edit)) return undefined
          return await task(engine)
        } finally {
          localEdits.delete(edit)
          publishCounts()
        }
      })
    }

    const commitInSerial = async (
      eng: OfficeSyncEngine<TSnapshot>
    ): Promise<{ op: OfficeChangeSet | null; snapshot: TSnapshot } | null> => {
      if (composing.peek()) return null
      clearIdleTimer()
      let committed: { op: OfficeChangeSet | null; snapshot: TSnapshot }
      try {
        committed = await eng.commitLocalStep()
      } catch (failure) {
        notify({ kind: 'rejected', message: failureMessage(failure) })
        return null
      }
      if (disposed) return null
      if (committed.op) {
        queue.push({ op: committed.op, busy: 0 })
        scheduleFlush()
      }
      applySnapshotState(committed.snapshot, Boolean(committed.op))
      return committed
    }

    const commitNow = () => editSerial(async eng => (await commitInSerial(eng))?.op ?? null)

    const savePending = (): Promise<boolean> => {
      if (saveAttempt) return saveAttempt.promise
      if (disposed || composing.peek()) return Promise.resolve(false)
      if (pending.peek() === 0 && selectionTasks === 0) return Promise.resolve(true)
      if (!editable.peek() || !channel) return Promise.resolve(pending.peek() === 0)

      const attempt = Promise.withResolvers<boolean>()
      saveAttempt = attempt
      // A Word pointer gesture can change the document before its selection task returns.
      const commitDraft = editSerial(async eng => {
        if (hasDraft.peek()) await commitInSerial(eng)
      })
      void commitDraft.then(
        () => {
          if (saveAttempt !== attempt) return
          if (composing.peek()) {
            finishSave(false)
            return
          }
          clearTimeout(sendTimer)
          void flush()
        },
        () => {
          if (saveAttempt === attempt) finishSave(false)
        }
      )
      return attempt.promise
    }

    const revoke = () => {
      if (revoked.peek()) return
      clearIdleTimer()
      notify({ kind: 'revoked' })
      batch(() => {
        revoked.value = true
        status.value = 'error'
      })
      clearTimeout(sendTimer)
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
        connected.on('office:changes', payload => void serial(() => receive(payload as OfficeChanges)))
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
      finishSave(false)
      clearIdleTimer()
      localEdits.clear()
      hasDraft.value = false
      composing.value = false
      inFlight = undefined
      queue = []
      publishCounts()
      clearTimeout(sendTimer)
      clearTimeout(presenceTimer)
      if (channel) {
        void channel.push('office:presence', { selection: null }).catch(() => undefined)
        channel.close()
      }
      engine?.dispose()
    })

    return {
      status,
      revision,
      snapshot,
      metadata,
      pending,
      hasDraft,
      composing,
      canUndo,
      canRedo,
      members,
      error,
      revoked,
      version,
      editable,
      start,
      revoke,
      sync() {
        if (loaded()) void sync()
      },
      retry() {
        if (status.peek() !== 'error' || revoked.peek()) return
        if (channel) void serial(load)
        else void start()
      },
      blur() {
        if (loaded()) {
          lastAnnouncedEditing = false
          announcePresence(null, true)
        }
      },
      /** Runs a read-only or navigation query on the Worker in FIFO order. */
      read<T>(task: (eng: OfficeSyncEngine<TSnapshot>) => Promise<T>): Promise<T | undefined> {
        if (disposed) return Promise.resolve(undefined)
        return serial(async () => {
          if (disposed || !engine || !loaded()) return undefined
          return task(engine)
        })
      },
      /**
       * Runs a local session mutation on the Worker, updates snapshot/Presence/idle timer, and
       * optionally commits immediately (used on unit exit or discrete toolbar/structural commands).
       */
      mutate<T>(
        task: (eng: OfficeSyncEngine<TSnapshot>) => Promise<{ result: T; snapshot: TSnapshot; commit?: boolean }>
      ): Promise<T | undefined> {
        return editSerial(async eng => {
          let outcome: { result: T; snapshot: TSnapshot; commit?: boolean }
          try {
            outcome = await task(eng)
          } catch (failure) {
            notify({ kind: 'rejected', message: failureMessage(failure) })
            return undefined
          }
          if (disposed) return undefined
          applySnapshotState(outcome.snapshot, true)
          if (outcome.commit) {
            await commitInSerial(eng)
          }
          return outcome.result
        })
      },
      /** Updates snapshot state after a read-only selection move (also usable by read-only viewers). */
      updateSelection(
        task: (eng: OfficeSyncEngine<TSnapshot>) => Promise<{ snapshot: TSnapshot; commitBefore?: boolean }>,
        selectionOptions?: { commitBefore?: boolean }
      ): Promise<TSnapshot | undefined> {
        if (disposed) return Promise.resolve(undefined)
        selectionTasks++
        return serial(async () => {
          if (disposed || !engine || !loaded()) return undefined
          if (selectionOptions?.commitBefore && status.peek() === 'ready' && hasDraft.peek() && !composing.peek()) {
            await commitInSerial(engine)
            if (disposed) return undefined
          }
          const outcome = await task(engine)
          if (disposed) return undefined
          if (outcome.commitBefore && status.peek() === 'ready' && hasDraft.peek() && !composing.peek()) {
            const committed = await commitInSerial(engine)
            if (disposed) return undefined
            if (committed) return committed.snapshot
          }
          applySnapshotState(outcome.snapshot, false)
          return outcome.snapshot
        }).finally(() => {
          selectionTasks--
        })
      },
      commitNow,
      savePending,
      hasUnsavedChanges() {
        return pending.value > 0 || composing.value
      },
      setExternalComposition(active: boolean) {
        externalComposition = active
        composing.value = active || Boolean(snapshot.peek()?.composing)
        if (active) finishSave(false)
        scheduleIdleCommit()
      },
      flushOnPageHide() {
        if (disposed || status.peek() !== 'ready' || composing.peek()) return
        clearIdleTimer()
        if (hasDraft.peek()) {
          void commitNow().then(() => void flush())
        } else if (queue.length && !pushing) {
          clearTimeout(sendTimer)
          void flush()
        }
      },
      undo() {
        return editSerial(async eng => {
          clearIdleTimer()
          let undone: { op: OfficeChangeSet | null; snapshot: TSnapshot }
          try {
            undone = await eng.undo()
          } catch (failure) {
            notify({ kind: 'rejected', message: failureMessage(failure) })
            return null
          }
          if (disposed) return null
          if (undone.op) {
            queue.push({ op: undone.op, busy: 0 })
            scheduleFlush()
          }
          applySnapshotState(undone.snapshot, true)
          return undone.op
        })
      },
      redo() {
        return editSerial(async eng => {
          clearIdleTimer()
          let redone: { op: OfficeChangeSet | null; snapshot: TSnapshot }
          try {
            redone = await eng.redo()
          } catch (failure) {
            notify({ kind: 'rejected', message: failureMessage(failure) })
            return null
          }
          if (disposed) return null
          if (redone.op) {
            queue.push({ op: redone.op, busy: 0 })
            scheduleFlush()
          }
          applySnapshotState(redone.snapshot, true)
          return redone.op
        })
      }
    }
  }
)
