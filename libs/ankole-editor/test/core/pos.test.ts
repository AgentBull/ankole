import { describe, it } from 'bun:test'
import ist from 'ist'
import { Pos, Plot, Leaf } from '../../src/core/doc'
import { basicBuilders, tag } from './schema'
const { doc, p, br, li, ul, $img } = basicBuilders

function testPos(name: string, doc: Plot.Doc, ...contexts: ([string, number] | [string, number, number])[]) {
  it(name, () => {
    const p = tag(doc, 0),
      pos = doc.resolve(p)
    ist(pos.pos, p)
    ist(pos.depth, contexts.length - 1)
    for (let i = 0, { parent, index, inText } = pos; i < contexts.length; i++) {
      const [name, idx, txt = 0] = contexts[i]!
      ist(parent.node.name, name)
      ist(index, idx)
      ist(inText, txt)
      index = parent.index
      inText = 0
      parent = parent.parent!
    }
  })
}

describe('Context', () => {
  testPos('can find a top-level position', doc(p('one'), 0, p('two')), ['Doc', 1])

  testPos('can find a position in text', doc(p('on', 0, 'e')), ['Paragraph', 0, 2], ['Doc', 0])

  testPos(
    'can find a position in a nested block',
    doc(p(), ul(li(p(), p(0)))),
    ['Paragraph', 0],
    ['ListItem', 1],
    ['BulletList', 0],
    ['Doc', 1]
  )

  it('can walk through a document', () => {
    const d = doc(p('one'), ul(li(p('a', br, 'b'), p())))
    let cx = d.resolve(0)
    const tokens =
      'OPEN(Paragraph) o n e CLOSE OPEN(BulletList) OPEN(ListItem) OPEN(Paragraph) a LineBreak' +
      ' b CLOSE OPEN(Paragraph) CLOSE CLOSE CLOSE'
    const found: string[] = []
    const walker: Pos.Walker = {
      enterPlot: n => {
        found.push(`OPEN(${n.name})`)
      },
      skip: n => {
        found.push(n.is(Leaf.Text) ? n.param : n.name)
      },
      leavePlot: () => {
        found.push('CLOSE')
      }
    }
    for (let i = 0; i < d.length; i++) cx = cx.advance(1, walker)
    ist(found.join(' '), tokens)
  })

  it('reports proper node positions', () => {
    const cx = doc(p(), ul(li(p(br)), li(p('ab'), p())), p()).resolve(11).parent
    ist(cx.start, 10)
    ist(cx.end, 12)
    ist(cx.before, 9)
    ist(cx.after, 13)
    ist(cx.parent!.start, 9)
    ist(cx.parent!.end, 15)
    ist(cx.parent!.parent!.start, 3)
    ist(cx.parent!.parent!.end, 16)
    ist(cx.parent!.parent!.parent!.start, 0)
    ist(cx.parent!.parent!.parent!.end, 19)
  })

  it('caches resolved contexts', () => {
    const d = doc(p('abc')),
      c1 = d.resolve(1),
      c2 = d.resolve(2)
    ist(d.resolve(1), c1)
    ist(d.resolve(2), c2)
  })

  it('can represent nodes', () => {
    const d = doc(p('abc', $img))
    ist(d.resolveNode(1), null)
    ist(d.resolveNode(5), null)
    const pPos = d.resolvePlot(0)!,
      iPos = d.resolveNode(4)!
    ist(pPos.before, 0)
    ist(pPos.start, 1)
    ist(pPos.after, 6)
    ist(iPos.before, 4)
    ist(iPos.after, 5)
  })
})
