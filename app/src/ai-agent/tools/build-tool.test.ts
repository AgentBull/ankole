import { describe, expect, it } from 'bun:test'
import { validateToolArguments } from '@earendil-works/pi-ai'
import { z } from 'zod'
import { buildTool } from './build-tool'

type PiAiTool = Parameters<typeof validateToolArguments>[0]

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

  it('converts zod schemas into pi-ai-compatible JSON Schema parameters', () => {
    const tool = buildTool({
      name: 'coerce',
      label: 'Coerce',
      description: 'test tool',
      schema: z.object({
        value: z.string().min(1).describe('Value to echo.'),
        limit: z.number().int().min(1).max(20).optional()
      }),
      async execute() {
        return { content: [], details: {} }
      }
    })

    expect(tool.parameters).toMatchObject({
      type: 'object',
      properties: {
        value: { type: 'string', minLength: 1, description: 'Value to echo.' },
        limit: { type: 'integer', minimum: 1, maximum: 20 }
      },
      required: ['value']
    })
    expect(
      validateToolArguments(tool as unknown as PiAiTool, {
        type: 'toolCall',
        id: 'tc_1',
        name: 'coerce',
        arguments: { value: 123, limit: '2' }
      })
    ).toEqual({
      value: '123',
      limit: 2
    })
  })
})
