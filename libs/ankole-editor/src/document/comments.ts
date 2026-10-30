import { element, type Element, type Node } from './tree'

/** Thread identifiers use the Page comment domain's UUIDv7 format. */
export const commentIDPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

export function commentIDs(value: string): string[] {
  const ids = value.split(' ')
  if (!ids.length || ids.some(id => !commentIDPattern.test(id))) throw new Error('Invalid comment thread identifiers')
  return [...new Set(ids)].sort()
}

/** Portable content and historical snapshots exclude live discussion anchors. */
export function stripComments(root: Element): Element {
  const children = (nodes: readonly Node[]): Node[] =>
    nodes.flatMap(node =>
      node.type === 'text'
        ? [node]
        : node.name === 'comment'
          ? children(node.children)
          : [element(node.name, node.attrs, children(node.children))]
    )
  return element(root.name, root.attrs, children(root.children))
}
