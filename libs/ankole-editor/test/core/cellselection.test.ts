import { describe, it } from 'bun:test'
import { CellSelection } from '../../src/core/table'
import { GardSelection } from '../../src/core/state'
import { Plot, Leaf, Mark, Node, Schema } from '../../src/core/doc'
import { Table, TableRow, Cell, ColSpan, RowSpan } from '../../src/core/types'
import { builder, basicBuilders, basicSchema } from './schema'
import ist from 'ist'

const schema = Schema.define(basicSchema.elements.concat(Table, TableRow, Cell, ColSpan, RowSpan))
const { p, table, tr, td } = basicBuilders
const doc = builder(schema)

// Cell positions in a 3x3:
//   2  7 12
//  19 24 29
//  31 36 41
function mkTable(rows = 3, cols = 3, spans?: string) {
  const rowNodes: Plot[] = [],
    done = new Set<string>()
  const spanInfo = !spans
    ? []
    : spans.split(' ').map(spec => {
        const m = /^(\d+,\d+):(\d+)x(\d+)$/.exec(spec)!
        return { id: m[1], cols: +m[2]!, rows: +m[3]! }
      })
  for (let r = 1; r <= rows; r++) {
    const cells: Plot[] = []
    for (let c = 1; c <= cols; c++) {
      const name = `${c},${r}`
      if (!done.has(name)) {
        const info = spanInfo.find(i => i.id == name)
        let marks = Mark.none
        if (info) {
          if (info.rows > 1) marks = RowSpan.of(info.rows).addToSet(marks)
          if (info.cols > 1) marks = ColSpan.of(info.cols).addToSet(marks)
          for (let sr = 0; sr < info.rows; sr++) {
            for (let sc = 0; sc < info.cols; sc++) done.add(`${c + sc},${r + sr}`)
          }
        }
        cells.push(Cell.withMarks(marks).create([Leaf.text(name)]))
      }
    }
    rowNodes.push(TableRow.create(cells))
  }
  return schema.doc([Table.create(rowNodes)])
}

function checkSel(sel: GardSelection, doc: Plot.Doc, cells: string) {
  const cellIDs = cells.split(' ')
  ist(cellIDs.length, sel.ranges.length)
  for (let i = 0; i < cellIDs.length; i++) {
    const r = sel.ranges[i]!,
      id = cellIDs[i]
    const cell = doc.plotAt(r.from - 1)!
    ist(r.from + cell.length - 2, r.to)
    ist(cell.textContent(), id)
  }
}

function testSel(doc: Plot.Doc, anchor: number, head: number, cells: string) {
  const sel = CellSelection.between(doc, anchor, head)!
  ist(sel instanceof CellSelection)
  ist(sel.anchor < sel.head, anchor < head)
  checkSel(sel, doc, cells)
}

function testNorm(doc: Plot.Doc, anchor: number, head: number, result: string | null) {
  const sel = CellSelection.normalize(GardSelection.range(anchor, head), doc)
  if (!result) {
    ist(!sel)
  } else if (/^\d+-\d+$/.test(result)) {
    ist(sel instanceof GardSelection.Text)
    ist(`${sel!.anchor}-${sel!.head}`, result)
  } else {
    ist(sel instanceof CellSelection)
    if (anchor < head) ist(sel!.anchor < sel!.head)
    checkSel(sel!, doc, result)
  }
}

function testMove(
  doc: Plot.Doc,
  anchor: number,
  head: number,
  dir: 'forward' | 'backward' | 'up' | 'down',
  cells: string | null
) {
  const sel = CellSelection.between(doc, anchor, head)!.moveHead(doc, dir)
  if (cells) {
    ist(sel)
    checkSel(sel!, doc, cells)
  } else {
    ist(!sel)
  }
}

describe('CellSelection', () => {
  it('Can select two adjacent cells', () => testSel(mkTable(), 7, 17, '2,1 3,1'))

  it('Can select two adjacent cells in reverse', () => testSel(mkTable(), 17, 7, '2,1 3,1'))

  it('Can select three adjacent cells', () => testSel(mkTable(), 19, 34, '1,2 2,2 3,2'))

  it('Can select two cells vertically', () => testSel(mkTable(), 7, 29, '2,1 2,2'))

  it('Can select two cells vertically in reverse', () => testSel(mkTable(), 29, 7, '2,1 2,2'))

  it('Can select a single cell', () => testSel(mkTable(), 24, 29, '2,2'))

  it('Can select a single cell in reverse', () => testSel(mkTable(), 24, 29, '2,2'))

  it('Can select a square of cells', () => testSel(mkTable(), 7, 34, '2,1 3,1 2,2 3,2'))

  it('Can select a square of cells in reverse', () => testSel(mkTable(), 34, 7, '2,1 3,1 2,2 3,2'))

  it('Can handle merged cells', () => testSel(mkTable(3, 3, '2,2:2x2'), 2, 29, '1,1 2,1 3,1 1,2 2,2 1,3'))

  it('grows to cover a colspan', () => testSel(mkTable(3, 3, '1,2:2x1'), 2, 24, '1,1 2,1 1,2'))

  it('grows to cover a rowspan', () => testSel(mkTable(3, 3, '2,1:1x3'), 2, 12, '1,1 2,1 1,2 1,3'))

  describe('normalize', () => {
    it('leaves selections inside a cell alone', () => testNorm(mkTable(), 8, 10, null))

    it('converts selections crossing cell boundaries', () => testNorm(mkTable(), 8, 13, '2,1 3,1'))

    it('preserves selection direction', () => testNorm(mkTable(), 13, 8, '2,1 3,1'))

    it('can handle selections starting between cells', () => testNorm(mkTable(), 7, 12, '2,1'))

    it('can handle cursor selection between cells', () => testNorm(mkTable(), 7, 7, '2,1'))

    it('allows a cursor at the end of a cell', () => testNorm(mkTable(), 11, 11, null))

    it('moves out of a table at the start', () => testNorm(doc(table(tr(td('x'))), p('a')), 3, 9, '0-9'))

    it('moves out of a table at the end', () => testNorm(doc(p('a'), table(tr(td('x')))), 1, 6, '1-10'))

    it('moves out of two tables', () => testNorm(doc(table(tr(td('x'))), p('a'), table(tr(td('y')))), 3, 13, '0-17'))
  })

  describe('moveHead', () => {
    it('can move forward', () => testMove(mkTable(), 24, 29, 'forward', '2,2 3,2'))

    it('can move backward', () => testMove(mkTable(), 24, 29, 'backward', '1,2 2,2'))

    it('can move up', () => testMove(mkTable(), 24, 29, 'up', '2,1 2,2'))

    it('can move down', () => testMove(mkTable(), 24, 29, 'down', '2,2 2,3'))

    it('moves the head', () => testMove(mkTable(), 2, 17, 'backward', '1,1 2,1'))

    it('moves the head when inverted', () => testMove(mkTable(), 17, 2, 'forward', '2,1 3,1'))

    it('extends to a rectangle', () => testMove(mkTable(), 2, 17, 'down', '1,1 2,1 3,1 1,2 2,2 3,2'))

    it('extend when hitting a colspan node', () => testMove(mkTable(3, 3, '1,1:3x1'), 9, 14, 'up', '1,1 1,2 2,2 3,2'))

    it('extend when hitting a rowspan node', () =>
      testMove(mkTable(3, 3, '2,1:1x3'), 24, 2, 'forward', '1,1 2,1 1,2 1,3'))
  })

  // A schema's own table type, with the table role, rows of different
  // length and empty rows.
  describe('tables with the table role', () => {
    const PageTable = Plot.define('PageTable', {
      blockContent: TableRow,
      group: Node.Group.Content,
      isolating: true,
      canBeEmpty: true,
      role: Node.Role.Table,
      shape: { element: 'table' }
    })
    const pageSchema = Schema.define(basicSchema.elements.concat(PageTable, TableRow, Cell, ColSpan, RowSpan))
    const pageDoc = builder(pageSchema),
      pageTable = builder(PageTable)

    // Cell positions: a 2, b 5, c 10.
    const ragged = () => pageDoc(pageTable(tr(td('a'), td('b')), tr(td('c'))))

    it('selects cells', () => testSel(ragged(), 2, 13, 'a c'))

    it('does not move into a missing cell', () => testMove(ragged(), 5, 8, 'down', null))

    it('keeps a cursor in an empty row', () => testNorm(pageDoc(pageTable(tr(td('a')), tr())), 7, 7, null))

    it('converts a selection across cells of a ragged table', () => testNorm(ragged(), 3, 11, 'a c'))

    it('keeps a cursor in an empty table', () => testNorm(pageDoc(p('x'), pageTable()), 4, 4, null))

    it('moves out of an empty table', () => testNorm(pageDoc(p('x'), pageTable()), 1, 4, '1-5'))
  })
})
