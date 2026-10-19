import { describe, expect, test } from 'bun:test'
import type { Node, Plot } from '../src/core/doc'
import { parseMarkdown } from '../src/document/markdown'
import { printXml } from '../src/document/xml'
import { markValue } from '../src/editor/attributes'
import { applyBlockType, duplicateBlocks, type BlockType } from '../src/editor/block-actions'
import { toggleFormat, type FormatName } from '../src/editor/commands'
import * as S from '../src/editor/schema'
import { expectReopens, exportMarkdown, open, press, readTree, select, shape, typeText, type Shape } from './helpers'

type Run = { text: string; formats: string[]; style?: string; link?: string }
const formatNames = Object.keys(S.formats) as FormatName[]

/** The text leaves of a node with their formats in vocabulary order, style and link target. */
function textRuns(node: Node): Run[] {
  if (node.isText) {
    const style = markValue(node, S.TextStyle)
    const link = markValue(node, S.Link)?.find(([name]) => name === 'href')?.[1]
    return [
      {
        text: node.param as string,
        formats: formatNames.filter(name => node.marks.some(mark => mark.type === S.formats[name].type)),
        ...(style ? { style } : {}),
        ...(link ? { link } : {})
      }
    ]
  }
  return node.isPlot ? node.content.flatMap(textRuns) : []
}

const readOnly = (doc: Plot.Doc) => {
  const found: string[] = []
  doc.iterate(node => {
    if (node.type === S.UnknownBlock || node.type === S.InlineElement) found.push(node.name)
  })
  return found
}

const paragraph = (text: string): Shape => ({ type: 'Paragraph', content: [{ type: 'Text', param: text }] })
const item = (text: string, marks?: Shape['marks']): Shape => ({
  type: 'ListItem',
  ...(marks ? { marks } : {}),
  content: [paragraph(text)]
})

describe('an empty page', () => {
  test('shows one paragraph for the caret and reads as empty', () => {
    const editor = open('')
    expect(editor.state.doc.content.map(shape)).toEqual([
      { type: 'Paragraph', marks: { PagePlaceholder: null }, content: [] }
    ])
    expect(readTree(editor)).toEqual(parseMarkdown(''))
    expectReopens(editor)
  })

  test('reads as empty again when the typed text is deleted', () => {
    const editor = open('')
    typeText(editor, 'a')
    expect(exportMarkdown(editor)).toBe('a')
    press(editor, 'Backspace')
    expect(readTree(editor)).toEqual(parseMarkdown(''))
  })

  test('keeps an empty paragraph that the source has', () => {
    const editor = open('<p />')
    expect(exportMarkdown(editor)).toBe('<p />')
    expectReopens(editor)
  })
})

describe('editable content keeps its visible form', () => {
  test('removing alignment, indent and style keeps the other attributes', () => {
    const editor = open('<p align="center" indent="1" source="manual" style="color: red;">text</p>')
    editor.dispatch({
      changes: [S.Align.of('center'), S.Indent.of(1), S.BlockStyle.of('color: red;')].map(mark => ({
        from: 0,
        remove: mark
      }))
    })
    expect(printXml(readTree(editor))).toBe('<page><p source="manual">text</p></page>')
    expectReopens(editor)
  })

  test('copies the block style when a paragraph becomes a heading', () => {
    const editor = open('<p style="color: red;">text</p>')
    select(editor)
    expect(applyBlockType(editor, 'h2')).toBe(true)
    expect(printXml(readTree(editor))).toBe('<page><h2 style="color: red;">text</h2></page>')
  })

  test.each([
    [
      '**bold** and *italic*',
      [
        { text: 'bold', formats: ['strong'] },
        { text: ' and ', formats: [] },
        { text: 'italic', formats: ['em'] }
      ]
    ],
    ['***both***', [{ text: 'both', formats: ['strong', 'em'] }]],
    ['~~**gone**~~', [{ text: 'gone', formats: ['strong', 's'] }]],
    [
      '**before `code` after**',
      [
        { text: 'before ', formats: ['strong'] },
        { text: 'code', formats: ['strong', 'code'] },
        { text: ' after', formats: ['strong'] }
      ]
    ],
    ['\\*literal\\* &amp; &#x1F642;', [{ text: '*literal* & 🙂', formats: [] }]],
    ['`` `tick` ``', [{ text: '`tick`', formats: ['code'] }]],
    ['中文 é 👩‍💻 العربية', [{ text: '中文 é 👩‍💻 العربية', formats: [] }]],
    [
      '[**label**][ref]\n\n[ref]: https://example.com "Title"',
      [{ text: 'label', formats: ['strong'], link: 'https://example.com' }]
    ],
    [
      '<u>u</u><mark>m</mark><sub>s</sub><sup>p</sup>',
      [
        { text: 'u', formats: ['u'] },
        { text: 'm', formats: ['mark'] },
        { text: 's', formats: ['sub'] },
        { text: 'p', formats: ['sup'] }
      ]
    ],
    ['<span style="color: red;">r</span>', [{ text: 'r', formats: [], style: 'color: red;' }]]
  ] as [string, Run[]][])('imports %s as editable text with its formats', (source, expected) => {
    const first = open(source)
    expect(textRuns(first.state.doc)).toEqual(expected)
    const second = open(exportMarkdown(first))
    expect(textRuns(second.state.doc)).toEqual(expected)
    expectReopens(first)
  })

  test.each([
    ['Title\n=====', { type: 'Heading', param: 1, content: [{ type: 'Text', param: 'Title' }] }],
    ['###### Deep', { type: 'Heading', param: 6, content: [{ type: 'Text', param: 'Deep' }] }],
    ['7. seven\n8. eight', { type: 'OrderedList', param: 7, content: [item('seven'), item('eight')] }],
    [
      '- [x] done\n- [ ] next',
      { type: 'BulletList', content: [item('done', { Task: 'done' }), item('next', { Task: 'todo' })] }
    ],
    [
      '```ts title=sample\nconst x = 1\n```',
      {
        type: 'CodeBlock',
        marks: { CodeBlockLanguage: 'ts', CodeMeta: 'title=sample' },
        content: [{ type: 'Text', param: 'const x = 1' }]
      }
    ],
    ['> first\n>\n> second', { type: 'Blockquote', content: [paragraph('first'), paragraph('second')] }],
    [
      '<callout tone="warning">\n  x\n</callout>',
      { type: 'Callout', marks: { CalloutTone: 'warning' }, content: [paragraph('x')] }
    ],
    ['<embed ref="roadmap" />', { type: 'Embed', marks: { EmbedRef: 'roadmap' } }]
  ] as [string, Shape][])('imports %s as an editing node', (source, expected) => {
    const first = open(source)
    const second = open(exportMarkdown(first))
    for (const editor of [first, second]) expect(shape(editor.state.doc.content[0]!)).toEqual(expected)
    expectReopens(first)
  })

  test('alignment set in the editor survives export', () => {
    const editor = open('Keep this paragraph')
    editor.dispatch({ changes: { from: 0, add: S.Align.of('center') } })
    expect(exportMarkdown(editor)).toBe('<p align="center">Keep this paragraph</p>')
    expectReopens(editor)
  })

  test.each([
    ['u', 'underline'],
    ['mark', 'highlight'],
    ['sub', 'subscript'],
    ['sup', 'superscript']
  ] as [FormatName, string][])('keeps the editor format %s (%s)', format => {
    const editor = open('**Keep this**')
    select(editor, 1, 10)
    expect(toggleFormat(editor, format)).toBe(true)
    const runs = textRuns(editor.state.doc)
    expect(runs).toEqual([
      { text: 'Keep this', formats: formatNames.filter(name => name === 'strong' || name === format) }
    ])
    expect(textRuns(open(exportMarkdown(editor)).state.doc)).toEqual(runs)
    expectReopens(editor)
  })
})

describe('content without an editing node stays visible', () => {
  test('formatted text inside attributed elements is editable text', () => {
    const editor = open(
      parseMarkdown(
        '<p align="center">Revenue grew **17%** this quarter.</p>\n\nSee the <a href="https://example.com/r" source="finance">revenue table</a>.'
      )
    )
    expect(editor.state.doc.textContent()).toBe('Revenue grew 17% this quarter.\nSee the revenue table.')
    expect(readOnly(editor.state.doc)).toEqual([])
    expectReopens(editor)
  })

  test('unknown elements show their text and keep their markup', () => {
    const source = 'Inline <chip id="x">chip text</chip> end\n\n<widget size="2">\n  block **text**\n</widget>'
    const editor = open(source)
    expect(readOnly(editor.state.doc)).toEqual(['InlineElement', 'UnknownBlock'])
    expect(editor.state.doc.textContent()).toBe('Inline chip text end\nblock text')
    expect(exportMarkdown(editor)).toBe(source)
  })

  test('a numbered task list keeps its tasks as editable list items', () => {
    const source = '1. [ ] first step\n2. [x] second step'
    const editor = open(source)
    expect(shape(editor.state.doc.content[0]!)).toEqual({
      type: 'OrderedList',
      param: 1,
      content: [item('first step', { Task: 'todo' }), item('second step', { Task: 'done' })]
    })
    expect(exportMarkdown(editor)).toBe(source)
  })
})

describe('block actions keep what the new block can show', () => {
  const run = (source: string, type: BlockType) => {
    const editor = open(source)
    select(editor)
    applyBlockType(editor, type)
    return printXml(readTree(editor))
  }

  test.each([
    ['<p align="center">x</p>', 'bullet', '<page><ul><li><p align="center">x</p></li></ul></page>'],
    ['<h2 indent="1">x</h2>', 'bullet', '<page><ul><li><p>x</p></li></ul></page>'],
    ['- a\n\n<h2 indent="1">x</h2>', 'bullet', '<page><ul><li><p>a</p><ul><li><p>x</p></li></ul></li></ul></page>'],
    ['<p align="center" data-x="1">a</p>', 'code', '<page><pre data-x="1">a</pre></page>'],
    ['<pre data-x="1" lang="js" meta="m">a</pre>', 'paragraph', '<page><p data-x="1">a</p></page>'],
    ['<pre lang="js" meta="m">a</pre>', 'quote', '<page><blockquote><p>a</p></blockquote></page>'],
    ['<pre lang="js" meta="m">a</pre>', 'callout', '<page><callout><p>a</p></callout></page>']
  ] as [string, BlockType, string][])('%s becomes %s', (source, type, expected) => {
    expect(run(source, type)).toBe(expected)
  })

  test('a divider or embed leaves one paragraph for the caret', () => {
    expect(run('x', 'divider')).toBe('<page><p>x</p><hr /><p /></page>')
    expect(run('x\n\n<p />', 'embed')).toBe('<page><p>x</p><embed /><p /></page>')
  })

  test('a copy keeps the state of task items', () => {
    const source = '<callout tone="warning">\n  - [x] done\n</callout>'
    const editor = open(source)
    expect(duplicateBlocks(editor, 0)).toBe(true)
    expect(readTree(editor)).toEqual(parseMarkdown(`${source}\n\n${source}`))
  })
})

test('the page read from the editor leaves out characters that a page cannot store', () => {
  const editor = open('a')
  select(editor)
  typeText(editor, 'x\u000by\u0000z')
  expect(editor.state.doc.textContent()).toBe('ax\u000by\u0000z')
  expect(printXml(readTree(editor))).toBe('<page><p>axyz</p></page>')
})

test('Tab indentation stops before the page limits', () => {
  const editor = open('a')
  select(editor, 1)
  for (let index = 0; index < 60; index++) press(editor, 'Tab')
  expect(printXml(readTree(editor))).toBe('<page><p indent="49">a</p></page>')
})
