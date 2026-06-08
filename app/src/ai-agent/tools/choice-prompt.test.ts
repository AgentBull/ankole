import { describe, expect, it } from 'bun:test'
import { bullxInteractiveOutputActionValueVersion } from '@agentbull/bullx-sdk/plugins'
import { parseClarifyAnswerValue, renderClarifyChoicePrompt } from './choice-prompt'
import { mapAnswer, renderClarifyPrompt } from './clarify-format'

describe('plain-text clarify fallback', () => {
  it('renders choices for chat replies and maps number, option text, and free text answers', () => {
    const prompt = renderClarifyPrompt('Pick one', ['Apple', 'Banana'])
    expect(prompt).toContain('1. Apple')
    expect(prompt).toContain('Reply with a number, the option text, or your own answer.')

    expect(mapAnswer('2', ['Red', 'Green', 'Blue'])).toEqual({ text: 'Green', choiceIndex: 1 })
    expect(mapAnswer('blue', ['Red', 'Green', 'Blue'])).toEqual({ text: 'Blue', choiceIndex: 2 })
    expect(mapAnswer('purple', ['Red', 'Green', 'Blue'])).toEqual({ text: 'purple' })
    expect(mapAnswer('  hello  ')).toEqual({ text: 'hello' })
  })
})

describe('renderClarifyChoicePrompt', () => {
  it('renders an interactive choice card that can later be locked to the winning answer', () => {
    const output = renderClarifyChoicePrompt({
      question: 'A or B?',
      choices: ['A', 'B'],
      correlationId: 'conv-1',
      fallbackText: '1. A\n2. B'
    })

    expect(output.version).toBe('bullx.interactive_output.v1')
    expect(output.content).toMatchObject({
      title: 'Clarification needed',
      body: 'A or B?',
      format: 'markdown'
    })
    expect(output.response).toMatchObject({
      type: 'choice',
      interactionId: 'conv-1',
      controlId: 'clarify_answer',
      selection: 'single',
      customText: { enabled: true },
      policy: { firstResponseWins: true, responderScope: 'any_room_member' }
    })
    expect(output.response?.options).toEqual([
      { id: 'choice_0', label: 'A', value: 'A', style: 'primary' },
      { id: 'choice_1', label: 'B', value: 'B', style: 'primary' }
    ])
    expect(output.state?.status).toBe('open')
    expect(output.fallbackText).toBe('1. A\n2. B')

    const answered = renderClarifyChoicePrompt({
      question: 'A or B?',
      choices: ['A', 'B'],
      correlationId: 'conv-1',
      fallbackText: 'Answered: B',
      locked: true,
      answeredChoiceIndex: 1,
      answeredText: 'B'
    })
    expect(answered.state).toEqual({
      status: 'answered',
      selectedOptionId: 'choice_1',
      responseText: 'B'
    })
  })
})

describe('parseClarifyAnswerValue', () => {
  it('accepts only BullX clarify action values from card buttons', () => {
    const value = JSON.stringify({
      version: bullxInteractiveOutputActionValueVersion,
      interactionId: 'conv-1',
      controlId: 'clarify_answer',
      optionId: 'choice_0',
      value: 'A'
    })
    expect(parseClarifyAnswerValue(value)).toEqual({
      controlId: 'clarify_answer',
      interactionId: 'conv-1',
      choiceIndex: 0,
      choiceValue: 'A'
    })

    expect(parseClarifyAnswerValue('not json')).toBeUndefined()
    expect(parseClarifyAnswerValue(JSON.stringify({ bullx_action: 'clarify_answer' }))).toBeUndefined()
    expect(
      parseClarifyAnswerValue(
        JSON.stringify({
          version: bullxInteractiveOutputActionValueVersion,
          interactionId: 'conv-1',
          controlId: 'other'
        })
      )
    ).toBeUndefined()
  })
})
