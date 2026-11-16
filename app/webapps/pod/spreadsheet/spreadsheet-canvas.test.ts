import { expect, test } from 'bun:test'
import { paneRegions } from './spreadsheet-canvas'

// One frozen column 100 px wide after a 48 px row header, and one frozen row 20 px tall after a 24 px column header.
const view = (scrollLeft: number) => ({
  frozenRows: 1,
  frozenCols: 1,
  frozenHeight: 20,
  frozenWidth: 100,
  firstRow: 1,
  lastRow: 30,
  firstCol: scrollLeft ? 4 : 1,
  lastCol: 12,
  width: 800,
  height: 600,
  colX: (col: number) => 48 + col * 100 - (col < 1 ? 0 : scrollLeft)
})

test('frozen and scrolled columns paint as one pane while they meet at the freeze line', () => {
  expect(paneRegions(view(0))).toEqual([
    { rows: { from: 1, to: 30 }, cols: { from: 0, to: 12 }, clip: [48, 44, 752, 556] },
    { rows: { from: 0, to: 0 }, cols: { from: 0, to: 12 }, clip: [48, 24, 752, 20] }
  ])
})

test('a scrolled grid clips each pane at the freeze line', () => {
  const regions = paneRegions(view(300))
  expect(regions.map(region => region.cols)).toEqual([
    { from: 4, to: 12 },
    { from: 4, to: 12 },
    { from: 0, to: 0 },
    { from: 0, to: 0 }
  ])
  expect(regions[2]!.clip).toEqual([48, 44, 100, 556])
})
