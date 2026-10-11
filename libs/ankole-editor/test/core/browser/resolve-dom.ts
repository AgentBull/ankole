import { describe, it } from './runner'
import { Wordgard, Widget, Decoration } from '../../../src/core/editor'
import { GardState } from '../../../src/core/state'
import { Plot, Leaf, Elt } from '../../../src/core/doc'
import { Paragraph } from '../../../src/core/types'
import ist from 'ist'
import { basicBuilders } from '../schema'

const { DocTile } = Wordgard
const dummyEditor: Wordgard = { connected: false } as any

const { doc, p, blockquote, $img, hr, capFig, strong, em, code } = basicBuilders

function render(doc: Plot.Doc, ...config: GardState.Extension[]) {
  return DocTile.create(GardState.create({ doc, config }), document.createElement('div'), dummyEditor)
}

function isIn(pos: { dom: Node; offset: number }, parent: string, offset: number) {
  ist(pos.dom.nodeValue || pos.dom.nodeName, parent)
  ist(pos.offset, offset)
}

describe('DocTile.resolve', () => {
  it('resolves into text nodes when biased', () => {
    const node = render(doc(p('one')))
    isIn(node.resolve(1, 1), 'one', 0)
    isIn(node.resolve(1, -1), 'P', 0)
    isIn(node.resolve(4, -1), 'one', 3)
    isIn(node.resolve(4, 1), 'P', 1)
  })

  it('resolves simple positions', () => {
    const node = render(doc(p('one', $img), hr))
    isIn(node.resolve(0, 1), 'DIV', 0)
    isIn(node.resolve(1, -1), 'P', 0)
    isIn(node.resolve(1, 1), 'one', 0)
    isIn(node.resolve(2, 1), 'one', 1)
    isIn(node.resolve(4, -1), 'one', 3)
    isIn(node.resolve(4, 1), 'P', 1)
    isIn(node.resolve(5, 1), 'P', 2)
    isIn(node.resolve(6, -1), 'DIV', 1)
    isIn(node.resolve(6, 1), 'DIV', 1)
    isIn(node.resolve(7, -1), 'DIV', 2)
  })

  function span(name: string) {
    const span = document.createElement('span')
    span.setAttribute('data-name', name)
    return span
  }

  it('resolves properly between widgets', () => {
    const set = Decoration.Point.set([
      [Decoration.Point.widget(Widget.create({ render: () => span('A') }), { side: -1 }), 3],
      [Decoration.Point.widget(Widget.create({ render: () => span('B') }), { side: 0 }), 3],
      [Decoration.Point.widget(Widget.create({ render: () => span('C') }), { side: 0 }), 3],
      [Decoration.Point.widget(Widget.create({ render: () => span('D') }), { side: 1 }), 3]
    ])
    const node = render(
      doc(p('abcd')),
      Decoration.Point.source.of(() => set)
    )
    isIn(node.resolve(3, -1), 'P', 2)
    isIn(node.resolve(3, 1), 'P', 4)
    isIn(node.resolve(4, 1), 'cd', 1)
  })

  it('picks the correct side on mark boundaries', () => {
    const node = render(doc(p('a', em('b', strong('c')), code('d'))))
    isIn(node.resolve(2, -1), 'a', 1)
    isIn(node.resolve(2, 1), 'b', 0)
    isIn(node.resolve(3, -1), 'b', 1)
    isIn(node.resolve(3, 1), 'c', 0)
    isIn(node.resolve(4, -1), 'c', 1)
    isIn(node.resolve(4, 1), 'd', 0)
    isIn(node.resolve(5, -1), 'd', 1)
    isIn(node.resolve(5, 1), 'P', 3)
  })

  it('picks the right side of widgets on wrapper boundaries', () => {
    const set = Decoration.Point.set([
      [Decoration.Point.widget(Widget.create({ render: () => span('A') }), { side: -1 }), 1],
      [Decoration.Point.widget(Widget.create({ render: () => span('B') }), { side: 1 }), 2],
      [Decoration.Point.widget(Widget.create({ render: () => span('C') }), { side: 1 }), 3],
      [Decoration.Point.widget(Widget.create({ render: () => span('D') }), { side: -1 }), 4]
    ])
    const node = render(
      doc(p(strong('a'), 'b', strong('c'), 'd')),
      Decoration.Point.source.of(() => set)
    )
    isIn(node.resolve(1, -1), 'P', 1)
    isIn(node.resolve(1, 1), 'a', 0)
    isIn(node.resolve(2, -1), 'a', 1)
    isIn(node.resolve(2, 1), 'P', 2)
    isIn(node.resolve(3, -1), 'b', 1)
    isIn(node.resolve(3, 1), 'P', 4)
    isIn(node.resolve(4, -1), 'P', 7)
    isIn(node.resolve(4, 1), 'd', 0)
  })

  it('does not resolve into inner point structure', () => {
    Plot.Doc.noValidate(() => {
      const node = render(doc(p('a'), capFig('test.png', 'Caption')))
      isIn(node.resolve(4, -1), 'FIGCAPTION', 0)
      isIn(node.resolve(11, 1), 'FIGCAPTION', 1)
    })
  })

  it('does go into inner content wrappers', () => {
    const Deep = Plot.define('Deep', {
      inlineContent: true,
      shape: { structure: Elt.mk('div', [Elt.mk('section', [Elt.mk('p', [0])])]) }
    })
    Plot.Doc.noValidate(() => {
      const node = render(doc(Deep.create([Leaf.text('abc')])))
      isIn(node.resolve(1, -1), 'P', 0)
      isIn(node.resolve(1, 1), 'abc', 0)
      isIn(node.resolve(4, 1), 'P', 1)
      isIn(node.resolve(4, -1), 'abc', 3)
    })
  })

  it('can handle node structure inside content wrappers', () => {
    const Complex = Plot.define('Complex', {
      shape: {
        structure: Elt.mk('weird', [
          Elt.mk('span', ['<<']),
          Elt.mk('inner', [Elt.mk('span', ['[[']), 0, Elt.mk('span', [']]'])]),
          Elt.mk('span', ['>>'])
        ])
      },
      inlineContent: true
    })
    Plot.Doc.noValidate(() => {
      const node = render(doc(Complex.create([Leaf.text('...')])))
      isIn(node.resolve(1, -1), 'INNER', 1)
      isIn(node.resolve(1, 1), '...', 0)
      isIn(node.resolve(4, -1), '...', 3)
      isIn(node.resolve(4, 1), 'INNER', 2)
    })
  })
})

describe('DocTile.posFromDOM', () => {
  it('locates basic positions', () => {
    const node = render(doc(p('ab', em('cd')), hr, blockquote(p('e'))))
    const [p1, p2] = Array.from(node.dom.querySelectorAll('p'))
    ist(node.posFromDOM(node.dom, 0), 0)
    ist(node.posFromDOM(node.dom, 1), 6)
    ist(node.posFromDOM(node.dom, 2), 7)
    ist(node.posFromDOM(node.dom, 3), 12)
    ist(node.posFromDOM(p1!, 0), 1)
    ist(node.posFromDOM(p1!, 1), 3)
    ist(node.posFromDOM(p1!, 2), 5)
    ist(node.posFromDOM(p1!.firstChild!, 0), 1)
    ist(node.posFromDOM(p1!.firstChild!, 1), 2)
    const e = p1!.lastChild!,
      q = node.dom.lastChild!
    ist(node.posFromDOM(e, 0), 3)
    ist(node.posFromDOM(e, 1), 5)
    ist(node.posFromDOM(e.firstChild!, 2), 5)
    ist(node.posFromDOM(p2!, 0), 9)
    ist(node.posFromDOM(p2!, 1), 10)
    ist(node.posFromDOM(q, 0), 8)
    ist(node.posFromDOM(q, 1), 11)
  })

  it('works in nodes with multiple wrappers', () => {
    const dummy = Elt.mk('dummy')
    const node = render(
      doc(p('ab')),
      Decoration.Tag.shape(Paragraph, Elt.mk('div', [dummy, Elt.mk('p', [dummy, 0, dummy]), dummy]))
    )
    const p0 = node.dom.querySelector('p')!,
      div = node.dom.querySelector('div')!
    ist(node.posFromDOM(p0, 0), 1)
    ist(node.posFromDOM(p0.firstChild!, 0), 1)
    ist(node.posFromDOM(p0, 1), 1)
    ist(node.posFromDOM(p0, 2), 3)
    ist(node.posFromDOM(p0, 3), 3)
    ist(node.posFromDOM(p0.lastChild!, 0), 3)
    ist(node.posFromDOM(div, 0), 1)
    ist(node.posFromDOM(div, 1), 1)
    ist(node.posFromDOM(div, 2), 3)
    ist(node.posFromDOM(div, 3), 3)
  })

  it('handles inline plot buffers correctly', () => {
    const plot = Plot.define('Plot', {
      inline: true,
      inlineContent: true,
      shape: { element: 'span' }
    })
    Plot.Doc.noValidate(() => {
      const node = render(doc(p('a', plot.create([Leaf.text('b')]), 'c')))
      const p0 = node.dom.querySelector('p')!,
        span = node.dom.querySelector('span')!
      ist(node.posFromDOM(span, 0), 2)
      ist(node.posFromDOM(span, 1), 3)
      ist(node.posFromDOM(span, 2), 4)
      ist(node.posFromDOM(span, 3), 5)
      ist(node.posFromDOM(p0, 1), 2)
      ist(node.posFromDOM(p0, 2), 5)
    })
  })
})
