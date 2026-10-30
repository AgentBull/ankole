import type { Node, Plot } from '../core/doc'

/**
 * The position before the block with `tag`, or null when the document no longer holds it. Tags are
 * immutable, so a rendered widget can find its block after the document has moved or changed.
 */
export function blockPosition(doc: Plot.Doc, tag: Node.Tag): number | null {
  let found: number | null = null
  doc.iterate((node, pos) => {
    if (found !== null) return false
    if (node.tag === tag) {
      found = pos
      return false
    }
  })
  return found
}
