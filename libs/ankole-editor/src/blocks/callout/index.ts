import { editorPhrases } from '../../editor/phrases'
import { Mark, Node, parse, Plot, Schema, ValidationError } from '../../core/doc'
import { element } from '../../document/tree'
import { Attrs, extraAttrs, extraOf, markSet, markValue } from '../../editor/attributes'
import type { BlockDefinition } from '../../editor/block'
import { insertBlock } from '../../editor/block-insert'

const tones = ['info', 'warning'] as const
type Tone = (typeof tones)[number]

/** `callout`: a container of blocks with a tone. */
export const Callout = Plot.define('Callout', {
  blockContent: Node.Group.Content,
  group: Node.Group.Content,
  canBeEmpty: true,
  cursorBarrier: 'empty',
  defining: true,
  // Other `aside` elements in pasted HTML are not callouts.
  shape: { element: 'aside', selector: 'aside.callout', attributes: { class: 'callout' } }
})

/** `tone` of callout. */
export const CalloutTone = Mark.Type.define<Tone>('CalloutTone', {
  target: Callout,
  keepOnTypeChange: true,
  validate: value => {
    if (!tones.includes(value)) throw new ValidationError(`Expected a callout tone, got ${value}`)
  },
  shape: {
    attribute: 'data-tone',
    value: 0,
    readAttribute: value => (tones.includes(value as Tone) ? (value as Tone) : parse.Reject)
  }
})

export const callout: BlockDefinition = {
  name: 'callout',
  type: Callout.type,
  schema: [Callout, CalloutTone, Schema.Override.markTarget(Attrs, target => [target, Callout])],
  extension: [],
  import: (node, context) =>
    Callout.withMarks(
      markSet([
        node.attrs.tone !== undefined && CalloutTone.of(node.attrs.tone as Tone),
        extraAttrs(node.attrs, ['tone'])
      ])
    ).create(context.blocks(node.children)),
  read: (node, context) => {
    const tone = markValue(node, CalloutTone)
    return element('callout', { ...extraOf(node), ...(tone ? { tone } : {}) }, context.children(node as Plot))
  },
  insert: {
    title: editorPhrases.ref('callout_title'),
    detail: editorPhrases.ref('callout_detail'),
    keywords: 'callout',
    glyph: '◈',
    turnInto: true,
    insert: wg => insertBlock(wg, Callout.create([]))
  }
}
