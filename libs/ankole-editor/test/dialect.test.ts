import { expect, test } from 'bun:test'
import type { Plot } from '../src/core/doc'
import { parseMarkdown } from '../src/document/markdown'
import { parseXml, printXml } from '../src/document/xml'
import { expectReopens, exportMarkdown, open, readTree, select, shape, typeText } from './helpers'

test.each([
  ['a<br /><br />b', 'a\n\nb', 'Paragraph'],
  ['a<br />', 'a\n', 'Paragraph'],
  ['# a<br />b', 'a\nb', 'Heading']
] as const)('hard breaks stay in %s', (source, text, type) => {
  const editor = open(source)
  const blocks = editor.state.doc.content
  expect(blocks.map(block => block.name)).toEqual([type])
  expect((blocks[0] as Plot).textContent()).toBe(text)
  expect(exportMarkdown(editor)).toBe(source)
})

test('header cells, merged cells and alignment are editable table cells', () => {
  const source =
    '<page><table><tr><th colspan="2"><p>h</p></th></tr><tr><th><p>side</p></th><td align="right"><p>1</p></td></tr></table></page>'
  const editor = open(parseXml(source))
  const cell = (type: string, text: string, marks?: Record<string, unknown>) => ({
    type,
    ...(marks ? { marks } : {}),
    content: [{ type: 'Paragraph', content: [{ type: 'Text', param: text }] }]
  })
  expect(shape(editor.state.doc.content[0]!)).toEqual({
    type: 'Table',
    content: [
      { type: 'TableRow', content: [cell('HeaderCell', 'h', { ColSpan: 2 })] },
      { type: 'TableRow', content: [cell('HeaderCell', 'side'), cell('Cell', '1', { Align: 'right' })] }
    ]
  })
  expect(printXml(readTree(editor))).toBe(source)
  expectReopens(editor)
})

test('an empty link keeps its destination without visible text', () => {
  const editor = open('[](/target "Title")')
  expect(shape(editor.state.doc)).toEqual({
    type: 'Doc',
    content: [
      {
        type: 'Paragraph',
        content: [
          {
            type: 'InlineElement',
            param: {
              name: 'a',
              attrs: [
                ['href', '/target'],
                ['title', 'Title']
              ],
              children: []
            }
          }
        ]
      }
    ]
  })
  expect(editor.state.doc.textContent()).toBe('')
  expect(exportMarkdown(editor)).toBe('[](/target "Title")')
})

test('a quote typed with the shortcut holds its text in a paragraph', () => {
  const editor = open('<p />')
  select(editor, 1)
  typeText(editor, '> typed quote')
  expect(readTree(editor)).toEqual(parseMarkdown('> typed quote'))
})

test('a typed URL becomes a link when a space follows it', () => {
  const editor = open('<p />')
  select(editor, 1)
  typeText(editor, 'see www.example.com ')
  expect(readTree(editor)).toEqual(
    parseXml('<page><p>see <a href="http://www.example.com">www.example.com</a> </p></page>')
  )
  typeText(editor, 'now')
  expect(exportMarkdown(editor)).toBe('see www.example.com now')
})

test('imported URL text stays text', () => {
  const editor = open('Visit www\\.example.com')
  expect(exportMarkdown(editor)).toBe('Visit www\\.example.com')
})
