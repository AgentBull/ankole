import { describe, expect, test } from 'bun:test'
import { parseMarkdown, printMarkdown } from '../src/document/markdown'
import { sampleMarkdown } from '../playground/sample'

const canonical = (source: string) => printMarkdown(parseMarkdown(source))

// Each accepted form and its single canonical spelling.
describe('canonical Markdown', () => {
  test.each([
    [
      'a void element without a slash, text <, an unquoted value',
      '温度<3 度时<br>停止，详见 <a href=报告>说明</a>。',
      '温度\\<3 度时<br />停止，详见 [说明](报告)。'
    ],
    ['single and missing quotes', "<x a='1' b=2 />", '<x a="1" b="2" />'],
    ['an attribute without a value', '<toggle open>x</toggle>', '<toggle open="open">x</toggle>'],
    ['an element without content', '<x></x>', '<x />'],
    ['attribute order', '<x z="1" a="2" />', '<x a="2" z="1" />'],
    [
      'a block element written on one line',
      '<callout tone="info">提示</callout>',
      '<callout tone="info">\n  提示\n</callout>'
    ],
    ['indentation inside a tag', '<callout>\n        deep indent\n</callout>', '<callout>\n  deep indent\n</callout>'],
    ['bullet markers', '* a\n+ b', '- a\n- b'],
    ['ordered numbers', '1. a\n1. b\n1. c', '1. a\n2. b\n3. c'],
    ['emphasis markers', '_强调_ 和 __加粗__', '*强调* 和 **加粗**'],
    ['code fences', '~~~\ncode\n~~~\n\n````\nmore\n````', '```\ncode\n```\n\n```\nmore\n```'],
    ['setext headings', 'Title\n=====', '# Title'],
    ['hard breaks', 'a  \nb\\\nc', 'a<br />b<br />c'],
    ['blank lines', 'a\n\n\n\nb', 'a\n\nb'],
    ['adjacent equal formats', '<u>a</u><u>b</u>', '<u>ab</u>'],
    ['soft breaks', 'English line\nwrapped\n中文\n续行', 'English line wrapped 中文续行'],
    [
      'styles keep only text color, background color, and letter case',
      '<span style="position:fixed;inset:0;z-index:9">a</span> <span style="COLOR:red; margin: 0">b</span>\n\n<p style="background-color: #fff; top: 0">c</p>',
      'a <span style="COLOR:red">b</span>\n\n<p style="background-color: #fff">c</p>'
    ],
    ['soft breaks beside characters outside the BMP', '𠀀\n𠀁 a😀\nb', '𠀀𠀁 a😀 b'],
    ['formats as Markdown where Markdown has syntax', '<strong>x</strong> <em>y</em> <s>z</s>', '**x** *y* ~~z~~'],
    ['white space at an emphasis edge', '<strong>bold </strong>after', '**bold** after'],
    ['an empty title', '[x](u "")', '[x](u)'],
    ['an image tag', '<img src=x.png>', '![](x.png)'],
    ['colons are text', '会议 10:30，比例 3:1，key:value', '会议 10:30，比例 3:1，key:value'],
    ['an escaped tag stays text', '\\<not a tag> and a < b', '\\<not a tag> and a \\< b'],
    ['URL text that is not a link', 'Visit www\\.example.com', 'Visit www\\.example.com'],
    [
      'a link whose text is its address',
      '[https://example.com/a](https://example.com/a) now',
      'https://example.com/a now'
    ],
    // GFM would not read these back as the same link.
    ['an address that GFM does not link', '[me@a.co-](mailto:me@a.co-)', '[me@a.co-](mailto:me@a.co-)'],
    ['an address before a semicolon', '[https://x.y](https://x.y); z', '[https://x.y](https://x.y); z'],
    ['an address before punctuation and code', 'x [https://y.z](https://y.z),`b`', 'x [https://y.z](https://y.z),`b`'],
    ['an address before punctuation and bold', '[https://y.z](https://y.z).**b**', '[https://y.z](https://y.z).**b**']
  ])('%s', (_, source, expected) => {
    expect(canonical(source)).toBe(expected)
    expect(canonical(expected)).toBe(expected)
  })
})

// Pages written the way people and models write Markdown are already canonical.
describe('natural pages print as written', () => {
  test.each([
    ['the playground sample', sampleMarkdown.trimEnd()],
    [
      'meeting notes',
      [
        '# 周会 2026-10-04',
        '',
        '会议 10:30 开始，比例 3:1。负责人见 [名单](https://example.com/team)。',
        '',
        '## 待办',
        '',
        '- [x] 核对统计口径',
        '- [ ] 更新 https://example.com/dashboard',
        '',
        '## 步骤',
        '',
        '1. 拉取数据：',
        '',
        '   ```sh',
        '   bun run sync --since 2026-10-01',
        '   ```',
        '2. 检查 `status:ok` 的记录',
        '',
        '<callout tone="warning">',
        '  本期数据包含 **新增产品**。',
        '</callout>',
        '',
        '> 引用一段话。',
        '',
        '| 指标 |  数值 |',
        '| -- | --: |',
        '| 收入 | 17% |',
        '',
        '<embed ref="weekly-metrics" />'
      ].join('\n')
    ],
    [
      'a table with merged cells',
      [
        '<table>',
        '  <tr>',
        '    <th colspan="2">季度</th>',
        '  </tr>',
        '',
        '  <tr>',
        '    <td>收入</td>',
        '    <td align="right">17%</td>',
        '  </tr>',
        '</table>'
      ].join('\n')
    ]
  ])('%s', (_, source) => {
    expect(canonical(source)).toBe(source)
  })
})
