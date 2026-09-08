import { describe, expect, it } from 'bun:test'
import { classifyLLMError, isLocallyRetryableLLMError, type LLMErrorKind } from '../src/core/llm-error-classifier'
import { aigatewayErrorFromFrame } from '../src/core/llm/parse'
import { turnFailureDetails } from '../src/worker/turn_failure'

describe('LLM error classification', () => {
  it('classifies AIGateway upstream WebSocket transport error frames as retryable transport', () => {
    const error = aigatewayErrorFromFrame({
      type: 'error',
      sequence_number: 0,
      error: {
        message: 'WebSocket protocol error: Connection reset without closing handshake',
        type: 'server_error',
        code: 'websocket_read_failed',
        details_json: { stage: 'read' }
      }
    })

    expect(classifyLLMError(error)).toMatchObject({ kind: 'timeout', retryable: true })
    expect(isLocallyRetryableLLMError(error)).toBe(true)

    for (const code of ['websocket_connect_failed', 'websocket_send_failed']) {
      expect(classifyLLMError({ code })).toMatchObject({ kind: 'timeout', retryable: true })
    }
  })

  it('retains a rendered AIGateway WebSocket code in durable Turn failure details', () => {
    const error = new Error(
      'AIGateway response failed code=websocket_read_failed WebSocket protocol error: Connection reset without closing handshake'
    )

    expect(turnFailureDetails(error)).toMatchObject({
      llm_error_kind: 'timeout',
      error_code: 'websocket_read_failed',
      retryable: true
    })
  })

  it('ends the turn on an Agent token quota rejection instead of retrying its 429', () => {
    const frame = aigatewayErrorFromFrame({
      type: 'error',
      status: 429,
      error: {
        code: 'agent_token_quota_exceeded',
        type: 'agent_token_quota_exceeded',
        message: 'The Agent has used its token quota for the current period.',
        retryable: false,
        resets_at: 1757980800,
        details: { used_tokens: 1200000, limit_tokens: 1000000, window_ends_at: '2026-09-16T00:00:00Z' }
      }
    })

    expect(classifyLLMError(frame)).toEqual({ kind: 'quota', retryable: false, shouldCompress: false })
    expect(isLocallyRetryableLLMError(frame)).toBe(false)
    expect(turnFailureDetails(frame)).toMatchObject({
      llm_error_kind: 'quota',
      error_code: 'agent_token_quota_exceeded',
      retryable: false,
      aigateway: {
        code: 'agent_token_quota_exceeded',
        status: 429,
        details_json: { used_tokens: 1200000, limit_tokens: 1000000, window_ends_at: '2026-09-16T00:00:00Z' }
      }
    })

    const httpError = { status: 429, error: { code: 'agent_token_quota_exceeded', retryable: false } }
    expect(classifyLLMError(httpError)).toEqual({ kind: 'quota', retryable: false, shouldCompress: false })

    const rendered = new Error(
      'AIGateway response failed status=429 code=agent_token_quota_exceeded The Agent has used its token quota for the current period.'
    )
    expect(classifyLLMError(rendered)).toEqual({ kind: 'quota', retryable: false, shouldCompress: false })

    expect(classifyLLMError({ status: 429, code: 'rate_limit_exceeded' })).toMatchObject({
      kind: 'rate_limit',
      retryable: true
    })
  })

  it('follows wrapped provider cause chains and terminates cyclic graphs', () => {
    const cases: Array<{ error: unknown; kind: LLMErrorKind }> = [
      {
        error: { cause: { response: { status: 429 } } },
        kind: 'rate_limit'
      },
      {
        error: { cause: { error: { code: 'ETIMEDOUT' } } },
        kind: 'timeout'
      },
      {
        error: { cause: { response: { message: 'context length exceeded for this model' } } },
        kind: 'overflow'
      }
    ]

    for (const item of cases) expect(classifyLLMError(item.error).kind).toBe(item.kind)

    const cyclic: Record<string, unknown> = { message: 'unclassified wrapper' }
    cyclic.cause = cyclic
    expect(classifyLLMError(cyclic).kind).toBe('unknown')
  })
})
