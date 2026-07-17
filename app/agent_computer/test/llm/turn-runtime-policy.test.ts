import { describe, expect, it } from 'bun:test'
import { ms } from '@pleisto/active-support'
import { agentRuntimePolicyFromTurnStart } from '../../src/core/turns/turn_runtime_policy'
import { turnStartForTest } from '../support/llm'

describe('@ankole/agent-computer turn runtime policy', () => {
  it('uses the snapshotted iteration budget and default inactivity timeout', () => {
    expect(agentRuntimePolicyFromTurnStart(turnStartForTest())).toEqual({
      maxIterations: 90,
      inactivityTimeoutMs: ms('35m')
    })
  })

  it('allows a zero inactivity timeout to disable the watchdog', () => {
    expect(
      agentRuntimePolicyFromTurnStart({
        ...turnStartForTest(),
        request_context: {
          ai_agent: {
            max_iterations: 90,
            inactivity_timeout_ms: 0
          }
        }
      })
    ).toEqual({
      maxIterations: 90,
      inactivityTimeoutMs: 0
    })
  })

  it('rejects a missing or invalid iteration-budget snapshot', () => {
    expect(() =>
      agentRuntimePolicyFromTurnStart({
        ...turnStartForTest(),
        request_context: {
          ai_agent: {
            inactivity_timeout_ms: -1,
            max_output_tokens: 12.5,
            max_iterations: 0
          }
        }
      })
    ).toThrow('request_context.ai_agent.max_iterations must be a positive integer')

    expect(() =>
      agentRuntimePolicyFromTurnStart({
        ...turnStartForTest(),
        request_context: { ai_agent: {} }
      })
    ).toThrow('request_context.ai_agent.max_iterations must be a positive integer')
  })

  it('clamps max output tokens to the model completion ceiling', () => {
    const base = turnStartForTest()

    expect(
      agentRuntimePolicyFromTurnStart({
        ...base,
        model_ref: {
          ...base.model_ref,
          max_completion_tokens: 8000
        },
        request_context: {
          ai_agent: {
            inactivity_timeout_ms: 120_000,
            max_output_tokens: 12_000,
            max_iterations: 42
          }
        }
      })
    ).toEqual({
      inactivityTimeoutMs: 120_000,
      maxIterations: 42,
      maxOutputTokens: 8000
    })
  })
})
