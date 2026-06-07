import { describe, expect, it } from 'bun:test'
import { mapAnswer, renderClarifyPrompt } from './clarify-format'

describe('renderClarifyPrompt', () => {
  it('renders a numbered list with choices', () => {
    const text = renderClarifyPrompt('Pick one', ['Apple', 'Banana'])
    expect(text).toContain('❓ Pick one')
    expect(text).toContain('1. Apple')
    expect(text).toContain('2. Banana')
    expect(text).toContain('Reply with a number, the option text, or your own answer.')
  })

  it('renders open-ended prompt without choices', () => {
    const text = renderClarifyPrompt('What is your name?')
    expect(text).toContain('❓ What is your name?')
    expect(text).toContain('Reply with your answer.')
    expect(text).not.toContain('1.')
  })
})

describe('mapAnswer', () => {
  const choices = ['Red', 'Green', 'Blue']

  it('maps a 1-based numeric reply to the choice', () => {
    expect(mapAnswer('2', choices)).toEqual({ text: 'Green', choiceIndex: 1 })
  })

  it('maps an exact case-insensitive text match', () => {
    expect(mapAnswer('blue', choices)).toEqual({ text: 'Blue', choiceIndex: 2 })
  })

  it('falls back to free text when no match', () => {
    expect(mapAnswer('purple', choices)).toEqual({ text: 'purple' })
  })

  it('treats out-of-range numbers as free text', () => {
    expect(mapAnswer('9', choices)).toEqual({ text: '9' })
  })

  it('trims and returns free text when there are no choices', () => {
    expect(mapAnswer('  hello  ')).toEqual({ text: 'hello' })
  })
})
