import { assign, fromPromise, setup } from 'xstate'

export const COLLAB_SEND_DELAY_MS = 30
export const COLLAB_PRESENCE_INTERVAL_MS = 250

export type CollaborationLoadOutcome =
  | { kind: 'too_large' }
  | { kind: 'loaded'; editable: boolean }
  | { kind: 'aborted' }

export type CollaborationPushOutcome =
  | { kind: 'idle' }
  | { kind: 'continue'; delayMs: number }
  | { kind: 'backoff'; delayMs: number }
  | { kind: 'reset' }

export type CollaborationMachineCallbacks<TPresence> = {
  idleCommitMs?: number
  hasChannel(): boolean
  hasQueuedWork(): boolean
  hasSaveWaiter(): boolean
  connect(): Promise<void>
  load(): Promise<CollaborationLoadOutcome>
  syncOnce(): Promise<void>
  onSyncSettled(succeeded: boolean, failure?: unknown): void
  pushOnce(): Promise<CollaborationPushOutcome>
  onResetFromPush(): Promise<void>
  onIdleCommit?(): void
  sendPresence(selection: TPresence | null): void
  onError(failure: unknown): void
  onStatusChange(status: 'loading' | 'ready' | 'read_only' | 'too_large' | 'error'): void
}

type CollaborationContext<TPresence> = {
  callbacks: CollaborationMachineCallbacks<TPresence>
  editable: boolean
  flushDelayMs: number
  immediateNextFlush: boolean
  syncRepeat: boolean
  idleCommitMs: number
  presenceSentAt: number
  presenceDelayMs: number
  presenceNext: TPresence | null
}

export type CollaborationEvent<TPresence> =
  | { type: 'START' }
  | { type: 'RETRY' }
  | { type: 'RESET' }
  | { type: 'REVOKE' }
  | { type: 'DISPOSE' }
  | { type: 'SCHEDULE_FLUSH'; delayMs?: number }
  | { type: 'FLUSH_NOW' }
  | { type: 'CANCEL_FLUSH' }
  | { type: 'SYNC_REQUEST'; repeatIfRunning: boolean }
  | { type: 'DRAFT_STATE'; hasDraft: boolean; composing: boolean }
  | { type: 'CANCEL_IDLE_COMMIT' }
  | { type: 'PRESENCE_UPDATE'; selection: TPresence | null; immediate?: boolean }

function readEventOutput<T>(event: object): T | undefined {
  return 'output' in event ? (event as { output?: T }).output : undefined
}

/**
 * Coordinates the client-side collaborative session protocol for Office and Spreadsheet editors:
 * connection bootstrap, document loading/reset, serialized outbox flushing with retry/busy delays,
 * coalesced catch-up `office:sync` rounds, IME-safe idle draft commits, and 250ms presence throttling.
 */
export function createCollaborationMachine<TPresence>(callbacks: CollaborationMachineCallbacks<TPresence>) {
  return setup({
    types: {
      context: {} as CollaborationContext<TPresence>,
      events: {} as CollaborationEvent<TPresence>
    },
    actors: {
      connectChannel: fromPromise(async ({ input }: { input: CollaborationMachineCallbacks<TPresence> }) => {
        await input.connect()
      }),
      loadDocument: fromPromise(async ({ input }: { input: CollaborationMachineCallbacks<TPresence> }) => {
        return input.load()
      }),
      syncOnce: fromPromise(async ({ input }: { input: CollaborationMachineCallbacks<TPresence> }) => {
        await input.syncOnce()
      }),
      pushOnce: fromPromise(async ({ input }: { input: CollaborationMachineCallbacks<TPresence> }) => {
        return input.pushOnce()
      })
    },
    delays: {
      flushDelay: ({ context }) => Math.max(0, context.flushDelayMs),
      idleCommitDelay: ({ context }) => Math.max(1, context.idleCommitMs),
      presenceDelay: ({ context }) => Math.max(0, context.presenceDelayMs)
    },
    guards: {
      hasChannel: ({ context }) => context.callbacks.hasChannel(),
      isTooLarge: ({ event }) => 'output' in event && (event.output as CollaborationLoadOutcome).kind === 'too_large',
      isLoaded: ({ event }) => 'output' in event && (event.output as CollaborationLoadOutcome).kind === 'loaded',
      shouldRepeatSync: ({ context }) => context.syncRepeat,
      isResetPushOutcome: ({ event }) =>
        'output' in event && (event.output as CollaborationPushOutcome).kind === 'reset',
      shouldFlushImmediatelyAfterPush: ({ context, event }) => {
        if (!('output' in event)) return false
        const outcome = event.output as CollaborationPushOutcome
        if (outcome.kind === 'reset' || outcome.kind === 'backoff' || !context.callbacks.hasQueuedWork()) {
          return false
        }
        return (
          context.immediateNextFlush ||
          context.callbacks.hasSaveWaiter() ||
          (outcome.kind === 'continue' && outcome.delayMs <= 0)
        )
      },
      shouldScheduleAfterPush: ({ context, event }) => {
        if (!('output' in event)) return false
        const outcome = event.output as CollaborationPushOutcome
        return outcome.kind !== 'reset' && context.callbacks.hasQueuedWork()
      },
      hasIdleCommitConfigured: ({ context }) => context.idleCommitMs > 0 && context.editable,
      isDraftComposing: ({ event }) => event.type === 'DRAFT_STATE' && event.hasDraft && event.composing,
      isDraftWaiting: ({ context, event }) =>
        context.idleCommitMs > 0 &&
        context.editable &&
        event.type === 'DRAFT_STATE' &&
        event.hasDraft &&
        !event.composing,
      isDraftClean: ({ event }) => event.type === 'DRAFT_STATE' && !event.hasDraft,
      shouldSendPresenceImmediately: ({ context, event }) => {
        if (event.type !== 'PRESENCE_UPDATE') return false
        if (event.selection === null || event.immediate) return true
        return Date.now() - context.presenceSentAt >= COLLAB_PRESENCE_INTERVAL_MS
      },
      isImmediatePresenceEvent: ({ event }) =>
        event.type === 'PRESENCE_UPDATE' && (event.selection === null || Boolean(event.immediate))
    },
    actions: {
      markLoading: ({ context }) => {
        context.callbacks.onStatusChange('loading')
      },
      markTooLarge: ({ context }) => {
        context.callbacks.onStatusChange('too_large')
      },
      markErrorFromEvent: ({ context, event }) => {
        if ('error' in event) context.callbacks.onError(event.error)
        context.callbacks.onStatusChange('error')
      },
      markRevoked: ({ context }) => {
        context.callbacks.onStatusChange('error')
      },
      applyLoadedMode: assign(({ event }) => {
        const out = readEventOutput<Extract<CollaborationLoadOutcome, { kind: 'loaded' }>>(event)
        return { editable: Boolean(out?.editable) }
      }),
      notifyLoadedStatus: ({ context }) => {
        context.callbacks.onStatusChange(context.editable ? 'ready' : 'read_only')
      },
      setFlushDelayFromEvent: assign(({ event }) => ({
        flushDelayMs: event.type === 'SCHEDULE_FLUSH' ? (event.delayMs ?? COLLAB_SEND_DELAY_MS) : COLLAB_SEND_DELAY_MS,
        immediateNextFlush: false
      })),
      markImmediateNextFlush: assign({
        immediateNextFlush: true
      }),
      clearImmediateNextFlush: assign({
        immediateNextFlush: false
      }),
      setFlushDelayFromPushOutcome: assign(({ context, event }) => {
        const outcome = readEventOutput<CollaborationPushOutcome>(event)
        let delayMs = COLLAB_SEND_DELAY_MS
        if (outcome?.kind === 'backoff') {
          delayMs = outcome.delayMs
        } else if (outcome?.kind === 'continue') {
          delayMs = context.callbacks.hasSaveWaiter() ? 0 : outcome.delayMs
        } else if (context.callbacks.hasSaveWaiter()) {
          delayMs = 0
        }
        return {
          flushDelayMs: delayMs,
          immediateNextFlush: false
        }
      }),
      triggerResetFromPush: ({ context }) => {
        void context.callbacks.onResetFromPush()
      },
      clearSyncRepeat: assign({
        syncRepeat: false
      }),
      requestSyncRepeat: assign(({ context, event }) => ({
        syncRepeat: event.type === 'SYNC_REQUEST' && event.repeatIfRunning ? true : context.syncRepeat
      })),
      settleSyncSuccess: ({ context }) => {
        context.callbacks.onSyncSettled(true)
      },
      settleSyncFailure: ({ context, event }) => {
        const failure = 'error' in event ? event.error : undefined
        context.callbacks.onSyncSettled(false, failure)
      },
      abortPendingSyncWaiters: ({ context }) => {
        context.callbacks.onSyncSettled(false)
      },
      triggerIdleCommit: ({ context }) => {
        context.callbacks.onIdleCommit?.()
      },
      sendPresenceImmediate: assign(({ context, event }) => {
        if (event.type !== 'PRESENCE_UPDATE') return {}
        const now = Date.now()
        context.callbacks.sendPresence(event.selection)
        return {
          presenceNext: event.selection,
          presenceSentAt: now,
          presenceDelayMs: 0
        }
      }),
      stagePresenceThrottle: assign(({ context, event }) => {
        if (event.type !== 'PRESENCE_UPDATE') return {}
        const delay = Math.max(0, context.presenceSentAt + COLLAB_PRESENCE_INTERVAL_MS - Date.now())
        return {
          presenceNext: event.selection,
          presenceDelayMs: delay
        }
      }),
      flushThrottledPresence: assign(({ context }) => {
        const now = Date.now()
        context.callbacks.sendPresence(context.presenceNext)
        return {
          presenceSentAt: now,
          presenceDelayMs: 0
        }
      })
    }
  }).createMachine({
    id: 'collaborationSession',
    initial: 'unstarted',
    context: {
      callbacks,
      editable: false,
      flushDelayMs: COLLAB_SEND_DELAY_MS,
      immediateNextFlush: false,
      syncRepeat: false,
      idleCommitMs: callbacks.idleCommitMs ?? 0,
      presenceSentAt: Number.NEGATIVE_INFINITY,
      presenceDelayMs: 0,
      presenceNext: null
    },
    on: {
      REVOKE: {
        target: '.revoked',
        actions: 'markRevoked'
      },
      DISPOSE: {
        target: '.disposed'
      }
    },
    states: {
      unstarted: {
        on: {
          START: { target: 'connecting' }
        }
      },
      connecting: {
        entry: 'markLoading',
        invoke: {
          src: 'connectChannel',
          input: ({ context }) => context.callbacks,
          onDone: {
            target: 'loading'
          },
          onError: {
            target: 'error',
            actions: 'markErrorFromEvent'
          }
        }
      },
      loading: {
        entry: 'markLoading',
        on: {
          RESET: {
            target: 'loading',
            reenter: true
          }
        },
        invoke: {
          src: 'loadDocument',
          input: ({ context }) => context.callbacks,
          onDone: [
            {
              guard: 'isTooLarge',
              target: 'tooLarge',
              actions: 'markTooLarge'
            },
            {
              guard: 'isLoaded',
              target: 'active',
              actions: ['applyLoadedMode', 'notifyLoadedStatus']
            }
          ],
          onError: {
            target: 'error',
            actions: 'markErrorFromEvent'
          }
        }
      },
      active: {
        type: 'parallel',
        exit: 'abortPendingSyncWaiters',
        on: {
          RESET: {
            target: 'loading'
          }
        },
        states: {
          outbox: {
            initial: 'idle',
            states: {
              idle: {
                always: [
                  {
                    guard: ({ context }) => context.callbacks.hasQueuedWork() && context.callbacks.hasSaveWaiter(),
                    target: 'pushing'
                  },
                  {
                    guard: ({ context }) => context.callbacks.hasQueuedWork(),
                    target: 'scheduled',
                    actions: assign({ flushDelayMs: COLLAB_SEND_DELAY_MS })
                  }
                ],
                on: {
                  SCHEDULE_FLUSH: {
                    target: 'scheduled',
                    actions: 'setFlushDelayFromEvent'
                  },
                  FLUSH_NOW: {
                    target: 'pushing',
                    actions: 'clearImmediateNextFlush'
                  }
                }
              },
              scheduled: {
                after: {
                  flushDelay: {
                    target: 'pushing',
                    actions: 'clearImmediateNextFlush'
                  }
                },
                on: {
                  SCHEDULE_FLUSH: {
                    target: 'scheduled',
                    reenter: true,
                    actions: 'setFlushDelayFromEvent'
                  },
                  FLUSH_NOW: {
                    target: 'pushing',
                    actions: 'clearImmediateNextFlush'
                  },
                  CANCEL_FLUSH: {
                    target: 'idle'
                  }
                }
              },
              pushing: {
                on: {
                  FLUSH_NOW: {
                    actions: 'markImmediateNextFlush'
                  }
                },
                invoke: {
                  src: 'pushOnce',
                  input: ({ context }) => context.callbacks,
                  onDone: [
                    {
                      guard: 'isResetPushOutcome',
                      actions: ['clearImmediateNextFlush', 'triggerResetFromPush']
                    },
                    {
                      guard: 'shouldFlushImmediatelyAfterPush',
                      target: 'pushing',
                      reenter: true,
                      actions: 'clearImmediateNextFlush'
                    },
                    {
                      guard: 'shouldScheduleAfterPush',
                      target: 'scheduled',
                      actions: 'setFlushDelayFromPushOutcome'
                    },
                    {
                      target: 'idle',
                      actions: 'clearImmediateNextFlush'
                    }
                  ],
                  onError: {
                    target: 'scheduled',
                    actions: assign({
                      flushDelayMs: 1000,
                      immediateNextFlush: false
                    })
                  }
                }
              }
            }
          },
          catchup: {
            initial: 'syncing',
            states: {
              idle: {
                on: {
                  SYNC_REQUEST: {
                    target: 'syncing',
                    actions: 'clearSyncRepeat'
                  }
                }
              },
              syncing: {
                on: {
                  SYNC_REQUEST: {
                    actions: 'requestSyncRepeat'
                  }
                },
                invoke: {
                  src: 'syncOnce',
                  input: ({ context }) => context.callbacks,
                  onDone: [
                    {
                      guard: 'shouldRepeatSync',
                      target: 'syncing',
                      reenter: true,
                      actions: 'clearSyncRepeat'
                    },
                    {
                      target: 'idle',
                      actions: 'settleSyncSuccess'
                    }
                  ],
                  onError: [
                    {
                      guard: 'shouldRepeatSync',
                      target: 'syncing',
                      reenter: true,
                      actions: 'clearSyncRepeat'
                    },
                    {
                      target: 'idle',
                      actions: 'settleSyncFailure'
                    }
                  ]
                }
              }
            }
          },
          idleCommit: {
            initial: 'clean',
            states: {
              clean: {
                on: {
                  DRAFT_STATE: [
                    {
                      guard: 'isDraftComposing',
                      target: 'composing'
                    },
                    {
                      guard: 'isDraftWaiting',
                      target: 'dirtyWaiting'
                    }
                  ]
                }
              },
              composing: {
                on: {
                  CANCEL_IDLE_COMMIT: { target: 'clean' },
                  DRAFT_STATE: [
                    {
                      guard: 'isDraftClean',
                      target: 'clean'
                    },
                    {
                      guard: 'isDraftWaiting',
                      target: 'dirtyWaiting'
                    }
                  ]
                }
              },
              dirtyWaiting: {
                after: {
                  idleCommitDelay: {
                    target: 'clean',
                    actions: 'triggerIdleCommit'
                  }
                },
                on: {
                  CANCEL_IDLE_COMMIT: { target: 'clean' },
                  DRAFT_STATE: [
                    {
                      guard: 'isDraftClean',
                      target: 'clean'
                    },
                    {
                      guard: 'isDraftComposing',
                      target: 'composing'
                    },
                    {
                      guard: 'isDraftWaiting',
                      target: 'dirtyWaiting',
                      reenter: true
                    }
                  ]
                }
              }
            }
          },
          presence: {
            initial: 'idle',
            states: {
              idle: {
                on: {
                  PRESENCE_UPDATE: [
                    {
                      guard: 'shouldSendPresenceImmediately',
                      actions: 'sendPresenceImmediate'
                    },
                    {
                      target: 'throttling',
                      actions: 'stagePresenceThrottle'
                    }
                  ]
                }
              },
              throttling: {
                after: {
                  presenceDelay: {
                    target: 'idle',
                    actions: 'flushThrottledPresence'
                  }
                },
                on: {
                  PRESENCE_UPDATE: [
                    {
                      guard: 'isImmediatePresenceEvent',
                      target: 'idle',
                      actions: 'sendPresenceImmediate'
                    },
                    {
                      actions: assign(({ event }) =>
                        event.type === 'PRESENCE_UPDATE' ? { presenceNext: event.selection } : {}
                      )
                    }
                  ]
                }
              }
            }
          }
        }
      },
      tooLarge: {},
      error: {
        on: {
          RETRY: [
            {
              guard: 'hasChannel',
              target: 'loading'
            },
            {
              target: 'connecting'
            }
          ]
        }
      },
      revoked: {},
      disposed: {
        type: 'final'
      }
    }
  })
}
