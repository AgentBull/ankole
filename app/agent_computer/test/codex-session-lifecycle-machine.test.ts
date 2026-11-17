import { describe, expect, it } from 'bun:test'
import { createCodexSessionLifecycle } from '../src/core/codex-runner/job/session-lifecycle-machine'

describe('CodexSessionLifecycle (XState v5)', () => {
  it('progresses across turn lifecycle states and gates steering strictly to activeTurn.executing', () => {
    const lifecycle = createCodexSessionLifecycle()
    try {
      expect(lifecycle.snapshot().value).toBe('booting')
      expect(lifecycle.canSteerActiveTurn()).toBe(false)
      expect(lifecycle.canQueueTurnCompleted()).toBe(false)
      expect(lifecycle.canBeginTurnCompletion()).toBe(false)
      lifecycle.markTurnStarted()
      expect(lifecycle.snapshot().value).toBe('booting')
      expect(lifecycle.isAcceptingServerRequests()).toBe(true)

      lifecycle.beginTurnStart()
      expect(lifecycle.snapshot().value).toBe('startingTurn')
      expect(lifecycle.canSteerActiveTurn()).toBe(false)

      lifecycle.markTurnStarted()
      expect(lifecycle.snapshot().value).toEqual({ activeTurn: 'executing' })
      expect(lifecycle.canSteerActiveTurn()).toBe(true)
      expect(lifecycle.canBeginTurnCompletion()).toBe(true)

      lifecycle.setSteeringInFlight(true)
      expect(lifecycle.canSteerActiveTurn()).toBe(false)
      lifecycle.setSteeringInFlight(false)
      expect(lifecycle.canSteerActiveTurn()).toBe(true)

      lifecycle.beginAwaitChildrenIdle()
      expect(lifecycle.snapshot().value).toEqual({ activeTurn: 'awaitingChildrenIdle' })
      expect(lifecycle.canSteerActiveTurn()).toBe(false)
      expect(lifecycle.canBeginTurnCompletion()).toBe(false)
      lifecycle.endAwaitChildrenIdle()

      lifecycle.beginSettlingTurn()
      expect(lifecycle.snapshot().value).toEqual({ activeTurn: 'settlingTurn' })
      expect(lifecycle.canSteerActiveTurn()).toBe(false)
      expect(lifecycle.canBeginTurnCompletion()).toBe(false)

      expect(lifecycle.claimFinalization('succeeded')).toBe(true)
      expect(lifecycle.isFinalizing()).toBe(true)
      expect(lifecycle.isStopping()).toBe(true)
      expect(lifecycle.sessionAbortSignal.aborted).toBe(true)
      expect(lifecycle.isAcceptingServerRequests()).toBe(false)

      // Trailing finally cleanup from settlingTurn must not clobber finalizing.
      lifecycle.endSettlingTurn()
      expect(lifecycle.isFinalizing()).toBe(true)

      lifecycle.markDurableStatusCommitted()
      expect(lifecycle.isDurableStatusCommitted()).toBe(true)

      lifecycle.enterCleanup()
      expect(lifecycle.isClosing()).toBe(true)
      expect(lifecycle.toolAbortSignal.aborted).toBe(true)

      lifecycle.close()
      expect(lifecycle.snapshot().value).toBe('closed')
    } finally {
      lifecycle.close()
    }
  })

  it('guarantees single-winner claimFinalization and preserves retry turn state across finally hooks', () => {
    const lifecycle = createCodexSessionLifecycle()
    try {
      lifecycle.beginTurnStart()
      lifecycle.markTurnStarted()

      // Failed turn enters recoveringTurn, starts a retry turn (which completes Turn/start),
      // and then runs finally { endRecoveringTurn() }.
      lifecycle.beginRecoveringTurn()
      expect(lifecycle.canBeginTurnCompletion()).toBe(false)
      lifecycle.beginTurnStart()
      expect(lifecycle.snapshot().value).toBe('startingTurn')
      expect(lifecycle.canSteerActiveTurn()).toBe(false)
      lifecycle.markTurnStarted()
      expect(lifecycle.snapshot().value).toEqual({ activeTurn: 'executing' })

      // `endRecoveringTurn()` in finally is a no-op once the retry turn is already executing.
      lifecycle.endRecoveringTurn()
      expect(lifecycle.snapshot().value).toEqual({ activeTurn: 'executing' })
      expect(lifecycle.canSteerActiveTurn()).toBe(true)

      // Concurrent finalization races admit exactly one winner.
      expect(lifecycle.claimFinalization('user_stop')).toBe(true)
      expect(lifecycle.claimFinalization('turn_failed')).toBe(false)
      expect(lifecycle.claimFinalization('steer_fatal_error')).toBe(false)

      // Late turn start / turn started events after finalization cannot reopen execution.
      lifecycle.beginTurnStart()
      lifecycle.markTurnStarted()
      expect(lifecycle.isFinalizing()).toBe(true)
      expect(lifecycle.canBeginTurnCompletion()).toBe(false)
      expect(lifecycle.canQueueTurnCompleted()).toBe(false)
    } finally {
      lifecycle.close()
    }
  })

  it('blocks turn completion during waitingOnUserInput and keeps unhandled runtime loss distinct from claimed finalization', () => {
    const lifecycle = createCodexSessionLifecycle()
    try {
      lifecycle.beginTurnStart()
      lifecycle.markTurnStarted()

      lifecycle.setWaitingOnUserInput(true)
      expect(lifecycle.snapshot().value).toEqual({ activeTurn: 'waitingOnUserInput' })
      expect(lifecycle.canQueueTurnCompleted()).toBe(false)
      expect(lifecycle.canBeginTurnCompletion()).toBe(false)
      expect(lifecycle.canSteerActiveTurn()).toBe(false)

      // Recovering if interrupt throws before finalization is claimed:
      lifecycle.setWaitingOnUserInput(false)
      expect(lifecycle.snapshot().value).toEqual({ activeTurn: 'executing' })
      expect(lifecycle.canQueueTurnCompleted()).toBe(true)

      // Runtime loss before finalization closes server requests and aborts tools,
      // while keeping `isFinalizing()` false so cleanup records the runtime exception.
      lifecycle.prepareForRuntimeCleanup()
      expect(lifecycle.isAcceptingServerRequests()).toBe(false)
      expect(lifecycle.toolAbortSignal.aborted).toBe(true)
      expect(lifecycle.isFinalizing()).toBe(false)

      lifecycle.markUnhandledFailure('runtime_lost')
      expect(lifecycle.isFinalizing()).toBe(true)
      expect(lifecycle.sessionAbortSignal.aborted).toBe(true)
    } finally {
      lifecycle.close()
    }
  })

  it('handles overlapping steering, finalization, and cleanup events deterministically with pure context updates', () => {
    const lifecycle = createCodexSessionLifecycle()
    try {
      lifecycle.beginTurnStart()
      lifecycle.markTurnStarted()
      lifecycle.setSteeringInFlight(true)
      expect(lifecycle.canSteerActiveTurn()).toBe(false)

      // Overlapping finalization claim wins over steering and late turn transitions.
      expect(lifecycle.claimFinalization('user_stop')).toBe(true)
      lifecycle.setSteeringInFlight(false)
      lifecycle.markUnhandledFailure('secondary_failure')
      lifecycle.prepareForRuntimeCleanup()
      lifecycle.enterCleanup()

      const snap = lifecycle.snapshot()
      expect(snap.value).toBe('cleaningUp')
      expect(snap.context.stopReason).toBe('user_stop')
      expect(snap.context.serverRequestsClosed).toBe(true)
      expect(lifecycle.sessionAbortSignal.aborted).toBe(true)
      expect(lifecycle.toolAbortSignal.aborted).toBe(true)
    } finally {
      lifecycle.close()
    }
  })
})
