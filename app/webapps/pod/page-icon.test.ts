import { describe, expect, test } from 'bun:test'
import { isCustomEmojiIcon } from './page-icon-value'

describe('Page icon values', () => {
  test('distinguishes a shared custom emoji from an emoji glyph', () => {
    expect(isCustomEmojiIcon('metadata/custom-emoji/aa/brain.png')).toBe(true)
    expect(isCustomEmojiIcon('🧠')).toBe(false)
    expect(isCustomEmojiIcon('metadata/custom-emoji')).toBe(false)
    expect(isCustomEmojiIcon('pages/aa/icon.png')).toBe(false)
    expect(isCustomEmojiIcon(null)).toBe(false)
    expect(isCustomEmojiIcon(undefined)).toBe(false)
  })
})
