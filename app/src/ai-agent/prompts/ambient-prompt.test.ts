import { describe, expect, it } from 'bun:test'

import { applyAmbientRecognizerStructuredOutput } from './ambient-prompt'

describe('ambient recognizer prompt', () => {
  it('adds structured-output schema to OpenAI Responses and Chat payload shapes', () => {
    const responsesPayload = applyAmbientRecognizerStructuredOutput({
      input: [],
      model: 'gpt-test',
      stream: true
    }) as Record<string, any>
    expect(responsesPayload.text.format).toMatchObject({
      type: 'json_schema',
      name: 'ambient_intervention_decision',
      strict: true
    })
    expect(responsesPayload.text.format.schema.required).toEqual(['intervene', 'reason_summary'])

    const chatPayload = applyAmbientRecognizerStructuredOutput({
      messages: [],
      model: 'gpt-test',
      stream: true
    }) as Record<string, any>
    expect(chatPayload.response_format).toMatchObject({
      type: 'json_schema',
      json_schema: {
        name: 'ambient_intervention_decision',
        strict: true
      }
    })
    expect(chatPayload.response_format.json_schema.schema.additionalProperties).toBe(false)
  })
})
