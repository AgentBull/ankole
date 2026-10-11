import { Leaf, type Mark, type Node, type Plot } from '../src/core/doc'
import * as T from '../src/core/types'
import { markSet } from '../src/editor/attributes'
import * as S from '../src/editor/schema'
import type { TiptapNode } from './semantic'

const formats: Record<string, Mark> = { bold: T.Strong, italic: T.Emphasis, strike: T.Strikethrough, code: T.Code }

/** Build an editor document from upstream JSON. This path uses neither a Markdown parser nor the page tree. */
export function editorFixture(doc: TiptapNode): Plot.Doc {
  function inline(node: TiptapNode): Node {
    if (node.type === 'hardBreak') return T.LineBreak
    if (node.type !== 'text') throw new Error(`Unknown fixture node: ${node.type}`)
    const marks = (node.marks ?? []).map(mark => {
      if (mark.type === 'link') {
        const title = mark.attrs?.title
        return S.Link.of([
          ['href', String(mark.attrs?.href)],
          ...(title == null ? [] : [['title', String(title)] as const])
        ])
      }
      const format = formats[mark.type]
      if (!format) throw new Error(`Unknown fixture mark: ${mark.type}`)
      return format
    })
    return Leaf.text(node.text!, markSet(marks))
  }
  if (doc.type !== 'doc') throw new Error(`Unknown fixture node: ${doc.type}`)
  return S.schema.doc(
    (doc.content ?? []).map(node => {
      if (node.type !== 'paragraph') throw new Error(`Unknown fixture node: ${node.type}`)
      return T.Paragraph.create((node.content ?? []).map(inline))
    })
  )
}
