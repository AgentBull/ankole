import type { Parent, Root } from 'mdast'

/** Sentence punctuation ends a bare URL; explicit Markdown links keep their URL. */
export function cjkAutolinks() {
  return (tree: Root, file: { value: unknown }) => {
    const source = String(file.value)
    const visit = (parent: Parent) => {
      for (let index = 0; index < parent.children.length; index++) {
        const node = parent.children[index]!
        if (node.type === 'link' && node.children.length === 1 && node.children[0]?.type === 'text') {
          const text = node.children[0].value
          const start = node.position?.start.offset
          const end = node.position?.end.offset
          const boundary = text.search(/[，。；！？、：）】》」』]/)
          if (boundary > 0 && source.slice(start, end) === text && /^(https?:\/\/|www\.)/.test(text)) {
            const label = text.slice(0, boundary)
            parent.children.splice(
              index,
              1,
              {
                ...node,
                url: node.url.slice(0, node.url.length - text.length + boundary),
                children: [{ type: 'text', value: label }]
              },
              { type: 'text', value: text.slice(boundary) }
            )
            index++
            continue
          }
        }
        if ('children' in node) visit(node)
      }
    }
    visit(tree)
  }
}
