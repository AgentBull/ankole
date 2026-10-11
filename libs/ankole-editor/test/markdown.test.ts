import { describe, expect, test } from 'bun:test'
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import type { Plot } from '../src/core/doc'
import * as T from '../src/core/types'
import { Callout } from '../src/blocks/callout'
import { Database, DatabaseRef } from '../src/blocks/database'
import { parseMarkdown } from '../src/document/markdown'
import { markValue } from '../src/editor/attributes'
import * as S from '../src/editor/schema'
import { sampleMarkdown } from '../playground/sample'
import { expectReopens, exportMarkdown, open, readTree } from './helpers'

describe('pages through the editor', () => {
  test('the sample opens with editable blocks and prints as written', () => {
    const editor = open(sampleMarkdown)
    const blocks = editor.state.doc.content
    const callout = blocks.find(node => node.type === Callout.type) as Plot
    const database = blocks.find(node => node.type === Database.type)!
    expect(callout.content).toHaveLength(1)
    expect(callout.textContent()).toContain('可编辑的提示块')
    expect(markValue(database, DatabaseRef)).toBe('product-roadmap')
    expect(readTree(editor)).toEqual(parseMarkdown(sampleMarkdown))
    expect(exportMarkdown(editor)).toBe(sampleMarkdown.trimEnd())
  })

  test('editor-created empty paragraphs are page content', () => {
    const editor = open(sampleMarkdown)
    editor.dispatch({
      changes: [
        { from: 0, insert: [T.Paragraph.create([])] },
        { from: editor.state.doc.length, insert: [T.Paragraph.create([])] }
      ]
    })
    expect(exportMarkdown(editor).startsWith('<p />\n\n# ')).toBe(true)
    expect(exportMarkdown(editor).endsWith('\n\n<p />')).toBe(true)
    expectReopens(editor)
  })

  test('unknown elements and attributes are kept and shown', () => {
    const source = [
      '<future layout="calendar">',
      '  **A title**',
      '',
      '  ```json',
      '  {"nested":{"a":[1,2,3]}}',
      '  ```',
      '</future>',
      '',
      '<database ref="tasks" version="99" />'
    ].join('\n')
    const editor = open(source)
    expect(editor.state.doc.content.map(node => node.type)).toEqual([S.UnknownBlock, Database.type])
    expect(editor.state.doc.textContent()).toContain('A title')
    expect(exportMarkdown(editor)).toBe(source)
  })

  test('CommonMark and GFM structures stay editable', () => {
    const source = [
      '# Heading',
      '',
      'Text **bold** and *italic*, ~~strike~~ and `code`, [link](https://example.com).',
      '',
      '- first',
      '  - nested',
      '- [x] done',
      '- [ ] open',
      '',
      '> Paragraph',
      '>',
      '> - quoted list',
      '> - second',
      '',
      '| Name | Value |',
      '| :--- | ----: |',
      '| abc  |    12 |',
      '',
      '```ts',
      'const n = 1',
      '```',
      '',
      '---',
      '',
      '![alt](https://example.com/image.png "Caption")'
    ].join('\n')
    const editor = open(source)
    expect(exportMarkdown(editor)).toBe(source)
    expect(editor.state.doc.content.map(node => node.name)).toEqual([
      'Heading',
      'Paragraph',
      'BulletList',
      'Blockquote',
      'Table',
      'CodeBlock',
      'HorizontalRule',
      'Paragraph'
    ])
    const list = editor.state.doc.content[2] as Plot
    expect(list.content.map(item => [(item as Plot).textContent(), markValue(item, S.Task)])).toEqual([
      ['first\nnested', undefined],
      ['done', 'done'],
      ['open', 'todo']
    ])
    expectReopens(editor)
  })

  test('nested custom and unknown blocks keep their structure', () => {
    const source =
      '<callout tone="warning">\n  - a\n  - b\n\n  <other payload="keep">\n    inner **content**\n  </other>\n</callout>\n\n<div data-unknown="keep">HTML</div>'
    const editor = open(source)
    expect(exportMarkdown(editor)).toBe(source)
    expectReopens(editor)
  })
})

// The repository documents of corpus.test.ts, including a table whose rows differ in length.
const corpus = join(import.meta.dir, 'corpus')
test.each(readdirSync(corpus).filter(name => name.endsWith('.md')))('%s reads back from the editor exactly', name => {
  const page = parseMarkdown(readFileSync(join(corpus, name), 'utf8'))
  expect(readTree(open(page))).toEqual(page)
})
