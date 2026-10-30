import { Node, Plot, Slice, Token } from '../core/doc'
import type { Wordgard } from '../core/editor'
import { GardSelection, GardState, Transaction } from '../core/state'
import { Comment, Mention } from './schema'
import { markValue } from './attributes'

export type CommentSelection = { from: number; to: number; quote: string }
export type CommentRange = { id: string; from: number; to: number }

type Range = { from: number; to: number }
type DraftSelection = { identity: object; ranges: Range[] }
const capture = Transaction.Effect.define<DraftSelection>()

/** Draft anchors follow source tokens; removing any selected content requires a new selection. */
export const commentDraftSelection = GardState.Field.define<DraftSelection | null>({
  create: () => null,
  update(value, transaction) {
    for (const effect of transaction.effects) if (effect.is(capture)) return effect.value
    if (!value || !transaction.docChanged) return value
    const ranges: Range[] = []
    transaction.changes.iterGaps((fromA, toA, fromB) => {
      for (const range of value.ranges) {
        const from = Math.max(fromA, range.from)
        const to = Math.min(toA, range.to)
        if (from >= to) continue
        const mapped = { from: fromB + from - fromA, to: fromB + to - fromA }
        const previous = ranges.at(-1)
        if (previous?.to === mapped.from) previous.to = mapped.to
        else ranges.push(mapped)
      }
    })
    const size = (items: Range[]) => items.reduce((length, range) => length + range.to - range.from, 0)
    if (size(ranges) !== size(value.ranges)) return null
    return { identity: value.identity, ranges }
  }
})

const commentLeafText = (leaf: { type: unknown }) => (leaf.type === Mention ? '@' : '')

/** The reader becomes invalid when selected source is removed or another selection is captured. */
export function trackCommentSelection(editor: Pick<Wordgard, 'state' | 'dispatch'>, selection: CommentSelection) {
  const identity = {}
  const ranges: Range[] = []
  editor.state.doc.iterate(selection.from, selection.to, (node, pos) => {
    if (node.isLeaf) ranges.push({ from: Math.max(selection.from, pos), to: Math.min(selection.to, pos + node.length) })
  })
  editor.dispatch({ effects: capture.of({ identity, ranges }) })
  return (state: GardState): CommentSelection | null => {
    const current = state.field(commentDraftSelection)
    if (current?.identity !== identity || !current.ranges.length) return null
    const from = current.ranges[0]!.from
    const to = current.ranges.at(-1)!.to
    const quote = Slice.of(state.doc.slice(from, to)).textContent({ blockSeparator: '\n', leafText: commentLeafText })
    return quote.trim() ? { from, to, quote } : null
  }
}

/** Capture the current visible selection without mutating the editor or the document. */
export function commentSelection(editor: Pick<Wordgard, 'state'>): CommentSelection | null {
  const { doc, selection } = editor.state
  if (selection.empty || selection.ranges.length !== 1) return null
  const { from, to } = selection
  const quote = Slice.of(doc.slice(from, to)).textContent({ blockSeparator: '\n', leafText: commentLeafText })
  return !quote.trim() ? null : { from, to, quote }
}

/** Every live segment, including noncontiguous parts of a thread that moved with selected text. */
export function commentRanges(editor: { state: { doc: Plot.Doc } }, id?: string): CommentRange[] {
  const ranges: CommentRange[] = []
  const latest = new Map<string, CommentRange>()
  editor.state.doc.iterate((node, from) => {
    if (!node.isLeaf) return
    for (const thread of markValue(node, Comment) ?? []) {
      if (id && thread !== id) continue
      const previous = latest.get(thread)
      if (previous?.to === from) previous.to += node.length
      else {
        const range = { id: thread, from, to: from + node.length }
        ranges.push(range)
        latest.set(thread, range)
      }
    }
  })
  return ranges
}

/** Select and scroll to a live anchor in either an editable document or a read-only preview. */
export function revealComment(editor: Wordgard, id: string): boolean {
  const range = commentRanges(editor, id)[0]
  if (!range) return false
  editor.dispatch({ selection: GardSelection.range(range.from, range.to), scrollIntoView: true })
  editor.focus()
  return true
}

/** Duplicates carry content, while moves carry the original thread marks. */
export function withoutCommentMarks(node: Node): Node {
  const marks = node.marks.filter(mark => mark.type !== Comment)
  if (node.isLeaf) return marks.length === node.marks.length ? node : node.withMarks(marks)
  const children = node.content.map(withoutCommentMarks)
  return node.tag.withMarks(marks).create(children)
}

export function withoutCommentSlice(slice: Slice): Slice {
  return Slice.of(
    slice.content.map(token =>
      token.tokenType === Token.Type.Close
        ? token
        : token.tokenType === Token.Type.Open
          ? (token as Plot.Tag).withMarks((token as Plot.Tag).marks.filter(mark => mark.type !== Comment))
          : withoutCommentMarks(token as Node)
    ),
    slice.context.map(tag => tag.withMarks(tag.marks.filter(mark => mark.type !== Comment)))
  )
}
