import { Wordgard } from '../core/editor'
import { validateKnowledge } from '../document/knowledge'
import { readTree } from './convert'
import { isKnowledge, knowledgeFacet } from './knowledge-context'

export { isKnowledge }
export const knowledgeExtension = [
  knowledgeFacet.of(true),
  Wordgard.transactionGuard.of(transactions => {
    if (transactions.some(transaction => transaction.docChanged)) {
      validateKnowledge(readTree(transactions.at(-1)!.newDoc))
    }
  })
]

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
