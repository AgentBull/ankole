import { expect, test } from 'bun:test'
import { Command, deleteUnit } from '../src/core/command'
import type { Wordgard } from '../src/core/editor'
import { CellSelection } from '../src/core/table'
import { parseMarkdown } from '../src/document/markdown'
import { parseXml } from '../src/document/xml'
import { exportMarkdown, expectReopens, open, press, readTree, select, typeText } from './helpers'

/** The position in the text node `text` at `offset`. */
function at(editor: Wordgard, text: string, offset: number | 'end' = 0) {
  let found: number | undefined
  editor.state.doc.iterate((node, pos) => {
    if (found === undefined && node.isText && node.param === text) {
      found = pos + (offset === 'end' ? text.length : offset)
    }
  })
  if (found === undefined) throw new Error(`The page has no text ${text}`)
  return found
}

test('Tab and Shift+Tab move to the end of the next and the previous cell and keep alignment', () => {
  const editor = open('| Name | Value |\n| :--- | ---: |\n| Alpha | 42 |')
  select(editor, at(editor, 'Name', 0))
  for (const text of ['1', '2', '3']) {
    expect(press(editor, 'Tab')).toBe(true)
    typeText(editor, text)
  }
  expect(press(editor, 'Shift-Tab')).toBe(true)
  typeText(editor, '4')
  expect(readTree(editor)).toEqual(parseMarkdown('| Name | Value1 |\n| :--- | ---: |\n| Alpha24 | 423 |'))
  expectReopens(editor)
})

test('Tab skips empty rows and stops in empty cells of rows with different lengths', () => {
  const editor = open('<table><tr><td>a</td><td>b</td></tr><tr /><tr><td /><td>c</td><td>d</td></tr></table>')
  select(editor, at(editor, 'a', 'end'))
  for (const text of ['1', '2', '3', '4']) {
    press(editor, 'Tab')
    typeText(editor, text)
  }
  expect(readTree(editor)).toEqual(
    parseMarkdown('<table><tr><td>a</td><td>b1</td></tr><tr /><tr><td>2</td><td>c3</td><td>d4</td></tr></table>')
  )
  for (const text of ['5', '6']) {
    press(editor, 'Shift-Tab')
    typeText(editor, text)
  }
  expect(readTree(editor)).toEqual(
    parseMarkdown('<table><tr><td>a</td><td>b1</td></tr><tr /><tr><td>26</td><td>c35</td><td>d4</td></tr></table>')
  )
})

test('Tab leaves the table after the last cell, and Shift+Tab before the first cell', () => {
  const editor = open('before\n\n| a | b |\n| - | - |\n| c | d |\n\nafter')
  select(editor, at(editor, 'd', 'end'))
  press(editor, 'Tab')
  typeText(editor, 'X')
  select(editor, at(editor, 'a', 'end'))
  press(editor, 'Shift-Tab')
  typeText(editor, 'Y')
  expect(exportMarkdown(editor)).toBe('beforeY\n\n| a | b |\n| - | - |\n| c | d |\n\nXafter')
})

test('Tab in a list inside a cell moves to the next cell', () => {
  const table = (next: string) =>
    parseXml(`<page><table><tr><td><ul><li><p>item</p></li></ul></td><td><p>${next}</p></td></tr></table></page>`)
  const editor = open(table('next'))
  select(editor, at(editor, 'item', 'end'))
  press(editor, 'Tab')
  typeText(editor, '!')
  expect(readTree(editor)).toEqual(table('next!'))
})

test('deleting a selection across cells empties the cells and keeps the table', () => {
  const editor = open('| Name | Value |\n| :--- | ---: |\n| Alpha | 42 |\n\nafter')
  select(editor, at(editor, 'Alpha', 2), at(editor, '42', 1))
  expect(editor.state.selection).toBeInstanceOf(CellSelection)
  Command.dispatch(editor, deleteUnit, 'backward')
  expect(readTree(editor)).toEqual(
    parseMarkdown(
      '<table><tr><th align="left">Name</th><th align="right">Value</th></tr>' +
        '<tr><td align="left" /><td align="right" /></tr></table>\n\nafter'
    )
  )
})
