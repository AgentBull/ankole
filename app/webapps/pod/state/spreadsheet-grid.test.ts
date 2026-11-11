import { expect, test } from 'bun:test'
import { officeFileFormat } from '../office/office-files'
import {
  cellName,
  columnName,
  decodeTSV,
  encodeTSV,
  filterColumnsWith,
  LineAxis,
  MAX_COLS,
  MAX_ROWS,
  parseCell,
  parseRange,
  rangeName,
  replaceText,
  selectedLines,
  shiftCell
} from './spreadsheet-grid'

test('A1 names round-trip for cells, ranges, whole rows, and whole columns', () => {
  expect([0, 25, 26, 51, 52, MAX_COLS - 1].map(columnName)).toEqual(['A', 'Z', 'AA', 'AZ', 'BA', 'XFD'])
  expect(parseCell('$C$5')).toEqual({ row: 4, col: 2 })
  expect(cellName({ row: 4, col: 2 })).toBe('C5')
  expect(parseCell('XFE1')).toBeUndefined()
  expect(parseCell('A0')).toBeUndefined()
  expect(parseRange('D10:B2')).toEqual({ r0: 1, c0: 1, r1: 9, c1: 3 })
  expect(rangeName({ r0: 1, c0: 1, r1: 9, c1: 3 })).toBe('B2:D10')
  expect(rangeName({ r0: 2, c0: 0, r1: 4, c1: MAX_COLS - 1 })).toBe('3:5')
  expect(rangeName({ r0: 0, c0: 0, r1: MAX_ROWS - 1, c1: 2 })).toBe('A:C')
  expect(parseRange('3:5')).toEqual({ r0: 2, c0: 0, r1: 4, c1: MAX_COLS - 1 })
  expect(parseRange('A:C')).toEqual({ r0: 0, c0: 0, r1: MAX_ROWS - 1, c1: 2 })
  expect(rangeName(parseRange('B7')!)).toBe('B7')
})

test('a line action on a whole-column selection covers the active row only', () => {
  const columns = { r0: 0, c0: 1, r1: MAX_ROWS - 1, c1: 2 }
  expect(selectedLines(columns, 'rows', { row: 6, col: 1 })).toEqual({ start: 6, end: 6 })
  expect(selectedLines(columns, 'cols', { row: 6, col: 1 })).toEqual({ start: 1, end: 2 })
})

test('a remote row insert or delete moves a cell with its content', () => {
  const insert = { type: 'line.insert', sheet_id: 1, axis: 'rows', at: 0, count: 2 }
  const remove = { type: 'line.delete', sheet_id: 1, axis: 'cols', at: 1, count: 3 }
  expect(shiftCell({ row: 0, col: 0 }, insert)).toEqual({ row: 2, col: 0 })
  expect(shiftCell({ row: 5, col: 0 }, remove)).toEqual({ row: 5, col: 0 })
  expect(shiftCell({ row: 5, col: 2 }, remove)).toEqual({ row: 5, col: 1 })
  expect(shiftCell({ row: 5, col: 7 }, remove)).toEqual({ row: 5, col: 4 })
})

test('line geometry adds overrides and hidden lines to the default size', () => {
  const rows = new LineAxis(20, MAX_ROWS)
  rows.replace(0, 99, [
    { index: 2, size: 50, hidden: false },
    { index: 4, size: null, hidden: true },
    { index: 6, size: 20, hidden: false }
  ])
  expect(rows.offset(0)).toBe(0)
  expect(rows.offset(3)).toBe(90)
  expect(rows.offset(5)).toBe(110)
  expect(rows.offset(10)).toBe(210)
  expect(rows.indexAt(0)).toBe(0)
  expect(rows.indexAt(45)).toBe(2)
  // The hidden row 4 has no height, so the position where it starts belongs to row 5.
  expect(rows.indexAt(110)).toBe(5)
  expect(rows.indexAt(MAX_ROWS * 40)).toBe(MAX_ROWS - 1)
  rows.replace(0, 3, [])
  expect(rows.offset(5)).toBe(80)
  expect(rows.size(4)).toBe(0)
})

test('the clipboard codec quotes tabs, quotes, and line breaks the way spreadsheet applications do', () => {
  const rows = [
    ['12', '=A1*2', ''],
    ['tab\there', 'say "hi"', 'two\nlines']
  ]
  const text = encodeTSV(rows)
  expect(text).toBe('12\t=A1*2\t\n"tab\there"\t"say ""hi"""\t"two\nlines"')
  expect(decodeTSV(text)).toEqual(rows)
  expect(decodeTSV('a\tb\r\nc\td\r\n')).toEqual([
    ['a', 'b'],
    ['c', 'd']
  ])
  expect(decodeTSV('')).toEqual([])
})

test('spreadsheet pages are files named .xlsx or .xlsm, including Drive duplicate names', () => {
  expect(
    ['Budget.XLSX', 'macro.xlsm', 'Budget.xlsx (2)', 'old.xls', 'data.csv', 'book.xlsb', 'Budget.xlsx.pdf'].map(
      name => officeFileFormat(name) === 'spreadsheet'
    )
  ).toEqual([true, true, true, false, false, false, false])
})

test('a filter column edit keeps the other value lists and drops custom criteria from the file', () => {
  const filter = {
    range: 'A1:D9',
    columns: [
      { col: 0, values: ['x'], blanks: true, custom: false },
      { col: 2, values: [], blanks: true, custom: true }
    ]
  }
  expect(filterColumnsWith(filter, 1, { values: ['y', 'z'], blanks: false })).toEqual([
    { col: 'A', values: ['x'], blanks: true },
    { col: 'B', values: ['y', 'z'] }
  ])
  expect(filterColumnsWith(filter, 0, null)).toEqual([])
  expect(filterColumnsWith(filter, 2, { values: ['q'], blanks: true })).toEqual([
    { col: 'A', values: ['x'], blanks: true },
    { col: 'C', values: ['q'], blanks: true }
  ])
})

test('replace rewrites every occurrence by the case and whole-cell options', () => {
  expect(replaceText('Total total', 'total', 'sum')).toBe('sum sum')
  expect(replaceText('Total total', 'total', 'sum', { match_case: true })).toBe('Total sum')
  expect(replaceText('Total', 'total', 'sum', { whole_cell: true })).toBe('sum')
  expect(replaceText('Total cost', 'total', 'sum', { whole_cell: true })).toBeUndefined()
  expect(replaceText('=SUM(A1)', 'sum', '=', { match_case: true })).toBeUndefined()
  expect(replaceText('abc', '', 'x')).toBeUndefined()
})
