import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../../common/i18n'
import { parseRouterSearch, stringifyRouterSearch } from '../../common/router'
import { contentKeys } from '../content-api'
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

test('a single dollar sign stays text and math takes double dollar signs', () => {
  for (const generated of [false, true]) {
    const prices = markup('单价 $300、采购 $120，合计 $420。', generated, false)
    expect(prices).not.toContain('katex')
    expect(prices).toContain('单价 $300、采购 $120，合计 $420。')
    expect(markup('面积 $$x^2$$ 平方米', generated, false)).toMatch(/class="katex[\s"]/)
    expect(markup('$$\nx^2\n$$', generated, false)).toMatch(/class="katex-display[\s"]/)
  }
})

test('emphasis that touches CJK punctuation parses, for people and Agents alike, and other scripts keep CommonMark', () => {
  for (const generated of [false, true]) {
    // A closing mark that follows CJK punctuation and meets a CJK character.
    expect(markup('**验收：**选择 M2-40V', generated)).toBe('<p dir="auto"><strong>验收：</strong>选择 M2-40V</p>')
    expect(markup('**核验建议：沪电暂时持有。**依据截至 **2026年11月11日**的行情', generated)).toBe(
      '<p dir="auto"><strong>核验建议：沪电暂时持有。</strong>依据截至 <strong>2026年11月11日</strong>的行情</p>'
    )
    // An opening mark that follows a CJK character and meets punctuation, in bold, italic and strikethrough.
    expect(markup('结论是**“先减仓”**这一条', generated)).toBe(
      '<p dir="auto">结论是<strong>“先减仓”</strong>这一条</p>'
    )
    expect(markup('这是*“强调”*的写法', generated)).toBe('<p dir="auto">这是<em>“强调”</em>的写法</p>')
    expect(markup('~~旧结论。~~新结论', generated)).toBe('<p dir="auto"><del>旧结论。</del>新结论</p>')
    // Text in other scripts reads as CommonMark reads it.
    expect(markup('**Done.**Next step', generated)).toBe('<p dir="auto">**Done.**Next step</p>')
    expect(markup('snake_case_name', generated)).toBe('<p dir="auto">snake_case_name</p>')
  }
})

test('a Page reference stands in its text as the reference card, without room against the edge of its block', async () => {
  const page = '0f8fad5b-d9cb-469f-a165-70867728950e'
  const text = `已发布：[Q4 路线图](ankole:page/${page})，请查看。\n\n[只有引用](ankole:page/${page})\n\n无效：[旧页面](ankole:page/not-an-id)`
  const client = new QueryClient()
  const root = createRootRoute({ component: () => <MarkdownRenderer text={text} generated /> })
  const router = createRouter({
    routeTree: root,
    history: createMemoryHistory({ initialEntries: ['/'] }),
    parseSearch: parseRouterSearch,
    stringifySearch: stringifyRouterSearch
  })
  await router.load()
  try {
    const html = renderToStaticMarkup(
      <QueryClientProvider client={client}>
        <RouterProvider router={router} />
      </QueryClientProvider>
    )
    const cards = [...html.matchAll(/<a\b[^>]*pod-chat-inline-reference[^>]*>/g)].map(([tag]) => tag)
    expect(cards).toHaveLength(2)
    expect(cards[0]).not.toContain('data-leading')
    expect(cards[0]).not.toContain('data-trailing')
    expect(cards[1]).toContain('data-leading=""')
    expect(cards[1]).toContain('data-trailing=""')
    expect(cards.every(card => card.includes('surface-outline') && card.includes('translate="no"'))).toBe(true)
    expect(html).toMatch(/data-slot="reference-card-title"[^>]*>Q4 路线图<\/span>/)
    expect(html).toContain('<span>旧页面</span>')
  } finally {
    client.clear()
  }
})

test('a Page reference shows the type mark for a stored icon that is a word rather than an emoji', async () => {
  const worded = '7c9e6679-7425-40de-944b-e07fc1f90ae7'
  const emoji = '16fd2706-8baf-433b-82eb-8c7fada847da'
  const text = `[运营看板](ankole:page/${worded}) · [路线审查](ankole:page/${emoji})`
  const client = new QueryClient()
  client.setQueryData(contentKeys.page(worded), {
    page: { id: worded, type: 'applet', title: '运营看板', icon: '演示数据' },
    ancestors: []
  })
  client.setQueryData(contentKeys.page(emoji), {
    page: { id: emoji, type: 'doc', title: '路线审查', icon: '🧭' },
    ancestors: []
  })
  const root = createRootRoute({ component: () => <MarkdownRenderer text={text} generated /> })
  const router = createRouter({
    routeTree: root,
    history: createMemoryHistory({ initialEntries: ['/'] }),
    parseSearch: parseRouterSearch,
    stringifySearch: stringifyRouterSearch
  })
  await router.load()
  try {
    const html = renderToStaticMarkup(
      <QueryClientProvider client={client}>
        <RouterProvider router={router} />
      </QueryClientProvider>
    )
    const cards = html.split('pod-chat-inline-reference').slice(1)
    expect(cards).toHaveLength(2)
    expect(html).not.toContain('演示数据')
    expect(cards[0]).toContain('<svg')
    expect(cards[1]).toMatch(/ankole-fluent-emoji[^>]*>🧭<\/span>/)
  } finally {
    client.clear()
  }
})
