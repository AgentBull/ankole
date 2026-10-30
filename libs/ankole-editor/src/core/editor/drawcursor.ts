import { Mark, Node } from '../doc'
import { GardState } from '../state'
import type { Wordgard } from './editor'
import { TextTile } from './tile'
import { coordsAtPos } from './coords'
import { textRange } from './dom'
import { renderMarks } from './decoration'

export const cursorBlinkRate = GardState.Facet.define<number, number>({
  combine: inputs => (inputs.length ? Math.min(...inputs) : 1200)
})

type CursorInfo = { left: number; top: number; size: number; horiz: boolean; style: CursorStyle | null } | null

class CursorStyle {
  constructor(
    readonly height: number,
    readonly align: string,
    readonly color: string,
    readonly bold: boolean,
    readonly italic: boolean
  ) {}

  static read(node: Element | Text, height: number) {
    const win = node.ownerDocument.defaultView || window
    const elt = node.nodeType == 1 ? (node as Element) : (node.parentNode as Element)
    const style = win.getComputedStyle(elt)
    return new CursorStyle(
      height,
      style.verticalAlign,
      style.color,
      +style.fontWeight > 400,
      style.fontStyle == 'italic'
    )
  }

  eq(other: CursorStyle | null) {
    return (
      other &&
      this.height == other.height &&
      this.align == other.align &&
      this.color == other.color &&
      this.bold == other.bold &&
      this.italic == other.italic
    )
  }
}

export class CursorLayer {
  readonly layer: HTMLElement
  info: CursorInfo = null
  cached: { style: CursorStyle; marks: Mark.Set; parent: Node.Tag } | null = null

  constructor(wg: Wordgard) {
    this.layer = wg.scrollDOM.appendChild(document.createElement('wg-cursor-layer'))
    this.positionCursor = this.positionCursor.bind(this)
    wg.scheduleDOMRead(this.positionCursor)
    setBlinkRate(wg.state, this.layer)
  }

  update(update: Wordgard.Update) {
    if (update.transactions.some(tr => tr.selection)) {
      this.layer.style.animationName = this.layer.style.animationName == 'wg-blink' ? 'wg-blink2' : 'wg-blink'
    }
    if (update.state.facet(cursorBlinkRate) != update.startState.facet(cursorBlinkRate)) {
      setBlinkRate(update.state, this.layer)
    }
    if (
      (update.docChanged || update.selectionSet || update.geometryChanged) &&
      (update.startState.selection.isCursor || update.state.selection.isCursor)
    ) {
      update.editor.scheduleDOMRead(this.positionCursor)
    }
  }

  docUpdate(wg: Wordgard) {
    wg.scheduleDOMRead(this.positionCursor)
  }

  remove() {
    this.layer.remove()
  }

  positionCursor(wg: Wordgard) {
    getCursorInfo(wg, this, info => {
      const cur = this.info
      if (
        !info
          ? cur
          : !cur ||
            cur.left != info.left ||
            cur.top != info.top ||
            cur.size != info.size ||
            (cur.style ? !cur.style.eq(info.style) : info.style)
      ) {
        this.info = info
        wg.scheduleDOMWrite(() => {
          let cursor = this.layer.firstChild as HTMLElement | null
          if (!info) {
            if (cursor) cursor.remove()
          } else {
            if (!cursor) cursor = this.layer.appendChild(document.createElement('wg-cursor'))
            cursor.className = `wg-cursor-${info.horiz ? 'h' : 'v'}`
            cursor.style.top = `${info.top}px`
            cursor.style.left = `${info.left}px`
            cursor.style.width = info.horiz ? `${info.size}px` : ''
            cursor.style.height = info.horiz ? '' : `${info.size}px`
            cursor.style.borderLeftColor = info.style ? info.style.color : ''
            cursor.classList.toggle('wg-cursor-bold', info.style?.bold ?? false)
            cursor.classList.toggle('wg-cursor-italic', info.style?.italic ?? false)
          }
        })
      }
    })
  }
}

// Try to estimate a baseline (relative to the bottom of the height)
// from a vertical-align value. Far from accurate, used to get a rough
// correction on the cursor position.
function alignOffset(align: string, height: number) {
  if (align == 'super') return height * 0.36
  if (align == 'sub') return height * -0.17
  if (align.endsWith('px')) return +align.slice(0, align.length - 2)
  if (align.endsWith('%')) return height * +align.slice(0, align.length - 1) * 100
  return 0
}

function vertOverlap(a: DOMRect, b: DOMRect) {
  const margin = a.height / 3
  return a.top < b.bottom - margin && a.bottom > b.top + margin
}

const VertWidth = 30,
  VertGap = 5

function getCursorInfo(wg: Wordgard, plugin: CursorLayer, cont: (info: CursorInfo) => void) {
  const { state } = wg
  if (!state.selection.isCursor) return cont(null)
  const { head, headSide } = state.selection,
    { sel } = wg.state
  const { ref, rect } = coordsAtPos(wg, head, headSide)
  // The layer belongs to the scroller. A host's block margins can move the
  // content independently of that layer, so use the layer's own origin.
  const origin = plugin.layer.getBoundingClientRect()

  // Block context, horizontal cursor
  if (!sel.head.parent.node.inlineContent) {
    const width = Math.min(VertWidth, rect.width)
    let top = rect.top
    const other = wg.coordsAtPos(head, headSide > 0 ? -1 : 1)
    if (other.top == other.bottom && other.top != top) {
      const move = Math.min(VertGap, Math.abs(other.top - top) / 2)
      top = top + move * (other.top < top ? -1 : 1)
    }
    return cont({
      left: (wg.state.textLTR ? rect.left : rect.right - width) - origin.left,
      top: top - origin.top,
      size: width,
      horiz: true,
      style: null
    })
  }

  const finish = (style: CursorStyle | null, vertRect?: DOMRect) => {
    if (style && (!plugin.cached || plugin.cached.style != style)) {
      plugin.cached = { style, marks, parent: sel.head.parent.node.tag }
    }
    const height = style ? style.height : rect.height
    let bot = rect.bottom
    if (vertRect && vertOverlap(vertRect, rect)) {
      bot = vertRect.bottom
    } else {
      const win = ref.dom.ownerDocument.defaultView || window
      const refAlign = win.getComputedStyle(
        (ref.dom.nodeType == 1 ? ref.dom : ref.dom.parentNode) as Element
      ).verticalAlign
      if (style && refAlign != style.align) {
        bot += alignOffset(refAlign, rect.height) - alignOffset(style.align, style.height)
      }
    }
    cont({
      left: rect.left - origin.left,
      top: bot - height - origin.top,
      size: height,
      horiz: false,
      style
    })
  }

  const marks = sel.activeMarks
  if (ref instanceof TextTile) {
    const node = ref.posBefore < head ? state.sel.head.nodeBefore : state.sel.head.nodeAfter
    // Ref is text with matching style, use directly
    if (node && node.isText && Mark.sameSet(node.marks, marks)) {
      return finish(CursorStyle.read(ref.dom, rect.height), rect)
    }
  }

  // See if a sibling node has the same set of marks, read style from that
  let pos = sel.head.parent.start,
    foundRect: DOMRect | undefined,
    foundNode: Text | undefined
  scan: for (const sibling of sel.head.parent.node.content) {
    if (sibling.isText && Mark.sameSet(sibling.marks, marks)) {
      const { tile } = wg.docTile.resolve(pos, 1)
      if (tile instanceof TextTile) {
        const rects = textRange(tile.dom, 0, tile.length).getClientRects()
        foundNode = tile.dom
        for (let i = 0; i < rects.length; i++) {
          foundRect = rects[i]
          if (vertOverlap(foundRect!, rect)) break scan
        }
      }
    }
    pos += sibling.length
  }
  if (foundNode) return finish(CursorStyle.read(foundNode, foundRect!.height), foundRect)

  // Check cache
  if (plugin.cached && Mark.sameSet(plugin.cached.marks, marks) && plugin.cached.parent.eq(sel.head.parent.node.tag)) {
    return finish(plugin.cached.style)
  }

  if (!marks.length) return finish(null)

  // Create a temporary node to measure
  const target = sel.head.parent.node.isDoc ? wg.contentDOM : wg.nodeDOM(sel.head.parent.before)!
  wg.scheduleDOMWrite(() => {
    const temp = renderMarks(wg.state, marks, 'M')
    ;(temp as HTMLElement).style.position = 'absolute'
    wg.observer.ignore(() => target.insertBefore(temp, target.firstChild))
    wg.scheduleDOMRead(() => {
      wg.scheduleDOMWrite(() => wg.observer.ignore(() => temp.remove()))
      let inner = temp as Element | Text
      while (inner.firstChild) inner = inner.firstChild as Element | Text
      const r = textRange(inner as Text, 0, 1).getClientRects()[0]!
      finish(CursorStyle.read(inner, r.height), r)
    })
  })
}

function setBlinkRate(state: GardState, dom: HTMLElement) {
  dom.style.animationDuration = `${state.facet(cursorBlinkRate)}ms`
}
