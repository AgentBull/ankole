import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { EmojiPicker } from '../src/components/emoji-picker'

describe('EmojiPicker', () => {
  test('renders the library picker with the localized labels and locale', () => {
    const html = renderToStaticMarkup(
      <EmojiPicker
        labels={{
          searchPlaceholder: '搜索表情符号',
          searchLabel: '搜索表情符号',
          categoryNavigation: '表情符号分类',
          skinToneDark: '深肤色'
        }}
        locale="zh-Hans-CN"
        onEmojiSelect={() => {}}
      />
    )

    expect(html).toContain('ankole-emoji-picker')
    expect(html).toContain('lang="zh-Hans-CN"')
    expect(html).toContain('placeholder="搜索表情符号"')
    expect(html).toContain('aria-label="搜索表情符号"')
    expect(html).toContain('aria-label="表情符号分类"')
    expect(html).toContain('aria-label="深肤色"')
    expect(html).toContain('width:100%')
    expect(html).toContain('height:min(380px, 60dvh)')
    expect(html).not.toContain('data-epr-part="preview"')
  })
})
