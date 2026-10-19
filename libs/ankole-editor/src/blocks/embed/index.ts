import { Elt, Leaf, Mark, Node, Plot, Schema } from '../../core/doc'
import { Decoration } from '../../core/editor'
import { element } from '../../document/tree'
import { Attrs, extraAttrs, extraOf, markSet, markValue } from '../../editor/attributes'
import type { BlockDefinition } from '../../editor/block'
import { insertBlock } from '../../editor/block-insert'

/**
 * `embed`: a block that shows content that another page owns. `ref` names that page. A database
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

/** `table` of a database embed. */
export const EmbedTable = Mark.Type.define<string>('EmbedTable', {
  target: Embed,
  validate: 'string',
  shape: { attribute: 'data-table', value: 0 }
})

/** `view` of a database embed. */
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
export function embedCard(attrs: Record<string, string>): Elt<string> {
  return Elt.mk('div', { class: 'embed', contenteditable: 'false' }, [
    Elt.mk('span', [attrs.table === undefined ? '嵌入' : '数据库']),
    Elt.mk('code', [attrs.ref ?? '未关联'])
  ])
}

export const embed: BlockDefinition = {
  name: 'embed',
  type: Embed.type,
  schema: [Embed, EmbedRef, EmbedTable, EmbedView, Schema.Override.markTarget(Attrs, target => [target, Embed])],
  extension: [Decoration.Tag.shape(Embed, tag => embedCard({ ...extraOf(tag), ...embedAttributes(tag) }))],
  import: node =>
    Embed.withMarks(
      markSet([
        ...names.map(name => node.attrs[name] !== undefined && types[name].of(node.attrs[name])),
        extraAttrs(node.attrs, names)
      ])
    ),
  read: node => element('embed', { ...extraOf(node), ...embedAttributes(node) }),
  insert: {
    title: '嵌入',
    detail: '引用另一个页面',
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
