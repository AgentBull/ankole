import { describe, it } from './runner'
import ist from 'ist'
import { Plot, Leaf, Mark, Slice, type Token, Schema, Elt, serialize, parse } from '../../../src/core/doc'
import { Paragraph, Heading, Figure, CaptionedFigure, Strikethrough, Underline } from '../../../src/core/types'
import { basicBuilders, builder, basicSchema, tag, eq } from '../schema'
const { doc, blockquote, p, em, strong, code, img, $img, imgAlt, fig, capFig, olStart, ul, li, pre, h1, h2, br, hr } =
  basicBuilders

function html(doc: Plot.Doc) {
  const wrap = document.createElement('div')
  wrap.appendChild(serialize(doc).toDOM())
  return wrap.innerHTML
}

function istHTML(doc: Plot.Doc, expected: string) {
  ist(html(doc), expected)
  ist(serialize(doc).toHTML(), expected)
}

function istSliceHTML(doc: Plot.Doc, expected: string, options?: serialize.slice.Options & { maxDepth?: number }) {
  const wrap = document.createElement('div')
  const slice = doc.slice(tag(doc, 0), tag(doc, 1)),
    opts = {
      ...options,
      context: doc.contextAt(tag(doc, 0), options?.maxDepth)
    }
  const frag = serialize.slice(slice, opts)
  wrap.appendChild(frag.toDOM())
  ist(wrap.innerHTML, expected)
  ist(frag.toHTML(), expected)
}

describe('serialize', () => {
  it('can serialize simple nodes', () => {
    istHTML(doc(p('One'), blockquote(p('Two'))), '<p>One</p><blockquote><p>Two</p></blockquote>')
  })

  it('can serialize tag parameters', () => {
    istHTML(doc(p($img)), '<p><img src="test.png"></p>')
  })

  it('can serialize spanning marks', () => {
    istHTML(doc(p(em('One', strong(br, 'Two')))), '<p><em>One<strong><br>Two</strong></em></p>')
  })

  it('can serialize attribute marks', () =>
    Plot.Doc.noValidate(() => {
      const Pr = Mark.Type.define<string>('Pr', {
        target: Paragraph,
        shape: { attribute: 'data-p', value: 0 }
      })
      const pr = builder(Pr)
      istHTML(doc(pr('one', p('x'))), '<p data-p="one">x</p>')
    }))

  it('can serialize style marks', () =>
    Plot.Doc.noValidate(() => {
      const Ul = Mark.define('Ul', {
        target: Leaf.Text,
        spanning: true,
        shape: { attribute: 'style/text-decoration', value: () => 'underline', readAttribute: () => null }
      })
      const ul = builder(Ul)
      istHTML(doc(p(ul('one'))), '<p><span style="text-decoration: underline">one</span></p>')
    }))

  it('can serialize targeted marks', () =>
    Plot.Doc.noValidate(() => {
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
      istHTML(doc(p(alt('x', img))), '<p><span class="my-img"><img alt="x" src="/x.webp"></span></p>')
    }))

  it('can serialize marks that add multiple attributes', () =>
    Plot.Doc.noValidate(() => {
      const M = Mark.Type.define<string>('M', {
          spanning: true,
          shape: { attributes: p => ({ 'data-value': p, class: 'm' }) }
        }),
        m = builder(M)
      istHTML(doc(p(m('??', 'hello'))), '<p><span class="m" data-value="??">hello</span></p>')
    }))

  it('serializes heading levels', () => {
    istHTML(doc(h1('One'), h2('Two')), '<h1>One</h1><h2>Two</h2>')
  })

  it('serializes line breaks in whitespace-preserving nodes', () => {
    istHTML(doc(p('a', br, 'b'), pre('a', br, 'b')), '<p>a<br>b</p><pre>a\nb</pre>')
  })
})

describe('serializeSlice', () => {
  it('can serialize a simple slice', () => {
    istSliceHTML(doc(0, p('One'), p('Two'), 1), '<p>One</p><p>Two</p>')
  })

  it('can serialize an open slice', () => {
    istSliceHTML(doc(h1(0, 'One'), p('Two', 1)), '<h1>One</h1><p>Two</p>')
  })

  it('can serialize a slice with deeper open sides', () => {
    istSliceHTML(
      doc(ul(li(p(0, 'A'))), blockquote(p('B', 1))),
      '<ul><li><p>A</p></li></ul><blockquote><p>B</p></blockquote>'
    )
  })

  it('can mark open nodes', () => {
    istSliceHTML(
      doc(p(0, 'a'), blockquote(p('b', 1))),
      '<p open="start">a</p><blockquote open="end"><p open="end">b</p></blockquote>',
      { openAttr: 'open' }
    )
  })

  it('can include extra context', () => {
    istSliceHTML(
      doc(blockquote(ul(li(p(0, 'a')), li(p('b'), 1)))),
      '<ul open="start end"><li open="start"><p open="start">a</p></li><li open="end"><p>b</p></li></ul>',
      { openAttr: 'open', maxDepth: 3, includeContext: 3 }
    )
  })
})

function parseDoc(html: string, options: parse.Options & { schema?: Schema } = {}) {
  const wrap = document.implementation.createHTMLDocument('').createElement('div')
  wrap.innerHTML = html
  return parse(options.schema || basicSchema, wrap, options)
}

describe('parse', () => {
  it('can parse simple content', () => {
    ist(parseDoc('<p>Ok</p>'), doc(p('Ok')), eq)
  })

  it('can parse nested nodes', () => {
    ist(
      parseDoc('<ul><li><p>A</p></li><li><blockquote><p>B</p></blockquote></li></ul>'),
      doc(ul(li(p('A')), li(blockquote(p('B'))))),
      eq
    )
  })

  it('can parse nodes with params', () => {
    ist(
      parseDoc("<p><img src='x.png'></p><ol start=3><li><p>Three</p></li></ol>"),
      doc(p(img('x.png')), olStart(3, li(p('Three')))),
      eq
    )
  })

  it('can parse marks', () => {
    ist(
      parseDoc('<p><em>one <strong>two</strong> <code>three</code></em> four</p>'),
      doc(p(em('one ', strong('two'), ' ', code('three')), ' four')),
      eq
    )
  })

  it('will add wrapper nodes', () => {
    ist(parseDoc('A'), doc(p('A')), eq)
    ist(parseDoc('<li>A</li>'), doc(ul(li(p('A')))), eq)
  })

  it('parses line breaks in code blocks as break nodes', () => {
    ist(parseDoc('<pre>a\n\nb</pre>'), doc(pre('a', br, br, 'b')), eq)
  })

  it('preserves whitespace in code blocks', () => {
    ist(parseDoc('<pre>one  two\n  three</pre>'), doc(pre('one  two', br, '  three')), eq)
  })

  it('collapses whitespace', () => {
    ist(parseDoc('<p>  \none   \n two  </p>\n  <p>three</p>'), doc(p('one two'), p('three')), eq)
  })

  it('can disable whitespace collapsing', () => {
    ist(parseDoc('<p>  \none \n two  </p>', { collapseWhiteSpace: false }), doc(p('   one   two  ')), eq)
  })

  it('parses heading levels', () => {
    ist(parseDoc('<h1>One</h1><h2>Two</h2>'), doc(h1('One'), h2('Two')), eq)
  })

  it('ignores non-content tags', () => {
    ist(parseDoc('<title>T</title><p>P</p><script>S</script>'), doc(p('P')), eq)
  })

  it('parses style properties', () => {
    ist(
      parseDoc("<p style='font-weight: bold'><span style='font-style: italic'>A</span>B</p>"),
      doc(p(strong(em('A'), 'B'))),
      eq
    )
  })

  it('clears marks via style properties', () => {
    ist(
      parseDoc("<p><strong>a<span style='font-weight: normal'>b</span>c</strong></p>"),
      doc(p(strong('a'), 'b', strong('c'))),
      eq
    )
  })

  it('ignores a break that only keeps an empty line visible', () => {
    ist(
      parseDoc('<p>a<br></p><p><br></p><div>b<br> </div><p>a</p><br><p>b</p>'),
      doc(p('a'), p(), p('b'), p('a'), p(), p('b')),
      eq
    )
  })

  it('keeps breaks that end a line of text', () => {
    ist(
      parseDoc('a<br>b<p><strong>c<br></strong></p>d<br><p>e</p>'),
      doc(p('a', br, 'b'), p(strong('c', br)), p('d', br), p('e')),
      eq
    )
  })

  it('parses b, i, del and strike', () => {
    const schema = Schema.define(basicSchema.elements.concat([Strikethrough]))
    const { doc, p } = { doc: builder(schema), p: builder(Paragraph) }
    const s = builder(Strikethrough)
    ist(
      parseDoc('<p><b>a</b><i>b</i><del>c</del><strike>d</strike></p>', { schema }),
      doc(p(strong('a'), em('b'), s('cd'))),
      eq
    )
  })

  it('does not read b with a normal weight as strong', () => {
    ist(parseDoc('<b style="font-weight: normal"><p>a</p></b>'), doc(p('a')), eq)
  })

  it('reads only bold and 700 as bold weights', () => {
    ist(
      parseDoc(
        ['bold', '700', '500', '600', '800', 'bolder']
          .map(w => `<span style="font-weight: ${w}">${w[0]}</span>`)
          .join('')
      ),
      doc(p(strong('b7'), '568b')),
      eq
    )
  })

  it('reads several text decoration lines', () => {
    const schema = Schema.define(basicSchema.elements.concat([Strikethrough]))
    const { doc, p } = { doc: builder(schema), p: builder(Paragraph) }
    const s = builder(Strikethrough),
      u = builder(Underline)
    ist(
      parseDoc('<p><span style="text-decoration: underline line-through">a</span></p>', { schema }),
      doc(p(u(s('a')))),
      eq
    )
  })

  it('reads vertical alignment as subscript and superscript', () => {
    const doc = parseDoc(
      '<p><span style="vertical-align: sub">a</span><span style="vertical-align: super">b</span></p>'
    )
    ist(
      (doc.content[0] as Plot).content.map(node => node.marks.map(mark => mark.name).join()).join(' '),
      'Subscript Superscript'
    )
  })

  it('can parse marks with pass-through attributes', () => {
    ist(parseDoc("<p><img alt=x src='test.png'></p>"), doc(p(imgAlt('x', img('test.png')))), eq)
  })

  it('joins text nodes', () => {
    ist(parseDoc('<p>a<span>b</span></p>'), doc(p('ab')), eq)
  })

  it('uses parse rule precedence', () => {
    const rules = parse.Rule.Set.of([
      { selector: 'p', tag: Paragraph },
      { selector: 'p.h', tag: Heading.of(1), precedence: 2 }
    ])
    ist(parseDoc('<p class=h>H</p>', { ruleSet: rules }), doc(h1('H')), eq)
  })

  it('can parse different image types', () => {
    const schema = Schema.define(basicSchema.elements.concat([Figure, CaptionedFigure]))
    const doc = builder(schema)
    const html = `<p>Img: <img src=test.png></p>
<figure><img src=test.png></figure>
<figure><img src=test.png><figcaption>Caption</figcaption></figure>`
    ist(
      parseDoc(html, { schema }),
      doc(p('Img: ', img('test.png')), fig('test.png'), capFig('test.png', 'Caption')),
      eq
    )
  })
})

describe('parse.slice', () => {
  function parseSlice(html: string, options: parse.Options & { schema?: Schema } = {}) {
    const wrap = document.implementation.createHTMLDocument('').createElement('div')
    wrap.innerHTML = html
    return parse.slice(options.schema || basicSchema, wrap, options)
  }

  function slice(children: (string | Token)[]) {
    return Slice.of(children.map(ch => (typeof ch == 'string' ? Leaf.text(ch) : ch)))
  }

  it('can parse a simple slice', () => {
    ist(parseSlice('<p>One</p><p>Two</p>').slice, slice(['One', Plot.End, p().tag, 'Two']), eq)
  })

  it('can parse text at the top level', () => {
    ist(parseSlice('hello').slice, slice(['hello']), eq)
  })

  it("doesn't trim text at the top level", () => {
    ist(parseSlice('  hello  ', { collapseWhiteSpace: false }).slice, slice(['  hello  ']), eq)
  })

  it('opens nested nodes', () => {
    ist(parseSlice('<ul><li><p>One</p></li></ul>').slice, slice(['One']), eq)
  })

  it("doesn't open leaf nodes", () => {
    ist(parseSlice('<hr><p>A<br></p>').slice, slice([hr, p().tag, 'A', br]), eq)
  })

  function isOpen(elt: Element): 'start' | 'end' | 'start end' | null {
    const start = elt.hasAttribute('open-start'),
      end = elt.hasAttribute('open-end')
    return start ? (end ? 'start end' : 'start') : end ? 'end' : null
  }

  it('can query the DOM for open structure', () => {
    ist(
      parseSlice('<blockquote open-start=true open-end=true><p open-end=true>hi</p></blockquote>', { isOpen }).slice,
      slice([p().tag, 'hi']),
      eq
    )
  })

  it('creates a block parent when seeing multiple unmatched block elements', () => {
    ist(parseSlice('<div>a</div><div>b</div>').slice, slice(['a', Plot.End, p('b')]), eq)
  })

  it('does not prefer an inline parent because of many inline nodes', () => {
    ist(
      parseSlice('<div><span>a</span><span>b</span><span>c</span><div>d</div></div>').slice,
      slice(['abc', Plot.End, p('d')]),
      eq
    )
  })

  it('does not prefer a list parent because of many list items', () => {
    ist(
      parseSlice('<li>a</li><li>b</li><p>c</p>').slice,
      slice(['a', Plot.End, Plot.End, li(p('b')), Plot.End, p().tag, 'c']),
      eq
    )
  })

  it('drops spaces at the edges of nested blocks', () => {
    ist(parseSlice('<ul><li> a </li><li> b </li></ul>').slice, slice(['a', Plot.End, Plot.End, li().tag, p('b')]), eq)
  })

  it('keeps spaces at the edges of a top-level block', () => {
    ist(parseSlice('<p> world </p>').slice, slice([' world ']), eq)
  })

  it('does not start a block for an element with an inline display', () => {
    ist(parseSlice('<span>a</span><div style="display: inline">b</div>').slice, slice(['ab']), eq)
  })
})
