import { describe, expect, it } from 'bun:test'
import { validateToolArguments } from '@/llm'
import { z } from 'zod'
import { buildTool } from './build-tool'

type LlmTool = Parameters<typeof validateToolArguments>[0]

const minimalDef = {
  name: 'minimal',
  label: 'Minimal',
  description: 'test tool',
  schema: z.object({}),
  async execute() {
    return { content: [], details: {} }
  }
}

describe('buildTool fail-closed defaults', () => {
  it('fills conservative defaults while allowing explicit tool declarations to opt out', () => {
    const tool = buildTool(minimalDef)
    expect(tool.executionMode).toBe('sequential')
    expect(tool.isReadOnly).toBe(false)
    expect(tool.isDestructive).toBe(true)

    const explicitlySafe = buildTool({
      ...minimalDef,
      executionMode: 'parallel',
      isReadOnly: true,
      isDestructive: false
    })
    expect(explicitlySafe.executionMode).toBe('parallel')
    expect(explicitlySafe.isReadOnly).toBe(true)
    expect(explicitlySafe.isDestructive).toBe(false)
  })

  it('uses the zod schema as the single source of truth for tool arguments', () => {
    const tool = buildTool({
      name: 'validate',
      label: 'Validate',
      description: 'test tool',
      schema: z.object({
        value: z.string().min(1).describe('Value to echo.'),
        limit: z.number().int().min(1).max(20).optional()
      }),
      async execute() {
        return { content: [], details: {} }
      }
    })

    expect(
      validateToolArguments(tool as unknown as LlmTool, {
        type: 'toolCall',
        id: 'tc_1',
        name: 'validate',
        arguments: { value: 'ok', limit: 2 }
      })
    ).toEqual({
      value: 'ok',
      limit: 2
    })
    expect(() =>
      validateToolArguments(tool as unknown as LlmTool, {
        type: 'toolCall',
        id: 'tc_2',
        name: 'validate',
        arguments: { value: 123, limit: '2' }
      })
    ).toThrow()
  })
})
