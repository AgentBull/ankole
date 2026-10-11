import { describe, it } from 'bun:test'
import ist from 'ist'
import { Plot, Leaf, Node } from '../../src/core/doc'
import { Paragraph, Image } from '../../src/core/types'
import { basicSchema as schema, basicBuilders, tag, eq } from './schema'
const { doc, blockquote, p, h1, li, ul, hr, em, strong, code, $img, $a } = basicBuilders

describe('Node', () => {
  describe('toString', () => {
    it('nests', () => {
      ist(
        doc(ul(li(p('hey'), p()), li(p('foo')))).toString(),
        'Doc(BulletList(ListItem(Paragraph("hey"),Paragraph()),ListItem(Paragraph("foo"))))'
      )
    })

    it('shows inline children', () => {
      ist(doc(p('foo', $img, 'bar')).toString(), 'Doc(Paragraph("foo",Image,"bar"))')
    })

    it('shows marks', () => {
      ist(
        doc(p('foo', em('bar', strong('quux')), code('baz'))).toString(),
        'Doc(Paragraph("foo","bar"[Emphasis],"quux"[Emphasis,Strong],"baz"[Code]))'
      )
    })
  })

  describe('iterate', () => {
    function iterate(doc: Plot, ...nodes: string[]) {
      let i = 0
      doc.iterate(tag(doc, 1), tag(doc, 2), (node, pos) => {
        if (i == nodes.length) throw new Error(`More nodes iterated than listed (${node.name})`)
        const compare = node.is(Leaf.Text) ? node.param : node.name
        if (compare != nodes[i++]) {
          throw new Error(`Expected ${JSON.stringify(nodes[i - 1])}, got ${JSON.stringify(compare)}`)
        }
        if (!node.isText && doc.nodeAt(pos) != node) {
          throw new Error(`Pos ${pos} does not point at node ${node} ${doc.nodeAt(pos)}`)
        }
      })
    }

    it('iterates over text', () => iterate(doc(p('foo', 1, 'bar', 2, 'baz')), 'Paragraph', 'foobarbaz'))

    it('descends multiple levels', () =>
      iterate(
        doc(blockquote(ul(li(p('f', 1, 'oo'))), p('b'), 2), p('c')),
        'Blockquote',
        'BulletList',
        'ListItem',
        'Paragraph',
        'foo',
        'Paragraph',
        'b'
      ))

    it('iterates over inline nodes', () =>
      iterate(
        doc(p(em('x'), 'f', 1, 'oo', em('bar', $img, strong('baz')), 'quux', code('xy', 2, 'z'))),
        'Paragraph',
        'foo',
        'bar',
        'Image',
        'baz',
        'quux',
        'xyz'
      ))
  })

  describe('textContent', () => {
    it('works with leafText', () => {
      const d = doc(p('foo', $img))
      ist(JSON.stringify(d.textContent({ leafText: '[LEAF]' })), JSON.stringify('foo[LEAF]'))
      ist(d.textContent({ leafText: _node => '[LEAF]' }), 'foo[LEAF]')
    })

    it('adds block separator around empty paragraphs', () => {
      ist(doc(p('one'), p(), p('two')).textContent({ blockSeparator: '\n\n' }), 'one\n\n\n\ntwo')
    })

    it('adds block separator around leaf nodes', () => {
      ist(doc(p('one'), hr, hr, p('two')).textContent(), 'one\n---\n---\ntwo')
    })

    it("doesn't duplicate separators for multiple opened blocks", () => {
      ist(doc(p('a'), blockquote(blockquote(p('b')))).textContent(), 'a\nb')
    })

    const BlockLeaf = Leaf.define('BlockLeaf', { group: Node.Group.Content, shape: { element: 'div' } })

    it("doesn't add block separator around non-rendered leaf nodes", () =>
      Plot.Doc.noValidate(() => {
        ist(blockquote(p('one'), BlockLeaf, BlockLeaf, p('two')).textContent(), 'one\ntwo')
      }))

    it('can take partial content', () => {
      ist(doc(p('one'), p('two')).textContent({ from: 2, to: 8 }), 'ne\ntw')
    })

    it("doesn't get confused by leading wrapper blocks", () => {
      ist(doc(blockquote(p('a'))).textContent(), 'a')
    })

    it('works on slices', () => {
      ist(
        doc(p('abc'), blockquote(p('def')))
          .slice(2, 9)
          .textContent(),
        'bc\nde'
      )
    })
  })

  describe('create', () => {
    it('fills params', () => {
      const i = Image.of('x.jpg')
      ist(i.param, 'x.jpg')
    })

    it('allows child nodes', () => {
      ist(schema.doc([Paragraph.create([Leaf.text('a')])]), doc(p('a')), eq)
    })

    it('disallows incorrect child nodes', () => {
      ist.throws(() => schema.doc([Paragraph.create([Paragraph.create()])]), /cannot contain child/)
    })
  })

  describe('toJSON', () => {
    function roundTrip(doc: Plot) {
      ist(schema.nodeFromJSON(doc.toJSON()), doc, eq)
    }

    it('can serialize a simple node', () => roundTrip(doc(p('foo'))))

    it('can serialize marks', () => roundTrip(doc(p('foo', em('bar', strong('baz')), ' ', $a('x')))))

    it('can serialize inline leaf nodes', () => roundTrip(doc(p('foo', em($img, 'bar')))))

    it('can serialize block leaf nodes', () => roundTrip(doc(p('a'), hr, p('b'), p())))

    it('can serialize nested nodes', () =>
      roundTrip(doc(blockquote(ul(li(p('a'), p('b')), li(p($img))), p('c')), p('d'))))

    it('complains about incorrect param types', () => {
      const json = doc(h1()).toJSON()
      json.content![0]!.param = 'huh'
      ist.throws(() => schema.nodeFromJSON(json), /Invalid heading level/)
    })

    it('complains about incorrect mark types', () => {
      const json = doc(p($a('hi'))).toJSON()
      json.content![0]!.content![0]!.marks!.Link = [1, 2, 3]
      ist.throws(() => schema.nodeFromJSON(json), /Expected value of type string/)
    })
  })
})
