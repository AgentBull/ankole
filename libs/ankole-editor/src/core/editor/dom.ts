import type { Tile } from './tile'
import browser from './browser'

export type DOMNode = Node

declare global {
  interface Node {
    wgTile?: Tile
  }
}

export function isElt(node: DOMNode | null | undefined): node is Element {
  return node?.nodeType == 1
}

export function isText(node: DOMNode | null | undefined): node is Text {
  return node?.nodeType == 3
}

export function getSelection(root: DocumentOrShadowRoot): Selection | null {
  let target
  // Browsers differ on whether shadow roots have a getSelection
  // method. If it exists, use that, otherwise, call it on the
  // document.
  if ((root as any).nodeType == 11) {
    // Shadow root
    target = (root as any).getSelection ? (root as Document) : (root as ShadowRoot).ownerDocument
  } else {
    target = root as Document
  }
  return target.getSelection()
}

export function getSelectionRange(root: DocumentOrShadowRoot): StaticRange | null {
  const sel = getSelection(root)
  if (!sel || !sel.rangeCount) return null
  if (browser.safari && (root as Document | ShadowRoot).nodeType == 11) {
    const composed = sel as Selection & { getComposedRanges(scope: DocumentOrShadowRoot): StaticRange[] }
    const range = composed.getComposedRanges(root)[0]
    if (range) return range
  }
  return new StaticRange(sel.getRangeAt(0))
}

export function hasSelection(dom: Element, selection: SelectionRange): boolean {
  if (!selection.focusNode) return false
  try {
    // Firefox will raise 'permission denied' errors when accessing
    // properties of `sel.focusNode` when it's in a generated CSS
    // element.
    return dom.contains(selection.focusNode)
  } catch (_) {
    return false
  }
}

// Scans forward and backward through DOM positions equivalent to the
// given one to see if the two are in the same place (i.e. after a
// text node vs at the end of that text node)
export function isEquivalentPosition(node: Node, off: number, targetNode: Node | null, targetOff: number): boolean {
  return targetNode
    ? scanFor(node, off, targetNode, targetOff, -1) || scanFor(node, off, targetNode, targetOff, 1)
    : false
}

export function domIndex(node: Node): number {
  for (let index = 0; ; index++) {
    node = node.previousSibling!
    if (!node) return index
  }
}

export function rmDOM(dom: ChildNode): ChildNode | null {
  const next = dom.nextSibling
  dom.remove()
  return next
}

export function isBlockElement(node: Node): boolean {
  const tile = node.wgTile
  if (tile?.tag) return tile.tag.type.isBlock
  return isElt(node) && /^(DIV|P|LI|UL|OL|BLOCKQUOTE|DD|DT|H\d|SECTION|PRE)$/.test(node.nodeName)
}

export function isBlocking(node: Node) {
  const tile = node.wgTile
  if (tile) return tile.isBlocking
  return isElt(node) && (node as HTMLElement).contentEditable == 'false'
}

function scanFor(node: Node, off: number, targetNode: Node, targetOff: number, dir: -1 | 1): boolean {
  for (;;) {
    if (node == targetNode && off == targetOff) return true
    if (off == (dir < 0 ? 0 : maxOffset(node))) {
      if (isBlockElement(node)) return false
      const parent = node.parentNode
      if (!parent || !isElt(parent)) return false
      off = domIndex(node) + (dir < 0 ? 0 : 1)
      node = parent
    } else if (isElt(node)) {
      node = node.childNodes[off + (dir < 0 ? -1 : 0)]!
      if (isBlocking(node)) return false
      off = dir < 0 ? maxOffset(node) : 0
    } else {
      return false
    }
  }
}

export function maxOffset(node: Node): number {
  return isText(node) ? node.nodeValue!.length : node.childNodes.length
}

export function windowRect(win: Window): DOMRect {
  const vp = win.visualViewport
  return new DOMRect(0, 0, vp ? vp.width : win.innerWidth, vp ? vp.height : win.innerHeight)
}

export function getScale(elt: HTMLElement, rect: DOMRect) {
  let scaleX = rect.width / elt.offsetWidth
  let scaleY = rect.height / elt.offsetHeight
  if ((scaleX > 0.995 && scaleX < 1.005) || !isFinite(scaleX) || Math.abs(rect.width - elt.offsetWidth) < 1) scaleX = 1
  if ((scaleY > 0.995 && scaleY < 1.005) || !isFinite(scaleY) || Math.abs(rect.height - elt.offsetHeight) < 1) {
    scaleY = 1
  }
  return { scaleX, scaleY }
}

export function scrollRectIntoView(
  dom: HTMLElement,
  rect: DOMRect,
  side: -1 | 1,
  x: 'nearest' | 'start' | 'end' | 'center',
  y: 'nearest' | 'start' | 'end' | 'center',
  xMargin: number,
  yMargin: number,
  ltr: boolean
) {
  const doc = dom.ownerDocument!,
    win = doc.defaultView || window

  for (let cur: DOMNode | null = dom, stop = false; cur && !stop;) {
    if (isElt(cur)) {
      // Element
      let bounding: DOMRect
      const top = cur == doc.body
      let scaleX = 1,
        scaleY = 1
      if (top) {
        bounding = windowRect(win)
      } else {
        if (/^(fixed|sticky)$/.test(getComputedStyle(cur).position)) stop = true
        if (cur.scrollHeight <= cur.clientHeight && cur.scrollWidth <= cur.clientWidth) {
          cur = cur.assignedSlot || cur.parentNode
          continue
        }
        const rect = cur.getBoundingClientRect()
        ;({ scaleX, scaleY } = getScale(cur as HTMLElement, rect))
        // Make sure scrollbar width isn't included in the rectangle
        bounding = new DOMRect(rect.left, rect.top, cur.clientWidth * scaleX, cur.clientHeight * scaleY)
      }

      let moveX = 0,
        moveY = 0
      if (y == 'nearest') {
        if (rect.top < bounding.top) {
          moveY = -(bounding.top - rect.top + yMargin)
          if (side > 0 && rect.bottom > bounding.bottom + moveY) moveY = rect.bottom - bounding.bottom + moveY + yMargin
        } else if (rect.bottom > bounding.bottom) {
          moveY = rect.bottom - bounding.bottom + yMargin
          if (side < 0 && rect.top - moveY < bounding.top) moveY = -(bounding.top + moveY - rect.top + yMargin)
        }
      } else {
        const rectHeight = rect.bottom - rect.top,
          boundingHeight = bounding.bottom - bounding.top
        const targetTop =
          y == 'center' && rectHeight <= boundingHeight
            ? rect.top + rectHeight / 2 - boundingHeight / 2
            : y == 'start' || (y == 'center' && side < 0)
              ? rect.top - yMargin
              : rect.bottom - boundingHeight + yMargin
        moveY = targetTop - bounding.top
      }
      if (x == 'nearest') {
        if (rect.left < bounding.left) {
          moveX = -(bounding.left - rect.left + xMargin)
          if (side > 0 && rect.right > bounding.right + moveX) moveX = rect.right - bounding.right + moveX + xMargin
        } else if (rect.right > bounding.right) {
          moveX = rect.right - bounding.right + xMargin
          if (side < 0 && rect.left < bounding.left + moveX) moveX = -(bounding.left + moveX - rect.left + xMargin)
        }
      } else {
        const targetLeft =
          x == 'center'
            ? rect.left + (rect.right - rect.left) / 2 - (bounding.right - bounding.left) / 2
            : (x == 'start') == ltr
              ? rect.left - xMargin
              : rect.right - (bounding.right - bounding.left) + xMargin
        moveX = targetLeft - bounding.left
      }
      if (moveX || moveY) {
        if (top) {
          win.scrollBy(moveX, moveY)
        } else {
          let movedX = 0,
            movedY = 0
          if (moveY) {
            const start = cur.scrollTop
            cur.scrollTop += moveY / scaleY
            movedY = (cur.scrollTop - start) * scaleY
          }
          if (moveX) {
            const start = cur.scrollLeft
            cur.scrollLeft += moveX / scaleX
            movedX = (cur.scrollLeft - start) * scaleX
          }
          rect = {
            left: rect.left - movedX,
            top: rect.top - movedY,
            right: rect.right - movedX,
            bottom: rect.bottom - movedY
          } as ClientRect
          if (movedX && Math.abs(movedX - moveX) < 1) x = 'nearest'
          if (movedY && Math.abs(movedY - moveY) < 1) y = 'nearest'
        }
      }
      if (top) break
      cur = cur.assignedSlot || cur.parentNode
    } else if (cur.nodeType == 11) {
      // A shadow root
      cur = (cur as ShadowRoot).host
    } else {
      break
    }
  }
}

export function scrollableParents(dom: HTMLElement) {
  const doc = dom.ownerDocument
  let x: Element | undefined
  let y: Element | undefined
  for (let cur = dom.parentNode; cur;) {
    if (cur == doc.body || (x && y)) {
      break
    } else if (isElt(cur)) {
      if (!y && cur.scrollHeight > cur.clientHeight) y = cur
      if (!x && cur.scrollWidth > cur.clientWidth) x = cur
      cur = cur.assignedSlot || (cur.parentNode as HTMLElement | null)
    } else if (cur.nodeType == 11) {
      cur = (cur as ShadowRoot).host
    } else {
      break
    }
  }
  return { x, y }
}

export interface SelectionRange {
  focusNode: Node | null
  focusOffset: number
  anchorNode: Node | null
  anchorOffset: number
}

export class DOMSelectionState implements SelectionRange {
  anchorNode: Node | null = null
  anchorOffset: number = 0
  focusNode: Node | null = null
  focusOffset: number = 0

  eq(domSel: SelectionRange): boolean {
    return (
      this.anchorNode == domSel.anchorNode &&
      this.anchorOffset == domSel.anchorOffset &&
      this.focusNode == domSel.focusNode &&
      this.focusOffset == domSel.focusOffset
    )
  }

  get empty() {
    return this.anchorNode == this.focusNode && this.anchorOffset == this.focusOffset
  }

  setRange(range: SelectionRange) {
    const { anchorNode, focusNode } = range
    // Clip offsets to node size to avoid crashes when Safari reports bogus offsets (#1152)
    this.set(
      anchorNode,
      Math.min(range.anchorOffset, anchorNode ? maxOffset(anchorNode) : 0),
      focusNode,
      Math.min(range.focusOffset, focusNode ? maxOffset(focusNode) : 0)
    )
  }

  set(anchorNode: Node | null, anchorOffset: number, focusNode: Node | null, focusOffset: number) {
    this.anchorNode = anchorNode
    this.anchorOffset = anchorOffset
    this.focusNode = focusNode
    this.focusOffset = focusOffset
  }
}

let scratchRange: Range | null

export function textRange(node: Text, from: number, to = from) {
  const range = scratchRange || (scratchRange = document.createRange())
  range.setEnd(node, to)
  range.setStart(node, from)
  return range
}

export function clearScratchRange() {
  if (scratchRange) {
    scratchRange.detach()
    scratchRange = null
  }
}

function nonZero(rect: DOMRect) {
  return rect.top < rect.bottom || rect.left < rect.right
}

export function singleRect(target: Element | Text | Range, bias: -1 | 1, preferWide = false): DOMRect {
  if ('nodeType' in target && isText(target)) target = textRange(target, 0, target.nodeValue!.length)
  const rects = (target as Element | Range).getClientRects()
  for (let i = bias < 0 ? 0 : rects.length - 1; bias < 0 ? i < rects.length : i >= 0; i -= bias) {
    const rect = rects[i]!
    if (nonZero(rect) && (!preferWide || rect.width)) return rect
  }
  return Array.prototype.find.call(rects, nonZero) || (target as Element | Range).getBoundingClientRect()
}

export function getRoot(node: Node | null | undefined): DocumentOrShadowRoot | null {
  while (node) {
    if (node && (node.nodeType == 9 || (node.nodeType == 11 && (node as ShadowRoot).host))) {
      return node as Document | ShadowRoot
    }
    node = (node as Element).assignedSlot || node.parentNode
  }
  return null
}

export function textNodeBefore(startNode: Node, startOffset: number): Text | null {
  for (let node = startNode, offset = startOffset; ;) {
    if (offset > 0 && isText(node)) {
      return node
    } else if (offset > 0 && isElt(node)) {
      if ((node as HTMLElement).contentEditable == 'false') return null
      node = node.childNodes[offset - 1]!
      offset = maxOffset(node)
    } else if (node.parentNode && !isBlockElement(node)) {
      offset = domIndex(node)
      node = node.parentNode
    } else {
      return null
    }
  }
}

export function textNodeAfter(startNode: Node, startOffset: number): Text | null {
  for (let node = startNode, offset = startOffset; ;) {
    if (isText(node) && offset < node.nodeValue!.length) {
      return node
    } else if (isElt(node) && offset < node.childNodes.length) {
      if ((node as HTMLElement).contentEditable == 'false') return null
      node = node.childNodes[offset]!
      offset = 0
    } else if (node.parentNode && !isBlockElement(node)) {
      offset = domIndex(node) + 1
      node = node.parentNode
    } else {
      return null
    }
  }
}

export function atElementStart(doc: HTMLElement, selection: SelectionRange) {
  let node: Node | null = selection.focusNode,
    offset = selection.focusOffset
  if (!node || selection.anchorNode != node || selection.anchorOffset != offset) return false
  for (;;) {
    if (offset) {
      if (!isElt(node)) return false
      const prev: ChildNode | undefined = node.childNodes[offset - 1]
      if (!prev || (prev as HTMLElement).contentEditable == 'false') offset--
      else {
        node = prev
        offset = maxOffset(node)
      }
    } else if (node == doc) {
      return true
    } else {
      if (!node.parentNode) return false
      offset = domIndex(node)
      node = node.parentNode
    }
  }
}
