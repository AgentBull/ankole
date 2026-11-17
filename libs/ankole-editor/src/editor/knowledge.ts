import { Leaf, type Node, type Plot, Slice, Token } from '../core/doc'
import { Wordgard } from '../core/editor'
import * as T from '../core/types'
import { InfographicBlock } from '../blocks/infographic'
import { InlineMath, MathBlock } from '../blocks/math/leaf'
import { MermaidBlock } from '../blocks/mermaid'
import { validateKnowledge } from '../document/knowledge'
import { codeNodes, markSet } from './attributes'
import { readTree } from './convert'
import { isKnowledge, knowledgeFacet } from './knowledge-context'
import { Link } from './schema'

export { isKnowledge }
export const knowledgeExtension = [
  knowledgeFacet.of(true),
  Wordgard.transactionGuard.of(transactions => {
    if (transactions.some(transaction => transaction.docChanged)) {
      validateKnowledge(readTree(transactions.at(-1)!.newDoc))
    }
  })
]

function downgradeKnowledgeTag(tag: Plot.Tag): Plot.Tag {
  if (tag.type === MermaidBlock.type) {
    return tag.marks.length ? MermaidBlock.withMarks([]) : tag
  }
  if (tag.type === InfographicBlock.type) {
    return T.CodeBlock.withMarks([T.CodeBlockLanguage.of('infographic')])
  }
  return tag
}

function downgradeKnowledgeNode(node: Node): Node | null {
  if (node.isLeaf) {
    if (node.type === MathBlock) {
      return T.CodeBlock.withMarks([T.CodeBlockLanguage.of('math')]).create(codeNodes((node as Leaf<string>).param))
    }
    if (node.type === InlineMath) {
      const value = (node as Leaf<string>).param
      if (!value) return null
      const keptMarks = node.marks.filter(
        mark =>
          mark.type === T.Strong.type ||
          mark.type === T.Emphasis.type ||
          mark.type === T.Strikethrough.type ||
          mark.type === Link
      )
      return Leaf.text(value, markSet([T.Code, ...keptMarks]))
    }
    return node
  }
  const tag = downgradeKnowledgeTag(node.tag)
  const content = node.content.flatMap(child => {
    const next = downgradeKnowledgeNode(child)
    return next ? [next] : []
  })
  return tag === node.tag &&
    content.length === node.content.length &&
    content.every((child, i) => child === node.content[i])
    ? node
    : tag.create(content)
}

/**
 * Downgrade cross-page diagram and formula nodes pasted into a knowledge editor so display-only
 * Mermaid marks are stripped, `<infographic>` / `<math>` blocks become `<pre lang="…">`, and
 * `<inline-math>` becomes `<code>` preserving source text.
 */
export function downgradeKnowledgeSlice(slice: Slice): Slice {
  const content = slice.content.flatMap((token): Token[] => {
    if (token.tokenType === Token.Type.Open) return [downgradeKnowledgeTag(token)]
    if (token.tokenType === Token.Type.Close) return [token]
    const downgraded = downgradeKnowledgeNode(token as Node)
    return downgraded ? [downgraded] : []
  })
  const context = slice.context.map(downgradeKnowledgeTag)
  return Slice.of(content, context)
}

export const knowledgeBlockTypes = new Set([
  'paragraph',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'table',
  'bullet',
  'number',
  'check',
  'quote',
  'code',
  'divider',
  'mention',
  'callout',
  'media',
  'mermaid'
])
