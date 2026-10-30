import { Plot, type Node, type Pos, type ChangeSet, type Token } from '../core/doc'
import { GardSelection, type GardState, type Transaction } from '../core/state'
import * as T from '../core/types'
import { BlockGroup } from './schema'
import { isList } from './block-insert'

export const isBlockGroup = (node: Node): boolean => node.type === BlockGroup.type
const ownsChildren = (node: Pos.Plot) => isBlockGroup(node.node) || !!(node.parent && isList(node.parent.node))

function childDepth(node: Node): number {
  if (!node.isPlot || node.inlineContent) return 0
  return Math.max(0, ...node.content.map(childDepth)) + (isBlockGroup(node) || isList(node) ? 1 : 0)
}

/** Drop children below a block's own content, before its existing children. */
export function insertChildren(parent: Pos.Node, nodes: readonly Node[]) {
  if (parent.node.isPlot && (isBlockGroup(parent.node) || (parent.parent && isList(parent.parent.node)))) {
    const head = parent.node.firstChild
    const from = parent.before + 1 + (head?.length ?? 0)
    return { changes: { from, insert: head ? nodes : [T.Paragraph.create([]), ...nodes] }, at: from + (head ? 0 : 2) }
  }
  return {
    changes: [
      { from: parent.before, insert: [BlockGroup] },
      { from: parent.after, insert: [...nodes, Plot.End] }
    ],
    at: parent.after + 1
  }
}

/** The preceding sibling that can own these children, within the document's nesting limit. */
export function nestingParent(first: Pos.Node, nodes: readonly Node[]): Pos.Node | null {
  const parent = first.parent!
  // The first child already belongs to its parent and has no preceding child to nest under.
  if (first.index < (ownsChildren(parent) ? 2 : 1)) return null
  let previous = first.doc.resolveNode(first.before - first.previousSibling!.length)!
  if (isList(previous.node) && previous.node.content.length) {
    previous = first.doc.resolveNode(previous.after - 1 - previous.node.lastChild!.length)!
  }
  let levels = 0
  for (let p = previous.parent; p; p = p.parent) {
    if (isBlockGroup(p.node) || (p.parent && isList(p.parent.node))) levels++
  }
  return levels + 1 + Math.max(...nodes.map(childDepth)) > 49 ? null : previous
}

/** Tab moves a contiguous run below its previous sibling; descendants move with their parent. */
export function sinkBlocks(units: readonly Pos.Node[]): ChangeSet.Spec[] | null {
  const first = units[0]!
  const last = units.at(-1)!
  if (
    units.some(
      (unit, i) => unit.parent?.start !== first.parent!.start || (i > 0 && unit.before !== units[i - 1]!.after)
    )
  ) {
    return null
  }
  const previous = nestingParent(
    first,
    units.map(unit => unit.node)
  )
  if (!previous) return null
  const previousList = isList(first.previousSibling!) ? previous.parent : null
  return [
    previousList
      ? { from: previous.after - 1, to: previousList.after }
      : isBlockGroup(previous.node) || (previous.parent && isList(previous.parent.node))
        ? { from: previous.after - 1, to: previous.after }
        : { from: previous.before, insert: [BlockGroup] },
    { from: last.after, insert: previousList ? [Plot.End, Plot.End] : [Plot.End] }
  ]
}

/** A list's leading items can nest below the ordinary block before that list. */
export function sinkListStart(list: Pos.Plot, last: number): ChangeSet.Spec[] | null {
  const changes = sinkBlocks([list])
  if (!changes) return null
  if (last < list.node.content.length - 1) {
    const end = list.start + list.node.content.slice(0, last + 1).reduce((size, item) => size + item.length, 0)
    const closing = changes.at(-1)! as ChangeSet.Change
    changes[changes.length - 1] = {
      from: end,
      insert: [Plot.End, ...(closing.insert as readonly Token[]), list.node.tag]
    }
  }
  return changes
}

/** Lift list children of an ordinary block; subsequent children follow the last lifted item. */
export function liftListFromBlock(list: Pos.Plot, first: number, last: number): ChangeSet.Spec[] | null {
  const owner = list.parent!
  if (!isBlockGroup(owner.node) || list.index === 0) return null
  const from = list.start + list.node.content.slice(0, first).reduce((size, item) => size + item.length, 0)
  const to = list.start + list.node.content.slice(0, last + 1).reduce((size, item) => size + item.length, 0)
  const after = last < list.node.content.length - 1
  const ownerAfter = !list.isLast
  const changes: ChangeSet.Spec[] = [
    first > 0
      ? { from, insert: [Plot.End, Plot.End, list.node.tag] }
      : { from: list.before, to: list.start, insert: [Plot.End, list.node.tag] }
  ]
  if (after) changes.push({ from: to - 1, to, insert: [list.node.tag] })
  else if (ownerAfter) changes.push({ from: to - 1, to: list.after })
  changes.push({
    from: owner.end,
    to: owner.after,
    insert: after || ownerAfter ? [Plot.End, Plot.End] : []
  })
  return changes
}

/** Shift+Tab lifts a child run. Following siblings become children of the last lifted block. */
export function liftBlocks(units: readonly Pos.Node[]): ChangeSet.Spec[] | null {
  const first = units[0]!
  const last = units.at(-1)!
  const parent = first.parent!
  if (
    !ownsChildren(parent) ||
    first.index === 0 ||
    units.some(
      (unit, index) => unit.parent?.start !== parent.start || (index > 0 && unit.before !== units[index - 1]!.after)
    )
  ) {
    return null
  }
  const list = parent.parent && isList(parent.parent.node) ? parent.parent : null
  const changes: ChangeSet.Spec[] = [{ from: first.before, insert: list ? [Plot.End, Plot.End] : [Plot.End] }]
  if (!last.isLast) {
    changes.push(
      isBlockGroup(last.node) ? { from: last.after - 1, to: last.after } : { from: last.before, insert: [BlockGroup] }
    )
  }
  if (list) {
    changes.push({
      from: parent.end,
      to: parent.isLast ? list.after : parent.after,
      insert: [...(last.isLast ? [] : [Plot.End]), ...(parent.isLast ? [] : [list.node.tag])]
    })
  } else if (last.isLast) changes.push({ from: parent.end, to: parent.after })
  return changes
}

/** Splitting the parent's own text transfers its children to the new sibling. */
export function enterNestedBlock(state: GardState, block: Pos.Plot): Transaction.Spec | false {
  if (block.node.type !== T.Paragraph.type && block.node.type !== T.Heading) return false
  const parent = block.parent!
  if (!ownsChildren(parent)) return false
  const head = state.selection.head
  if (block.index > 0) {
    const changes = !block.node.content.length && liftBlocks([block])
    return changes ? { changes, scrollIntoView: true, userEvent: 'outdent' } : false
  }
  if (!isBlockGroup(parent.node)) return false
  if (head === block.start && block.node.content.length) {
    return {
      changes: { from: parent.before, insert: [T.Paragraph.create([])] },
      scrollIntoView: true,
      userEvent: 'split.textblock'
    }
  }
  const tag = block.node.type === T.Heading ? T.Paragraph : block.node.tag.split(head === block.end)
  return {
    changes: { from: head, insert: [Plot.End, Plot.End, BlockGroup, tag] },
    selection: GardSelection.cursor(head + 4),
    scrollIntoView: true,
    userEvent: 'split.textblock'
  }
}
