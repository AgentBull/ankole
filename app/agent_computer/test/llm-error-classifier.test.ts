import { describe, expect, it } from 'bun:test'
import { classifyLLMError, type LLMErrorKind } from '../src/core/llm-error-classifier'

describe('LLM error classification', () => {
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
