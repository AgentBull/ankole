import type { Node, Plot, Pos } from '../core/doc'
import { isContainer, isList } from './block-insert'
import { isBlockGroup } from './nesting'
import { Column, Columns } from './schema'

/** A menu or pointer target is a block in a container, or an individual list item. */
export function targetAt(doc: Plot.Doc, pos: number): Pos.Node | null {
  if (pos < 0 || pos >= doc.length) return null
  const node = doc.resolveNode(pos)
  if (node?.parent && isBlockGroup(node.parent.node) && node.index === 0) return null
  if (node?.parent?.parent && isList(node.parent.parent.node) && node.index > 0) return node
  return node?.parent && (isList(node.parent.node) || isContainer(node.parent)) ? node : null
}

/**
 * The block that a block shortcut acts on at `pos` (SPEC §7.6): a list item with its children, or
 * a block in a container. `side` picks the block after or before a position between blocks.
 */
export function unitAt(doc: Plot.Doc, pos: number, side: -1 | 1): Pos.Node | null {
  const at = doc.resolve(pos)
  let node: Pos.Node | null
  if (at.parent.node.inlineContent || !at.parent.node.content.length) node = at.parent.parent ? at.parent : null
  else {
    const after = at.nodeAfter ? pos : null
    const before = at.nodeBefore ? pos - at.nodeBefore.length : null
    const start = side > 0 ? (after ?? before) : (before ?? after)
    node = start === null ? null : doc.resolveNode(start)
  }
  for (; node?.parent; node = node.parent) {
    if (isBlockGroup(node.parent.node) && node.index === 0) continue
    if (node.parent.parent && isList(node.parent.parent.node) && node.index > 0) return node
    if (isList(node.parent.node) || isContainer(node.parent)) return node
  }
  return null
}

/** Complete blocks in a range, descending into partially selected containers. */
export function blocksBetween(doc: Plot.Doc, from: number, to: number): Pos.Node[] {
  const result: Pos.Node[] = []
  doc.iterate((node, pos) => {
    if (pos >= to || pos + node.length <= from) return false
    if (pos >= from && pos + node.length <= to && targetAt(doc, pos)) {
      result.push(doc.resolveNode(pos)!)
      return false
    }
    return true
  })
  return result
}

/** The adjacent visible block, crossing list and column boundaries in reading order. */
export function adjacentUnit(unit: Pos.Node, direction: -1 | 1): Pos.Node | null {
  for (let current: Pos.Node = unit; current.parent; current = current.parent) {
    if (direction < 0 && isBlockGroup(current.parent.node) && current.index === 1) return current.parent
    if (direction < 0 && current.parent.parent && isList(current.parent.parent.node)) return current.parent
    const sibling = direction < 0 ? current.previousSibling : current.nextSibling
    if (sibling) {
      let next = unit.doc.resolveNode(direction < 0 ? current.before - sibling.length : current.after)!
      while (
        (next.node.type === Column.type || next.node.type === Columns.type || isList(next.node)) &&
        next.node.isPlot &&
        next.node.content.length
      ) {
        next = unit.doc.resolveNode(direction < 0 ? next.after - 1 - next.node.lastChild!.length : next.before + 1)!
      }
      return targetAt(unit.doc, next.before)
    }
    if (current.parent.node.type.isolating && current.parent.node.type !== Column.type) return null
  }
  return null
}

/** Copy selected blocks, wrapping list-item runs without copying unselected ancestors. */
export function blockContent(units: readonly Pos.Node[]): Node[] {
  if (units.every(unit => unit.parent!.start === units[0]!.parent!.start)) return units.map(unit => unit.node)
  const result: Node[] = []
  let previous: Pos.Plot | null = null
  for (const unit of units) {
    const parent = unit.parent!
    const last = result.at(-1)
    if (!isList(parent.node)) result.push(unit.node)
    else if (previous?.start === parent.start && last?.isPlot) {
      result[result.length - 1] = last.tag.create([...last.content, unit.node])
    } else {
      result.push(parent.node.tag.create([unit.node]))
    }
    previous = parent
  }
  return result
}

/** Include a list's wrapper when removing all its items, so no empty item is left behind. */
export function blockRemovalRange(units: readonly Pos.Node[]): { from: number; to: number } {
  const first = units[0]!
  const last = units.at(-1)!
  let from = first.before
  let to = last.after
  const startList = first.parent!
  const endList = last.parent!
  if (isList(startList.node) && from === startList.start && startList.end <= to) from = startList.before
  if (isList(endList.node) && to === endList.end && endList.start >= from) to = endList.after
  return { from, to }
}

/** Remove sibling runs separately so unselected content and container boundaries stay intact. */
export function blockRemovalRanges(units: readonly Pos.Node[]): { from: number; to: number }[] {
  const runs: Pos.Node[][] = []
  for (const unit of units) {
    const run = runs.at(-1)
    if (run?.at(-1)?.after === unit.before && run[0]!.parent!.start === unit.parent!.start) run.push(unit)
    else runs.push([unit])
  }
  return runs.map(blockRemovalRange)
}
