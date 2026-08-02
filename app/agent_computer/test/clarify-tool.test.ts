import { describe, expect, it } from 'bun:test'
import { z } from 'zod'
import { createClarifyTool } from '../src/tools/clarify/clarify-tool'

describe('@ankole/agent-computer clarify tool', () => {
  it('publishes the clarification policy in the model-visible tool contract', () => {
    const tool = createClarifyTool()

    expect(tool.description).toBe(
      [
        'Ask the user one question only when the answer is necessary to choose the intended result or next action.',
        'Use the request and prior conversation before asking. Do not ask about a preference the user already gave or when a safe low-risk default is available.',
        'For post-task feedback, ask only when the answer will decide whether to accept, revise, or continue the work.',
        'On success it returns the normalized question and choices, records them durably, and ends the current turn. Do not emit another answer or call more tools; the user reply arrives as the next user message.'
      ].join('\n')
    )
    expect(z.toJSONSchema(tool.schema)).toMatchObject({
      properties: {
        question: {
          description: 'One self-contained question with only the context needed to answer it.'
        },
        choices: {
          minItems: 2,
          maxItems: 4,
          description:
            'Two to four materially different choices. Omit this field for an open-ended question. Include a no-action choice when the user may decline the action.',
          items: {
            anyOf: [
              {
                description: 'A short label that identifies the choice without rereading the question.'
              },
              {
                properties: {
                  label: {
                    description: 'A short label that identifies the choice without rereading the question.'
                  },
                  description: {
                    description: 'The result or tradeoff of selecting this choice.'
                  }
                }
              }
            ]
          }
        }
      }
    })
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
