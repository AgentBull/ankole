import { beforeAll, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../../common/i18n'
import MarkdownRenderer from './markdown-renderer'

beforeAll(async () => {
  await loadLocale('en-US')
})

function markup(text: string, generated = false, streaming = true) {
  return renderToStaticMarkup(<MarkdownRenderer text={text} generated={generated} streaming={streaming} />)
}

test('streamed nested blocks stay inside their list item', () => {
  for (const generated of [false, true]) {
    const heading = markup('- item\n\n  # Nested heading\n\n  text\n\nend', generated)
    expect(heading).toBe(
      '<ul>\n<li dir="auto">\n<p dir="auto">item</p>\n<h1 dir="auto">Nested heading</h1>\n<p dir="auto">text</p>\n</li>\n</ul>\n<p dir="auto">end</p>'
    )
    const code = markup('- item\n\n  ```js\n  const x = 1\n  ```\n\nend', generated)
    expect(code).toContain('const x = 1')
    expect(code).toContain('pod-chat-code-body')
    expect(code.indexOf('pod-chat-code-body')).toBeLessThan(code.indexOf('</li>'))
  }
})

test('streamed multiline reference definitions resolve earlier links', () => {
  for (const generated of [false, true]) {
    const html = markup('[label][id]\n\n[id]:\n  https://example.com\n\nend', generated)
    expect(html).toContain('href="https://example.com"')
    expect(html).toContain('>label</a>')
    expect(html).not.toContain('[label][id]')
  }
})

test('streamed HTML comments preserve their whitespace and boundaries', () => {
  for (const generated of [false, true]) {
    expect(markup('<!--\n\nsecret\n\n-->\n\nend', generated)).toBe('&lt;!--\n\nsecret\n\n--&gt;\n<p dir="auto">end</p>')
  }
})

test('streamed prefixes render the same markup as a settled document', () => {
  const fixtures = [
    [
      '第一段包含 **重点** 与公式 $x^2$。',
      '请查看 https://example.com，继续讨论。',
      '## 结果',
      '- 共享报告\n- 私有草稿',
      '> 引用。\n>\n> 第二段。',
      '| 名称 | 数量 |\n| --- | --- |\n| 任务 | 18 |',
      '$$\ny = x + 1\n$$',
      '```ts\nconst 数量 = 18\n```',
      '结束。'
    ].join('\n\n'),
    '结果：\\n\\n- **金额： **203\\n- 波动 ~50%~ 对比 ~~旧方案~~，公式 $\\nabla \\cdot E \\neq 0$',
    '- item\n\n  # Nested heading\n\n  ```js\n  const x = 1\n  ```\n\nend',
    '[label][id]\n\n[id]:\n  https://example.com\n\nend',
    '<!--\n\nsecret\n\n-->\n\nend',
    '甲\n\n<div>\n\n乙\n\n</div>\n\n丙'
  ]
  for (const source of fixtures) {
    for (const generated of [false, true]) {
      for (let length = 1; length <= source.length; length++) {
        const text = source.slice(0, length)
        expect(markup(text, generated, true)).toBe(markup(text, generated, false))
      }
    }
  }
})
