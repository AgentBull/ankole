import { describe, expect, it } from 'bun:test'
import { renderInteractiveOutputToLarkCard } from './interactive-output'

describe('renderInteractiveOutputToLarkCard', () => {
  it('renders choice output as CardKit buttons with protocol action values', () => {
    const card = renderInteractiveOutputToLarkCard({
      version: 'bullx.interactive_output.v1',
      content: {
        title: 'Clarification needed',
        body: 'A or B?',
        format: 'markdown',
        facts: [{ label: 'Run', value: 'conv-1' }]
      },
      response: {
        type: 'choice',
        interactionId: 'conv-1',
        controlId: 'clarify_answer',
        selection: 'single',
        options: [
          { id: 'choice_0', label: 'A', value: 'A', style: 'primary' },
          { id: 'choice_1', label: 'B', value: 'B' }
        ],
        customText: { enabled: true, hint: 'Reply in this chat if none fit.' },
        policy: { firstResponseWins: true, responderScope: 'any_room_member' }
      },
      state: { status: 'open' },
      fallbackText: 'A or B?'
    }) as any

    expect(card.schema).toBe('2.0')
    expect(card.header.title.content).toBe('Clarification needed')
    expect(card.body.elements[0].text).toEqual({ tag: 'lark_md', content: 'A or B?' })
    // Card JSON 2.0 dropped the `action` wrapper module: buttons live directly in elements.
    expect(card.body.elements.some((el: any) => el.tag === 'action')).toBe(false)
    const buttons = card.body.elements.filter((el: any) => el.tag === 'button')
    expect(buttons[0]).toMatchObject({
      tag: 'button',
      name: 'clarify_answer',
      type: 'primary',
      behaviors: [
        {
          type: 'callback',
          value: {
            version: 'bullx.interactive_output.action.v1',
            interactionId: 'conv-1',
            controlId: 'clarify_answer',
            optionId: 'choice_0',
            value: 'A'
          }
        }
      ]
    })
  })

  it('renders answered state as disabled selected buttons', () => {
    const card = renderInteractiveOutputToLarkCard({
      version: 'bullx.interactive_output.v1',
      content: { body: 'A or B?', format: 'plain' },
      response: {
        type: 'choice',
        interactionId: 'conv-1',
        controlId: 'clarify_answer',
        selection: 'single',
        options: [
          { id: 'choice_0', label: 'A', value: 'A' },
          { id: 'choice_1', label: 'B', value: 'B' }
        ]
      },
      state: { status: 'answered', selectedOptionId: 'choice_1', responseText: 'B' },
      fallbackText: 'Answered: B'
    }) as any

    const buttons = card.body.elements.filter((el: any) => el.tag === 'button')
    expect(buttons.length).toBe(2)
    expect(buttons.every((button: any) => button.disabled === true)).toBe(true)
    expect(buttons[1].text.content).toBe('B (selected)')
    expect(card.body.elements.some((el: any) => el.text?.content === 'Answered: B')).toBe(true)
  })
})
