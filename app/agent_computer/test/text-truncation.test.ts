import { describe, expect, it } from 'bun:test'
import { truncateUtf16Safe, truncateUtf16SafeTail } from '../src/common/text-sanitize'
import { truncateOutput } from '../src/tools/computer/format'

const rocket = '🚀'

describe('UTF-16 safe truncation', () => {
  it('drops a split character instead of keeping half of it at either end', () => {
    const text = `${rocket}${rocket}${rocket}`

    expect(truncateUtf16Safe(text, 3)).toBe(rocket)
    expect(truncateUtf16SafeTail(text, 3)).toBe(rocket)
    expect(truncateUtf16Safe(text, 4)).toBe(`${rocket}${rocket}`)
    expect(truncateUtf16SafeTail(text, 4)).toBe(`${rocket}${rocket}`)
  })

  it('keeps text that already fits and returns nothing for an empty budget', () => {
    expect(truncateUtf16SafeTail('abc', 3)).toBe('abc')
    expect(truncateUtf16SafeTail('abc', 10)).toBe('abc')
    expect(truncateUtf16SafeTail('abc', 2)).toBe('bc')
    expect(truncateUtf16SafeTail('abc', 0)).toBe('')
  })
})

describe('command output truncation', () => {
  it('returns output that fits without a truncation marker', () => {
    expect(truncateOutput('short output', 100)).toBe('short output')
  })

  it('keeps the head and the tail around one marker and reports the omitted count', () => {
    const result = truncateOutput('a'.repeat(50) + 'b'.repeat(50), 40)

    expect(result).toStartWith('a'.repeat(16))
    expect(result).toEndWith('b'.repeat(24))
    expect(result).toContain('[output truncated — 60 chars omitted of 100 total]')
  })

  it('never leaves half of a character at the tail cut', () => {
    const result = truncateOutput(`${'a'.repeat(50)}${rocket.repeat(20)}`, 41)

    expect(result).not.toContain('�')
    expect([...result].every(char => char.codePointAt(0)! < 0xd800 || char.codePointAt(0)! > 0xdfff)).toBe(true)
  })
})
