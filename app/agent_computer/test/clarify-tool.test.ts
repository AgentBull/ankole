import { describe, expect, it } from 'bun:test'
import { z } from 'zod'
import { createClarifyTool } from '../src/tools/clarify/clarify-tool'

describe('@ankole/agent-computer clarify tool', () => {
  it('publishes the clarification schema', () => {
    const tool = createClarifyTool()

    const schema = z.toJSONSchema(tool.schema) as { properties: Record<string, Record<string, unknown>> }
    expect(schema.properties.question).toBeDefined()
    expect(schema.properties.choices).toMatchObject({ minItems: 2, maxItems: 4 })
  })

  it('returns schema-defined choices and declares the turn-ending contract', async () => {
    const tool = createClarifyTool()
    const params = tool.schema.parse({
      question: 'Who should this brief target?',
      choices: [
        { label: 'Operators', description: 'People running the system.' },
        { label: 'Executives' },
        'Developers'
      ]
    })
    const result = await tool.execute('clarify-1', params)

    expect(result.details).toEqual({
      tool: 'clarify',
      ok: true,
      question: 'Who should this brief target?',
      choices: [
        { label: 'Operators', description: 'People running the system.' },
        { label: 'Executives' },
        { label: 'Developers' }
      ]
    })
    expect(result.content[0]).toMatchObject({ type: 'text' })
    expect(JSON.parse(result.content[0]?.type === 'text' ? result.content[0].text : '')).toEqual(result.details)
    expect(result.terminate).toBe(true)
    expect(
      tool.schema.safeParse({
        question: 'Who should this brief target?',
        choices: [
          { title: 'Operators', detail: 'People running the system.' },
          { title: 'Developers', detail: 'People building the system.' }
        ]
      }).success
    ).toBe(false)
    expect(tool.schema.safeParse({ question: '   ' }).success).toBe(false)
    expect(tool.schema.safeParse({ question: 'Choose one', choices: ['   ', 'Operators'] }).success).toBe(false)
    expect(tool.schema.safeParse({ question: 'Describe the intended audience.' }).success).toBe(true)
    expect(tool.schema.safeParse({ question: 'Choose one', choices: ['Operators'] }).success).toBe(false)

    expect(
      tool.schema.parse({
        question: '  Choose one  ',
        choices: [
          { label: '  Operators  ', description: '  Runs the system.  ' },
          { label: '  Developers  ', description: '  Builds the system.  ' }
        ]
      })
    ).toEqual({
      question: 'Choose one',
      choices: [
        { label: 'Operators', description: 'Runs the system.' },
        { label: 'Developers', description: 'Builds the system.' }
      ]
    })
  })
})
