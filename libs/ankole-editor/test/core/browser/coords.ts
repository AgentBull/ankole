import { describe, it } from './runner'
import { Wordgard } from '../../../src/core/editor'
import { GardSelection } from '../../../src/core/state'
import { Table, Cell } from '../types'
import { TableRow } from '../types'
import { Node, Plot, Schema } from '../../../src/core/doc'
import ist from 'ist'
import { tempEditor } from './tempview'
import { basicSchema, basicBuilders, builder } from '../schema'

const schema = Schema.define(basicSchema.elements.concat(Table, TableRow, Cell))
const { p, pre, br, hr, blockquote, ul, li, strong, table, tr, td } = basicBuilders
const doc = builder(schema)

const P = (wg: Wordgard, x: number, y: number) => {
  const pos = wg.posAtCoords({ x, y })
  return `${pos.pos}${pos.side < 0 ? '<' : pos.side ? '>' : ''}`
}

describe('coordsAtPos', () => {
  it('finds reasonable coordinates for simple text', () => {
    const wg = tempEditor(
      doc(p('abc def ghi jkl mno pqr stu')),
      Wordgard.theme({
        '&': { width: '8ch' }
      })
    )
    for (let i = 1; i < wg.state.doc.length - 1; i++) {
      const coords = wg.coordsAtPos(i)
      ist(wg.posAtCoords({ x: coords.left, y: coords.top + 1 }).pos, i)
    }
  })

  it('properly assigns a side to positions', () => {
    const wg = tempEditor(
      doc(p('abcde fghijk')),
      Wordgard.theme({
        '&': { width: '8ch' }
      })
    )
    const p3 = wg.coordsAtPos(3)
    ist(P(wg, p3.left - 1.5, p3.top + 2), '3<')
    ist(P(wg, p3.left + 1.5, p3.bottom - 2), '3>')
    const p7a = wg.coordsAtPos(7, -1)
    const p7b = wg.coordsAtPos(7, 1)
    ist(p7a.top, p7b.top, '<')
    ist(p7a.left, p7b.left, '>')
    ist(P(wg, p7a.left + 20, p7a.top + 2), '7<')
    ist(P(wg, p7b.left - 10, p7b.top + 2), '7>')
  })

  it('assigns positions below text to the end', () => {
    const wg = tempEditor(
      doc(p('abcde')),
      Wordgard.theme({
        p: { paddingBottom: '3px' }
      })
    )
    const p5 = wg.coordsAtPos(5)
    ist(P(wg, p5.left - 1, p5.bottom + 10), '7<')
  })

  it('assigns position below wrapped text to end', () => {
    const wg = tempEditor(
      doc(p('abcde fg')),
      Wordgard.theme({
        p: { paddingBottom: '3px' },
        '&': { width: '6ch' }
      })
    )
    const p9 = wg.coordsAtPos(9)
    ist(p9.top, wg.coordsAtPos(1).bottom, '>=')
    ist(P(wg, p9.right + 10, p9.bottom + 2), '9<')
  })

  it('works around hard breaks', () => {
    const wg = tempEditor(doc(p('ab', br, 'cd')))
    const p3 = wg.coordsAtPos(3),
      p4 = wg.coordsAtPos(4, 1)
    ist(p3.bottom, p4.top, '<=')
    ist(P(wg, p3.left - 1, p3.top + 1), '3<')
    ist(P(wg, p3.left + 1, p3.top + 1), '3<')
    ist(P(wg, p4.left - 1, p4.top + 1), '4>')
    ist(P(wg, p4.left + 1, p4.top + 1), '4>')
  })

  it('works in block atoms', () => {
    const wg = tempEditor(doc(hr, hr, hr))
    const p0 = wg.coordsAtPos(0)
    ist(p0.left, p0.right, '<')
    ist(p0.top, p0.bottom)
    ist(P(wg, p0.left + 10, p0.top - 1), '0>')
    ist(P(wg, p0.left + 10, p0.top + 0.1), '0>')
    const r2 = wg.contentDOM.children[1]!.getBoundingClientRect()
    ist(P(wg, r2.left, r2.top + 0.1), '1>')
    ist(P(wg, r2.left, r2.bottom - 0.1), '2<')
  })

  it('can handle different text height', () => {
    const wg = tempEditor(
      doc(p('abc', strong('def'), 'ghi')),
      Wordgard.theme({
        strong: { fontSize: '300%' }
      })
    )
    const c2 = wg.coordsAtPos(2)
    ist(P(wg, c2.left - 1, c2.top - 5), '2<')
    ist(P(wg, c2.left + 1, c2.bottom + 1), '2>')
    const c8 = wg.coordsAtPos(8)
    ist(P(wg, c8.left - 1, c8.top - 5), '8<')
  })

  it('works in right-to-left context', () => {
    const wg = tempEditor(doc(p('مطر')))
    const c2 = wg.coordsAtPos(2)
    ist(P(wg, c2.left - 1, c2.top + 2), '2>')
    ist(P(wg, c2.left + 1, c2.top + 2), '2<')
  })

  it('works around line breaks', () => {
    const wg = tempEditor(doc(pre('a', br, br, 'b', br)))
    const c2 = wg.coordsAtPos(2, -1)
    ist(wg.coordsAtPos(2, 1).top, c2.top)
    const c3 = wg.coordsAtPos(3, -1)
    ist(c3.top, c2.top, '>')
    ist(P(wg, c3.left + 20, c3.top + 2), '3>')
    ist(wg.coordsAtPos(3, 1).top, c3.top)
    const c4 = wg.coordsAtPos(4, 1)
    ist(c4.top, c3.top, '>')
    const c6 = wg.coordsAtPos(6, -1)
    ist(c6.top, c4.top, '>')
    ist(P(wg, c6.left + 2, c6.top + 2), '6>')
  })
})

function s(pos: number, b?: number) {
  if (b == null) return GardSelection.cursor(pos)
  if (b == 1 || b == -1) return GardSelection.cursor(pos, b)
  return GardSelection.cursor(pos, 1, b)
}

describe('moveVertically', () => {
  it('can move between paragraphs', () => {
    const wg = tempEditor(doc(p('one'), p('two')))
    ist(wg.moveVertically(s(1), true)?.head, 6)
    ist(wg.moveVertically(s(2), true)?.head, 7)
    ist(wg.moveVertically(s(4), true)?.head, 9)
    ist(wg.moveVertically(s(6), false)?.head, 1)
    ist(wg.moveVertically(s(7), false)?.head, 2)
    ist(wg.moveVertically(s(9), false)?.head, 4)
  })

  it('can move within a paragraph', () => {
    const wg = tempEditor(
      doc(p('abcde ugh')),
      Wordgard.theme({
        '&': { width: '10ch' }
      })
    )
    ist(wg.moveVertically(s(1), true)?.head, 7)
    ist(wg.moveVertically(s(3), true)?.head, 9)
    ist(wg.moveVertically(s(6, -1), true)?.head, 10)
    ist(wg.moveVertically(s(7, 1), true), null)
    ist(wg.moveVertically(s(9), true), null)
    ist(wg.moveVertically(s(8), false)?.head, 2)
    ist(wg.moveVertically(s(1), false), null)
  })

  it('stops in an empty block that holds a cursor', () => {
    const Box = Plot.define('Box', {
      blockContent: Node.Group.Content,
      group: Node.Group.Content,
      canBeEmpty: true,
      cursorBarrier: 'empty',
      shape: { element: 'aside' }
    })
    const wg = tempEditor(builder(Schema.define(basicSchema.elements.concat(Box)))(p('a'), Box.create([]), p('b')))
    // The box spans 3 to 5; its only cursor position is 4.
    ist(wg.moveVertically(s(2), true)?.head, 4)
    ist(wg.moveVertically(s(4), true)?.head, 6)
    ist(wg.moveVertically(s(7), false)?.head, 4)
    ist(wg.moveVertically(s(4), false)?.head, 1)
  })

  it('preserves a goal column', () => {
    const wg = tempEditor(doc(p('one'), p('x'), p('two')))
    const r1 = wg.moveVertically(s(4), true)
    ist(r1?.head, 7)
    ist(wg.moveVertically(r1!, true)?.head, 12)
    ist(wg.moveVertically(r1!, false)?.head, 4)
  })

  it('can move across atom blocks', () => {
    const wg = tempEditor(doc(p('one'), hr, p('two'), hr))
    ist(wg.moveVertically(s(2), true)?.head, 8)
    ist(wg.moveVertically(s(8), true)?.head, 12)
  })

  it('can enter nested blocks', () => {
    const wg = tempEditor(
      doc(p('one'), blockquote(p('two')), ul(li(p('three')), li(p('four'))), p('five')),
      Wordgard.theme({
        '&': { fontFamily: 'monospace' },
        'ul, li, blockquote': { margin: 0, padding: 0, listStyle: 'none' }
      })
    )
    ist(wg.moveVertically(s(2), true)?.head, 8)
    ist(wg.moveVertically(s(8), true)?.head, 16)
    ist(wg.moveVertically(s(16), true)?.head, 25)
    ist(wg.moveVertically(s(25), true)?.head, 33)
    ist(wg.moveVertically(s(34), false)?.head, 26)
    ist(wg.moveVertically(s(26), false)?.head, 17)
    ist(wg.moveVertically(s(17), false)?.head, 9)
    ist(wg.moveVertically(s(9), false)?.head, 3)
  })

  it('can move through rows in a table', () => {
    const wg = tempEditor(
      doc(p('a'), table(tr(td('a'), td('a')), tr(td('a'), td('a'))), p('a'.repeat(10))),
      Wordgard.theme({ td: { padding: '0' } })
    )
    ist(wg.moveVertically(s(2), true)?.head, 7)
    ist(wg.moveVertically(s(7), true)?.head, 15)
    ist(wg.moveVertically(s(14), true)?.head, 22)
    ist(wg.moveVertically(s(9), true)?.head, 17)
    ist(wg.moveVertically(s(17), true)?.head, 22, '>')
    ist(wg.moveVertically(s(22), false)?.head, 14)
    ist(wg.moveVertically(s(32), false)?.head, 18)
    ist(wg.moveVertically(s(18), false)?.head, 10)
    ist(wg.moveVertically(s(10), false)?.head, 2)
    ist(wg.moveVertically(s(6), false)?.head, 1)
  })
})
