import { describe, it } from 'bun:test'
import ist from 'ist'
import { Plot, Leaf, Mark, Node, Schema } from '../../src/core/doc'
import { Paragraph, CodeBlock, Blockquote, Strong, Image } from '../../src/core/types'
import { basicBuilders, basicSchema, builder } from './schema'
const { doc, p, strong, $img } = basicBuilders

describe('Schema', () => {
  it('allow querying of valid content', () => {
    ist(basicSchema.canContain(Paragraph.type, Image))
    ist(!basicSchema.canContain(Paragraph.type, Blockquote.type))
  })

  it('allows querying valid mark target', () => {
    ist(basicSchema.markAllowed(Strong.type, Leaf.Text))
    ist(!basicSchema.markAllowed(Strong.type, Paragraph.type))
  })

  it('can determine whether plots share content', () => {
    ist(basicSchema.sharesContent(Paragraph.type, CodeBlock.type))
    ist(!basicSchema.sharesContent(Paragraph.type, Blockquote.type))
  })

  it('finds default content plot type', () => {
    ist(basicSchema.defaultContentPlot(Blockquote.type), Paragraph)
    ist(basicSchema.defaultContentPlot(Paragraph.type), null)
  })

  it('can match node types to group queries', () => {
    ist(basicSchema.matchNode(Paragraph.type, Node.Group.Textblock))
    ist(basicSchema.matchNode(Paragraph.type, Node.Group.Content))
    ist(!basicSchema.matchNode(Paragraph.type, Node.Group.Inline))
    ist(basicSchema.matchNode(Paragraph.type, [Node.Group.Inline, Node.Group.Textblock]))
    ist(!basicSchema.matchNode(Paragraph.type, { and: [Node.Group.Inline, Node.Group.Textblock] }))
    ist(basicSchema.matchNode(Paragraph.type, Paragraph))
    ist(!basicSchema.matchNode(Paragraph.type, Image))
  })

  it('supports overriding mark targets', () => {
    const s = Schema.define([
      Paragraph,
      Strong,
      Plot.defineDoc({ blockContent: Paragraph }),
      Schema.Override.markTarget(Strong, Paragraph)
    ])
    ist(builder(s)(strong(p('hi'))).toString(), 'Doc(Paragraph[Strong]("hi"))')
    ist.throws(() => builder(s)(p(strong('hi'))))
  })

  it('supports overriding plot content', () => {
    const s = Schema.define([
      Paragraph,
      Image,
      Plot.defineDoc({ blockContent: Paragraph }),
      Schema.Override.plotContent(Paragraph, Leaf.Text)
    ])
    builder(s)(p('hi'))
    ist.throws(() => builder(s)(p($img)))
  })

  describe('validate', () => {
    it('checks for tags not in the schema', () => {
      const Stranger = Plot.define('Stranger', {
        group: Node.Group.Content,
        inlineContent: true,
        shape: { element: 'div' }
      })
      ist.throws(() => doc(Stranger.create()), /cannot contain/)
    })

    it('checks for marks not in the schema', () => {
      const Odd = Mark.define('Odd', { target: Node.Group.Content, shape: { attribute: 'odd', value: 'yes' } })
      const odd = builder(Odd)
      ist.throws(() => doc(odd(p())), /not in schema/)
    })
  })
})
