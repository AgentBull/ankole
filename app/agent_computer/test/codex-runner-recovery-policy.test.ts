import { describe, expect, it } from 'bun:test'
import {
  classifyCodexRecoveryFailure,
  codexCredentialPoolExhaustion,
  initialCodexRecoveryState,
  transitionCodexRecovery,
  type CodexRecoveryState
} from '../src/core/codex-runner/recovery-policy'

describe('@ankole/agent-computer Codex recovery policy', () => {
  it('bounds transient turn retries before handing recovery back to the durable Job lease', () => {
    let state: CodexRecoveryState = initialCodexRecoveryState
    const delays: number[] = []

    for (let attempt = 0; attempt < 3; attempt += 1) {
      const decision = transitionCodexRecovery({ stage: 'turn', failure: 'transient', state })
      expect(decision.action).toBe('retry_turn')
      delays.push(decision.delayMs!)
      state = decision.nextState
    }

    expect(delays).toEqual([250, 500, 1_000])
    expect(state).toEqual({ transientRetries: 3, compactRetries: 0, newThreadRetries: 0 })
    expect(transitionCodexRecovery({ stage: 'turn', failure: 'transient', state })).toEqual({
      action: 'durable_retry',
      nextState: state
    })
  })

  it('shares the single replacement-thread budget between resume and active-turn recovery', () => {
    const initial = { ...initialCodexRecoveryState }
    const resume = transitionCodexRecovery({ stage: 'resume', failure: 'unknown_session', state: initial })

    expect(resume).toEqual({
      action: 'replace_thread',
      nextState: { transientRetries: 0, compactRetries: 0, newThreadRetries: 1 }
    })
    expect(initial).toEqual(initialCodexRecoveryState)
    expect(transitionCodexRecovery({ stage: 'turn', failure: 'unknown_session', state: resume.nextState })).toEqual({
      action: 'fail',
      nextState: resume.nextState
    })
  })

  it('compacts once only when the current session can actually compact', () => {
    const unavailable = transitionCodexRecovery({
      stage: 'turn',
      failure: 'context_overflow',
      state: initialCodexRecoveryState,
      canCompact: false
    })
    expect(unavailable).toEqual({ action: 'fail', nextState: initialCodexRecoveryState })

    const first = transitionCodexRecovery({
      stage: 'turn',
      failure: 'context_overflow',
      state: initialCodexRecoveryState,
      canCompact: true
    })
    expect(first).toEqual({
      action: 'compact_then_retry',
      nextState: { transientRetries: 0, compactRetries: 1, newThreadRetries: 0 }
    })
    expect(
      transitionCodexRecovery({
        stage: 'turn',
        failure: 'context_overflow',
        state: first.nextState,
        canCompact: true
      })
    ).toEqual({ action: 'fail', nextState: first.nextState })
  })

  it('keeps resume transients retryable and terminal failures terminal', () => {
    expect(
      transitionCodexRecovery({ stage: 'resume', failure: 'transient', state: initialCodexRecoveryState })
    ).toEqual({ action: 'durable_retry', nextState: initialCodexRecoveryState })
    expect(transitionCodexRecovery({ stage: 'turn', failure: 'terminal', state: initialCodexRecoveryState })).toEqual({
      action: 'fail',
      nextState: initialCodexRecoveryState
    })
  })

  it('classifies structured Codex failures before message fallbacks', () => {
    expect(classifyCodexRecoveryFailure({ codexErrorInfo: 'contextWindowExceeded' })).toBe('context_overflow')
    expect(classifyCodexRecoveryFailure({ codexErrorInfo: { serverOverloaded: {} } })).toBe('transient')
    expect(classifyCodexRecoveryFailure({ code: -32001, message: 'request failed' })).toBe('transient')
    expect(classifyCodexRecoveryFailure({ message: 'No rollout found for thread abc' })).toBe('unknown_session')
    expect(classifyCodexRecoveryFailure({ message: 'permission denied' })).toBe('terminal')
  })

  it('recognizes the AIGateway pool terminal through Codex 429 projections', () => {
    expect(
      codexCredentialPoolExhaustion({
        codexErrorInfo: { responseTooManyFailedAttempts: { httpStatusCode: 429 } },
        message: 'exceeded retry limit'
      })
    ).toEqual({})

    expect(
      codexCredentialPoolExhaustion({
        message: 'AIGateway credential pool exhausted. retry_at=2026-07-29T08:15:00Z'
      })
    ).toEqual({ retryAt: '2026-07-29T08:15:00.000Z' })

    expect(
      codexCredentialPoolExhaustion({
        codexErrorInfo: { responseTooManyFailedAttempts: { httpStatusCode: 503 } },
        message: 'provider unavailable'
      })
    ).toBeUndefined()
  })
})
