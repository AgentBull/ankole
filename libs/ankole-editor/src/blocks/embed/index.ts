import { editorPhrases, type EditorLabels } from '../../editor/phrases'
import { Elt, Leaf, Mark, Node, Plot, Schema } from '../../core/doc'
import { Decoration } from '../../core/editor'
import { element } from '../../document/tree'
import { Attrs, extraAttrs, extraOf, markSet, markValue } from '../../editor/attributes'
import type { BlockDefinition } from '../../editor/block'
import { insertBlock } from '../../editor/block-insert'

/**
 * `embed`: a block that shows content that another page owns. `ref` names that page. A base
 * embed can also carry `table` and `view`. The page holds only the embed; the embedded page owns
 * its fields, records, and views.
 */
export const Embed = Leaf.define('Embed', {
  group: Node.Group.Content,
  selectable: true,
  shape: {
    element: 'div',
    // Other `div` elements in pasted HTML are not embeds.
    selector: 'div.embed',
    attributes: { class: 'embed', contenteditable: 'false' }
  }
})

/** `ref` of embed: the page that the embed shows. */
export const EmbedRef = Mark.Type.define<string>('EmbedRef', {
  target: Embed,
  validate: 'string',
  shape: { attribute: 'data-ref', value: 0 }
})

/** `table` of a base embed. */
export const EmbedTable = Mark.Type.define<string>('EmbedTable', {
  target: Embed,
  validate: 'string',
  shape: { attribute: 'data-table', value: 0 }
})

/** `view` of a base embed. */
export const EmbedView = Mark.Type.define<string>('EmbedView', {
  target: Embed,
  validate: 'string',
  shape: { attribute: 'data-view', value: 0 }
})

const names = ['ref', 'table', 'view'] as const
const types = { ref: EmbedRef, table: EmbedTable, view: EmbedView } as const

export function embedAttributes(node: Node | Plot.Tag): Record<string, string> {
  const attrs: Record<string, string> = {}
  for (const name of names) {
    const value = markValue(node, types[name])
    if (value !== undefined) attrs[name] = value
  }
  return attrs
}

/** The card that shows an embed, in the editor and in read-only elements. */
export function embedCard(
  attrs: Record<string, string>,
  labels: Pick<EditorLabels, 'embed' | 'base' | 'unlinked'> = editorPhrases.phrases
): Elt<string> {
  return Elt.mk('div', { class: 'embed', contenteditable: 'false' }, [
    Elt.mk('span', [attrs.table === undefined ? labels.embed : labels.base]),
    Elt.mk('code', [attrs.ref ?? labels.unlinked])
  ])
}

export const embed: BlockDefinition = {
  name: 'embed',
  type: Embed.type,
  schema: [Embed, EmbedRef, EmbedTable, EmbedView, Schema.Override.markTarget(Attrs, target => [target, Embed])],
  extension: [
    Decoration.Tag.shape.derived(Embed.type, state => {
      const labels = {
        embed: editorPhrases.get(state, 'embed'),
        base: editorPhrases.get(state, 'base'),
        unlinked: editorPhrases.get(state, 'unlinked')
      }
      return tag => embedCard({ ...extraOf(tag), ...embedAttributes(tag) }, labels)
    })
  ],
  import: node =>
    Embed.withMarks(
      markSet([
        ...names.map(name => node.attrs[name] !== undefined && types[name].of(node.attrs[name])),
        extraAttrs(node.attrs, names)
      ])
    ),
  read: node => element('embed', { ...extraOf(node), ...embedAttributes(node) }),
  insert: {
    title: editorPhrases.ref('embed_title'),
    detail: editorPhrases.ref('embed_detail'),
    keywords: 'embed',
    glyph: '⧉',
    turnInto: false,
    insert: wg => insertBlock(wg, Embed)
  }
}

/** Insert a reference where the user is working, with the normal block insertion rules. */
export function insertEmbed(editor: import('../../core/editor').Wordgard, attrs: Record<string, string>) {
  if (editor.state.readOnly) return
  insertBlock(editor, embed.import(element('embed', attrs), { blocks: () => [] }))
}
