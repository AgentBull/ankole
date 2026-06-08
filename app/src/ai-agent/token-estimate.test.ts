import 'reflect-metadata'
import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'
import type { AgentMessage } from './core'

await loadTestEnvFiles()
const { estimateContextTokensJsonAware } = await import('./token-estimate')

function toolResult(text: string): AgentMessage {
  return {
    role: 'toolResult',
    toolCallId: 't',
    toolName: 'web_extract',
    content: [{ type: 'text', text }],
    isError: false,
    timestamp: 0
  }
}

describe('estimateContextTokensJsonAware', () => {
  it('counts JSON-dense tool results heavier than equal-length plain text', () => {
    const json = JSON.stringify({ key: 'v'.repeat(400), nested: { a: 1, b: 2 } })
    const plain = 'p'.repeat(json.length)
    const jsonTokens = estimateContextTokensJsonAware([toolResult(json)])
    const plainTokens = estimateContextTokensJsonAware([toolResult(plain)])
    // JSON (~len/2) is counted heavier than plain text (~len/4) of the same length.
    expect(jsonTokens).toBeGreaterThan(plainTokens)
    expect(jsonTokens).toBeGreaterThanOrEqual(Math.floor(plainTokens * 1.7))
  })
})
