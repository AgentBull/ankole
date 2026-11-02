import { expect, test } from 'bun:test'
import {
  acceptsReference,
  formulaReferences,
  functionContext,
  namePrefix,
  referenceText,
  splice,
  suggestFunctions,
  toggleAbsolute
} from './spreadsheet-formula'
import { MAX_COLS, MAX_ROWS } from './spreadsheet-grid'

test('references are found with their sheet, outside string literals and function names', () => {
  const text = `=SUM(A1:B2)+'预算 2026'!$C$3+LOG10(Sheet2!D4)&"E5"+F:F+3:4`
  const found = formulaReferences(text).map(({ start, end, sheet, rect }) => ({
    text: text.slice(start, end),
    sheet,
    rect
  }))
  expect(found).toEqual([
    { text: 'A1:B2', sheet: undefined, rect: { r0: 0, c0: 0, r1: 1, c1: 1 } },
    { text: `'预算 2026'!$C$3`, sheet: '预算 2026', rect: { r0: 2, c0: 2, r1: 2, c1: 2 } },
    { text: 'Sheet2!D4', sheet: 'Sheet2', rect: { r0: 3, c0: 3, r1: 3, c1: 3 } },
    { text: 'F:F', sheet: undefined, rect: { r0: 0, c0: 5, r1: MAX_ROWS - 1, c1: 5 } },
    { text: '3:4', sheet: undefined, rect: { r0: 2, c0: 0, r1: 3, c1: MAX_COLS - 1 } }
  ])
  expect(formulaReferences('A1+B2')).toEqual([])
})

test('the function call around the caret names its argument, skipping nested calls and strings', () => {
  const text = '=IF(A1>0, ROUND(B1, 2), "a,b"'
  expect(functionContext(text, text.length)).toEqual({ name: 'IF', argument: 2, start: 1 })
  expect(functionContext(text, 20)).toEqual({ name: 'ROUND', argument: 1, start: 10 })
  expect(functionContext('=SUM(A1:A3) + 1', 15)).toBeUndefined()
  expect(functionContext('=SUM({1,2},', 11)).toEqual({ name: 'SUM', argument: 1, start: 1 })
})

test('a name typed at an operand position is a suggestion prefix', () => {
  expect(namePrefix('=SU', 3)).toEqual({ start: 1, prefix: 'SU' })
  expect(namePrefix('=A1+vlo', 7)).toEqual({ start: 4, prefix: 'vlo' })
  expect(namePrefix('=SUM(', 5)).toBeUndefined()
  expect(namePrefix('="SU', 4)).toBeUndefined()
  expect(namePrefix('=Sheet1!A', 9)).toBeUndefined()
  expect(namePrefix('SU', 2)).toBeUndefined()
  expect(namePrefix('=SU(', 3)).toBeUndefined()
})

test('clicked cells go where an operand may start', () => {
  expect(acceptsReference('=', 1)).toBe(true)
  expect(acceptsReference('=SUM(', 5)).toBe(true)
  expect(acceptsReference('=A1+ ', 5)).toBe(true)
  expect(acceptsReference('=A1', 3)).toBe(false)
  expect(acceptsReference('="x,', 4)).toBe(false)
  expect(acceptsReference('total', 5)).toBe(false)
  expect(referenceText({ r0: 1, c0: 1, r1: 4, c1: 2 })).toBe('B2:C5')
  expect(referenceText({ r0: 0, c0: 0, r1: 0, c1: 0 }, '汇率')).toBe('汇率!A1')
  expect(referenceText({ r0: 0, c0: 0, r1: 0, c1: 0 }, "Q1 'plan'")).toBe(`'Q1 ''plan'''!A1`)
  expect(referenceText({ r0: 0, c0: 0, r1: 0, c1: 0 }, 'AB12')).toBe(`'AB12'!A1`)
  expect(splice('=SUM()', 5, 5, 'A1:A3')).toEqual({ text: '=SUM(A1:A3)', caret: 10 })
})

test('F4 cycles the reference at the caret through absolute and mixed forms', () => {
  const steps = ['=A1+B2', '=$A$1+B2', '=A$1+B2', '=$A1+B2', '=A1+B2']
  for (let index = 0; index < steps.length - 1; index++) {
    expect(toggleAbsolute(steps[index]!, 2)?.text).toBe(steps[index + 1])
  }
  expect(toggleAbsolute('=SUM(A1:B3)', 8)).toEqual({ text: '=SUM($A$1:$B$3)', caret: 14 })
  expect(toggleAbsolute('=Sheet2!C3', 9)?.text).toBe('=Sheet2!$C$3')
  expect(toggleAbsolute('=1+2', 2)).toBeUndefined()
})

test('suggestions list matching functions with the common ones first', () => {
  const functions = ['SUBSTITUTE', 'SUM', 'SUMIF', 'SUMX2MY2', 'COUNT', 'SUMPRODUCT'].map(name => ({ name }))
  expect(suggestFunctions(functions, 'su').map(fn => fn.name)).toEqual([
    'SUM',
    'SUMIF',
    'SUBSTITUTE',
    'SUMPRODUCT',
    'SUMX2MY2'
  ])
  expect(suggestFunctions(functions, 'su', 2)).toHaveLength(2)
})
