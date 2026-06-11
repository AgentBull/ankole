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
  it('clears old compactable tool results without changing replay-critical content', () => {
    const messages = [
      user('q1'),
      toolResult('web_search', 'search result 1', 's1'),
      toolResult('web_extract', 'extract result 1', 'e1'),
      toolResult('web_search', 'search result 2', 's2'),
      toolResult('clarify', 'user said yes', 'c1'),
      toolResult('web_search', 'search result 3', 's3')
    ]
    const out = microcompact(messages, { keepRecent: 2 })
    // 4 compactable; keep last 2 (s2, s3) full, clear the older two (s1, e1).
    expect(textOf(out[1]!)).toBe(MICROCOMPACT_CLEARED_TEXT)
    expect(textOf(out[2]!)).toBe(MICROCOMPACT_CLEARED_TEXT)
    expect(textOf(out[3]!)).toBe('search result 2')
    expect(textOf(out[4]!)).toBe('user said yes')
    expect(textOf(out[5]!)).toBe('search result 3')
    expect(textOf(out[0]!)).toBe('q1')
    expect(textOf(messages[1]!)).toBe('search result 1')
  })

  it('is stable across repeated compaction and returns the original array when no work is needed', () => {
    const messages = [
      toolResult('web_search', 'r1', 's1'),
      toolResult('web_search', 'r2', 's2'),
      toolResult('web_search', 'r3', 's3')
    ]
    const once = microcompact(messages, { keepRecent: 1 })
    const twice = microcompact(once, { keepRecent: 1 })
    expect(JSON.stringify(twice)).toBe(JSON.stringify(once))

    const unchanged = [toolResult('web_search', 'r1', 's1'), user('q')]
    expect(microcompact(unchanged, { keepRecent: 5 })).toBe(unchanged)
  })
})
