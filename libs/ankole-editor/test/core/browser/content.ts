import { describe, it } from './runner'
import { Wordgard, Decoration } from '../../../src/core/editor'
import { Widget } from '../../../src/core/editor/decoration'
import { GardState, Transaction } from '../../../src/core/state'
import { Plot, Leaf, Node, Elt, Mark, Schema, Token } from '../../../src/core/doc'
import {
  CodeBlock,
  Emphasis,
  Strong,
  Paragraph,
  Heading,
  Image,
  ImageAlt,
  HorizontalRule
} from '../../../src/core/types/schema'
import { Blockquote } from '../types'
import ist from 'ist'
import { builder, basicBuilders, tableSchema } from '../schema'
import { rDoc, rChangeSpec } from '../generate'

const { DocTile } = Wordgard
const { doc, p, blockquote, h2, ul, li, br, $img, img, imgAlt, hr, strong, em, table, tr, td } = basicBuilders

type DocTile = InstanceType<typeof DocTile>
const dummyEditor: Wordgard = { connected: false } as any

const uned = ` contenteditable="false"`

function render(doc: Plot.Doc, ...config: GardState.Extension[]): DocTile {
  return DocTile.create(GardState.create({ doc, config }), document.createElement('div'), dummyEditor)
}

function update(node: InstanceType<typeof DocTile>, spec: Transaction.Spec) {
  const tr = node.state.update(spec)
  return node.update(tr.state, tr.changes.sections, dummyEditor)
}

function span(text: string) {
  const s = document.createElement('span')
  s.textContent = text
  return s
}

const inlineWidget = Widget.define<string>({ render: span, editable: true })

function compareDOM(a: Element | Text, b: Element | Text) {
  if (a instanceof Element) {
    if (
      !(b instanceof Element) ||
      b.childNodes.length != a.childNodes.length ||
      b.attributes.length != a.attributes.length
    ) {
      return false
    }
    for (let i = 0; i < a.childNodes.length; i++) {
      if (!compareDOM(a.childNodes[i] as any, b.childNodes[i] as any)) return false
    }
    for (let i = 0; i < a.attributes.length; i++) {
      const attr = a.attributes[i]!
      if (b.getAttribute(attr.name) != attr.value) return false
    }
    return true
  } else if (a instanceof Text) {
    return b instanceof Text && a.nodeValue == b.nodeValue
  } else {
    return false
  }
}

describe('DocTile', () => {
  it('can draw a simple document', () => {
    ist(render(doc(p('one'), p('two'))).dom.innerHTML, '<p>one</p><p>two</p>')
  })

  it('can draw basic structure', () => {
    ist(
      render(doc(blockquote(ul(li(p('a: ', $img)), li(p('b'), p('c')))), hr)).dom.innerHTML,
      '<blockquote><ul><li><p>a: <img src="test.png"></p></li><li><p>b</p><p>c</p></li></ul></blockquote><hr>'
    )
  })

  it('can draw marks on text', () => {
    ist(render(doc(p(em('ab', strong('cd')), 'ef'))).dom.innerHTML, '<p><em>ab<strong>cd</strong></em>ef</p>')
  })

  it('can draw marks with a preferred target', () => {
    const Img = Leaf.define('Img', {
      inline: true,
      shape: { structure: () => Elt.mk('span', { class: 'my-img' }, [Elt.mk('img', { src: '/x.webp' })]) }
    })
    const Alt = Mark.Type.define<string>('Alt', {
      target: Img,
      shape: { attribute: 'alt', value: 0, preferTarget: 'img' }
    })
    const alt = builder(Alt),
      img = builder(Img)
    Plot.Doc.noValidate(() => {
      ist(
        render(doc(p(alt('x', img)))).dom.innerHTML,
        `<p><span class="my-img"${uned}><img alt="x" src="/x.webp"></span></p>`
      )
    })
  })

  it('can draw nodes with structure representation', () => {
    ist(render(doc(h2('head'))).dom.innerHTML, '<h2>head</h2>')
  })

  it('can draw nodes with complicated structure', () => {
    const FancyBlock = Plot.define('FancyBlock', {
      group: Node.Group.Content,
      inlineContent: Node.Group.Inline,
      shape: {
        structure: Elt.mk('div', { class: 'c' }, [Elt.mk('span', ['before']), 0, Elt.mk('span', ['after'])])
      }
    })
    Plot.Doc.noValidate(() => {
      let tile = render(doc(FancyBlock.create([Leaf.text('!')])))
      ist(tile.dom.innerHTML, `<div class="c"><span${uned}>before</span>!<span${uned}>after</span></div>`)
      tile = update(tile, {
        changes: [
          { from: 0, insert: [p('(')] },
          { from: 1, to: 2, insert: [Leaf.text('?')] },
          { from: 3, insert: [p(')')] }
        ]
      })
      ist(
        tile.dom.innerHTML,
        `<p>(</p><div class="c"><span${uned}>before</span>?<span${uned}>after</span></div><p>)</p>`
      )
    })
  })

  it('can draw marks on nodes', () => {
    ist(render(doc(p(imgAlt('alt text', $img)))).dom.innerHTML, '<p><img alt="alt text" src="test.png"></p>')
  })

  it('can update for a text change', () => {
    const node = update(render(doc(p('123'))), { changes: { from: 2, insert: [Leaf.text('..')] } })
    ist(node.dom.innerHTML, '<p>1..23</p>')
  })

  it('can update for a tag change', () => {
    const node = update(render(doc(p('a'))), { changes: { from: 0, to: 1, insert: [CodeBlock] } })
    ist(node.dom.innerHTML, '<pre>a</pre>')
  })

  it('can make multiple changes', () => {
    const node = update(render(doc(p('ab'), p('cd'))), {
      changes: [
        { from: 1, insert: [Leaf.text('..')] },
        { from: 2, to: 6 }
      ]
    })
    ist(node.dom.innerHTML, '<p>..ad</p>')
  })

  it('can update text marks', () => {
    const node = update(render(doc(p('one ', em('two')))), {
      changes: [
        { from: 1, to: 4, add: Strong },
        { from: 5, to: 8, remove: Emphasis }
      ]
    })
    ist(node.dom.innerHTML, '<p><strong>one</strong> two</p>')
  })

  it('can update node marks', () => {
    const node = update(render(doc(p($img, ' ', imgAlt('a2', $img)))), {
      changes: [
        { from: 1, add: ImageAlt.of('a1') },
        { from: 3, remove: ImageAlt.of('a2') }
      ]
    })
    ist(node.dom.innerHTML, '<p><img src="test.png" alt="a1"> <img src="test.png"></p>')
  })

  it('can draw spanning marks', () => {
    ist(render(doc(p(strong('a', $img, 'b'), 'c'))).dom.innerHTML, '<p><strong>a<img src="test.png">b</strong>c</p>')
  })

  it('can join spanning marks in updates', () => {
    const node = update(render(doc(p(strong('a'), 'b', strong('c')))), { changes: { from: 2, to: 3 } })
    ist(node.dom.innerHTML, '<p><strong>ac</strong></p>')
  })

  it('preserves DOM nodes with changed wrappers marks', () => {
    let node = render(doc(p(strong($img))))
    const img = node.dom.querySelector('img')
    node = update(node, { changes: { from: 1, remove: Strong, add: Emphasis } })
    ist(node.dom.querySelector('img'), img)
  })

  it('properly syncs replacements inside wrappers', () => {
    const node = render(doc(p(strong('abc')), p('def')))
    ist(
      update(node, { changes: { from: 2, insert: [Leaf.text('..', [Strong])] } }).dom.innerHTML,
      '<p><strong>a..bc</strong></p><p>def</p>'
    )
  })

  it('preserves DOM nodes with changed attribute marks', () => {
    let node = render(doc(p($img)))
    const img = node.dom.querySelector('img')
    node = update(node, { changes: { from: 1, add: ImageAlt.of('text') } })
    ist(node.dom.querySelector('img'), img)
  })

  it('preserves mark wrapper nodes', () => {
    let node = render(doc(p(strong('ab'))))
    const str = node.dom.querySelector('strong')
    node = update(node, { changes: { from: 2, insert: [Leaf.text('!')] } })
    ist(node.dom.querySelector('strong'), str)
  })

  it('adds breaks for empty textblocks and those ending in breaks', () => {
    const node = render(doc(p(), p('a'), p('b', br)))
    ist(node.dom.innerHTML, '<p><br></p><p>a</p><p>b<br><br></p>')
  })

  it('adds a break to an empty block that holds a cursor', () => {
    const Box = Plot.define('Box', {
      blockContent: Node.Group.Content,
      group: Node.Group.Content,
      canBeEmpty: true,
      cursorBarrier: 'empty',
      shape: { element: 'aside' }
    })
    const schema = Schema.define([Plot.defineDoc({ blockContent: Node.Group.Content }), Paragraph, Box])
    const node = render(schema.doc([Box.create([]), Box.create([Paragraph.create([])])]))
    ist(node.dom.innerHTML, '<aside><br></aside><aside><p><br></p></aside>')
  })

  it('fixes textblock breaks on changes', () => {
    const node = render(doc(p(), p('a')))
    ist(
      update(node, {
        changes: [
          { from: 1, insert: [Leaf.text('x')] },
          { from: 3, to: 4 }
        ]
      }).dom.innerHTML,
      '<p>x</p><p><br></p>'
    )
  })

  it('keeps parent nodes when updating their content', () => {
    let node = render(doc(p('a')))
    const para = node.dom.firstChild
    node = update(node, { changes: [{ from: 2, insert: [Leaf.text('b')] }] })
    ist(node.dom.firstChild, para)
  })

  it('reuses text nodes when changing their start', () => {
    let node = render(doc(p('abc'), p('def')))
    const abc = node.dom.firstChild!.firstChild!,
      def = node.dom.lastChild!.firstChild!
    node = update(node, {
      changes: [
        { from: 1, insert: [Leaf.text('..')] },
        { from: 6, to: 7 }
      ]
    })
    ist(abc.nodeValue, '..abc')
    ist(def.nodeValue, 'ef')
  })

  it('reuses text nodes when changing their end', () => {
    let node = render(doc(p('abc'), p('def')))
    const abc = node.dom.firstChild!.firstChild!,
      def = node.dom.lastChild!.firstChild!
    node = update(node, {
      changes: [
        { from: 4, insert: [Leaf.text('..')] },
        { from: 8, to: 9 }
      ]
    })
    ist(abc.nodeValue, 'abc..')
    ist(def.nodeValue, 'de')
  })

  it('reuses text nodes when changing their middle', () => {
    let node = render(doc(p('abc'), p('def')))
    const abc = node.dom.firstChild!.firstChild!,
      def = node.dom.lastChild!.firstChild!
    node = update(node, {
      changes: [
        { from: 2, insert: [Leaf.text('..')] },
        { from: 7, to: 8 }
      ]
    })
    ist(abc.nodeValue, 'a..bc')
    ist(def.nodeValue, 'df')
  })

  it('can handle adding a mark to part of a textblock', () => {
    const tile = update(render(doc(p('one two'))), { changes: { from: 5, to: 8, add: Strong } })
    ist(tile.dom.innerHTML, '<p>one <strong>two</strong></p>')
  })

  it('can handle a change moving content up', () => {
    const tile = update(render(doc(blockquote(p('abc')))), {
      changes: [
        { from: 0, to: 2, insert: [Paragraph] },
        { from: 6, to: 7 }
      ]
    })
    ist(tile.dom.innerHTML, '<p>abc</p>')
  })

  it('can handle a change moving content down', () => {
    const tile = update(render(doc(p('abc'))), {
      changes: [
        { from: 0, to: 1, insert: [Blockquote, Paragraph] },
        { from: 5, insert: [Token.End] }
      ]
    })
    ist(tile.dom.innerHTML, '<blockquote><p>abc</p></blockquote>')
  })

  it('handles insertion of text before a mark', () => {
    const tile = update(render(doc(p(strong('a'), 'b'))), { changes: { from: 1, insert: [Leaf.text('x')] } })
    ist(tile.dom.innerHTML, '<p>x<strong>a</strong>b</p>')
  })

  it('can handle random changes', () => {
    for (let i = 0; i < 100; i++) {
      const start = rDoc(20)
      let doc = start
      let tile = render(doc)
      const log = []
      for (let j = 0; j < 100; j++) {
        const changes = rChangeSpec(doc)
        log.push(changes)
        tile = update(tile, { changes })
        doc = tile.state.doc
      }
      if (!compareDOM(render(doc).dom, tile.dom)) {
        ist(render(doc).dom.innerHTML, tile.dom.innerHTML)
      }
    }
  })

  describe('decoration', () => {
    it('can draw widgets around nodes', () => {
      const src = (side: 'before' | 'after' | 'start' | 'end') =>
        Decoration.Tag.widget(Paragraph, side, inlineWidget.of(side))
      const node = render(doc(p('xyz'), hr), src('before'), src('start'), src('end'), src('after'))
      ist(node.dom.innerHTML, '<span>before</span><p><span>start</span>xyz<span>end</span></p><span>after</span><hr>')
    })

    it('can reuse widgets when replacing next to them', () => {
      const src = (side: 'before' | 'after' | 'start' | 'end') =>
        Decoration.Tag.widget(Image, side, inlineWidget.of(side))
      let node = render(doc(p('x', $img, 'y')), src('before'), src('after'))
      const widgets = node.dom.querySelectorAll('span')
      node = update(node, { changes: { from: 2, to: 3, insert: [img('/x.webp')] } })
      const newWidgets = node.dom.querySelectorAll('span')
      ist(newWidgets.length, 2)
      for (let i = 0; i < widgets.length; i++) ist(newWidgets[i], widgets[i])
    })

    it('can reuse widgets when updating across them', () => {
      const src = (side: 'before' | 'after' | 'start' | 'end') =>
        Decoration.Tag.widget(Image, side, inlineWidget.of(side))
      let node = render(doc(p(strong('x', $img, 'y'), em('z', $img))), src('before'), src('after'))
      const widgets = node.dom.querySelectorAll('span')
      node = update(node, {
        changes: [
          { from: 1, to: 4, remove: Strong, add: Emphasis },
          { from: 4, to: 6, remove: Emphasis }
        ]
      })
      const newWidgets = node.dom.querySelectorAll('span')
      ist(newWidgets.length, 4)
      for (let i = 0; i < widgets.length; i++) ist(newWidgets[i], widgets[i])
    })

    it('updates tag widgets at the end of a changed plot', () => {
      let node = render(doc(p('x'), h2('y')), [
        Decoration.Tag.widget(Heading, 'end', t => inlineWidget.of(`E${t.param}`)),
        Decoration.Tag.widget(Heading, 'after', t => inlineWidget.of(`A${t.param}`))
      ])
      ist(node.dom.innerHTML, `<p>x</p><h2>y<span>E2</span></h2><span>A2</span>`)
      node = update(node, {
        changes: [
          { from: 0, to: 1, insert: [Heading.of(2)] },
          { from: 3, to: 4, insert: [Heading.of(3)] }
        ]
      })
      ist(node.dom.innerHTML, `<h2>x<span>E2</span></h2><span>A2</span><h3>y<span>E3</span></h3><span>A3</span>`)
      node = update(node, {
        changes: [
          { from: 0, to: 1, insert: [Paragraph] },
          { from: 3, to: 4, insert: [Paragraph] }
        ]
      })
      ist(node.dom.innerHTML, `<p>x</p><p>y</p>`)
    })

    it("doesn't break spanning wrappers on widgets", () => {
      const src = (side: 'before' | 'after' | 'start' | 'end') =>
        Decoration.Tag.widget(Image, side, inlineWidget.of(side))
      const node = render(doc(p(strong('x', $img, 'y'))), src('before'), src('after'))
      ist(node.dom.querySelectorAll('strong').length, 1)
    })

    it('keeps structure entirely the same on a no-change update', () => {
      let node = render(doc(p(strong('one', em('two'), $img, 'three')), hr))
      const elts = node.dom.querySelectorAll('*')
      const tr1 = node.state.update({ changes: { from: 1, to: 12, remove: Strong } })
      const tr2 = tr1.state.update({ changes: { from: 1, to: 12, add: Strong } })
      node = node.update(tr2.state, tr1.changes.compose(tr2.changes).sections, dummyEditor)
      const newElts = node.dom.querySelectorAll('*')
      ist(newElts.length, elts.length)
      for (let i = 0; i < elts.length; i++) ist(newElts[i], elts[i])
    })

    it('can draw widgets from a point set', () => {
      const node = render(
        doc(p('abc')),
        Decoration.Point.source.of(_state => {
          return Decoration.Point.set([
            [Decoration.Point.widget(inlineWidget.of('x')), 1],
            [Decoration.Point.widget(inlineWidget.of('y')), 3]
          ])
        })
      )
      ist(node.dom.innerHTML, '<p><span>x</span>ab<span>y</span>c</p>')
    })

    it('can update widgets from a point set', () => {
      const f = GardState.Field.define({
        create: () => Decoration.Point.set([[Decoration.Point.widget(inlineWidget.of('x')), 1]]),
        update: () => Decoration.Point.set([[Decoration.Point.widget(inlineWidget.of('y')), 4]]),
        provide: f => Decoration.Point.source.of(s => s.field(f))
      })
      const node = update(render(doc(p('a'), p('b')), f), {})
      ist(node.dom.innerHTML, '<p>a</p><p><span>y</span>b</p>')
    })

    it('can update widgets in place', () => {
      const f = GardState.Field.define({
        create: () => Decoration.Point.set([[Decoration.Point.widget(inlineWidget.of('x')), 1]]),
        update: () => Decoration.Point.set([[Decoration.Point.widget(inlineWidget.of('y')), 1]]),
        provide: f => Decoration.Point.source.of(s => s.field(f))
      })
      const node = update(render(doc(p('a')), f), {})
      ist(node.dom.innerHTML, '<p><span>y</span>a</p>')
    })

    it('orders widgets by side', () => {
      const w = (n: number) => Widget.create({ render: () => span(`${n}`), editable: true })
      const src = (s: number) =>
        Decoration.Point.source.of(() => Decoration.Point.set([[Decoration.Point.widget(w(s), { side: s }), 2]]))
      ist(
        render(doc(p('xy')), src(1), src(-2), src(-1)).dom.innerHTML,
        '<p>x<span>-2</span><span>-1</span><span>1</span>y</p>'
      )
    })

    it('can redraw widgets at the end of the document', () => {
      const widget = Widget.define({
        render: v => Object.assign(document.createElement('b'), { textContent: v }),
        editable: true
      })
      const flip = Transaction.Effect.define()
      const field = GardState.Field.define({
        create: s => Decoration.Point.set([[Decoration.Point.widget(widget.of('x')), s.doc.length]]),
        update: (v, tr) =>
          tr.effects.some(e => e.is(flip))
            ? Decoration.Point.set([[Decoration.Point.widget(widget.of('y')), tr.state.doc.length]])
            : v,
        provide: f => Decoration.Point.source.of(s => s.field(f))
      })

      const tile = update(render(doc(p('ab')), field), { effects: flip.of(null) })
      ist(tile.dom.innerHTML, '<p>ab</p><b>y</b>')
    })

    it("doesn't duplicate widgets on section boundaries", () => {
      let node = render(doc(p(strong('a'), $img)), Decoration.Tag.widget(Image, 'before', inlineWidget.of('!')))
      ist(node.dom.innerHTML, '<p><strong>a</strong><span>!</span><img src="test.png"></p>')
      node = update(node, {
        changes: [
          { from: 1, to: 2, remove: Strong },
          { from: 2, to: 3, insert: [$img] }
        ]
      })
      ist(node.dom.innerHTML, '<p>a<span>!</span><img src="test.png"></p>')
    })

    it('can decorate tags', () => {
      const pWrap = Decoration.Tag.wrapper(Paragraph, Elt.mk('div', { class: 'pwrap' }, [0]))
      const iWrap = Decoration.Tag.wrapper(Image, Elt.mk('image', [0]))
      ist(
        render(doc(p('a', $img)), [pWrap, iWrap]).dom.innerHTML,
        `<div class="pwrap"><p>a<image${uned}><img src="test.png"></image></p></div>`
      )
    })

    it('updates wrappers when they change', () => {
      const wA = Decoration.Range.wrapper('span', { attributes: { class: 'a' } })
      const wB = Decoration.Range.wrapper('span', { attributes: { class: 'b' } })
      let tile = render(
        doc(p('-')),
        Decoration.Range.source.of(s => {
          return Decoration.Range.set([[s.selection.from == 1 ? wA : wB, 1, 2]])
        })
      )
      ist(tile.dom.innerHTML, `<p><span class="a">-</span></p>`)
      tile = update(tile, { selection: { anchor: 2 } })
      ist(tile.dom.innerHTML, `<p><span class="b">-</span></p>`)
    })

    it('can handle changes from range and point decorations in a single transactions', () => {
      const point = Decoration.Point.source.of(s => {
        return Decoration.Point.set([[Decoration.Point.widget(inlineWidget.of(s.selection.from == 1 ? 'x' : 'y')), 2]])
      })
      const range = Decoration.Range.source.of(s => {
        return Decoration.Range.set([[Decoration.Range.attribute('data-m', String(s.selection.from)), 5, 6]])
      })
      const tile = update(render(doc(p('abcdef')), [point, range]), { selection: { anchor: 2 } })
      ist(tile.dom.innerHTML, `<p>a<span>y</span>bcd<span data-m="2">e</span>f</p>`)
    })

    it('can add attributes to tags', () => {
      ist(render(doc(p('?')), Decoration.Tag.attribute(Paragraph, 'lang', 'nl')).dom.innerHTML, '<p lang="nl">?</p>')
    })

    it('can remove attributes from tags', () => {
      const comp = GardState.Compartment.define()
      let node = render(doc(p('?')), comp.of(Decoration.Tag.attribute(Paragraph, 'lang', 'nl')))
      node = update(node, { effects: comp.reconfigure([]) })
      ist(node.dom.innerHTML, '<p>?</p>')
    })

    it('preserves DOM nodes when adding attributes', () => {
      let node = render(doc(p('a')))
      const para = node.dom.firstChild
      node = update(node, { effects: GardState.reconfigure.of(Decoration.Tag.attribute(Paragraph, 'lang', 'nl')) })
      ist(node.dom.innerHTML, '<p lang="nl">a</p>')
      ist(node.dom.firstChild, para)
    })

    it("doesn't drop point decorations directly after a change", () => {
      const classes = Decoration.Point.source.of(s => {
        return Decoration.Point.set(add => {
          let i = 0
          s.doc.iterate((node, pos) => {
            if (node.type == Paragraph.type) add(Decoration.Point.attributes({ class: `c${++i % 3}` }), pos)
          })
        })
      })
      const node = update(render(doc(p('a'), p('b'), p('c')), classes), { changes: { from: 0, to: 3 } })
      ist(node.dom.innerHTML, `<p class="c1">b</p><p class="c2">c</p>`)
    })

    it('can take wrappers from spans', () => {
      ist(
        render(
          doc(p('ab', $img, 'cd')),
          Decoration.Range.source.of(_s => {
            return Decoration.Range.set([[Decoration.Range.wrapper('span', { attributes: { class: 'a' } }), 2, 5]])
          })
        ).dom.innerHTML,
        '<p>a<span class="a">b<img src="test.png">c</span>d</p>'
      )
    })

    it('can take attributes from spans', () => {
      ist(
        render(
          doc(p('ab', $img, 'cd')),
          Decoration.Range.source.of(_s => {
            return Decoration.Range.set([[Decoration.Range.attribute('alt', 'a test', { query: Image }), 2, 5]])
          })
        ).dom.innerHTML,
        '<p>ab<img alt="a test" src="test.png">cd</p>'
      )
    })

    it('notices changes to spans that start before a preserved section', () => {
      ist(
        update(
          render(
            doc(p('abcd')),
            Decoration.Range.source.of(s => {
              const wrap = Decoration.Range.wrapper('span', { attributes: { class: s.doc.length % 2 ? 'x' : 'y' } })
              return Decoration.Range.set([[wrap, 1, s.doc.length - 1]])
            })
          ),
          {
            changes: { from: 3, insert: [Leaf.text('/')] }
          }
        ).dom.innerHTML,
        `<p><span class="x">ab/cd</span></p>`
      )
    })

    it("can override a specific leaf node's shape", () => {
      ist(
        render(
          doc(p('ab', $img, 'cd')),
          Decoration.Point.source.of(_state => {
            return Decoration.Point.set([[Decoration.Point.shape(Elt.mk('span', ['!'])), 3]])
          })
        ).dom.innerHTML,
        `<p>ab<span${uned}>!</span>cd</p>`
      )
    })

    it("can override a specific non-leaf node's shape", () => {
      ist(
        render(
          doc(p('ab', $img, 'cd')),
          Decoration.Point.source.of(_state => {
            return Decoration.Point.set([[Decoration.Point.shape(Elt.mk('div', [0])), 0]])
          })
        ).dom.innerHTML,
        '<div>ab<img src="test.png">cd</div>'
      )
    })

    it('can give a plot with atomic shape', () => {
      ist(
        render(
          doc(p('ab', $img, 'cd')),
          Decoration.Point.source.of(_state => {
            return Decoration.Point.set([[Decoration.Point.shape(Elt.mk('div', ['?'])), 0]])
          })
        ).dom.innerHTML,
        `<div${uned}>?</div>`
      )
    })

    it('can dynamically redraw a plot as an atom', () => {
      let tile = render(doc(p('abc')))
      tile = update(tile, {
        effects: GardState.appendConfig.of(
          Decoration.Point.source.of(_state => {
            return Decoration.Point.set([[Decoration.Point.shape(Elt.mk('div', ['?'])), 0]])
          })
        )
      })
      ist(tile.dom.innerHTML, `<div${uned}>?</div>`)
    })

    it('can dynamically redraw an atom plot as a regular plot', () => {
      let tile = render(
        doc(p('abc')),
        Decoration.Point.source.of(_state => {
          return Decoration.Point.set([[Decoration.Point.shape(Elt.mk('div', ['?'])), 0]])
        })
      )
      tile = update(tile, { effects: GardState.reconfigure.of([]) })
      ist(tile.dom.innerHTML, '<p>abc</p>')
    })

    it('can add attributes to a specific node', () => {
      const deco = Decoration.Point.set([[Decoration.Point.attributes({ class: 'u' }), 0]])
      ist(
        render(
          doc(p(), p()),
          Decoration.Point.source.of(() => deco)
        ).dom.innerHTML,
        '<p class="u"><br></p><p><br></p>'
      )
    })

    it("won't try to add attributes to a text node", () => {
      const deco = Decoration.Point.set([[Decoration.Point.attributes({ class: 'u' }), 1]])
      ist(
        render(
          doc(p('a')),
          Decoration.Point.source.of(() => deco)
        ).dom.innerHTML,
        '<p>a</p>'
      )
    })

    it("doesn't leave stale decorations on complex changes", () => {
      const doc = builder(tableSchema)
      const attr = Decoration.Point.attributes({ class: 'x' })
      let tile = render(
        doc(p('-'), table(tr(td('A'), td('B')), tr(td('C'), td('D')))),
        Decoration.Point.source.of(state =>
          state.doc.length == 21
            ? Decoration.Point.set([
                [attr, 5],
                [attr, 8]
              ])
            : Decoration.Point.none
        )
      )
      tile = update(tile, {
        changes: [
          { from: 6, to: 7 },
          { from: 9, to: 10 },
          { from: 14, to: 15, insert: [Leaf.text('A')] },
          { from: 17, to: 18, insert: [Leaf.text('B')] }
        ]
      })
      ist(tile.dom.querySelector('.x'), null)
    })

    it('can add wrapping structure to a specific node', () => {
      const deco = Decoration.Point.set([[Decoration.Point.wrapper(Elt.mk('div', [Elt.mk('hr'), 0])), 3]])
      ist(
        render(
          doc(p('x'), p('y')),
          Decoration.Point.source.of(() => deco)
        ).dom.innerHTML,
        '<p>x</p><div><hr><p>y</p></div>'
      )
    })

    it("can handle a change modifying the depth of a plot's wrapper", () => {
      const deco = Decoration.Point.set([[Decoration.Point.wrapper(Elt.mk('div', [Elt.mk('hr'), 0])), 0]])
      const node = update(render(doc(p('x'), p('y'))), {
        effects: GardState.appendConfig.of(Decoration.Point.source.of(() => deco))
      })
      ist(node.dom.innerHTML, '<div><hr><p>x</p></div><p>y</p>')
    })

    it('can replace the shape of a node type', () => {
      const tile = render(doc(p('a', $img, 'b')), Decoration.Tag.shape(Image, Elt.mk('span', { class: 'img' })))
      ist(tile.dom.innerHTML, `<p>a<span class="img"${uned}></span>b</p>`)
    })

    it('properly handles insertions at the start and end of wrapping structure', () => {
      const wrapPara = Decoration.Tag.shape(Paragraph, Elt.mk('div', [Elt.mk('p', [0])]))
      let tile = render(doc(p('ab')), wrapPara)
      tile = update(tile, { changes: { from: 3, insert: [Leaf.text('x')] } })
      ist(tile.dom.innerHTML, '<div><p>abx</p></div>')
      tile = update(tile, { changes: { from: 1, insert: [Leaf.text('y')] } })
      ist(tile.dom.innerHTML, '<div><p>yabx</p></div>')
    })

    it('can handle changes inside atomic plots', () => {
      let tile = render(doc(p('abcd')), Decoration.Tag.shape(Paragraph, Elt.mk('para')))
      const para = tile.dom.querySelector('para')
      tile = update(tile, { changes: { from: 1, insert: [Leaf.text('--')] } })
      ist(tile.dom.innerHTML, `<para${uned}></para>`)
      ist(tile.dom.querySelector('para'), para)
    })

    it('can handle deletion inside an atomic plot', () => {
      let tile = render(doc(p('abcd')), Decoration.Tag.shape(Paragraph, Elt.mk('para')))
      tile = update(tile, { changes: { from: 2, to: 4 } })
      ist(tile.dom.innerHTML, `<para${uned}></para>`)
      ist(tile.children[0]!.length, 4)
    })

    it('can handle changes covering parts of atomic plots', () => {
      let tile = render(doc(p('ab'), p('cd')), Decoration.Tag.shape(Paragraph, Elt.mk('para')))
      tile = update(tile, { changes: { from: 2, to: 6 } })
      ist(tile.dom.innerHTML, `<para${uned}></para>`)
    })

    it('can handle changes covering parts of wrapped atomic plots', () => {
      let tile = render(doc(p('ab'), p('cd')), [
        Decoration.Tag.shape(Paragraph, Elt.mk('para')),
        Decoration.Tag.wrapper(Paragraph, Elt.mk('outer', [0]))
      ])
      tile = update(tile, { changes: { from: 2, to: 6, insert: [Plot.End, Paragraph] } })
      ist(tile.dom.innerHTML, `<outer${uned}><para></para></outer><outer${uned}><para></para></outer>`)
    })

    it('can handle changes covering the start of atomic plots', () => {
      let tile = render(doc(h2('ab'), p('cd')), Decoration.Tag.shape(Paragraph, Elt.mk('para')))
      tile = update(tile, { changes: { from: 2, to: 6, insert: [Plot.End, Paragraph] } })
      ist(tile.dom.innerHTML, `<h2>a</h2><para${uned}></para>`)
    })

    it('supports selectors for wrapper decorations', () => {
      const complexImg = Decoration.Tag.shape(Image, i =>
        Elt.mk('span', { class: 'my-image' }, [Elt.mk('img', { src: i.param })])
      )
      const deco = Decoration.Point.set([
        [Decoration.Point.wrapper(Elt.mk('span', { class: 'inner' }, [0]), { target: 'img' }), 2]
      ])
      const tile = render(doc(p('»', $img)), [complexImg, Decoration.Point.source.of(() => deco)])
      ist(
        tile.dom.innerHTML,
        `<p>»<span class="my-image"${uned}><span class="inner"><img src="test.png"></span></span></p>`
      )
    })

    it('can reuse DOM structure when adding a shape wrapper', () => {
      let node = render(doc(p($img)))
      const img = node.dom.querySelector('img')
      node = update(node, {
        effects: GardState.appendConfig.of(
          Decoration.Point.source.of(_state => {
            return Decoration.Point.set([[Decoration.Point.wrapper(Elt.mk('span', { class: 'u' }, [0])), 1]])
          })
        )
      })
      ist(node.dom.querySelector('img'), img)
    })

    it('makes isAtom aware of tag shapes', () => {
      ist(GardState.create({ doc: doc(p()) }).isAtom(Paragraph.type), false)
      const s = GardState.create({ doc: doc(p()), config: Decoration.Tag.shape(Paragraph, Elt.mk('div')) })
      ist(s.isAtom(Paragraph.type), true)
    })

    it('can override shapes by tag', () => {
      ist(
        render(doc(p('a')), Decoration.Tag.shape(Paragraph, Elt.mk('div', { class: 'para' }, [0]))).dom.innerHTML,
        '<div class="para">a</div>'
      )
    })

    it('makes by-point shapes override by-tag ones', () => {
      ist(
        render(doc(p('a')), [
          Decoration.Tag.shape(Paragraph, Elt.mk('div', { class: 'b' }, [0])),
          Decoration.Point.source.of(_state => {
            return Decoration.Point.set([[Decoration.Point.shape(Elt.mk('div', { class: 'a' }, [0])), 0]])
          })
        ]).dom.innerHTML,
        '<div class="a">a</div>'
      )
    })

    it('properly updates when tag shapes change', () => {
      let tile = render(doc(p('a')))
      tile = update(tile, {
        effects: GardState.appendConfig.of(Decoration.Tag.shape(Paragraph, Elt.mk('para', [0])))
      })
      ist(tile.dom.innerHTML, '<para>a</para>')
    })

    it('properly updates when positional shapes change', () => {
      let tile = render(doc(p('a')))
      tile = update(tile, {
        effects: GardState.appendConfig.of(
          Decoration.Point.source.of(_state => {
            return Decoration.Point.set([[Decoration.Point.shape(Elt.mk('para')), 0]])
          })
        )
      })
      ist(tile.dom.innerHTML, `<para${uned}></para>`)
    })

    it('supports dynamic shapes', () => {
      const cls = GardState.Facet.define<string>()
      let called = 0
      let tile = render(doc(hr), [
        Decoration.Tag.shape.derived(HorizontalRule.type, state => {
          called++
          return Elt.mk('hr', { class: state.facet(cls)[0]! })
        }),
        cls.of('a')
      ])
      tile = update(tile, { selection: { anchor: 1 } })
      ist(tile.dom.innerHTML, `<hr class="a">`)
      ist(called, 1)
      tile = update(tile, { effects: GardState.appendConfig.of(GardState.prec.high(cls.of('b'))) })
      ist(tile.dom.innerHTML, `<hr class="b">`)
    })

    it('can change the shape of element marks', () => {
      ist(
        render(doc(p(strong('ab'))), Decoration.Mark.shape(Strong, { element: 'b' })).dom.innerHTML,
        '<p><b>ab</b></p>'
      )
    })

    it('can change the shape of attribute marks', () => {
      const deco = Decoration.Mark.shape(ImageAlt, { attribute: 'aria-description', value: 0 })
      ist(render(doc(p(imgAlt('p', $img))), deco).dom.innerHTML, `<p><img aria-description="p" src="test.png"></p>`)
    })
  })
})
