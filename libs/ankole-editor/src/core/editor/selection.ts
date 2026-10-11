import { GardSelection } from '../state'
import { Pos, Leaf } from '../doc'
import { Wordgard } from './editor'
import { type CoordPos } from './tile'
import { isEquivalentPosition, getSelection, SelectionRange } from './dom'

export function setDOMSelection(wg: Wordgard) {
  const { anchor, head, anchorSide, headSide } = wg.state.selection.domSelection
  const anchorDOM = wg.docTile.resolve(anchor, anchorSide)
  const headDOM = head == anchor ? anchorDOM : wg.docTile.resolve(head, headSide)
  const domSel = getSelection(wg.root)
  if (!domSel) return
  if (
    domSel.focusNode &&
    isEquivalentPosition(anchorDOM.dom, anchorDOM.offset, domSel.anchorNode!, domSel.anchorOffset) &&
    isEquivalentPosition(headDOM.dom, headDOM.offset, domSel.focusNode!, domSel.focusOffset)
  ) {
    return
  }

  // Selection.extend can be used to create an 'inverted' selection
  // (one where the focus is before the anchor)
  domSel.collapse(anchorDOM.dom, anchorDOM.offset)
  let failed = false
  if (anchor != head) {
    try {
      domSel.extend(headDOM.dom, headDOM.offset)
    } catch (_) {
      // Safari may raise an exception when the editor is hidden
      failed = true
    }
  }
  if (!failed) wg.observer.setSelectionRange(anchorDOM, headDOM)
}

export function readDOMSelection(wg: Wordgard, range: SelectionRange) {
  const anchor = wg.posAtDOM(range.anchorNode!, range.anchorOffset)
  const head =
    range.anchorNode == range.focusNode && range.anchorOffset == range.focusOffset
      ? anchor
      : wg.posAtDOM(range.focusNode!, range.focusOffset)
  return GardSelection.range(anchor, head)
}

export function selectionFromTouch(event: TouchEvent, wg: Wordgard) {
  const pos = wg.posAtCoords({ x: event.touches[0]!.clientX, y: event.touches[0]!.clientY })
  if (pos.target != null) {
    const target = wg.state.doc.nodeAt(pos.target)
    if (target && target.type.isSelectable && wg.state.isAtom(target.type)) {
      return GardSelection.node(pos.target, target)
    }
  }
  return GardSelection.near(wg.state, pos.pos, pos.side)
}

export function rangeForClick(wg: Wordgard, pos: CoordPos, type: number): GardSelection {
  if (type < 3 && pos.target != null) {
    const target = wg.state.doc.nodeAt(pos.target)
    if (target && target.type.isSelectable && wg.state.isAtom(target.type)) {
      return GardSelection.node(pos.target, target)
    }
  }
  if (type == 1) {
    // Single click
    return GardSelection.near(wg.state, pos.pos, pos.side || -1)
  } else if (type == 2) {
    // Double click
    return wg.state.wordAt(pos.pos, pos.side || 1)
  } else {
    // Triple click
    const cx = wg.state.doc.resolve(pos.pos),
      block = cx.textblockParent
    if (block) return GardSelection.range(block.start, block.end)
    else return GardSelection.near(wg.state, pos.pos, pos.side || -1)
  }
}

const Y_STEP = 2

export function moveVertically(
  wg: Wordgard,
  start: GardSelection,
  forward: boolean,
  distance: number = 0,
  selectNode = false
): GardSelection | null {
  const editorRect = wg.contentDOM.getBoundingClientRect()
  const coords = wg.coordsAtPos(start.head, start.headSide)
  const baseLTR = wg.state.textLTR
  const goalColumn = start.goalColumn ?? (baseLTR ? coords.left - editorRect.left : editorRect.right - coords.left)
  const x = baseLTR ? editorRect.left + goalColumn : editorRect.right - goalColumn
  let y = forward ? coords.bottom + distance : coords.top - distance
  for (let scan = start.head; ;) {
    const pos = wg.state.doc.resolve(scan),
      block = pos.textblockParent
    if (block) {
      const blockTile = block.parent ? wg.docTile.nodeTile(block.before)! : wg.docTile
      const rect = (blockTile.dom as Element).getBoundingClientRect()
      if (forward ? y < rect.top : y > rect.bottom) y = forward ? rect.top : rect.bottom
      while (forward ? rect.bottom >= y : rect.top <= y) {
        const found = blockTile.posAtCoords(wg.state, x, y)
        if (!found.vertOutside && found.pos != start.head) {
          return GardSelection.cursor(found.pos, found.side, goalColumn)
        }
        y += forward ? Y_STEP : -Y_STEP
      }
      if (!block.parent) return null
      scan = forward ? block.after : block.before
    }

    const nextCursor = GardSelection.cursor(scan).nextNormalCursor(wg.state, forward)
    if (!nextCursor) return null
    const nextNode = findTargetVertically(wg, scan, forward, x, selectNode)
    if (
      !nextNode ||
      ((forward ? nextCursor.head <= nextNode.before : nextCursor.head >= nextNode.after) &&
        wg.state.doc.resolve(nextCursor.head).depth < nextNode.depth)
    ) {
      const coords = wg.coordsAtPos(nextCursor.head, nextCursor.headSide)
      if (forward ? coords.bottom > y : coords.top < y) {
        return GardSelection.cursor(nextCursor.head, nextCursor.headSide, goalColumn)
      }
      if (!nextNode) return null
    }
    if (nextNode instanceof Pos.Plot && !nextNode.node.inlineContent) {
      // An empty block that holds a cursor
      const coords = wg.coordsAtPos(nextNode.start)
      if (forward ? coords.bottom > y : coords.top < y) return GardSelection.cursor(nextNode.start, 1, goalColumn)
      scan = forward ? nextNode.after : nextNode.before
    } else if (nextNode instanceof Pos.Plot) {
      scan = forward ? nextNode.start : nextNode.end
    } else {
      const coords = wg.coordsForElement(nextNode.before)!
      if (forward ? coords.bottom > y : coords.top < y) {
        return GardSelection.node(nextNode.before, nextNode.node as Leaf, goalColumn)
      }
      scan = forward ? nextNode.after : nextNode.before
    }
  }
}

function findTargetVertically(wg: Wordgard, from: number, forward: boolean, x: number, allowNode: boolean) {
  let { parent, index, pos } = wg.state.doc.resolve(from),
    entering = false
  for (;;) {
    if (
      (forward ? index == parent.node.content.length : !index) ||
      (parent.node.type.orientation == 'row' && !entering)
    ) {
      if (!parent.parent) return null
      index = parent.index + (forward ? 1 : 0)
      pos = forward ? parent.after : parent.before
      parent = parent.parent
      entering = false
    } else {
      const next = parent.node.content[index - (forward ? 0 : 1)]!
      const nextPos = pos - (forward ? 0 : next.length)
      if (next.isLeaf || wg.state.isAtom(next.type)) {
        if (allowNode && next.type.isSelectable && wg.state.isAtom(next.type)) {
          return Pos.Node.create(parent, next, nextPos, index - (forward ? 0 : 1))
        }
        index += forward ? 1 : -1
        pos += (forward ? 1 : -1) * next.length
        continue
      }
      const node = Pos.Plot.create(parent, next, nextPos, index - (forward ? 0 : 1))
      if (!next.inlineContent && next.type.orientation == 'row') {
        // Find the child closest to the given x
        let closest = -1,
          closestPos = -1,
          closestDist = -1
        for (let chPos = nextPos + 1, i = 0; i < next.content.length; i++) {
          const ch = next.content[i]!
          const tile = wg.docTile.nodeTile(chPos)!
          const rect = (tile.dom as Element).getBoundingClientRect()
          const dist = x < rect.left ? rect.left - x : x > rect.right ? x - rect.right : 0
          if (closestDist < 0 || dist < closestDist) {
            closestDist = dist
            closest = i + (forward ? 0 : 1)
            closestPos = chPos + (forward ? 0 : ch.length)
          }
          chPos += ch.length
        }
        parent = node
        index = closest
        pos = closestPos
        entering = true
      } else if (next.isTextblock || (!next.content.length && next.type.spec.cursorBarrier == 'empty')) {
        // A textblock, or an empty block that holds a cursor
        return node
      } else {
        parent = node
        index = forward ? 0 : next.content.length
        pos += forward ? 1 : -1
      }
    }
  }
}

export function moveToLineBoundary(wg: Wordgard, start: GardSelection, forward: boolean) {
  const block = wg.state.doc.resolve(start.head).textblockParent
  if (!block) return null
  const startCoords = wg.coordsAtPos(start.head, start.headSide)
  const ltr = wg.state.textblockLTR(block.node)
  const y = (startCoords.top + startCoords.bottom) / 2
  const left = forward != ltr
  let { pos } = wg.posAtCoords({ x: left ? -1e7 : 1e7, y })
  if (pos < block.start || pos > block.end) {
    const blockRect = (wg.docTile.nodeTile(block.before)!.dom as Element).getBoundingClientRect()
    pos = wg.posAtCoords({ x: left ? blockRect.left : blockRect.right, y }).pos
  }
  return GardSelection.cursor(pos, forward ? -1 : 1)
}
