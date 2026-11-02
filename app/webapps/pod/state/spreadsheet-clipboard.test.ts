import { expect, test } from 'bun:test'
import { decodeClipboard, encodeClipboard } from './spreadsheet-clipboard'
import { fillTarget } from './spreadsheet-grid'

const block = {
  origin: 'B2',
  rows: [
    [
      { input: '=A2*2', value: '4', text: '4.0', format: { bold: true } },
      { input: '<b>"x"</b>', value: '<b>"x"</b>', text: '<b>"x"</b>', format: {} }
    ],
    [
      { input: '第二行\n换行', value: '第二行\n换行', text: '第二行\n换行', format: {} },
      { input: '', value: '', text: '', format: {} }
    ]
  ]
}

test('a copy carries the kernel block for Ankole and plain cells for other applications', () => {
  const source = { pageID: 'page', sheetID: 3, range: 'B2:C3', cut: 'cut-1' }
  const { text, html } = encodeClipboard(block, source)
  expect(text).toBe('4.0\t"<b>""x""</b>"\n"第二行\n换行"\t')
  expect(decodeClipboard(html)).toEqual({ payload: { version: 1, source, block } })
  const foreign = html.replace(/ data-ankole-spreadsheet="[^"]*"/, '')
  expect(decodeClipboard(foreign)).toEqual({
    rows: [
      ['4.0', '<b>"x"</b>'],
      ['第二行\n换行', '']
    ]
  })
})

test('pasted HTML from other applications yields the text of each table cell', () => {
  const html =
    '<html><body><table border=1><tr><th>名称</th><td style="x">1&nbsp;200</td></tr>' +
    '<tr><td><span>A &amp; B</span></td><td>3<br/>4</td></tr></table></body></html>'
  expect(decodeClipboard(html)).toEqual({
    rows: [
      ['名称', '1 200'],
      ['A & B', '3\n4']
    ]
  })
  expect(decodeClipboard('<p>no table</p>')).toEqual({})
})

test('the fill handle extends the source along the axis the pointer left it by the most', () => {
  const source = { r0: 2, c0: 1, r1: 3, c1: 2 }
  expect(fillTarget(source, { row: 3, col: 2 })).toBeUndefined()
  expect(fillTarget(source, { row: 8, col: 3 })).toEqual({ r0: 2, c0: 1, r1: 8, c1: 2 })
  expect(fillTarget(source, { row: 0, col: 2 })).toEqual({ r0: 0, c0: 1, r1: 3, c1: 2 })
  expect(fillTarget(source, { row: 4, col: 9 })).toEqual({ r0: 2, c0: 1, r1: 3, c1: 9 })
  expect(fillTarget(source, { row: 2, col: 0 })).toEqual({ r0: 2, c0: 0, r1: 3, c1: 2 })
})
