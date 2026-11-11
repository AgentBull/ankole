import type { Element } from './tree'

export const knowledgeAttributes: Readonly<Record<string, readonly string[]>> = {
  page: [],
  p: [],
  h1: [],
  h2: [],
  h3: [],
  h4: [],
  h5: [],
  h6: [],
  strong: [],
  em: [],
  s: [],
  code: [],
  br: [],
  hr: [],
  blockquote: [],
  ul: [],
  mermaid: [],
  table: [],
  tr: [],
  a: ['href', 'title'],
  img: ['src', 'alt', 'title'],
  ol: ['start'],
  li: ['task'],
  pre: ['lang', 'meta'],
  callout: ['tone', 'icon'],
  th: ['align'],
  td: ['align'],
  media: ['src', 'title', 'description', 'kind'],
  mention: ['page', 'principal']
}

/**
 * Validates that a normalized page tree belongs to the lossless knowledge vocabulary shared
 * with the kernel codec, including plain `<mermaid>` diagrams without display attributes.
 */
export function validateKnowledge(tree: Element): Element {
  const allowed = knowledgeAttributes[tree.name]
  if (!allowed) throw new Error(`Knowledge pages do not support <${tree.name}>.`)
  for (const key of Object.keys(tree.attrs)) {
    if (!allowed.includes(key)) throw new Error(`Knowledge pages do not support ${tree.name}.${key}.`)
  }
  if (tree.name === 'media' && tree.attrs.kind && tree.attrs.kind !== 'image') {
    throw new Error('Knowledge media must be an image.')
  }
  if (tree.name === 'table') {
    const rows = tree.children.filter((child): child is Element => child.type === 'element')
    const width = rows[0]?.children.length
    if (!width) throw new Error('Knowledge tables need a header row.')
    rows.forEach((row, index) => {
      if (row.children.length !== width) throw new Error('Knowledge tables must be rectangular.')
      for (const cell of row.children) {
        if (
          cell.type === 'text' ||
          cell.name !== (index === 0 ? 'th' : 'td') ||
          cell.children.length !== 1 ||
          cell.children[0]?.type === 'text' ||
          cell.children[0]?.name !== 'p'
        ) {
          throw new Error('Knowledge tables use one header row and one paragraph per cell.')
        }
      }
    })
  }
  for (const child of tree.children) if (child.type === 'element') validateKnowledge(child)
  return tree
}
