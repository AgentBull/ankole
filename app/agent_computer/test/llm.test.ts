import { describe, expect, it } from 'bun:test'
import { z } from 'zod'
import { zodToJSONSchema } from '../src/core/llm'

describe('@ankole/agent-computer llm helpers', () => {
  it('converts Zod tool parameters with zod v4 JSON Schema support', () => {
    const schema = z.object({
      command: z.string(),
      timeoutMs: z.number().int().positive().optional()
    })

    const jsonSchema = zodToJSONSchema(schema)

    expect(jsonSchema).toMatchObject({
      type: 'object',
      properties: {
        command: { type: 'string' },
        timeoutMs: { type: 'integer', exclusiveMinimum: 0 }
      },
      required: ['command']
    })
    expect(jsonSchema).toMatchObject({ additionalProperties: false })
  })
})
