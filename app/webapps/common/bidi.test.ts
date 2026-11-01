import { describe, expect, test } from 'bun:test'
import { containsBidi, sanitizeFileName, sanitizeRenameValue, stripBidi } from './bidi'

describe('bidi utilities', () => {
  test('detects and strips Unicode Bidi overrides while preserving ZWJ emoji sequences', () => {
    const spoofed = '报价单_\u202Efdp.sh'
    expect(containsBidi(spoofed)).toBe(true)
    expect(stripBidi(spoofed)).toBe('报价单_fdp.sh')
    expect(sanitizeFileName(spoofed)).toBe('报价单_fdp.sh')

    const emojiName = '研发_👩‍💻_报告.pdf'
    expect(containsBidi(emojiName)).toBe(false)
    expect(stripBidi(emojiName)).toBe(emojiName)
    expect(sanitizeFileName(emojiName)).toBe(emojiName)
  })

  test('replaces controls, line separators, and path slashes in filenames', () => {
    expect(sanitizeRenameValue('line\u2028break.txt')).toBe('line break.txt')
    expect(sanitizeFileName('evil\u0000\u2028../payload\u2066.txt')).toBe('evil_.._payload.txt')
    expect(sanitizeFileName('\u202E..')).toBe('file')
    expect(sanitizeRenameValue('Report\u202E\nDraft')).toBe('Report Draft')
  })
})
