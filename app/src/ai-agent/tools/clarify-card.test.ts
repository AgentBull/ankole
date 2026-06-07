import { describe, expect, it } from 'bun:test'
import { parseClarifyAnswerValue, renderClarifyCard } from './clarify-card'

describe('renderClarifyCard', () => {
  it('renders a card v2 with the question, choices as buttons, and the answer protocol', () => {
    const card = renderClarifyCard({ question: 'A or B?', choices: ['A', 'B'], correlationId: 'conv-1' }) as any
    expect(card.schema).toBe('2.0')
    expect(card.header.title.content).toBe('Clarification needed')

    const question = card.body.elements.find((el: any) => el.text?.tag === 'lark_md')
    expect(question.text.content).toBe('A or B?')

    const action = card.body.elements.find((el: any) => el.tag === 'action')
    expect(action.actions).toHaveLength(2)
    expect(action.actions[0].value).toEqual({
      bullx_action: 'clarify_answer',
      correlation_id: 'conv-1',
      choice_index: 0,
      choice_value: 'A'
    })
    expect(action.actions[0].disabled).toBeUndefined()
  })

  it('open-ended question renders no action block', () => {
    const card = renderClarifyCard({ question: 'why?', choices: [], correlationId: 'conv-2' }) as any
    expect(card.body.elements.some((el: any) => el.tag === 'action')).toBe(false)
  })

  it('locked card disables buttons, marks the chosen option, and shows the answer', () => {
    const card = renderClarifyCard({
      question: 'A or B?',
      choices: ['A', 'B'],
      correlationId: 'conv-1',
      locked: true,
      answeredChoiceIndex: 1,
      answeredText: 'B'
    }) as any
    const action = card.body.elements.find((el: any) => el.tag === 'action')
    expect(action.actions.every((btn: any) => btn.disabled === true)).toBe(true)
    expect(action.actions[1].text.content).toBe('B ✓')
    const answered = card.body.elements.find((el: any) => el.text?.content?.startsWith('Answered:'))
    expect(answered.text.content).toBe('Answered: B')
  })
})

describe('parseClarifyAnswerValue', () => {
  it('parses a JSON string value', () => {
    const value = JSON.stringify({
      bullx_action: 'clarify_answer',
      correlation_id: 'conv-1',
      choice_index: 0,
      choice_value: 'A'
    })
    expect(parseClarifyAnswerValue(value)).toEqual({
      bullx_action: 'clarify_answer',
      correlation_id: 'conv-1',
      choice_index: 0,
      choice_value: 'A'
    })
  })

  it('parses an object value', () => {
    expect(
      parseClarifyAnswerValue({ bullx_action: 'clarify_answer', correlation_id: 'c', choice_index: 2, choice_value: 'X' })
    ).toMatchObject({ correlation_id: 'c', choice_index: 2, choice_value: 'X' })
  })

  it('rejects non-clarify or malformed values', () => {
    expect(parseClarifyAnswerValue('not json')).toBeUndefined()
    expect(parseClarifyAnswerValue(JSON.stringify({ bullx_action: 'other' }))).toBeUndefined()
    expect(parseClarifyAnswerValue(JSON.stringify({ bullx_action: 'clarify_answer' }))).toBeUndefined()
  })
})
