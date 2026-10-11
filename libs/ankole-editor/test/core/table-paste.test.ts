import { describe, it } from 'bun:test'
import { Plot, Slice, Leaf, Token } from '../../src/core/doc'
import { TableRow, Cell } from '../../src/core/types'
import { CellSelection, handleTablePaste } from '../../src/core/table'
import { GardState, GardSelection, Transaction } from '../../src/core/state'
import ist from 'ist'
import { tableSchema as schema, basicBuilders, builder, maybeTag, eq } from './schema'
const { table, tr, td, rowspan, colspan } = basicBuilders

const doc = builder(schema)

function selFor(doc: Plot.Doc): GardSelection | undefined {
  const from = maybeTag(doc, 0)
  if (from == null) return undefined
  const range = GardSelection.range(from, maybeTag(doc, 1) ?? from)
  return CellSelection.normalize(range, doc) || range
}

function test(
  doc: Plot.Doc,
  content: Token[] | { slice: readonly Token[]; context: readonly Plot.Tag[] },
  expect: Plot.Doc | null
) {
  let state = GardState.create({ doc, selection: selFor(doc), config: CellSelection })
  const [slice, context] = Array.isArray(content) ? [Slice.of(content), []] : [Slice.of(content.slice), content.context]
  const tr = handleTablePaste(state, slice, context)
  if (expect) {
    ist(tr)
    state = state.update(tr as Transaction.Spec).state
    ist(state.doc, expect, eq)
    const newSel = selFor(expect)
    if (newSel) ist(`${newSel.anchor}-${newSel.head}`, `${state.selection.anchor}-${state.selection.head}`)
  } else {
    ist(!tr)
  }
}

describe('Table paste', () => {
  it('allows regular pastes inside cells through', () =>
    test(doc(table(tr(td('a', 0), td('b')))), [Leaf.text('?')], null))

  it('repeats regular pastes across a cell selection', () =>
    test(
      doc(table(tr(td('a', 0), td('b'), td('c')), tr(td('d'), td('e', 1), td('f')))),
      [Leaf.text('!')],
      doc(table(tr(td('!', 0), td('!'), td('c')), tr(td('!'), td('!', 1), td('f'))))
    ))

  it('expands the pasted range for cell content', () =>
    test(
      doc(table(tr(td(0, 'a'), td('b'), td('c')))),
      [td('x'), td('y')],
      doc(table(tr(td(0, 'x'), td('y', 1), td('c'))))
    ))

  it('can grow a table horizontally', () =>
    test(
      doc(table(tr(td(0, 'a')), tr(td('b')))),
      [td('x'), td('y')],
      doc(table(tr(td(0, 'x'), td('y', 1)), tr(td('b'), td())))
    ))

  it('can grow a table vertically', () =>
    test(
      doc(table(tr(td(0, 'a'), td('b')))),
      [tr(td('x')), tr(td('y'))],
      doc(table(tr(td(0, 'x'), td('b')), tr(td('y', 1), td())))
    ))

  it('recognizes opened cells as table content', () =>
    test(
      doc(table(tr(td(0, 'a'), td('b')))),
      { slice: [Leaf.text('x'), Token.End, Token.End, TableRow, Cell, Leaf.text('y')], context: [Cell, TableRow] },
      doc(table(tr(td(0, 'x'), td('b')), tr(td('y', 1), td())))
    ))

  it('recognizes a full table as table content', () =>
    test(
      doc(table(tr(td('a'), td('b', 0)))),
      [table(tr(td('x'), td('y')), tr(td('z'), td('q')))],
      doc(table(tr(td('a'), td(0, 'x'), td('y')), tr(td(), td('z'), td('q', 1))))
    ))

  it('can split merged cells on the left selection border', () =>
    test(
      doc(table(tr(td('a'), td(0, 'b'), td('c')), tr(colspan(2, td('d')), td('e')), tr(td('f'), td('g', 1), td('h')))),
      [Leaf.text('x')],
      doc(table(tr(td('a'), td(0, 'x'), td('c')), tr(td('d'), td('x'), td('e')), tr(td('f'), td('x', 1), td('h'))))
    ))

  it('can split merged cells on the right selection border', () =>
    test(
      doc(table(tr(td('a'), td(0, 'b'), td('c')), tr(td('d'), colspan(2, td('e'))), tr(td('f'), td('g', 1), td('h')))),
      [Leaf.text('x')],
      doc(table(tr(td('a'), td(0, 'x'), td('c')), tr(td('d'), td('x'), td()), tr(td('f'), td('x', 1), td('h'))))
    ))

  it('can split merged cells on vertical selection borders', () =>
    test(
      doc(table(tr(td('a'), rowspan(3, td('b')), td('c')), tr(td(0, 'd'), td('e', 1)), tr(td('f'), td('h')))),
      [Leaf.text('x')],
      doc(table(tr(td('a'), td('b'), td('c')), tr(td(0, 'x'), td('x'), td('x', 1)), tr(td('f'), td(), td('h'))))
    ))

  it('can split cells on the selection border', () =>
    test(
      // a b c d    a b c d
      // e<f c g    e<x x g
      // h h h h => h x x ø
      // i j k>l    i x x>l
      // m j n l    m ø n l
      doc(
        table(
          tr(td('a'), td('b'), rowspan(2, td('c')), td('d')),
          tr(td('e'), td(0, 'f'), td('g')),
          tr(colspan(4, td('h'))),
          tr(td('i'), rowspan(2, td('j')), td('k', 1), rowspan(2, td('l'))),
          tr(td('m'), td('n'))
        )
      ),
      [Leaf.text('x')],
      doc(
        table(
          tr(td('a'), td('b'), td('c'), td('d')),
          tr(td('e'), td(0, 'x'), td('x'), td('g')),
          tr(td('h'), td('x'), td('x'), td()),
          tr(td('i'), td('x'), td('x', 1), rowspan(2, td('l'))),
          tr(td('m'), td(), td('n'))
        )
      )
    ))

  it('can clip content to the selection size', () =>
    test(
      doc(table(tr(td('a'), td(0, 'b')), tr(td('c'), td('d')), tr(td('e'), td('f', 1)))),
      [tr(td('x'), td('y')), tr(td('z'), td('q'))],
      doc(table(tr(td('a'), td(0, 'x')), tr(td('c'), td('z')), tr(td('e'), td('x', 1))))
    ))

  it('can fill out non-rectangular input', () =>
    test(
      doc(table(tr(td('a', 0)))),
      [tr(td('b'), td('c'), td('d')), tr(rowspan(2, colspan(2, td('e'))))],
      doc(table(tr(td(0, 'b'), td('c'), td('d')), tr(rowspan(2, colspan(2, td('e'))), td()), tr(td(1))))
    ))
})
