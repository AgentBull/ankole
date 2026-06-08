import { describe, expect, it } from 'bun:test'
import type { AgentMessage } from './core'
import { microcompact, MICROCOMPACT_CLEARED_TEXT } from './microcompact'

function toolResult(toolName: string, text: string, id = toolName): AgentMessage {
  return {
    role: 'toolResult',
    toolCallId: id,
    toolName,
    content: [{ type: 'text', text }],
    isError: false,
    timestamp: 0
  }
}

function user(text: string): AgentMessage {
  return { role: 'user', content: [{ type: 'text', text }], timestamp: 0 }
}

function textOf(message: AgentMessage): string {
  const content = (message as { content?: Array<{ type: string; text?: string }> }).content
  return content?.[0]?.text ?? ''
}

describe('microcompact', () => {
  it('clears old compactable tool results, keeps the most recent N in full', () => {
    const messages = [
      user('q1'),
      toolResult('web_search', 'search result 1', 's1'),
      toolResult('web_extract', 'extract result 1', 'e1'),
      toolResult('web_search', 'search result 2', 's2'),
      toolResult('web_search', 'search result 3', 's3')
    ]
    const out = microcompact(messages, { keepRecent: 2 })
    // 4 compactable; keep last 2 (s2, s3) full, clear the older two (s1, e1).
    expect(textOf(out[1]!)).toBe(MICROCOMPACT_CLEARED_TEXT)
    expect(textOf(out[2]!)).toBe(MICROCOMPACT_CLEARED_TEXT)
    expect(textOf(out[3]!)).toBe('search result 2')
    expect(textOf(out[4]!)).toBe('search result 3')
    expect(textOf(out[0]!)).toBe('q1')
  })

  it('never clears clarify (user answers)', () => {
    const messages = [
      toolResult('clarify', 'user said yes', 'c1'),
      toolResult('web_search', 'r1', 's1'),
      toolResult('web_search', 'r2', 's2'),
      toolResult('web_search', 'r3', 's3')
    ]
    const out = microcompact(messages, { keepRecent: 1 })
    expect(textOf(out[0]!)).toBe('user said yes')
  })

  it('does not mutate the input array or its messages (PG trajectory stays intact)', () => {
    const source = toolResult('web_search', 'original result', 's1')
    const messages = [source, toolResult('web_search', 'r2', 's2'), toolResult('web_search', 'r3', 's3')]
    microcompact(messages, { keepRecent: 1 })
    expect(textOf(source)).toBe('original result')
    expect(textOf(messages[0]!)).toBe('original result')
  })

  it('is idempotent / monotonic — re-running yields byte-identical output (cache-safe)', () => {
    const messages = [
      toolResult('web_search', 'r1', 's1'),
      toolResult('web_search', 'r2', 's2'),
      toolResult('web_search', 'r3', 's3')
    ]
    const once = microcompact(messages, { keepRecent: 1 })
    const twice = microcompact(once, { keepRecent: 1 })
    expect(JSON.stringify(twice)).toBe(JSON.stringify(once))
  })

  it('is a no-op (same reference) when compactable count <= keepRecent', () => {
    const messages = [toolResult('web_search', 'r1', 's1'), user('q')]
    expect(microcompact(messages, { keepRecent: 5 })).toBe(messages)
  })

  it('shrinks cleared content', () => {
    const big = 'x'.repeat(10_000)
    const messages = [
      toolResult('web_search', big, 's1'),
      toolResult('web_search', 'r2', 's2'),
      toolResult('web_search', 'r3', 's3')
    ]
    const out = microcompact(messages, { keepRecent: 2 })
    expect(textOf(out[0]!).length).toBeLessThan(big.length)
  })
})
