import { describe, expect, it } from 'bun:test'
import { parseMarkdownAst } from '../../index.js'

describe('parseMarkdownAst', () => {
  it('parses paragraphs and inline formatting into mdast shapes', () => {
    const ast = parseMarkdownAst('Hello **bold** and *italic* and `code` and ~~gone~~.') as any
    expect(ast.type).toBe('root')
    const paragraph = ast.children[0]
    expect(paragraph.type).toBe('paragraph')
    const types = paragraph.children.map((child: any) => child.type)
    expect(types).toContain('strong')
    expect(types).toContain('emphasis')
    expect(types).toContain('inlineCode')
    expect(types).toContain('delete')
  })

  it('parses GFM tables, lists, links, and code blocks', () => {
    const ast = parseMarkdownAst(
      [
        '| a | b |',
        '|---|---|',
        '| 1 | 2 |',
        '',
        '- item',
        '',
        '[x](https://example.com)',
        '',
        '```ts',
        'let a = 1',
        '```'
      ].join('\n')
    ) as any
    const types = ast.children.map((child: any) => child.type)
    expect(types).toContain('table')
    expect(types).toContain('list')
    expect(types).toContain('code')
    const code = ast.children.find((child: any) => child.type === 'code')
    expect(code.lang).toBe('ts')
    expect(code.value).toBe('let a = 1')
    const table = ast.children.find((child: any) => child.type === 'table')
    expect(table.children[0].type).toBe('tableRow')
    expect(table.children[0].children[0].type).toBe('tableCell')
  })

  it('returns an empty root for empty input', () => {
    expect(parseMarkdownAst('') as any).toEqual({ type: 'root', children: [] })
  })
})
