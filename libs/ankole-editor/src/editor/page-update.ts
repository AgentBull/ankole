import { ChangeSet, Leaf, type Mark, type Node, type Plot } from '../core/doc'
import { Transaction } from '../core/state'
import { printNormalizedXml } from '../document/xml'
import { checkSource } from '../document/tree'
import { normalizedPageDocument, readTree } from './convert'
import { commentRanges, withoutCommentMarks } from './comments'
import { Comment } from './schema'

// Documents are immutable. Reuse the guard's validated normal form at flush
// and for confirmed XML without keeping editor sessions alive.
const sources = new WeakMap<Plot.Doc, { tree: ReturnType<typeof readTree>; xml: string; canonical?: Plot.Doc }>()

/** @internal One validated source for one immutable editor document. */
export function validatedPageSource(document: Plot.Doc) {
  let source = sources.get(document)
  if (!source) {
    const tree = readTree(document)
    const xml = printNormalizedXml(tree)
    checkSource(xml, 'xml')
    source = { tree, xml }
    sources.set(document, source)
  }
  return source
}

/** Portable source omits thread IDs. Retain live anchors on content that the source edit keeps. */
export function portablePageChanges(before: Plot.Doc, after: Plot.Doc): ChangeSet {
  const changes: ChangeSet.Change[] = []
  diffChildren(before.content.map(withoutCommentMarks), after.content.map(withoutCommentMarks), 0, changes)
  const content = ChangeSet.create(before, changes)
  const retained: { from: number; to: number }[] = []
  content.iterGaps((from, to) => retained.push({ from, to }))
  const detached = commentRanges({ state: { doc: before } })
    .filter(range => !retained.some(gap => gap.from <= range.from && gap.to >= range.to))
    .map(({ id, from, to }) => ({ from, to, remove: Comment.of([id]) }))
  return ChangeSet.create(before, detached).compose(content)
}

/**
 * Prepare the final local transaction after input appenders and IME composition end.
 * Apply this transaction instead of the original, and submit its changes in the same batch.
 * The correction keeps the transaction's selection, effects, annotations, and undo boundary.
 */
export function preparePageUpdate(transaction: Transaction): Transaction {
  const source = validatedPageSource(transaction.newDoc)
  const canonical = (source.canonical ??= normalizedPageDocument(source.tree))
  if (canonical.eq(transaction.newDoc)) return transaction
  const corrections: ChangeSet.Change[] = []
  diffChildren(transaction.newDoc.content, canonical.content, 0, corrections)
  return transaction.startState.update(
    Transaction.merge(transaction.startState, transaction, {
      changes: ChangeSet.create(transaction.newDoc, corrections),
      sequential: true
    })
  )
}

function diffMarks(from: number, to: number, before: Mark.Set, after: Mark.Set): ChangeSet.Change[] {
  return [
    ...before.filter(mark => !after.some(other => mark.eq(other))).map(remove => ({ from, to, remove })),
    ...after.filter(mark => !before.some(other => mark.eq(other))).map(add => ({ from, to, add }))
  ]
}

/** Text can split or merge when N moves whitespace out of a format. Keep the text and its positions. */
function diffLeaves(before: readonly Node[], after: readonly Node[], from: number): ChangeSet.Change[] | null {
  const changes: ChangeSet.Change[] = []
  let left = 0,
    right = 0,
    leftOffset = 0,
    rightOffset = 0
  while (left < before.length && right < after.length) {
    const a = before[left]!,
      b = after[right]!
    if (!a.isLeaf || !b.isLeaf) return null
    const length = Math.min(a.length - leftOffset, b.length - rightOffset)
    if (a.isText && b.isText) {
      if (
        (a.param as string).slice(leftOffset, leftOffset + length) !==
        (b.param as string).slice(rightOffset, rightOffset + length)
      ) {
        return null
      }
    } else if (!a.tag.withMarks([]).eq(b.tag.withMarks([]))) return null
    changes.push(...diffMarks(from, from + length, a.marks, b.marks))
    from += length
    leftOffset += length
    rightOffset += length
    if (leftOffset === a.length) {
      left++
      leftOffset = 0
    }
    if (rightOffset === b.length) {
      right++
      rightOffset = 0
    }
  }
  return left === before.length && right === after.length ? changes : null
}

function diffText(before: Leaf, after: Leaf, from: number): ChangeSet.Change {
  const a = before.param as string,
    b = after.param as string
  let prefix = 0,
    suffix = 0
  if (before.marks.length === after.marks.length && before.marks.every((mark, i) => mark.eq(after.marks[i]!))) {
    while (prefix < a.length && prefix < b.length && a[prefix] === b[prefix]) prefix++
    if (splitsPair(a, prefix) || splitsPair(b, prefix)) prefix--
    while (
      suffix < a.length - prefix &&
      suffix < b.length - prefix &&
      a[a.length - suffix - 1] === b[b.length - suffix - 1]
    ) {
      suffix++
    }
    if (splitsPair(a, a.length - suffix) || splitsPair(b, b.length - suffix)) suffix--
  }
  const text = b.slice(prefix, b.length - suffix)
  return { from: from + prefix, to: from + a.length - suffix, insert: text ? [Leaf.text(text, after.marks)] : [] }
}

const splitsPair = (text: string, offset: number) => offset > 0 && (text.codePointAt(offset - 1) ?? 0) > 0xffff

function diffChildren(
  before: readonly Node[],
  after: readonly Node[],
  from: number,
  changes: ChangeSet.Change[]
): void {
  let start = 0,
    endA = before.length,
    endB = after.length
  while (start < endA && start < endB && before[start]!.eq(after[start]!)) {
    from += before[start]!.length
    start++
  }
  while (endA > start && endB > start && before[endA - 1]!.eq(after[endB - 1]!)) {
    endA--
    endB--
  }
  const a = before.slice(start, endA),
    b = after.slice(start, endB)
  const leaves = diffLeaves(a, b, from)
  if (leaves) {
    changes.push(...leaves)
  } else if (a.length === b.length) {
    for (let index = 0; index < a.length; index++) {
      const left = a[index]!,
        right = b[index]!
      if (left.eq(right)) {
        from += left.length
        continue
      }
      if (left.isText && right.isText) {
        changes.push(diffText(left, right, from))
      } else if (left.tag.withMarks([]).eq(right.tag.withMarks([]))) {
        changes.push(...diffMarks(from, from + (left.isPlot ? 1 : left.length), left.marks, right.marks))
        if (left.isPlot && right.isPlot) diffChildren(left.content, right.content, from + 1, changes)
      } else {
        changes.push({ from, to: from + left.length, insert: [right] })
      }
      from += left.length
    }
  } else {
    changes.push({ from, to: from + a.reduce((length, node) => length + node.length, 0), insert: b })
  }
}
