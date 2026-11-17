import { batch, computed, createModel, signal } from '@preact/signals-react'
import { assign, fromPromise, setup, waitFor } from 'xstate'
import { createActorSignal } from '../../common/xstate-signals'
import type { ViewConfig } from './view-config'

type ChartAutoSavePayload = {
  viewId: string
  config: ViewConfig
  seq: number
}

type ChartAutoSavePersistResult = {
  version?: number
}

export type ChartAutoSavePersist = (
  payload: ChartAutoSavePayload,
  targetVersion: number
) => Promise<ChartAutoSavePersistResult | void>

type TableWorkspaceOptions = {
  autoSaveDelayMs?: number
}

type QueuedChartSave = ChartAutoSavePayload & {
  fallbackVersion: number
  persist: ChartAutoSavePersist
  ready: boolean
  flushed: boolean
}

type ChartAutoSaveContext = {
  inFlight: QueuedChartSave | undefined
  queued: QueuedChartSave[]
  error: unknown
  cancelledUpToSeq: number
}

function upsertQueuedSave(queue: readonly QueuedChartSave[], next: QueuedChartSave): QueuedChartSave[] {
  const existingIndex = queue.findIndex(item => item.viewId === next.viewId)
  if (existingIndex === -1) return [...queue, next]
  return queue.map((item, index) => (index === existingIndex ? next : item))
}

type ChartAutoSaveEvent =
  | { type: 'SCHEDULE'; request: QueuedChartSave }
  | { type: 'FLUSH' }
  | { type: 'SELECT_VIEW' }
  | { type: 'DISCARD'; cancelledUpToSeq: number }
  | { type: 'CLEAR_ERROR' }

const DEFAULT_AUTO_SAVE_DELAY_MS = 600

export const TableWorkspaceModel = createModel((options?: TableWorkspaceOptions) => {
  const autoSaveDelayMs = options?.autoSaveDelayMs ?? DEFAULT_AUTO_SAVE_DELAY_MS
  const viewID = signal('')
  const draft = signal<{ config: ViewConfig; version: number; seq: number }>()
  const newRecord = signal(false)
  const viewVersions = new Map<string, number>()
  let defaultViewID = ''
  let initialized = false
  let nextSeq = 0
  let disposed = false
  let activeSavePromise: Promise<unknown> | undefined

  const activeViewID = () => viewID.value || defaultViewID

  const knownViewVersion = (id: string, fallbackVersion: number): number => {
    return viewVersions.get(id) ?? fallbackVersion
  }

  const recordViewVersion = (id: string, version: number) => {
    const previous = viewVersions.get(id) ?? 0
    if (version > previous) {
      viewVersions.set(id, version)
    }
  }

  const observeViewVersions = (views: ReadonlyArray<{ id: string; version: number }>) => {
    defaultViewID = views[0]?.id ?? ''
    for (const item of views) {
      recordViewVersion(item.id, item.version)
    }
  }

  const acknowledgeDraft = (seq: number) => {
    if (draft.value?.seq === seq) draft.value = undefined
  }

  const executeSave = (request: QueuedChartSave): Promise<ChartAutoSavePersistResult | void> => {
    const targetVersion = knownViewVersion(request.viewId, request.fallbackVersion)
    const run = request.persist(
      {
        viewId: request.viewId,
        config: request.config,
        seq: request.seq
      },
      targetVersion
    )
    const tracked = run.then(result => {
      const nextVersion =
        result && typeof result === 'object' && typeof result.version === 'number' ? result.version : targetVersion + 1
      recordViewVersion(request.viewId, nextVersion)
      return result
    })
    const settled = tracked.then(
      () => undefined,
      () => undefined
    )
    const token = settled.then(() => {
      if (activeSavePromise === token) activeSavePromise = undefined
    })
    activeSavePromise = token
    return tracked
  }

  const autoSaveMachine = setup({
    types: {
      context: {} as ChartAutoSaveContext,
      events: {} as ChartAutoSaveEvent
    },
    actors: {
      runAutoSave: fromPromise(async ({ input }: { input: QueuedChartSave }) => {
        return executeSave(input)
      })
    },
    delays: {
      autoSaveDelay: () => autoSaveDelayMs
    },
    guards: {
      hasNoQueued: ({ context }) => context.queued.length === 0,
      hasNoActiveDraft: ({ context }) => context.queued.every(item => item.flushed),
      canDispatchQueued: ({ context }) => !context.inFlight && context.queued.some(item => item.ready)
    },
    actions: {
      storeQueued: assign(({ context, event }) =>
        event.type === 'SCHEDULE'
          ? {
              queued: upsertQueuedSave(context.queued, event.request),
              error: undefined
            }
          : {}
      ),
      markQueuedReady: assign(({ context }) => ({
        queued: context.queued.map(item => (item.ready ? item : { ...item, ready: true }))
      })),
      markQueuedFlushed: assign(({ context }) => ({
        queued: context.queued.map(item => (item.flushed ? item : { ...item, ready: true, flushed: true }))
      })),
      dropUnflushedQueued: assign(({ context }) => ({
        queued: context.queued.filter(item => item.flushed),
        error: undefined
      })),
      discardQueued: assign(({ context, event }) => {
        const cancelledUpToSeq =
          event.type === 'DISCARD'
            ? Math.max(context.cancelledUpToSeq, event.cancelledUpToSeq)
            : context.cancelledUpToSeq
        return {
          queued: context.queued.filter(item => item.flushed && item.viewId !== activeViewID()),
          error: undefined,
          cancelledUpToSeq
        }
      }),
      clearError: assign({
        error: undefined
      }),
      promoteQueuedToInFlight: assign(({ context }) => {
        const nextIndex = context.queued.findIndex(item => item.ready)
        if (nextIndex < 0) return {}
        const next = context.queued[nextIndex]!
        return {
          inFlight: next,
          queued: context.queued.filter((_, index) => index !== nextIndex)
        }
      }),
      completeInFlight: assign(({ context }) => {
        const finished = context.inFlight
        if (finished && !disposed && finished.seq > context.cancelledUpToSeq && activeViewID() === finished.viewId) {
          acknowledgeDraft(finished.seq)
          return {
            inFlight: undefined,
            error: undefined
          }
        }
        return {
          inFlight: undefined
        }
      }),
      failInFlight: assign(({ context, event }) => {
        const finished = context.inFlight
        const failure = 'error' in event ? event.error : undefined
        const hasNewerQueuedForView = Boolean(finished && context.queued.some(item => item.viewId === finished.viewId))
        const shouldSurfaceError =
          Boolean(finished) &&
          !disposed &&
          !hasNewerQueuedForView &&
          finished!.seq > context.cancelledUpToSeq &&
          activeViewID() === finished!.viewId
        return {
          inFlight: undefined,
          error: shouldSurfaceError ? failure : context.error
        }
      })
    }
  }).createMachine({
    id: 'tableChartAutoSave',
    type: 'parallel',
    context: {
      inFlight: undefined,
      queued: [],
      error: undefined,
      cancelledUpToSeq: 0
    },
    on: {
      SELECT_VIEW: {
        actions: 'clearError'
      },
      DISCARD: {
        actions: 'discardQueued'
      },
      CLEAR_ERROR: {
        actions: 'clearError'
      }
    },
    states: {
      debounce: {
        initial: 'idle',
        states: {
          idle: {
            on: {
              SCHEDULE: {
                target: 'waiting',
                actions: 'storeQueued'
              }
            }
          },
          waiting: {
            after: {
              autoSaveDelay: {
                target: 'readyToSend'
              }
            },
            on: {
              SCHEDULE: {
                target: 'waiting',
                reenter: true,
                actions: 'storeQueued'
              },
              FLUSH: {
                target: 'readyToSend',
                actions: 'markQueuedFlushed'
              },
              SELECT_VIEW: {
                target: 'idle',
                actions: 'dropUnflushedQueued'
              },
              DISCARD: {
                target: 'idle',
                actions: 'discardQueued'
              }
            }
          },
          readyToSend: {
            entry: 'markQueuedReady',
            always: [
              {
                guard: 'hasNoQueued',
                target: 'idle'
              },
              {
                guard: 'hasNoActiveDraft',
                target: 'idle'
              }
            ],
            on: {
              SCHEDULE: {
                target: 'waiting',
                actions: 'storeQueued'
              },
              FLUSH: {
                actions: 'markQueuedFlushed'
              },
              SELECT_VIEW: {
                target: 'idle',
                actions: 'dropUnflushedQueued'
              },
              DISCARD: {
                target: 'idle',
                actions: 'discardQueued'
              }
            }
          }
        }
      },
      transport: {
        initial: 'idle',
        states: {
          idle: {
            always: {
              guard: 'canDispatchQueued',
              target: 'saving',
              actions: 'promoteQueuedToInFlight'
            }
          },
          saving: {
            invoke: {
              src: 'runAutoSave',
              input: ({ context }) => context.inFlight!,
              onDone: {
                target: 'idle',
                actions: 'completeInFlight'
              },
              onError: {
                target: 'idle',
                actions: 'failInFlight'
              }
            }
          }
        }
      }
    }
  })

  const machine = createActorSignal(autoSaveMachine, undefined, actor => {
    disposed = true
    const ctx = actor.getSnapshot().context
    if (ctx.queued.length === 0) return
    let chain = (activeSavePromise ?? Promise.resolve()).catch(() => undefined)
    for (const trailing of ctx.queued) {
      chain = chain.then(() => executeSave(trailing).catch(() => {}))
    }
    const trackedChain = chain.finally(() => {
      if (activeSavePromise === trackedChain) activeSavePromise = undefined
    })
    activeSavePromise = trackedChain
  })

  const autoSaveError = computed(() => machine.snapshot.value.context.error)

  const configure = (config: ViewConfig, version: number): number => {
    const seq = ++nextSeq
    draft.value = { config, version: draft.value?.version ?? version, seq }
    return seq
  }

  return {
    viewID,
    draft,
    newRecord,
    autoSaveSnapshot: machine.snapshot,
    autoSaveError,
    load(initialView?: string) {
      if (!initialized) {
        initialized = true
        viewID.value = initialView ?? ''
      }
    },
    observeViewVersions,
    knownViewVersion,
    recordViewVersion,
    clearAutoSaveError() {
      machine.send({ type: 'CLEAR_ERROR' })
    },
    select(id: string) {
      nextSeq += 1
      batch(() => {
        viewID.value = id
        draft.value = undefined
        newRecord.value = false
        machine.send({ type: 'SELECT_VIEW' })
      })
    },
    configure,
    scheduleChartAutoSave(input: {
      viewId: string
      config: ViewConfig
      fallbackVersion: number
      persist: ChartAutoSavePersist
    }): number {
      const targetVersion = knownViewVersion(input.viewId, input.fallbackVersion)
      const seq = configure(input.config, targetVersion)
      machine.send({
        type: 'SCHEDULE',
        request: {
          viewId: input.viewId,
          config: input.config,
          seq,
          fallbackVersion: targetVersion,
          persist: input.persist,
          ready: false,
          flushed: false
        }
      })
      return seq
    },
    async flushChartAutoSave(): Promise<boolean> {
      const initial = machine.actor.getSnapshot().context
      const hadPending = Boolean(initial.queued.length > 0 || initial.inFlight || activeSavePromise)
      if (!hadPending) return false
      if (!disposed) {
        machine.send({ type: 'FLUSH' })
        await waitFor(machine.actor, s => s.context.queued.length === 0 && !s.context.inFlight).catch(() => {})
      }
      if (activeSavePromise) {
        await activeSavePromise.catch(() => {})
      }
      return true
    },
    acknowledgeDraft,
    cancelPendingChartAutoSave() {
      nextSeq += 1
      machine.send({ type: 'DISCARD', cancelledUpToSeq: nextSeq })
    },
    discard() {
      nextSeq += 1
      const cancelledUpToSeq = nextSeq
      batch(() => {
        draft.value = undefined
        machine.send({ type: 'DISCARD', cancelledUpToSeq })
      })
    }
  }
})
