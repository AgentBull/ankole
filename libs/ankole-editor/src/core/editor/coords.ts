import { textRange, singleRect } from './dom'
import { ltrAt, WidgetTile, TextTile, Tile } from './tile'
import type { Wordgard } from './editor'

export class Coords {
  constructor(
    readonly ref: Tile,
    readonly rect: DOMRect
  ) {}
}

// Given a position in the document model, get a bounding box of the
// character at that position, relative to the window.
export function coordsAtPos(wg: Wordgard, pos: number, assoc: -1 | 1): Coords {
  const textblock = wg.state.doc.resolve(pos).textblockParent
  const map = textblock ? wg.state.textblockMap(textblock) : null

  // Treat position pointing out of a textblock specially if the bidi
  // span at that side isn't in the block's main direction.
  if (
    textblock &&
    textblock.node.contentLength &&
    ((pos == textblock.start && assoc < 0) || (pos == textblock.end && assoc > 0))
  ) {
    const span = map!.order[pos == textblock.start ? 0 : map!.order.length - 1]!
    if (span.ltr != map!.ltr) pos = textblock.start + (pos == textblock.start ? span.to : span.from)
    else assoc = -assoc as -1 | 1
  }

  const resolved = wg.docTile.resolve(pos, assoc)
  const tilePos = resolved.pos
  let { offset, tile } = resolved

  if (tile instanceof TextTile) {
    let from = offset,
      to = offset
    const side: -1 | 1 = from == 0 ? -1 : from == tile.length ? 1 : (-assoc as -1 | 1)
    if (side < 0) to++
    else from--
    return new Coords(
      tile,
      flattenV(singleRect(textRange(tile.dom, from, to), side, true), side < 0 == ltrAt(wg.state, pos, assoc, map))
    )
  }

  let tagTile = tile
  while (!tagTile.tag) tagTile = tagTile.parent!
  // Return a horizontal line in block context
  const horizontal = tagTile.tag.isPlot && tagTile.tag.type.orientation == 'column'

  if (tile instanceof WidgetTile) {
    const after = pos > tilePos + tile.length / 2
    if (tile.widget.type.inFlow) {
      const rect = singleRect(tile.dom, after ? 1 : -1)
      if (rect.width || rect.height) {
        return new Coords(
          tile,
          horizontal ? flattenH(rect, !after) : flattenV(rect, ltrAt(wg.state, pos, 1, map) == !after)
        )
      }
    }
    if (!tile.parent) return new Coords(tile, new DOMRect())
    offset = tile.parent.children.indexOf(tile) + (after ? 1 : 0)
    tile = tile.parent
    assoc = after ? 1 : -1
  }

  // Scan through nearby nodes for a suitable target
  for (let pass = 0; pass < 2; pass++) {
    if (pass == (assoc < 0 ? 0 : 1)) {
      // Scan back
      for (let i = offset; i > 0; i--) {
        const before = tile.children[i - 1]!
        if (before instanceof WidgetTile && !before.widget.type.inFlow) continue
        if (before.dom.nodeName == 'BR') break
        const rect = singleRect(before.dom, 1)
        if (rect.width || rect.height) {
          return new Coords(before, horizontal ? flattenH(rect, false) : flattenV(rect, !ltrAt(wg.state, pos, 1, map)))
        }
      }
    } else {
      // Scan forward
      for (let i = offset; i < tile.children.length; i++) {
        const after = tile.children[i]!
        if (after instanceof WidgetTile && !after.widget.type.inFlow) continue
        const rect = singleRect(after.dom, -1)
        if (rect.width || rect.height) {
          return new Coords(after, horizontal ? flattenH(rect, true) : flattenV(rect, ltrAt(wg.state, pos, 1, map)))
        }
      }
    }
  }
  // All else failed, just try to get a rectangle for the target node
  const rect = singleRect(tile.dom, -assoc as -1 | 1)
  return new Coords(tile, horizontal ? flattenH(rect, assoc < 0) : flattenV(rect, assoc < 0))
}

function flattenV(rect: DOMRect, left: boolean) {
  return rect.width ? new DOMRect(left ? rect.left : rect.right, rect.top, 0, rect.height) : rect
}

function flattenH(rect: DOMRect, top: boolean) {
  return rect.height ? new DOMRect(rect.left, top ? rect.top : rect.bottom, rect.width, 0) : rect
}
