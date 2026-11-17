import { assign, createActor, setup } from 'xstate'

type CodexSessionLifecycleContext = {
  serverRequestsClosed: boolean
  steeringInFlight: boolean
  durableStatusCommitted: boolean
  stopReason: string | undefined
}

type CodexSessionLifecycleEvent =
  | { type: 'BEGIN_TURN_START' }
  | { type: 'TURN_STARTED' }
  | { type: 'BEGIN_AWAIT_CHILDREN_IDLE' }
  | { type: 'END_AWAIT_CHILDREN_IDLE' }
  | { type: 'BEGIN_SETTLING_TURN' }
  | { type: 'END_SETTLING_TURN' }
  | { type: 'BEGIN_RECOVERING_TURN' }
  | { type: 'END_RECOVERING_TURN' }
  | { type: 'PAUSE_FOR_USER_INPUT' }
  | { type: 'CANCEL_USER_INPUT_WAIT' }
  | { type: 'SET_STEERING_IN_FLIGHT'; inFlight: boolean }
  | { type: 'PREPARE_RUNTIME_CLEANUP' }
  | { type: 'CLAIM_FINALIZATION'; reason: string }
  | { type: 'MARK_UNHANDLED_FAILURE'; reason: string }
  | { type: 'DURABLE_STATUS_COMMITTED' }
  | { type: 'ENTER_CLEANUP' }
  | { type: 'CLOSE' }

function abortControllerWithReason(controller: AbortController, reason: string): void {
  if (!controller.signal.aborted) {
    controller.abort(new DOMException(reason, 'AbortError'))
  }
}

export type CodexSessionLifecycle = ReturnType<typeof createCodexSessionLifecycle>

/**
 * Explicit XState v5 lifecycle state machine for one `CodexJobSession` attempt.
 *
 * Replaces interlocking boolean flags (`waitingOnUserInput`, `recoveryInFlight`,
 * `completionPending`, `finalizing`, `closing`, `acceptingServerRequests`,
 * `durableJobStatusCommitted`, and `activeTurnUpdateInFlight`) with explicit
 * hierarchical states and single-winner finalization transitions.
 */
export function createCodexSessionLifecycle(externalAbortSignal?: AbortSignal) {
  const sessionAbortController = new AbortController()
  const toolAbortController = new AbortController()

  const machine = setup({
    types: {
      context: {} as CodexSessionLifecycleContext,
      events: {} as CodexSessionLifecycleEvent
    },
    actions: {
      setSteeringInFlight: assign(({ event }) =>
        event.type === 'SET_STEERING_IN_FLIGHT'
          ? {
              steeringInFlight: event.inFlight
            }
          : {}
      ),
      abortToolsForCleanup: () => {
        abortControllerWithReason(toolAbortController, 'Background agent Job is cleaning up')
      },
      markServerRequestsClosed: assign({
        serverRequestsClosed: true
      }),
      abortSessionForFinalizing: ({ context, event }) => {
        const reason =
          event.type === 'CLAIM_FINALIZATION' || event.type === 'MARK_UNHANDLED_FAILURE'
            ? event.reason
            : (context.stopReason ?? 'finalizing')
        abortControllerWithReason(sessionAbortController, reason)
      },
      recordFinalizingReason: assign(({ context, event }) => {
        const reason =
          event.type === 'CLAIM_FINALIZATION' || event.type === 'MARK_UNHANDLED_FAILURE'
            ? event.reason
            : (context.stopReason ?? 'finalizing')
        return {
          stopReason: context.stopReason ?? reason
        }
      }),
      markDurableCommitted: assign({
        durableStatusCommitted: true
      }),
      abortSessionForCleanup: ({ context }) => {
        abortControllerWithReason(sessionAbortController, context.stopReason ?? 'closing')
      },
      recordCleaningUp: assign(({ context }) => ({
        serverRequestsClosed: true,
        stopReason: context.stopReason ?? 'closing'
      }))
    }
  }).createMachine({
    id: 'codexSession',
    initial: 'booting',
    context: {
      serverRequestsClosed: false,
      steeringInFlight: false,
      durableStatusCommitted: false,
      stopReason: undefined
    },
    on: {
      SET_STEERING_IN_FLIGHT: {
        actions: 'setSteeringInFlight'
      },
      PREPARE_RUNTIME_CLEANUP: {
        actions: ['abortToolsForCleanup', 'markServerRequestsClosed']
      },
      DURABLE_STATUS_COMMITTED: {
        actions: 'markDurableCommitted'
      }
    },
    states: {
      booting: {
        on: {
          BEGIN_TURN_START: { target: 'startingTurn' },
          CLAIM_FINALIZATION: {
            target: 'finalizing',
            actions: ['abortSessionForFinalizing', 'recordFinalizingReason']
          },
          MARK_UNHANDLED_FAILURE: {
            target: 'finalizing',
            actions: ['abortSessionForFinalizing', 'recordFinalizingReason']
          },
          ENTER_CLEANUP: {
            target: 'cleaningUp',
            actions: ['abortSessionForCleanup', 'abortToolsForCleanup', 'recordCleaningUp']
          }
        }
      },
      startingTurn: {
        on: {
          TURN_STARTED: { target: '#codexSession.activeTurn.executing' },
          BEGIN_AWAIT_CHILDREN_IDLE: { target: '#codexSession.activeTurn.awaitingChildrenIdle' },
          BEGIN_SETTLING_TURN: { target: '#codexSession.activeTurn.settlingTurn' },
          BEGIN_RECOVERING_TURN: { target: '#codexSession.activeTurn.recoveringTurn' },
          PAUSE_FOR_USER_INPUT: { target: '#codexSession.activeTurn.waitingOnUserInput' },
          CLAIM_FINALIZATION: {
            target: 'finalizing',
            actions: ['abortSessionForFinalizing', 'recordFinalizingReason']
          },
          MARK_UNHANDLED_FAILURE: {
            target: 'finalizing',
            actions: ['abortSessionForFinalizing', 'recordFinalizingReason']
          },
          ENTER_CLEANUP: {
            target: 'cleaningUp',
            actions: ['abortSessionForCleanup', 'abortToolsForCleanup', 'recordCleaningUp']
          }
        }
      },
      activeTurn: {
        initial: 'executing',
        on: {
          BEGIN_TURN_START: { target: '#codexSession.startingTurn' },
          PAUSE_FOR_USER_INPUT: { target: '.waitingOnUserInput' },
          CLAIM_FINALIZATION: {
            target: '#codexSession.finalizing',
            actions: ['abortSessionForFinalizing', 'recordFinalizingReason']
          },
          MARK_UNHANDLED_FAILURE: {
            target: '#codexSession.finalizing',
            actions: ['abortSessionForFinalizing', 'recordFinalizingReason']
          },
          ENTER_CLEANUP: {
            target: '#codexSession.cleaningUp',
            actions: ['abortSessionForCleanup', 'abortToolsForCleanup', 'recordCleaningUp']
          }
        },
        states: {
          executing: {
            on: {
              TURN_STARTED: { target: 'executing' },
              BEGIN_AWAIT_CHILDREN_IDLE: { target: 'awaitingChildrenIdle' },
              BEGIN_SETTLING_TURN: { target: 'settlingTurn' },
              BEGIN_RECOVERING_TURN: { target: 'recoveringTurn' }
            }
          },
          awaitingChildrenIdle: {
            on: {
              END_AWAIT_CHILDREN_IDLE: { target: 'executing' }
            }
          },
          settlingTurn: {
            on: {
              END_SETTLING_TURN: { target: 'executing' }
            }
          },
          recoveringTurn: {
            on: {
              END_RECOVERING_TURN: { target: 'executing' }
            }
          },
          waitingOnUserInput: {
            on: {
              CANCEL_USER_INPUT_WAIT: { target: 'executing' }
            }
          }
        }
      },
      finalizing: {
        on: {
          ENTER_CLEANUP: {
            target: 'cleaningUp',
            actions: ['abortSessionForCleanup', 'abortToolsForCleanup', 'recordCleaningUp']
          }
        }
      },
      cleaningUp: {
        on: {
          CLOSE: { target: 'closed' }
        }
      },
      closed: {
        type: 'final'
      }
    }
  })

  const actor = createActor(machine)
  actor.start()

  const snap = () => actor.getSnapshot()

  const isFinalizing = (): boolean => snap().matches('finalizing')

  const isClosing = (): boolean => {
    const s = snap()
    return s.matches('cleaningUp') || s.matches('closed')
  }

  const isFinalizingOrClosing = (): boolean => isFinalizing() || isClosing()

  const isStopping = (): boolean =>
    sessionAbortController.signal.aborted || isFinalizingOrClosing() || externalAbortSignal?.aborted === true

  return {
    actor,
    sessionAbortSignal: sessionAbortController.signal,
    toolAbortSignal: toolAbortController.signal,
    snapshot: snap,
    isFinalizing,
    isClosing,
    isFinalizingOrClosing,
    isStopping,
    isDurableStatusCommitted(): boolean {
      return snap().context.durableStatusCommitted
    },
    isAcceptingServerRequests(): boolean {
      const s = snap()
      return !s.context.serverRequestsClosed && !isFinalizingOrClosing()
    },
    canQueueTurnCompleted(): boolean {
      const s = snap()
      return !s.matches('booting') && !isFinalizingOrClosing() && !s.matches({ activeTurn: 'waitingOnUserInput' })
    },
    canBeginTurnCompletion(): boolean {
      if (isStopping()) return false
      return snap().matches({ activeTurn: 'executing' })
    },
    canSteerActiveTurn(): boolean {
      const s = snap()
      return s.matches({ activeTurn: 'executing' }) && !s.context.steeringInFlight && !isStopping()
    },
    abortSession(reason = 'stopped'): void {
      abortControllerWithReason(sessionAbortController, reason)
    },
    beginTurnStart(): void {
      actor.send({ type: 'BEGIN_TURN_START' })
    },
    markTurnStarted(): void {
      actor.send({ type: 'TURN_STARTED' })
    },
    beginAwaitChildrenIdle(): void {
      actor.send({ type: 'BEGIN_AWAIT_CHILDREN_IDLE' })
    },
    endAwaitChildrenIdle(): void {
      actor.send({ type: 'END_AWAIT_CHILDREN_IDLE' })
    },
    beginSettlingTurn(): void {
      actor.send({ type: 'BEGIN_SETTLING_TURN' })
    },
    endSettlingTurn(): void {
      actor.send({ type: 'END_SETTLING_TURN' })
    },
    beginRecoveringTurn(): void {
      actor.send({ type: 'BEGIN_RECOVERING_TURN' })
    },
    endRecoveringTurn(): void {
      actor.send({ type: 'END_RECOVERING_TURN' })
    },
    setWaitingOnUserInput(waiting: boolean): void {
      actor.send({ type: waiting ? 'PAUSE_FOR_USER_INPUT' : 'CANCEL_USER_INPUT_WAIT' })
    },
    setSteeringInFlight(inFlight: boolean): void {
      actor.send({ type: 'SET_STEERING_IN_FLIGHT', inFlight })
    },
    prepareForRuntimeCleanup(): void {
      actor.send({ type: 'PREPARE_RUNTIME_CLEANUP' })
    },
    claimFinalization(reason = 'finalizing'): boolean {
      if (isFinalizingOrClosing()) return false
      actor.send({ type: 'CLAIM_FINALIZATION', reason })
      return isFinalizing()
    },
    markUnhandledFailure(reason = 'runtime_exception'): void {
      actor.send({ type: 'MARK_UNHANDLED_FAILURE', reason })
    },
    markDurableStatusCommitted(): void {
      actor.send({ type: 'DURABLE_STATUS_COMMITTED' })
    },
    enterCleanup(): void {
      actor.send({ type: 'ENTER_CLEANUP' })
    },
    close(): void {
      actor.send({ type: 'CLOSE' })
      actor.stop()
    }
  }
}
