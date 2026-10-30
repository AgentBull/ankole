import { type Node, type Plot } from '../core/doc'
import type { Wordgard } from '../core/editor'
import type { GardState } from '../core/state'
import { relocation } from '../editor/block-actions'
import { isList } from '../editor/block-insert'
import { columnDrop } from '../editor/columns'
import { isBlockGroup } from '../editor/nesting'
import { Column, Columns } from '../editor/schema'

type BlockBox = { pos: number; node: Node; dom: HTMLElement; rect: DOMRect }
type BlockRect = Pick<DOMRect, 'left' | 'right' | 'top' | 'bottom' | 'width' | 'height'>
type DropMarker = Pick<DOMRect, 'left' | 'top' | 'width' | 'height'>

/** Visible block faces. A parent's face excludes the children that have their own handles. */
export function* blockBoxes(editor: Wordgard, parent: Plot = editor.state.doc, start = 0): Generator<BlockBox> {
  let pos = start
  for (const node of parent.content) {
    const dom = editor.nodeDOM(pos)
    if (dom instanceof HTMLElement) {
      if (
        node.isPlot &&
        (node.type === Columns.type || node.type === Column.type || isList(node)) &&
        node.content.length
      ) {
        yield* blockBoxes(editor, node, pos + 1)
      } else if (node.isPlot && node.content.length && (isBlockGroup(node) || isList(parent))) {
        const children = blockBoxes(editor, node, pos + 1)
        const first = children.next().value as BlockBox | undefined
        if (first) yield { ...first, pos, node }
        yield* children
      } else {
        yield { pos, node, dom, rect: dom.getBoundingClientRect() }
      }
    }
    pos += node.length
  }
}

/** Margins belong to their block; a clamped position outside the page picks its nearest block. */
export function blockAt(editor: Wordgard, x: number, y: number, clamp: boolean): BlockBox | null {
  let found: BlockBox | null = null
  let distance = Infinity
  for (const box of blockBoxes(editor)) {
    const style = getComputedStyle(box.dom)
    const dy = Math.max(
      box.rect.top - parseFloat(style.marginTop) - y,
      y - box.rect.bottom - parseFloat(style.marginBottom),
      0
    )
    if (dy && !clamp) continue
    const dx = Math.max(box.rect.left - x, x - box.rect.right, 0)
    const score = dy * 10000 + dx
    if (score < distance) {
      found = box
      distance = score
    }
  }
  return found
}

/** Resolve a measured drop into one valid edit and its marker for both preview and release. */
export function blockDrop(
  state: GardState,
  positions: readonly number[],
  hit: { pos: number; rect: BlockRect },
  pointer: { x: number; y: number; viewportWidth: number },
  rectAt: (pos: number) => BlockRect | null
) {
  const { x, y, viewportWidth } = pointer
  const before = y < hit.rect.top + hit.rect.height / 2
  let block = state.doc.resolveNode(hit.pos)!
  let rect = hit.rect
  const drop = (to: number, marker: DropMarker, nestUnder?: number, side?: -1 | 1) => {
    const edit = side ? columnDrop(state, positions, to, side) : relocation(state, positions, to, nestUnder)
    return edit ? { edit, marker } : null
  }
  const middle = y > rect.top + rect.height / 4 && y < rect.bottom - rect.height / 4
  const side = x <= rect.left ? -1 : x >= rect.right - 8 ? 1 : null
  if (middle && side && viewportWidth > 600) {
    return drop(
      block.before,
      {
        left: side < 0 ? rect.left - 8 : rect.right + 6,
        top: rect.top,
        width: 2,
        height: rect.height
      },
      undefined,
      side
    )
  }
  // Above or below an entire row, a full-width drop returns its blocks to the page.
  let column = block.parent
  while (column?.parent && column.node.type !== Column.type) column = column.parent
  if (column?.node.type === Column.type) {
    const row = column.parent!
    const rowRect = rectAt(row.before)
    if (rowRect && (y < rowRect.top - 4 || y > rowRect.bottom + 4)) {
      return drop(y < rowRect.top ? row.before : row.after, {
        left: rowRect.left,
        top: y < rowRect.top ? rowRect.top - 4 : rowRect.bottom + 4,
        width: rowRect.width,
        height: 2
      })
    }
  }
  // Right below text nests under that block; moving left lifts through parent levels.
  if (block.node.isPlot && !before && x >= rect.left + 30) {
    return drop(
      block.after,
      {
        left: rect.left + 30,
        top: rect.bottom + 4,
        width: rect.width - 30,
        height: 2
      },
      block.before
    )
  }
  while ((isList(block.parent!.node) || isBlockGroup(block.parent!.node)) && x < rect.left - 16) {
    const list = block.parent!
    const owner = list.parent!
    block = isBlockGroup(list.node) ? list : owner.parent && isList(owner.parent.node) ? owner : list
    const parentRect = rectAt(block.before)
    if (!parentRect) break
    rect = parentRect
  }
  return drop(before ? block.before : block.after, {
    left: rect.left,
    top: before ? rect.top - 4 : rect.bottom + 4,
    width: rect.width,
    height: 2
  })
}
