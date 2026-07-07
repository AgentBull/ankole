import { describe, expect, it } from 'bun:test'
import { ms } from '@pleisto/active-support'
import { agentRuntimePolicyFromTurnStart } from '../../src/core/turns/turn_runtime_policy'
import { turnStartForTest } from '../support/llm'

describe('@ankole/agent-computer turn runtime policy', () => {
  it('uses the default inactivity timeout when no per-turn policy is present', () => {
    expect(agentRuntimePolicyFromTurnStart(turnStartForTest())).toEqual({
      inactivityTimeoutMs: ms('30m')
    })
  })

  it('allows a zero inactivity timeout to disable the watchdog', () => {
    expect(
      agentRuntimePolicyFromTurnStart({
        ...turnStartForTest(),
        request_context: {
          ai_agent: {
            inactivity_timeout_ms: 0
          }
        }
      })
    ).toEqual({
      inactivityTimeoutMs: 0
    })
  })

  it('ignores invalid runtime policy values', () => {
    expect(
      agentRuntimePolicyFromTurnStart({
        ...turnStartForTest(),
        request_context: {
          ai_agent: {
            inactivity_timeout_ms: -1,
            max_output_tokens: 12.5
          }
        }
      })
    ).toEqual({
      inactivityTimeoutMs: ms('30m')
    })
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
            max_output_tokens: 12_000
          }
        }
      })
    ).toEqual({
      inactivityTimeoutMs: 120_000,
      maxOutputTokens: 8000
    })
  })
})
