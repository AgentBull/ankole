import { describe, expect, it } from 'bun:test'
import { findUniqueFuzzyMatch } from './fuzzy-match'

describe('findUniqueFuzzyMatch', () => {
  // Pins the core promise: indentation and collapsed interior spacing differ, yet the
  // block still matches via the loosest strategy, and the returned span covers the
  // ORIGINAL text (so the eventual edit uses the file's real bytes, not the needle's).
  it('matches a unique multiline block with harmless whitespace drift', () => {
    const source = ['function demo() {', '  const value = 1', '  return value', '}'].join('\n')
    const needle = ['function demo() {', '    const   value = 1', '    return value', '}'].join('\n')

    const match = findUniqueFuzzyMatch(source, needle)

    expect(match?.strategy).toBe('normalize_horizontal_whitespace')
    expect(source.slice(match!.start, match!.end)).toBe(source)
  })

  // Pins the safety rule: when the same block appears twice, the matcher returns nothing
  // rather than guessing one — refusing an ambiguous edit is preferred over a wrong one.
  it('refuses ambiguous fuzzy matches', () => {
    const source = ['const value = 1', 'return value', '', 'const value = 1', 'return value'].join('\n')
    const needle = [' const   value = 1', ' return value'].join('\n')

    expect(findUniqueFuzzyMatch(source, needle)).toBeUndefined()
  })
})
