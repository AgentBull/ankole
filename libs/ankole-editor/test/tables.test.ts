import { expect, test } from 'bun:test'
import { Command } from '../src/core/command/command'
import { deleteUnit } from '../src/core/command/commands'
import type { Wordgard } from '../src/core/editor'
import { Rect } from '../src/core/table/tablemap'
import { tableSelection } from '../src/editor/table-context'
import { CellSelection } from '../src/core/table'
import { parseMarkdown } from '../src/document/markdown'
import { changeTable, editableTable, colorTableCells, resizeTable, tableCSV, moveTableAxis } from '../src/editor/tables'
import { Align, CellBackground, TableWidths } from '../src/editor/schema'
import { undo, redo } from '../src/editor/commands'
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

test('Tab adds a row after the last cell, and Shift+Tab leaves before the first cell', () => {
  const editor = open('before\n\n| a | b |\n| - | - |\n| c | d |\n\nafter')
  select(editor, at(editor, 'd', 'end'))
  press(editor, 'Tab')
  typeText(editor, 'X')
  select(editor, at(editor, 'a', 'end'))
  press(editor, 'Shift-Tab')
  typeText(editor, 'Y')
  expect(exportMarkdown(editor)).toBe('beforeY\n\n| a | b |\n| - | - |\n| c | d |\n| X |   |\n\nafter')
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

test('inserted rows and Tab extensions inherit every column alignment', () => {
  for (const action of ['row_before', 'row_after', 'Tab'] as const) {
    const editor = open('| A | B | C |\n| :--- | :---: | ---: |\n| D | E | F |')
    select(editor, at(editor, 'F', 'end'))
    expect(action === 'Tab' ? press(editor, action) : changeTable(editor, action)).toBe(true)
    const { rows } = editableTable(editor.state)!
    expect(rows).toHaveLength(3)
    for (const row of rows) expect(row.content.map(cell => cell.mark(Align))).toEqual(['left', 'center', 'right'])
    typeText(editor, 'Inserted')
    expect(exportMarkdown(editor)).toContain('Inserted')
    expectReopens(editor)
  }
})

test('column commands pad uneven and empty rows without replacing existing cells', () => {
  for (const action of ['column_before', 'column_after', 'delete_column'] as const) {
    const editor = open(
      '<table custom="table"><tr><th>A</th><th align="right" custom="cell">B</th><th>C</th></tr><tr><td>D</td></tr><tr/><tr><td>E</td><td>F</td></tr></table>'
    )
    select(editor, at(editor, 'B'))
    const before = readTree(editor)
    const original = editableTable(editor.state)!
    const first = original.rows[0]!.content[0]!
    const second = original.rows[0]!.content[1]!
    const last = original.rows[0]!.content[2]!
    expect(changeTable(editor, action)).toBe(true)
    const context = editableTable(editor.state)!
    expect(context.rows.map(row => row.content.length)).toEqual(Array(4).fill(action === 'delete_column' ? 2 : 4))
    expect(context.rows[0]!.content[0]).toBe(first)
    expect(context.rows[0]!.content.at(-1)).toBe(last)
    if (action !== 'delete_column') {
      expect(context.rows[0]!.content[action === 'column_before' ? 2 : 1]).toBe(second)
      const padded = context.rows[1]!.content[action === 'column_before' ? 2 : 1]!
      expect(padded.mark(Align)).toBe('right')
    }
    expectReopens(editor)
    undo(editor)
    expect(readTree(editor)).toEqual(before)
  }
})

const sample =
  '| Name | Count | State |\n| --- | ---: | --- |\n| Alpha | 10 | Open |\n| Beta | 2 | Done |\n| Gamma | 3 | Review |'
function rectangle(editor: Wordgard, left: number, top: number, right: number, bottom: number) {
  const context = editableTable(editor.state)!
  editor.dispatch({ selection: tableSelection(editor.state.doc, context.map, new Rect(left, top, right, bottom)) })
}

test('row and column deletion acts on every selected logical row or column as one undo step', () => {
  for (const action of ['delete_row', 'delete_column'] as const) {
    const editor = open(sample)
    select(editor, at(editor, 'Alpha'))
    const before = readTree(editor)
    rectangle(editor, 0, 1, 2, 3)
    expect(changeTable(editor, action)).toBe(true)
    const context = editableTable(editor.state)!
    expect(action === 'delete_row' ? context.map.height : context.map.width).toBe(action === 'delete_row' ? 2 : 1)
    expect(exportMarkdown(editor)).toContain(action === 'delete_row' ? 'Gamma' : 'Review')
    expectReopens(editor)
    undo(editor)
    expect(readTree(editor)).toEqual(before)
    redo(editor)
    expectReopens(editor)
  }
})

test('merge and split retain rich content and unknown attributes and are undoable', () => {
  const editor = open(
    '<table custom="kept"><tr><td custom="cell">**Alpha**</td><td>Beta</td></tr><tr><td>Gamma</td><td>Delta</td></tr></table>'
  )
  select(editor, at(editor, 'Alpha'))
  const before = readTree(editor)
  rectangle(editor, 0, 0, 2, 2)
  expect(changeTable(editor, 'merge')).toBe(true)
  let context = editableTable(editor.state)!
  expect(context.map.width).toBe(2)
  expect(context.map.height).toBe(2)
  expect(context.map.getCell(context.map.cellAt(0, 0)!).textContent()).toContain('Delta')
  expect(exportMarkdown(editor)).toContain('colspan="2"')
  expect(exportMarkdown(editor)).toContain('custom="cell"')
  expectReopens(editor)
  expect(changeTable(editor, 'split')).toBe(true)
  context = editableTable(editor.state)!
  expect(context.rows.map(row => row.content.length)).toEqual([2, 2])
  expect(exportMarkdown(editor)).not.toContain('colspan')
  expectReopens(editor)
  undo(editor)
  undo(editor)
  expect(readTree(editor)).toEqual(before)
})

test('row insertion and deletion extend and shrink spanning cells without losing their content', () => {
  const editor = open(
    '<table><tr><td rowspan="3">Span</td><td>A</td></tr><tr><td>B</td></tr><tr><td>C</td></tr></table>'
  )
  select(editor, at(editor, 'B'))
  expect(changeTable(editor, 'row_before')).toBe(true)
  expect(exportMarkdown(editor)).toContain('rowspan="4"')
  select(editor, at(editor, 'B'))
  expect(changeTable(editor, 'delete_row')).toBe(true)
  expect(exportMarkdown(editor)).toContain('rowspan="3"')
  select(editor, at(editor, 'A'))
  expect(changeTable(editor, 'delete_row')).toBe(true)
  expect(exportMarkdown(editor)).toContain('Span')
  expect(exportMarkdown(editor)).toContain('rowspan="2"')
  expectReopens(editor)
})

test('column insertion and deletion extend and shrink merged cells', () => {
  const editor = open('<table><tr><th colspan="3">Merged</th></tr><tr><td>A</td><td>B</td><td>C</td></tr></table>')
  select(editor, at(editor, 'B'))
  expect(changeTable(editor, 'column_before')).toBe(true)
  expect(exportMarkdown(editor)).toContain('colspan="4"')
  select(editor, at(editor, 'B'))
  expect(changeTable(editor, 'delete_column')).toBe(true)
  expect(exportMarkdown(editor)).toContain('colspan="3"')
  expect(exportMarkdown(editor)).toContain('Merged')
  expectReopens(editor)
})

test('merging empty cells keeps one editable paragraph and takes nonempty content without blank padding', () => {
  for (const value of ['', 'Value']) {
    const editor = open(parseXml(`<page><table><tr><td><p /></td><td><p>${value}</p></td></tr></table></page>`))
    select(editor, 4)
    rectangle(editor, 0, 0, 2, 1)
    const before = readTree(editor)
    expect(changeTable(editor, 'merge')).toBe(true)
    const cell = editableTable(editor.state)!.rows[0]!.content[0]!
    expect(cell.isPlot && cell.content).toHaveLength(1)
    expect(cell.isPlot && cell.textContent()).toBe(value)
    expectReopens(editor)
    undo(editor)
    expect(readTree(editor)).toEqual(before)
  }
})

test('cell, row and column formatting use their advertised scope and survive reopen', () => {
  const editor = open(sample)
  select(editor, at(editor, 'Alpha'))
  colorTableCells(editor, '#deedfc', 'cell')
  expect(
    editableTable(editor.state)!.map.getCell(editableTable(editor.state)!.map.cellAt(0, 1)!).mark(CellBackground)
  ).toBe('#deedfc')
  changeTable(editor, 'align_center', 'row')
  let context = editableTable(editor.state)!
  expect(context.rows[1]!.content.every(cell => cell.mark(Align) === 'center')).toBe(true)
  expect(context.rows[2]!.content[0]!.mark(Align)).toBeUndefined()
  changeTable(editor, 'header_column')
  context = editableTable(editor.state)!
  expect(context.rows.every(row => row.content[0]!.name === 'HeaderCell')).toBe(true)
  colorTableCells(editor, null, 'column')
  expect(exportMarkdown(editor)).not.toContain('background')
  expectReopens(editor)
})

test('row and column moves preserve content and column widths, sort is numeric and keeps the header', () => {
  const editor = open(sample)
  select(editor, at(editor, 'Alpha'))
  const context = editableTable(editor.state)!
  resizeTable(editor, context.table.before, [100, 200, 300])
  expect(changeTable(editor, 'row_down')).toBe(true)
  expect(editableTable(editor.state)!.rows[2]!.textContent()).toContain('Alpha')
  select(editor, at(editor, 'Count'))
  expect(changeTable(editor, 'sort_ascending')).toBe(true)
  expect(
    editableTable(editor.state)!.rows.map(row => (row.content[1]!.isPlot ? row.content[1]!.textContent() : ''))
  ).toEqual(['Count', '2', '3', '10'])
  expect(moveTableAxis(editor, 'column', 3)).toBe(true)
  expect(editableTable(editor.state)!.table.node.mark(TableWidths)).toBe('100,300,200')
  expectReopens(editor)
})

test('successive formatting preserves the selected rectangle and distributing preserves its total width', () => {
  const editor = open(sample)
  select(editor, at(editor, 'Alpha'))
  rectangle(editor, 0, 1, 2, 3)
  changeTable(editor, 'align_center', 'cell')
  expect(editor.state.selection).toBeInstanceOf(CellSelection)
  colorTableCells(editor, '#deedfc', 'cell')
  let context = editableTable(editor.state)!
  expect(context.rows.flatMap(row => row.content).filter(cell => cell.mark(CellBackground))).toHaveLength(4)
  changeTable(editor, 'distribute', 'table', 900)
  context = editableTable(editor.state)!
  expect(context.table.node.mark(TableWidths)).toBe('300,300,300')
  expect(editor.state.selection).toBeInstanceOf(CellSelection)
  expectReopens(editor)
})

test('Mod-Enter adds a row and puts subsequent typing in the new row', () => {
  const editor = open(sample)
  select(editor, at(editor, 'Alpha'))
  expect(press(editor, 'Meta-Enter')).toBe(true)
  typeText(editor, 'Inserted')
  expect(editableTable(editor.state)!.rows[2]!.textContent()).toContain('Inserted')
  expectReopens(editor)
})

test('CSV quotes multiline cells, escapes quotes, and protects formulas', () => {
  const editor = open(
    parseXml(
      '<page><table><tr><td><p>"Quoted"</p></td><td><p>=SUM(A1)</p></td></tr><tr><td><p>One</p><p>Two</p></td><td><p>Normal</p></td></tr></table></page>'
    )
  )
  select(editor, at(editor, 'Normal'))
  expect(tableCSV(editableTable(editor.state)!)).toBe('"""Quoted""","\'=SUM(A1)"\r\n"One\nTwo","Normal"')
})

test('CSV preserves signed numbers and percentages while escaping formula expressions', () => {
  const values = ['-12.5', '-12.5%', '+12', '-.5', '-1.2e-3', '25%', '-1+2', '+SUM(A1)', '@SUM(A1)', ' -CMD()']
  const editor = open(
    parseXml(`<page><table><tr>${values.map(value => `<td><p>${value}</p></td>`).join('')}</tr></table></page>`)
  )
  select(editor, at(editor, '-12.5'))
  expect(tableCSV(editableTable(editor.state)!)).toBe(
    values.map((value, index) => `"${index < 6 ? value : `'${value}`}"`).join(',')
  )
})

test('logical columns include row spans when a later imported row is wider', () => {
  const editor = open('<table><tr><td rowspan="2">Span</td><td>A</td></tr><tr><td>B</td><td>C</td></tr></table>')
  select(editor, at(editor, 'C'))
  const context = editableTable(editor.state)!
  expect(context.width).toBe(3)
  expect(context.map.getCell(context.map.cellAt(2, 1)!).textContent()).toBe('C')
  expect(changeTable(editor, 'column_after')).toBe(true)
  expect(editableTable(editor.state)!.width).toBe(4)
  expectReopens(editor)
})
