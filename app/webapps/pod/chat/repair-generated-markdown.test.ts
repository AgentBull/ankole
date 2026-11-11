import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { fromMarkdown } from 'mdast-util-from-markdown'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import Markdown from 'react-markdown'
import rehypeKatex from 'rehype-katex'
import remarkMath from 'remark-math'
import { MARKDOWN_SYNTAX_PLUGINS } from '../../common/markdown-syntax'
import { cjkAutolinks } from './cjk-autolinks'
import { MATH_OPTIONS, repairGeneratedMarkdown } from './repair-generated-markdown'

interface GoldenCase {
  name: string
  input: string
  expected: string
}

const GOLDEN_PATH = resolve(
  import.meta.dir,
  '../../../control_plane/test/fixtures/generated_markdown_repair_cases.json'
)

const PARSE_OPTIONS = (() => {
  const data: {
    micromarkExtensions?: NonNullable<Parameters<typeof fromMarkdown>[1]>['extensions']
    fromMarkdownExtensions?: NonNullable<Parameters<typeof fromMarkdown>[1]>['mdastExtensions']
  } = {}
  const processor = { data: () => data }
  for (const plugin of MARKDOWN_SYNTAX_PLUGINS) (plugin as () => void).call(processor)
  remarkMath.call(processor as never, MATH_OPTIONS)
  return {
    extensions: data.micromarkExtensions ?? [],
    mdastExtensions: data.fromMarkdownExtensions ?? []
  }
})()

function applyRemarkRepairPlugin(source: string): string {
  if (!source) return ''
  const tree = fromMarkdown(source, PARSE_OPTIONS)
  const file: { value: unknown } = { value: source }
  repairGeneratedMarkdown()(tree, file)
  return String(file.value)
}

describe('repairGeneratedMarkdown', () => {
  test('matches shared Rust/TS golden corpus and is idempotent', () => {
    const cases = JSON.parse(readFileSync(GOLDEN_PATH, 'utf8')) as GoldenCase[]
    expect(cases.length).toBeGreaterThan(0)

    for (const entry of cases) {
      const repaired = applyRemarkRepairPlugin(entry.input)
      expect(repaired).toBe(entry.expected)
      expect(applyRemarkRepairPlugin(repaired)).toBe(repaired)
    }
  })

  test('renders repaired strong, literal tilde, preserved double-tilde, and intact KaTeX math for agent replies', () => {
    const input = '结果：\\n\\n- **金额： **203\\n- 波动 ~50%~ 对比 ~~旧方案~~，公式 $$\\nabla \\cdot E \\neq 0$$'
    const html = renderToStaticMarkup(
      createElement(
        Markdown,
        {
          remarkPlugins: [
            ...MARKDOWN_SYNTAX_PLUGINS,
            [remarkMath, MATH_OPTIONS],
            repairGeneratedMarkdown,
            cjkAutolinks
          ],
          rehypePlugins: [rehypeKatex]
        },
        input
      )
    )

    expect(html).toContain('<ul>')
    expect(html).toContain('<strong>金额：</strong> 203')
    expect(html).toContain('~50%~')
    expect(html).not.toContain('<del>50%</del>')
    expect(html).toContain('<del>旧方案</del>')
    expect(html).toContain('class="katex"')
  })
})
