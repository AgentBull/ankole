import { Elt, Leaf, Mark, Node, Schema } from '../../core/doc'
import { Decoration } from '../../core/editor'
import { element } from '../../document/tree'
import { Attrs, extraAttrs, extraOf, markSet, markValue } from '../../editor/attributes'
import type { BlockDefinition } from '../../editor/block'
import { insertBlock } from '../../editor/block-insert'

/**
 * `database`: a reference to a database. The page holds only the reference; the database owns its
 * fields, records and views. The editor shows a placeholder card.
 */
export const Database = Leaf.define('Database', {
  group: Node.Group.Content,
  selectable: true,
  shape: {
    element: 'div',
    // Other `div` elements in pasted HTML are not references.
    selector: 'div.database-reference',
    attributes: { class: 'database-reference', contenteditable: 'false' }
  }
})

/** `ref` of database. */
export const DatabaseRef = Mark.Type.define<string>('DatabaseRef', {
  target: Database,
  validate: 'string',
  shape: { attribute: 'data-ref', value: 0 }
})

/** The card that shows a reference, in the editor and in read-only elements. */
export function databaseCard(ref: string | undefined): Elt<string> {
  return Elt.mk('div', { class: 'database-reference', contenteditable: 'false' }, [
    Elt.mk('span', ['数据库']),
    Elt.mk('code', [ref ?? '未关联'])
  ])
}

export const database: BlockDefinition = {
  name: 'database',
  type: Database.type,
  schema: [Database, DatabaseRef, Schema.Override.markTarget(Attrs, target => [target, Database])],
  extension: [Decoration.Tag.shape(Database, tag => databaseCard(markValue(tag, DatabaseRef)))],
  import: node =>
    Database.withMarks(
      markSet([node.attrs.ref !== undefined && DatabaseRef.of(node.attrs.ref), extraAttrs(node.attrs, ['ref'])])
    ),
  read: node => {
    const ref = markValue(node, DatabaseRef)
    return element('database', { ...extraOf(node), ...(ref !== undefined ? { ref } : {}) })
  },
  insert: {
    title: '数据库',
    detail: '数据库占位 · database',
    glyph: '▦',
    turnInto: false,
    insert: wg => insertBlock(wg, Database)
  }
}
