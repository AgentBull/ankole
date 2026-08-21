import { describe, expect, test } from 'bun:test'
import { loadPasswordScorer, strengthLevel } from './password-strength'

describe('strengthLevel', () => {
  test('maps zxcvbn scores onto the four levels', () => {
    expect(strengthLevel(0)).toBe('weak')
    expect(strengthLevel(1)).toBe('weak')
    expect(strengthLevel(2)).toBe('fair')
    expect(strengthLevel(3)).toBe('good')
    expect(strengthLevel(4)).toBe('strong')
  })
})

describe('loadPasswordScorer', () => {
  test('scores dictionary passwords low and long random passphrases high', async () => {
    const scorer = await loadPasswordScorer()

    expect(scorer('password')).toBeLessThanOrEqual(1)
    expect(scorer('correct-horse-battery-staple-9')).toBe(4)
  })

  test('caches one scorer for repeat calls', async () => {
    expect(await loadPasswordScorer()).toBe(await loadPasswordScorer())
  })
})
