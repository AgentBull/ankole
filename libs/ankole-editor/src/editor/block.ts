import type { Node, Plot, Schema } from '../core/doc'
import type { Wordgard } from '../core/editor'
import type { GardState } from '../core/state'
import type { Element, Node as PageNode } from '../document/tree'

/** Imports the child elements of a block element. */
export type BlockImport = { blocks(nodes: readonly PageNode[]): Node[] }
/** Reads the children of a block node as page nodes. */
export type BlockRead = { children(node: Plot): PageNode[] }

export type BlockInsert = {
  title: string
  detail: string
  /** Search aliases, kept out of the visible menu description. */
  keywords?: string
  glyph: string
  /** The block can replace the text block at the caret. */
  turnInto: boolean
  insert(wg: Wordgard): void
}

/**
 * A block element with its own node type. The definition owns the node type and its marks, its
 * editing behavior, the conversion between the page element and the node, and the menu entry.
 * Elements without a definition use the core conversion or show as read-only elements.
 */
export type BlockDefinition = {
  name: string
  /** The node type that holds the element. */
  type: Node.Type
  /** Node types, marks and overrides that the block adds to the schema. */
  schema: readonly Schema.Element[]
  extension: GardState.Extension
  import(element: Element, context: BlockImport): Node
  read(node: Node, context: BlockRead): Element
  insert: BlockInsert
}
