import { describe, it } from 'bun:test'
import { Plot } from '../../src/core/doc'
import { tables } from '../../src/core/table'
import { GardState } from '../../src/core/state'
import ist from 'ist'
import { tableSchema as schema, basicBuilders, builder, eq } from './schema'
const { table, tr, td, rowspan, colspan } = basicBuilders

const doc = builder(schema)

function test(doc: Plot.Doc, expect: Plot.Doc | null) {
  const state = GardState.create({ doc })
  const tr = tables.correction.scan(state)
  if (expect) {
    ist(tr)
    ist(state.update(tr!).newDoc, expect, eq)
  } else {
    ist(!tr)
  }
}

describe('tables.correction', () => {
  it('adds cells to rows that are too short', () =>
    test(doc(table(tr(td('a'), td('b')), tr(td('c')))), doc(table(tr(td('a'), td('b')), tr(td('c'), td())))))

  it('prefers to add cells to the start of the first row', () =>
    test(doc(table(tr(td('a')), tr(td('b'), td('c')))), doc(table(tr(td(), td('a')), tr(td('b'), td('c'))))))

  it("notices when the missing cells aren't at the end of the row", () =>
    test(doc(table(tr(td('a'), rowspan(2, td('b'))), tr())), doc(table(tr(td('a'), rowspan(2, td('b'))), tr(td())))))

  it('notices rowspans sticking out', () =>
    test(doc(table(tr(td('a'), rowspan(2, td('b')), td('c')))), doc(table(tr(td('a'), td('b'), td('c'))))))

  it('fixes span collisions', () =>
    test(
      doc(table(tr(td('a'), rowspan(3, td('b')), td('c')), tr(colspan(3, td('d'))), tr(td('e'), td('f')))),
      doc(table(tr(td('a'), rowspan(3, td('b')), td('c')), tr(td('d'), td()), tr(td('e'), td('f'))))
    ))

  it('adds missing cells in the middle', () =>
    test(
      doc(table(tr(td('a'), td('b')), tr(td('c')), tr(td('d'), td('e')))),
      doc(table(tr(td('a'), td('b')), tr(td('c'), td()), tr(td('d'), td('e'))))
    ))
})
