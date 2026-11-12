import { describe, expect, test } from 'bun:test'
import { isCustomEmojiIcon, pageIcon } from './page-icon-value'

describe('Page icon values', () => {
  test('distinguishes a shared custom emoji from an emoji glyph', () => {
    expect(isCustomEmojiIcon('metadata/custom-emoji/aa/brain.png')).toBe(true)
    expect(isCustomEmojiIcon('🧠')).toBe(false)
    expect(isCustomEmojiIcon('metadata/custom-emoji')).toBe(false)
    expect(isCustomEmojiIcon('pages/aa/icon.png')).toBe(false)
    expect(isCustomEmojiIcon(null)).toBe(false)
    expect(isCustomEmojiIcon(undefined)).toBe(false)
  })

  test('shows one emoji or a custom picture as the icon', () => {
    for (const icon of ['🧠', '👩🏽‍💻', '🇧🇷', '0️⃣', '❤️', '☺', '©', '🏴󠁧󠁢󠁥󠁮󠁧󠁿', 'metadata/custom-emoji/aa/:ankole:']) {
      expect(pageIcon(icon)).toBe(icon)
    }
  })

  test('shows no icon for text that is not one emoji', () => {
    for (const icon of ['演示数据', '演', 'A', '0', '★', '♪', '🧠🧠', '🧠 demo', '', null, undefined]) {
      expect(pageIcon(icon)).toBeUndefined()
    }
  })
})
