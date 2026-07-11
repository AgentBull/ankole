import { describe, expect, it } from 'bun:test'
import { z } from 'zod'
import { estimateO200kBaseTokens } from '@ankole/kernel'
import type { AgentTool } from '../src/core'
import { buildSubagentProjection } from '../src/tools/subagent/dynamic-tools'

describe('@ankole/agent-computer subagent capability projection', () => {
  it('shares only the allowlist, renders the same enabled skill index, and validates calls', async () => {
    const calls: unknown[] = []
    const tools: AgentTool[] = [
      tool('skill_view', z.object({ name: z.string() }), params => {
        calls.push(params)
        return 'skill loaded'
      }),
      tool('memory_search', z.object({ query: z.string().min(1) }), params => {
        calls.push(params)
        return 'memory result'
      }),
      tool('memory_browse', z.object({ cursor: z.string() }), () => 'x'.repeat(20_000)),
      ...['command', 'interactive_terminal', 'read_file', 'patch'].map(name =>
        tool(name, z.object({ value: z.string() }), () => 'must stay hidden')
      ),
      tool(
        'web_search',
        z.string().transform(value => value.trim()),
        () => 'quarantined'
      )
    ]

    const projection = buildSubagentProjection({
      tools,
      soul: 'SOUL',
      mission: 'MISSION',
      skills: [
        { skill_name: 'enabled-skill', description: 'Visible skill.', metadata: {} },
        {
          skill_name: 'disabled-skill',
          description: 'Hidden skill.',
          metadata: { disable_model_invocation: true }
        }
      ]
    })

    expect(projection.dynamicTools.map(spec => ('name' in spec ? spec.name : undefined))).toEqual([
      'skill_view',
      'memory_search',
      'memory_browse'
    ])
    expect(projection.quarantinedTools).toEqual(['web_search'])
    expect(projection.projectedSkillCount).toBe(1)
    expect(projection.developerInstructions).toContain('enabled-skill')
    expect(projection.developerInstructions).not.toContain('disabled-skill')
    expect(projection.developerInstructions).toContain('No terminal')

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
  })

  it('budgets identity and skill context with the Kernel tokenizer', () => {
    const projection = buildSubagentProjection({
      tools: [],
      soul: `SOUL ${'长期身份背景'.repeat(10_000)}`,
      mission: `MISSION ${'长期任务目标'.repeat(10_000)}`,
      skills: Array.from({ length: 100 }, (_, index) => ({
        skill_name: `skill-${index}`,
        description: `Skill ${index} ${'详细说明'.repeat(1_000)}`,
        metadata: {}
      }))
    })

    expect(estimateO200kBaseTokens(projection.developerInstructions)).toBeLessThanOrEqual(24_000)
    expect(projection.developerInstructions).toContain('Background task safety')
    expect(projection.developerInstructions).toContain('truncated')
  })
})

function tool(name: string, schema: z.ZodType, execute: (params: unknown) => string): AgentTool {
  return {
    name,
    description: `${name} description`,
    schema,
    isReadOnly: true,
    isDestructive: false,
    async execute(_callId, params) {
      const text = execute(params)
      return { content: [{ type: 'text', text }], details: { text } }
    }
  }
}
