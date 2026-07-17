import { describe, expect, it } from 'bun:test'
import { z } from 'zod'
import type { AgentTool } from '../src/core'
import { buildCodexJobProjection } from '../src/core/codex-runner/projection'

describe('@ankole/agent-computer Codex job capability projection', () => {
  it('projects the exact Job allowlist and rejects browser and foreground-only tools', async () => {
    const calls: unknown[] = []
    const tools: AgentTool[] = [
      tool('skill_view', z.object({ name: z.string() }), () => 'must stay hidden'),
      tool('memory_note', z.object({ content: z.string() }), () => 'must stay hidden'),
      tool('web_search', z.object({ query: z.string() }), params => {
        calls.push(params)
        return 'search result'
      }),
      tool('web_fetch', z.object({ urls: z.array(z.string()) }), () => 'fetch result'),
      tool('memory_search', z.object({ query: z.string().min(1) }), params => {
        calls.push(params)
        return 'memory result'
      }),
      tool('memory_browse', z.object({ cursor: z.string() }), () => 'x'.repeat(20_000)),
      tool('memory_open', z.object({ name: z.string() }), () => 'opened memory'),
      tool('memory_update', z.object({ operation: z.literal('set_summary') }), () => 'updated memory'),
      tool('memory_health_check', z.object({}), () => 'healthy memory'),
      tool('browser_navigate', z.object({ url: z.string() }), () => 'page snapshot'),
      imageTool('browser_screenshot'),
      ...['browser_run', 'command', 'interactive_terminal', 'read_file', 'patch', 'reply_attachment'].map(name =>
        tool(name, z.object({ value: z.string() }), () => 'must stay hidden')
      ),
      tool(
        'browser_snapshot',
        z.string().transform(value => value.trim()),
        () => 'quarantined'
      )
    ]

    const projection = buildCodexJobProjection({
      tools
    })

    expect(projection.dynamicTools.map(spec => ('name' in spec ? spec.name : undefined)).sort()).toEqual(
      [
        'web_search',
        'web_fetch',
        'memory_search',
        'memory_browse',
        'memory_open',
        'memory_update',
        'memory_health_check'
      ].sort()
    )
    expect(projection.quarantinedTools).toEqual([])

    const invalid = await projection.handleToolCall(
      {
        ['threadId']: 'thread-1',
        ['turnId']: 'turn-1',
        ['callId']: 'call-invalid',
        namespace: null,
        tool: 'memory_search',
        arguments: { query: '' }
      },
      new AbortController().signal
    )
    expect(invalid.success).toBe(false)
    expect(calls).toHaveLength(0)

    const valid = await projection.handleToolCall(
      {
        ['threadId']: 'thread-1',
        ['turnId']: 'turn-1',
        ['callId']: 'call-valid',
        namespace: null,
        tool: 'memory_search',
        arguments: { query: 'decision' }
      },
      new AbortController().signal
    )
    expect(valid).toEqual({ contentItems: [{ type: 'inputText', text: 'memory result' }], success: true })
    expect(calls).toEqual([{ query: 'decision' }])

    const hidden = await projection.handleToolCall(
      {
        ['threadId']: 'thread-1',
        ['turnId']: 'turn-1',
        ['callId']: 'call-hidden',
        namespace: null,
        tool: 'command',
        arguments: { value: 'pwd' }
      },
      new AbortController().signal
    )
    expect(hidden.success).toBe(false)
    expect(hidden.contentItems[0]).toEqual({
      type: 'inputText',
      text: 'Dynamic tool is unavailable: command'
    })

    const bounded = await projection.handleToolCall(
      {
        ['threadId']: 'thread-1',
        ['turnId']: 'turn-1',
        ['callId']: 'call-bounded',
        namespace: null,
        tool: 'memory_browse',
        arguments: { cursor: 'next' }
      },
      new AbortController().signal
    )
    expect(bounded.success).toBe(true)
    const boundedText = bounded.contentItems[0]?.type === 'inputText' ? bounded.contentItems[0].text : ''
    expect(new TextEncoder().encode(boundedText).byteLength).toBeLessThanOrEqual(16_384)
    expect(boundedText).toEndWith('...[truncated]')

    const screenshot = await projection.handleToolCall(
      {
        ['threadId']: 'thread-1',
        ['turnId']: 'turn-1',
        ['callId']: 'call-image',
        namespace: null,
        tool: 'browser_screenshot',
        arguments: {}
      },
      new AbortController().signal
    )
    expect(screenshot).toEqual({
      contentItems: [{ type: 'inputText', text: 'Dynamic tool is unavailable: browser_screenshot' }],
      success: false
    })
  })
})

function tool(name: string, schema: z.ZodType, execute: (params: unknown) => string): AgentTool {
  return {
    name,
    description: `${name} description`,
    schema,
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => `测试工具：${name}`,
    async execute(_callId, params) {
      const text = execute(params)
      return { content: [{ type: 'text', text }], details: { text } }
    }
  }
}

function imageTool(name: string): AgentTool {
  return {
    name,
    description: `${name} description`,
    schema: z.object({}),
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => `测试工具：${name}`,
    async execute() {
      return {
        content: [
          { type: 'text', text: 'screenshot saved' },
          { type: 'image', image: 'data:image/png;base64,iVBORw0KGgo=', mimeType: 'image/png' }
        ],
        details: { path: '/workspace/user-files/screenshot.png' }
      }
    }
  }
}
