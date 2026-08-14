import { describe, expect, it } from 'bun:test'
import { classifyLLMError, isLocallyRetryableLLMError, type LLMErrorKind } from '../src/core/llm-error-classifier'
import { aigatewayErrorFromFrame } from '../src/core/llm/parse'

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
