import { describe, expect, it } from 'bun:test'
import { findUniqueFuzzyMatch } from './fuzzy-match'

describe('findUniqueFuzzyMatch', () => {
  it('matches a unique multiline block with harmless whitespace drift', () => {
    const source = ['function demo() {', '  const value = 1', '  return value', '}'].join('\n')
    const needle = ['function demo() {', '    const   value = 1', '    return value', '}'].join('\n')

    const match = findUniqueFuzzyMatch(source, needle)

    expect(match?.strategy).toBe('normalize_horizontal_whitespace')
    expect(source.slice(match!.start, match!.end)).toBe(source)
  })

  it('refuses ambiguous fuzzy matches', () => {
    const source = ['const value = 1', 'return value', '', 'const value = 1', 'return value'].join('\n')
    const needle = [' const   value = 1', ' return value'].join('\n')

    expect(findUniqueFuzzyMatch(source, needle)).toBeUndefined()
  })
})
