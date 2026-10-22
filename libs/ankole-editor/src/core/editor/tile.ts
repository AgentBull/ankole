import { Node, Mark, Leaf, Elt, ChangeSet, Attributes } from '../doc'
import { GardState, TextblockMap, BidiSpan } from '../state'
import { findClusterBreak } from '@marijn/find-cluster-break'
import {
  Widget,
  DecoElt,
  Decoration,
  DecoIterator,
  findChangedRanges,
  WrapperSource,
  renderWrapper,
  renderMarkWrapper,
  DecoSet,
  getDecoSet
} from './decoration'
import { eqArray } from './util'
import { textRange, singleRect, DOMNode, rmDOM } from './dom'
import { separateChange, Changes, isEmpty } from './changes'
import { type CompositionInfo } from './input'
import { type Wordgard } from './editor'

export enum TileFlag {
  None = 0,
  NodeInner = 0x1,
  PlotContent = 0x2,
  Spanning = 0x4,
  Wrapper = 0x8,
  Point = 0x10,
  PointBefore = 0x20,
  PointAfter = 0x40,
  PointSide = PointBefore | PointAfter,
  Composition = 0x80,
  Synced = 0x100, // Node has been synced. DOM content matches child list / text content, child array becomes read-only
  Atom = 0x200, // Composite tile whose length isn't determined by child length
  HasContent = 0x400, // EltTile whose elt has a content hole
  AfterContent = 0x800, // Tiles that sit after their parent's content position
  ContentNotLast = 0x1000, // EltTile that has children with AfterContent flag
  Dirty = 0x2000 // DOM change observed in this node, must not reuse
}

enum Orientation {
  Row,
  Col
}

export class CoordPos {
  constructor(
    readonly pos: number,
    readonly target: number | null,
    readonly side: -1 | 1,
    readonly vertOutside: boolean
  ) {}
  map(mapping: ChangeSet) {
    const target = this.target == null ? null : mapping.mapPos(this.target, 1, 'after')
    return new CoordPos(mapping.mapPos(this.pos), target, this.side, this.vertOutside)
  }
  static create(pos: number, side: -1 | 1, target: number | null = null, vertOutside = false) {
    return new CoordPos(pos, target, side, vertOutside)
  }
}

export class TilePos {
  constructor(
    readonly tile: Tile,
    readonly offset: number,
    readonly pos: number
  ) {}

  get dom() {
    return this.tile.dom
  }
}

// The nodes of the view tree are called tiles, because "node" already names document nodes and
// DOM nodes. A tile can hold other tiles.

export abstract class Tile {
  parent: CompositeTile | null = null
  abstract children: Tile[]
  length = 0
  flags: TileFlag

  constructor(
    public dom: Element | Text,
    flags: number
  ) {
    this.flags = flags & ~TileFlag.Synced
    dom.wgTile = this
  }

  get isAtom() {
    return false
  }
  get isNodeOuter() {
    return false
  }
  get isNodeInner() {
    return (this.flags & TileFlag.NodeInner) > 0
  }
  get isNode() {
    return this.isNodeOuter || (this.flags & TileFlag.NodeInner) > 0
  }
  get isPlotContent() {
    return (this.flags & TileFlag.PlotContent) > 0
  }
  get isText() {
    return false
  }
  get isDoc() {
    return false
  }
  get isWrapper() {
    return (this.flags & TileFlag.Wrapper) > 0
  }
  get isSpanning() {
    return false
  }
  get isComposition() {
    return (this.flags & TileFlag.Composition) > 0
  }
  get isPoint() {
    return (this.flags & TileFlag.Point) > 0
  }

  get isBlocking() {
    return !this.isText && (this.isNodeOuter || (this.isPoint && this.flags & TileFlag.PointSide))
  }
  get tag(): Node.Tag | null {
    return null
  }

  posBeforeChild(child: Tile, ownStart = this.posAtStart): number {
    for (let i = 0, pos = ownStart; ; i++) {
      const cur = this.children[i]!
      if (cur == child) return pos
      pos += cur.length
    }
  }

  get posBefore() {
    return this.parent!.posBeforeChild(this)
  }

  get posAtStart() {
    return this.parent ? this.parent.posBeforeChild(this) + this.boundary : 0
  }

  get posAfter() {
    return this.posBefore + this.length
  }

  get posAtEnd() {
    return this.posAtStart + this.length - 2 * this.boundary
  }

  get boundary(): 0 | 1 {
    return 0
  }

  get firstChild(): Tile | null {
    return this.children.length ? this.children[0]! : null
  }

  get lastChild(): Tile | null {
    const last = this.children.length - 1
    return last < 0 ? null : this.children[last]!
  }

  ignoreEvent(_event: Event) {
    return false
  }

  get ignoreMutations() {
    return false
  }

  toString() {
    return this.dom.nodeName + (this.children.length ? `(${this.children})` : '')
  }

  abstract sync(): void

  connect() {
    for (const ch of this.children) ch.connect()
  }

  disconnect(reused?: Map<Tile, Reused>) {
    if (!reused || reused.get(this) != Reused.Full) for (const ch of this.children) ch.disconnect(reused)
  }

  nearestNode(): Tile {
    return this.tag ? this : this.parent!.nearestNode()
  }

  markDirty() {
    if (!(this.flags & TileFlag.Dirty)) {
      this.flags |= TileFlag.Dirty
      this.parent?.markDirty()
    }
  }

  posAtCoords(state: GardState, x: number, y: number): CoordPos {
    const nodeTile = this.nearestNode()
    return nodeTile.posAtCoordsInner(nodeTile.posAtStart, state, x, y, null, Orientation.Col)
  }

  abstract posAtCoordsInner(
    start: number,
    state: GardState,
    x: number,
    y: number,
    textblock: TextblockMap | null,
    orientation: Orientation
  ): CoordPos

  static get(node: DOMNode) {
    return node.wgTile
  }
}

function checkSync(tile: Tile) {
  if (tile.flags & TileFlag.Synced && !(tile.flags & TileFlag.Dirty)) return false
  tile.flags |= TileFlag.Synced
  tile.flags &= ~TileFlag.Dirty
  return true
}

export class CompositeTile extends Tile {
  children: Tile[] = []
  declare dom: Element

  addChild(child: Tile) {
    if (this.flags & TileFlag.Synced) throw new Error('Cannot add to a synced tile')
    if (this.flags & TileFlag.ContentNotLast && !(child.flags & TileFlag.AfterContent)) {
      let i = this.children.length
      while (i > 0 && this.children[i - 1]!.flags & TileFlag.AfterContent) i--
      this.children.splice(i, 0, child)
    } else {
      this.children.push(child)
    }
    child.parent = this
  }

  sync() {
    if (!checkSync(this)) return
    let len = this.boundary * 2
    for (const ch of this.children) {
      ch.sync()
      len += ch.length
    }
    if (!(this.flags & TileFlag.Atom)) this.length = len
    this.syncChildren()
  }

  syncChildren() {
    let prev: DOMNode | null = null,
      next: ChildNode | null = this.dom.firstChild
    for (const child of this.children) {
      if (child.dom.parentNode == this.dom) {
        while (next && next != child.dom) next = rmDOM(next)
      } else {
        this.dom.insertBefore(child.dom, next)
      }
      prev = child.dom
      next = prev.nextSibling
    }
    while (next) next = rmDOM(next)
  }

  posAtCoordsInner(
    start: number,
    state: GardState,
    x: number,
    y: number,
    textblock: TextblockMap | null,
    orientation: Orientation
  ): CoordPos {
    const { tag } = this
    const outerOrientation = orientation
    if (tag && tag.isPlot) {
      orientation = tag.type.orientation == 'row' ? Orientation.Row : Orientation.Col
      if (tag.isTextblock) textblock = TextblockMap.get(state, start, start ? state.doc.plotAt(start - 1)! : state.doc)
      else if (tag.type.isBlock) textblock = null
    } else if (tag && tag.isText) {
      orientation = Orientation.Row
    }
    const result =
      this.isAtom || !this.children.length
        ? null
        : orientation == Orientation.Col
          ? this.posAtCoordsCol(start, state, x, y, textblock)
          : this.posAtCoordsRow(start, state, x, y, textblock)
    if (result) return result
    const rect = this.dom.getBoundingClientRect()
    const after =
      outerOrientation == Orientation.Row ? x > (rect.left + rect.right) / 2 : y > (rect.top + rect.bottom) / 2
    const target =
      this.tag && this.tag.type.isSelectable && x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom
        ? start
        : null
    return CoordPos.create(start + (after ? this.length - 2 * this.boundary : 0), after ? -1 : 1, target)
  }

  posAtCoordsRow(
    start: number,
    state: GardState,
    x: number,
    y: number,
    textblock: TextblockMap | null
  ): CoordPos | null {
    const result = rowScan<Tile>(x, y, add => {
      for (const child of this.children) {
        if (child instanceof WidgetTile && !child.widget.type.inFlow) continue
        let rects
        const { dom } = child
        if (dom.nodeType == 1) rects = (dom as Element).getClientRects()
        else if (dom.nodeType == 3) rects = textRange(dom as Text, 0, dom.nodeValue!.length).getClientRects()
        else continue
        for (let i = 0; i < rects.length; i++) if (add(rects[i]!, child)) return
      }
    })
    if (!result) return null
    const { closest, rect } = result
    const pos = this.posBeforeChild(closest, start)
    // Special case when querying a position after/before the
    // first/last child in a textblock
    if (textblock && textblock.start == start && (x < rect.left || x > rect.right)) {
      const atStart = x < rect.left == textblock.ltr
      const span = atStart ? textblock.order[0]! : textblock.order[textblock.order.length - 1]!
      if (span.ltr != textblock.ltr && pos >= span.from + textblock.start && pos <= span.to + textblock.start) {
        return atStart
          ? CoordPos.create(textblock.start, -1)
          : CoordPos.create(textblock.start + textblock.node.contentLength, 1)
      }
    }

    if (closest.dom.nodeName == 'BR') return CoordPos.create(pos, 1)
    if (closest.tag && closest.tag.isPlot && closest.tag.type.isInline) {
      if (x > rect.right) return CoordPos.create(pos + closest.length, -1)
      if (x < rect.left) return CoordPos.create(pos, 1)
    }
    return closest.posAtCoordsInner(
      pos + closest.boundary,
      state,
      x,
      Math.max(rect!.top, Math.min(rect!.bottom, y)),
      textblock,
      Orientation.Row
    )
  }

  posAtCoordsCol(start: number, state: GardState, x: number, y: number, textblock: TextblockMap | null): CoordPos {
    const lastBot = -1
    for (const child of this.children) {
      if (child.isPoint || child.dom.nodeType != 1) continue
      const rect = (child.dom as Element).getBoundingClientRect()
      if (rect.top > y) return CoordPos.create(this.posBeforeChild(child, start), y > (lastBot + rect.top) / 2 ? 1 : -1)
      if (rect.bottom >= y) {
        return child.posAtCoordsInner(
          this.posBeforeChild(child, start) + child.boundary,
          state,
          x,
          y,
          textblock,
          Orientation.Col
        )
      }
    }
    return CoordPos.create(start + this.length - 2 * this.boundary, -1)
  }
}

// Algorithm for posAtCoords in row-layout elements (textblocks, block
// containers with orientation=row, and text nodes). Locates the
// closest element to the coordinates, prioritizing y closeness, and
// organizing things that overlap vertically into rows.
function rowScan<T>(
  x: number,
  y: number,
  scan: (rect: (rect: DOMRect, value: T) => boolean) => void,
  depth = 0
): { closest: T; rect: DOMRect } | null {
  if (depth > 1) return null
  let closest: T | null = null,
    closestDx = 1e8,
    closestRect: DOMRect | null = null as any
  let above: DOMRect | null = null as any,
    below: DOMRect | null = null as any
  scan((rect: DOMRect, value: T) => {
    if (rect.bottom < y) {
      if (!above || above.bottom < rect.bottom) above = rect
    } else if (rect.top > y) {
      if (!below || below.top > rect.top) below = rect
    } else {
      const dx = rect.left > x ? rect.left - x : rect.right < x ? x - rect.right : 0
      if (dx < closestDx) {
        closest = value
        closestDx = dx
        closestRect = rect
        return !dx
      }
    }
    return false
  })

  if (closestRect) {
    if (closestDx) {
      // Use overlap over half of the smaller height to group rects into one row.
      // Glyph rects on adjacent lines can overlap by a fraction of a pixel.
      if (
        above &&
        above.bottom - Math.max(above.top, closestRect.top) > Math.min(above.height, closestRect.height) / 2
      ) {
        return rowScan(x, above.bottom - 1, scan, depth + 1)
      }
      if (
        below &&
        Math.min(below.bottom, closestRect.bottom) - below.top > Math.min(below.height, closestRect.height) / 2
      ) {
        return rowScan(x, below.top + 1, scan, depth + 1)
      }
    }
    return { closest: closest!, rect: closestRect }
  }
  const side: DOMRect | null = above && (!below || y - above.bottom < below.top - y) ? above : below
  if (!side) return null
  return rowScan(x, (side.top + side.bottom) / 2, scan, depth + 1)
}

export function ltrAt(state: GardState, pos: number, assoc: -1 | 1, textblock?: TextblockMap | null) {
  if (textblock === undefined) {
    const { textblockParent: block } = state.doc.resolve(pos)
    textblock = block ? TextblockMap.get(state, block.start, block.node) : null
  }
  if (!textblock) return state.textLTR
  const found = BidiSpan.find(textblock.order, textblock.toIndex(pos), assoc)
  return textblock.order[found]!.ltr
}

// Find the tile and offset for `pos` in the tile tree under `root`. See `DocTile.resolve`.
function resolveIn(root: Tile, pos: number, side: -1 | 1): TilePos {
  // First find the parent plot or wrapper that contains this position
  let parent: Tile = root,
    i = 0
  search: for (let scan: Tile = root, off = 0; ;) {
    for (let j = 0; j < scan.children.length && off <= pos; j++) {
      const ch = scan.children[j]!,
        end = off + ch.length
      if (scan == parent) {
        if (off == pos) i = j
        else if (pos == end) i = j + 1
      }
      if (
        !ch.isPoint &&
        ((ch.isPlotContent || ch.isNodeInner) && !ch.boundary ? pos >= off && pos <= end : pos > off && pos < end)
      ) {
        if (ch instanceof TextTile) return new TilePos(ch, pos - off, pos)
        else if (ch.isAtom) {
          i = j
          break search
        }
        scan = ch!
        off += ch.boundary
        if (ch.isPlotContent || ch.isWrapper) parent = ch!
        continue search
      }
      off = end
    }
    break
  }

  // Then make sure we're on the right side of nearby point and
  // node-inner structure
  adjust: for (;;) {
    if (i) {
      let before = parent.children[i - 1],
        parentBefore = parent,
        beforeI = i - 1
      while (before!.isWrapper) {
        parentBefore = before!
        before = before!.children[(beforeI = before!.children.length - 1)]
      }
      if ((before!.isNodeInner && before!.flags & TileFlag.AfterContent) || before!.flags & TileFlag.PointAfter) {
        parent = parentBefore
        i = beforeI
        continue adjust
      }
    }
    if (i < parent.children.length) {
      let after = parent.children[i],
        parentAfter = parent,
        afterI = i
      while (after!.isWrapper) {
        parentAfter = after!
        after = after!.children[(afterI = 0)]
      }
      if ((after!.isNodeInner && !(after!.flags & TileFlag.AfterContent)) || after!.flags & TileFlag.PointBefore) {
        parent = parentAfter
        i = afterI + 1
        continue adjust
      }
    }
    break
  }

  // Finally, skip side-less widgets and enter/leave wrappers or
  // text tiles at the given side
  if (side < 0) {
    while (!i && parent.isWrapper) {
      i = parent.parent!.children.indexOf(parent)
      parent = parent.parent!
    }
    while (i) {
      const before = parent.children[i - 1]!
      if (before.isPoint && !(before.flags & TileFlag.PointSide) && !before.isNodeInner) {
        i--
      } else if (before.isWrapper) {
        parent = before!
        i = parent.children.length
      } else {
        if (before instanceof TextTile) {
          parent = before
          i = parent.length
        }
        break
      }
    }
  } else {
    while (parent.isWrapper && i == parent.children.length) {
      i = parent.parent!.children.indexOf(parent) + 1
      parent = parent.parent!
    }
    while (i < parent.children.length) {
      const after = parent.children[i]!
      if (after.isPoint && !(after.flags & TileFlag.PointSide) && !after.isNodeInner) {
        i++
      } else if (after.isWrapper) {
        parent = after!
        i = 0
      } else {
        if (after instanceof TextTile) {
          parent = after
          i = 0
        }
        break
      }
    }
  }

  return new TilePos(parent, i, pos)
}

export class DocTile extends CompositeTile {
  declare dom: Element

  constructor(
    readonly state: GardState,
    dom: Element,
    readonly cursorWrapper: Mark.Set | null,
    readonly decoSet: DecoSet
  ) {
    super(dom, TileFlag.PlotContent)
  }

  static create(state: GardState, dom: Element, wg: Wordgard) {
    return new DocTile(state, dom, null, { points: new Map(), ranges: new Map() }).updateRanges(
      state,
      getDecoSet(state),
      [0, state.doc.length],
      wg
    )
  }

  get isDoc() {
    return true
  }

  get tag() {
    return this.state.doc.tag
  }

  update(state: GardState, changes: Changes, wg: Wordgard, composition?: CompositionInfo | null) {
    const decoSet = getDecoSet(state)
    const changed = findChangedRanges(this.state, this.decoSet, state, decoSet, changes)
    return this.updateRanges(state, decoSet, changed, wg, composition)
  }

  updateRanges(
    state: GardState,
    decoSet: DecoSet,
    changes: Changes,
    wg: Wordgard,
    composition?: CompositionInfo | null
  ) {
    const wrapper = composition?.wrapCursor || null
    if (isEmpty(changes) && eqArray(wrapper, this.cursorWrapper)) return this
    if (composition) {
      const separated = separateChange(changes, composition.fromB, composition.toB)
      if (!separated) composition = null
      else changes = separated
    }
    const builder = new ContentUpdate(state, this, wg, new DecoIterator(state, decoSet), wrapper)
    if (composition?.target && Tile.get(composition.target)) {
      builder.reused.set(Tile.get(composition.target)!, Reused.DOM)
    }
    for (let i = 0, posB = 0, startCovered = false; i < changes.length;) {
      const len = changes[i++]!,
        ins = changes[i++]!
      if (composition && posB == composition.fromB && ins >= 0) {
        if (!startCovered) builder.update(0, true)
        builder.composition(composition!, len)
        if (ins) {
          startCovered = i == changes.length || changes[i + 1] == -1
          if (startCovered) builder.update(0, true)
        }
      } else if (ins == -1) {
        builder.keep(len, !startCovered, i == changes.length)
        startCovered = false
      } else if (ins == -2) {
        builder.update(len, !startCovered)
        startCovered = true
      } else {
        builder.replace(len, ins, !startCovered)
        startCovered = true
      }
      posB += (ins >= 0 ? ins : len)!
    }
    const result = builder.finish()
    result.sync()
    if (wg.connected) {
      for (const ch of this.children) ch.disconnect(builder.reused)
      for (const tile of builder.toConnect) tile.widget.type.connect!(tile.widget.value, tile.dom)
    }
    return result
  }

  nearest(dom: DOMNode, requireNode = false) {
    for (let cur: DOMNode | null = dom; cur; cur = cur.parentNode) {
      const elt = cur.wgTile
      if (elt && (!requireNode || elt.tag) && this.owns(elt)) return elt
    }
    return null
  }

  owns(elt: Tile) {
    for (;;) {
      if (elt == this) return true
      const { parent } = elt
      if (!parent) return false
      elt = parent
    }
  }

  nodeTile(pos: number) {
    let off = 0,
      children = this.children
    search: for (;;) {
      for (const ch of children) {
        const end = off + ch.length
        if (pos < end) {
          if ((off == pos && ch.tag) || ch instanceof TextTile) return ch
          children = ch.children
          off += ch.boundary
          continue search
        }
        off = end
      }
      return null
    }
  }

  resolve(pos: number, side: -1 | 1 = -1) {
    return resolveIn(this, pos, side)
  }

  posFromDOM(dom: DOMNode, offset: number, bias: -1 | 1 = -1) {
    const elt = this.nearest(dom)
    if (!elt) return this.dom.compareDocumentPosition(dom) & 4 /* following */ ? this.length : 0

    if (elt.isText) return elt.posAtStart + Math.min(offset, elt.length)
    if (elt.isAtom) return elt.posAtStart + (bias > 0 ? elt.length : 0)

    let domBefore
    if (dom == elt.dom) {
      domBefore = dom.childNodes[offset - 1]
    } else {
      while (dom.parentNode != elt.dom) dom = dom.parentNode!
      domBefore = dom.previousSibling
    }
    // Move positions at the very start or end of inline plots out of them
    if (elt.tag && elt.tag.type.isInline && elt.tag.isPlot && (!domBefore || !domBefore.nextSibling)) {
      return domBefore ? elt.posAfter : elt.posBefore
    }

    while (domBefore && domBefore.wgTile?.parent != elt) domBefore = domBefore.previousSibling
    const eltBefore = domBefore?.wgTile
    return eltBefore ? elt.posBeforeChild(eltBefore) + eltBefore.length : elt.posAtStart
  }

  posBeforeDOM(dom: DOMNode) {
    const tile = this.nearest(dom)
    if (!tile) return null
    let pos = tile.posAtStart
    if (tile.dom != dom) {
      for (const ch of tile.children) {
        if (ch.dom.compareDocumentPosition(dom) & 2 /* preceding */) break
        pos += ch.length
      }
    }
    return pos
  }

  coordsForElement(pos: number): DOMRect | null {
    const tile = this.nodeTile(pos)
    if (!tile) return null
    if (tile instanceof TextTile) return textTileRect(tile, pos - tile.posBefore)
    return (tile.dom as Element).getBoundingClientRect()
  }
}

function textTileRect(tile: TextTile, offset: number) {
  return textRange(tile.dom, offset, findClusterBreak(tile.text, offset)).getBoundingClientRect()
}

export class EltTile extends CompositeTile {
  declare dom: Element
  declare parent: CompositeTile

  constructor(
    readonly elt: DecoElt,
    readonly _tag: Node.Tag | null,
    flags: number,
    length: number,
    dom: Element
  ) {
    super(dom, flags)
    this.length = length
  }

  get isSpanning() {
    return (this.flags & TileFlag.Spanning) > 0
  }
  get isNodeOuter() {
    return !!this.tag
  }
  get isAtom() {
    return !!this._tag && (this.flags & TileFlag.Atom) > 0
  }
  get boundary() {
    return this._tag && !(this.flags & TileFlag.Atom) ? 1 : 0
  }
  get tag() {
    return this._tag
  }

  get contentTile(): EltTile | null {
    if (!(this.flags & TileFlag.HasContent)) return null
    for (const ch of this.children) {
      if (ch.isNodeInner && ch.flags & TileFlag.HasContent) return (ch as EltTile).contentTile
    }
    return this
  }

  static of(elt: DecoElt, tag: Node.Tag | null, flags: number, length: number, dom?: Element | null) {
    if (elt.hasContent) {
      flags |= TileFlag.HasContent
      if (elt.children.length > 1) {
        const zero = elt.children.indexOf(0)
        if (zero > -1 && zero < elt.children.length - 1) flags |= TileFlag.ContentNotLast
      }
    }
    return new EltTile(elt, tag, flags, length, dom || elt.outerDOM())
  }
}

function setUneditable(dom: Element | Text) {
  if (dom.nodeType != 1) {
    const span = document.createElement('span')
    span.appendChild(dom)
    dom = span
  }
  if ((dom as HTMLElement).contentEditable == 'inherit' && !/^(br|hr|img|input|wbr)$/i.test(dom.nodeName)) {
    ;(dom as HTMLElement).contentEditable = 'false'
  }
}

export class WidgetTile extends Tile {
  constructor(
    readonly widget: Widget<any>,
    readonly _tag: Node.Tag | null,
    flags: TileFlag,
    dom: Element | Text,
    length: number = 0
  ) {
    super(dom, flags)
    this.length = length
  }

  get isNodeOuter() {
    return !!this._tag
  }
  get isAtom() {
    return true
  }
  get tag() {
    return this._tag
  }

  get children() {
    return noChildren
  }

  ignoreEvent(event: Event) {
    return !this.widget.type.propagateEvent(event)
  }

  get ignoreMutations() {
    return !this.widget.type.editable
  }

  sync() {
    checkSync(this)
  }

  connect() {
    this.widget.type.connect?.(this.widget.value, this.dom)
  }

  disconnect(reused?: Map<Tile, Reused>) {
    if (!reused || reused.get(this) != Reused.Full) this.widget.type.disconnect?.(this.widget.value, this.dom)
  }

  toString() {
    return this.widget.type == Widget.editableText || this.widget.type == Widget.text
      ? JSON.stringify(this.widget.value)
      : super.toString()
  }

  posAtCoordsInner(
    start: number,
    state: GardState,
    x: number,
    y: number,
    textblock: TextblockMap | null,
    orientation: Orientation
  ): CoordPos {
    if (!this.tag) return CoordPos.create(start, 1)
    const rect =
      this.dom.nodeType == 1
        ? (this.dom as Element).getBoundingClientRect()
        : textRange(this.dom as Text, 0, this.length).getBoundingClientRect()
    const after =
      orientation == Orientation.Col
        ? y > (rect.top + rect.bottom) / 2
        : x < (rect.left + rect.right) / 2 == ltrAt(state, start, 1, textblock)
    return after
      ? CoordPos.create(start + this.length - 2 * this.boundary, -1, start)
      : CoordPos.create(start, 1, start)
  }
}

export class TextTile extends Tile {
  declare dom: Text

  constructor(
    public text: string,
    dom: Text,
    flags: TileFlag = TileFlag.None
  ) {
    super(dom, flags)
    this.length = text.length
  }

  get children() {
    return noChildren
  }

  get isText() {
    return true
  }
  get isNodeOuter() {
    return true
  }
  get isAtom() {
    return true
  }

  sync() {
    if (!checkSync(this)) return
    if (this.dom.nodeValue != this.text) this.dom.nodeValue = this.text
  }

  toString() {
    return JSON.stringify(this.text)
  }

  posAtCoordsInner(start: number, state: GardState, x: number, y: number, textblock: TextblockMap | null): CoordPos {
    const { closest, rect } = rowScan<number>(x, y, add => {
      for (let i = 0; i < this.length;) {
        const end = findClusterBreak(this.text, i)
        const rect = singleRect(textRange(this.dom, i, end), 1, true)
        if (rect.top == rect.bottom) continue
        if (add(rect, i)) break
        i = end
      }
    })!
    const pos = start + closest
    const after = x > (rect.left + rect.right) / 2 == ltrAt(state, pos, 1, textblock)
    if (after) return CoordPos.create(start + findClusterBreak(this.text, closest), -1)
    else return CoordPos.create(pos, 1)
  }

  static of(text: string) {
    return new TextTile(text, document.createTextNode(text))
  }
}

const noChildren: Tile[] = []

interface TileWalker {
  enter(tile: EltTile): void
  skip(tile: Tile, from: number, to: number): void
  leave(tile: EltTile): void
}

// Used to track the previous tree during an update.
class TilePointer {
  // In most tiles, index is a child position. In text nodes, it is a
  // character offset, and in atoms (with length > 1), a position
  // offset.
  constructor(
    readonly tile: Tile,
    readonly index: number,
    readonly parent: TilePointer | null
  ) {}

  walk(dist: number, side: -1 | 1, walker?: TileWalker) {
    let { tile, index, parent } = this,
      nodeBoundary = 0 // 1=entering, 2=leaving
    for (;;) {
      if (!dist && side < 0 && !nodeBoundary) break
      if (tile.isAtom) {
        if (!dist) break
        nodeBoundary = 0
        const left = tile.length - index
        if (dist >= left) {
          dist -= left
          if (left && walker) {
            walker.skip(tile, index, tile.length)
          }
          ;({ tile, index, parent } = parent!)
          index++
        } else {
          if (walker) walker.skip(tile, index, index + dist)
          index += dist
          dist = 0
        }
      } else if (index == tile.children.length) {
        if (!dist && (tile.isDoc || (nodeBoundary != 2 && tile.isNode))) break
        if (walker) walker.leave(tile as EltTile)
        nodeBoundary = tile.isNodeInner ? 2 : 0
        dist -= tile.boundary
        ;({ tile, index, parent } = parent!)
        index++
      } else {
        const next = tile.children[index]!
        if (nodeBoundary == 1 && !next.isNodeInner) {
          nodeBoundary = 0
          if (side < 0 && !dist) break
        }
        if (!dist && next.isNodeInner && !nodeBoundary) break
        if (next.length < dist || (next.length == dist && (next.isPoint || next.boundary))) {
          if (walker) walker.skip(next, 0, next.length)
          dist -= next.length
          index++
          if (!next.isNodeInner) nodeBoundary = 0
        } else {
          if (next.isNodeOuter && !dist) break
          if (walker && !next.isAtom) walker.enter(next as EltTile)
          dist -= next.boundary
          parent = tile == this.tile && index == this.index ? this : new TilePointer(tile, index, parent)
          tile = next!
          index = 0
          nodeBoundary = next.isNode ? 1 : 0
        }
      }
    }
    return tile == this.tile && index == this.index ? this : new TilePointer(tile, index, parent)
  }

  tileAfter() {
    const { tile, index } = this
    if (tile.isAtom) return tile
    return index < tile.children.length ? tile.children[index] : null
  }

  matchingWrapper(elt: DecoElt, spanning: boolean, reused: Map<Tile, Reused>) {
    let best: EltTile | undefined,
      bestScore = 0
    const start = this.tile.isText ? this.parent! : this
    for (let { tile, parent } = start; !(tile.isNode || tile.isDoc); { tile, parent } = parent!) {
      const wrap = tile as EltTile
      if (reused.has(wrap) || wrap.elt.tagName != elt.tagName || wrap.isSpanning != spanning) continue
      const score = Attributes.compare(wrap.elt.attrs, elt.attrs)
      if (!best || bestScore < score) {
        best = wrap
        bestScore = score
      }
    }
    if (!best) return null
    if (bestScore < 0) updateAttributes(best.dom, best.elt.attrs, elt.attrs)
    reused.set(best, Reused.DOM)
    return best.dom
  }

  matchingWidget(widget: Widget<any>, sideFlag: number, reused: Map<Tile, Reused>) {
    let { index, tile, parent } = this
    if (!tile.isAtom) {
      for (;;) {
        if (!index) {
          if (!parent || (tile instanceof EltTile ? tile.tag : !(tile instanceof TextTile))) {
            break
          }
          ;({ index, tile, parent } = parent)
        } else {
          if (tile instanceof TextTile) break
          const before = tile.children[--index]!
          if (!before.isPoint) break
          if (
            !reused.has(before) &&
            before instanceof WidgetTile &&
            before.widget.eq(widget) &&
            (before.flags & TileFlag.PointSide) == sideFlag &&
            !(before.flags & TileFlag.Dirty)
          ) {
            reused.set(before, Reused.Full)
            return before
          }
        }
      }
    }
    return null
  }
}

enum Reused {
  Full = 1,
  DOM = 2
}

class ContentUpdate {
  old: TilePointer
  new: CompositeTile
  // Current position in the new document
  posB = 0
  reused = new Map<Tile, Reused>()
  keepWalker: TileWalker
  toConnect: WidgetTile[] = []
  partialNode: { tag: Node.Tag; length: number; shape: Decoration.Shape; wrappers: number; reuse: Tile | null } | null =
    null

  constructor(
    readonly state: GardState,
    old: DocTile,
    readonly wg: Wordgard,
    readonly deco: DecoIterator,
    cursorWrapper: Mark.Set | null
  ) {
    this.old = new TilePointer(old, 0, null)
    this.new = new DocTile(state, old.dom as Element, cursorWrapper, deco.decoSet)
    this.keepWalker = {
      enter: tile => {
        const span = tile.isSpanning && this.enterSpanning(tile.elt)
        if (span) {
          this.new = span
        } else {
          this.reused.set(tile, Reused.DOM)
          const inner = EltTile.of(tile.elt, tile.tag, tile.flags, tile.boundary * 2, tile.dom)
          this.new.addChild(inner)
          this.new = inner
        }
      },
      leave: tile => {
        if (tile.isWrapper) {
          for (let scan = this.new, i = 0; ;) {
            if (!scan.isWrapper) break
            if ((scan as EltTile).elt.eq(tile.elt) && scan.isSpanning == tile.isSpanning) {
              for (let j = 0; j <= i; j++) this.up()
              break
            }
            if (!scan.parent) break
            scan = scan.parent
          }
        } else if (tile.isNodeOuter) {
          this.leaveNode()
          this.leaveWrappers()
        }
      },
      skip: (tile, from, to) => {
        if (!(tile instanceof TextTile)) {
          if (!from && to == tile.length) {
            this.reused.set(tile, Reused.Full)
            this.new.addChild(tile)
          } else if (from == 0) {
            let wrappers = 0
            for (let w: Tile | null = this.new; w && w.isWrapper; w = w.parent) wrappers++
            const shape = tile instanceof EltTile ? tile.elt : tile instanceof WidgetTile ? tile.widget : null
            if (!shape || !tile.tag) throw new Error('Unexpected atom tile')
            this.partialNode = { tag: tile.tag, length: to - from, reuse: tile, shape, wrappers }
          } else {
            if (!this.partialNode) throw new Error('Missing partial node')
            if (to == tile.length) {
              const { tag, length, shape, reuse } = this.partialNode
              this.partialNode = null
              this.new.addChild(this.buildNodeShape(tag, length + (to - from), shape, reuse))
            }
          }
        } else if (this.new.lastChild instanceof TextTile && !this.new.lastChild.isComposition) {
          this.addText(tile.text.slice(from, to))
        } else if (!from && to == tile.text.length && !(tile.flags & TileFlag.Dirty) && !this.reused.has(tile)) {
          this.reused.set(tile, Reused.Full)
          this.new.addChild(tile)
        } else if (!this.reused.has(tile)) {
          this.reused.set(tile, Reused.DOM)
          this.new.addChild(new TextTile(tile.text.slice(from, to), tile.dom))
        } else {
          this.new.addChild(TextTile.of(tile.text.slice(from, to)))
        }
      }
    }
  }

  keep(len: number, includeStart: boolean, includeEnd: boolean) {
    const cut: number[] = [],
      end = this.posB + len
    // Compare this.old and this.new to find node tiles whose tag
    // changed and who have end widgets and whose end is inside the
    // kept range.
    if (this.deco.endWidgets) {
      for (let nw: CompositeTile = this.new, { tile, index, parent } = this.old, pos = this.posB; pos < end;) {
        if (tile.isAtom) {
          pos += tile.length - index
          ;({ tile, index, parent } = parent!)
          index++
        } else if (index < tile.children.length) {
          pos += tile.children[index]!.length
          index++
        } else {
          if (tile.tag) {
            while (!nw.tag && nw.parent) nw = nw.parent
            if (!nw.parent) break
            if (
              !nw.tag!.eq(tile.tag) &&
              (this.deco.hasEndWidget(tile.tag.type) || this.deco.hasEndWidget(nw.tag!.type))
            ) {
              cut.push(pos)
            }
            nw = nw.parent
            if (!nw) break
            pos++
          }
          if (!parent) {
            break
          }
          ;({ tile, index, parent } = parent)
          index++
        }
      }
    }
    // Split the kept range at such points, emitting update calls for
    // them, so that the widgets can be redrawn.
    for (let i = cut.length; i;) {
      let from = cut[--i]!
      const to = Math.min(from + 1, includeEnd ? end : end - 1)
      while (i && cut[i - 1] == from - 1) {
        from--
        i--
      }
      if (from > this.posB) this.keepInner(from - this.posB, includeStart, false)
      this.update(to - from, true)
      includeStart = false
      len = end - to
    }
    if (len) this.keepInner(len, includeStart, includeEnd)
  }

  keepInner(len: number, includeStart: boolean, includeEnd: boolean) {
    if (!includeStart) {
      this.old = this.old.walk(0, 1)
      this.openOldWrappers()
    }
    this.old = this.old.walk(len, includeEnd ? 1 : -1, this.keepWalker)
    this.posB += len
  }

  replace(len: number, ins: number, includeStart: boolean) {
    const start = this.old.walk(0, 1),
      end = (this.old = start.walk(len, 1))
    this.build(ins, false, includeStart, start, end)
  }

  update(len: number, includeStart: boolean) {
    this.old = this.old.walk(0, 1)
    this.build(len, true, includeStart)
  }

  composition(composition: CompositionInfo, lenA: number) {
    this.leaveWrappers()
    if (!composition.target) {
      for (const mark of composition.wrapCursor!) {
        if (mark.type.element) {
          this.openWrapper(renderMarkWrapper(mark), mark.spanning, false)
        }
      }
      this.new.addChild(
        new WidgetTile(Widget.img, null, TileFlag.Point | TileFlag.PointBefore, Widget.img.render(this.wg))
      )
      return
    }
    const found: EltTile[] = []
    for (let parent = composition.target.parentNode; parent; parent = parent.parentNode) {
      let tile = parent.wgTile
      if (!tile) {
        const elt = Elt.create(parent.nodeName.toLowerCase(), takeAttributes(parent as Element), Elt.hole)
        tile = new EltTile(elt, null, 0, 0, parent as Element)
      } else if (tile.isNode || tile.isDoc) {
        break
      }
      found.push(tile as EltTile)
    }
    for (let i = found.length - 1; i >= 0; i--) {
      const old = found[i]!
      if (old.isSpanning && this.enterSpanning(old.elt)) continue
      if (old.isSpanning && this.reused.has(old)) {
        const owner = old.dom.wgTile
        if (owner && owner != old) owner.dom = (owner as EltTile).elt.outerDOM()
      } else {
        this.reused.set(old, Reused.DOM)
      }
      const tile = EltTile.of(old.elt, null, old.flags, 0, old.dom)
      this.new.addChild(tile)
      this.new = tile
    }
    this.new.addChild(new TextTile(composition.text, composition.target, TileFlag.Composition))
    this.old = this.old.walk(lenA, 1)
    this.posB += composition.text.length
  }

  build(len: number, reuse: boolean, includeStart: boolean, startOld?: TilePointer, endOld?: TilePointer) {
    this.leaveWrappers()
    const start = this.posB,
      end = this.posB + len
    this.deco.walk(start, includeStart, end, {
      enter: (node, elt, wrappers) => {
        this.openWrappers(wrappers, reuse)
        const tile = this.buildNodeShape(node.tag, node.length, elt, (reuse ? this.old.tileAfter() : null)!) as EltTile
        this.new.addChild(tile)
        this.new = tile.contentTile!
        if (!this.new) throw new Error('Non-atom node rendered without hole')
        if (reuse) this.old = this.old.walk(1, 1)
        this.posB++
      },
      leave: () => {
        this.leaveNode()
        if (reuse) this.old = this.old.walk(1, 1)
        this.posB++
      },
      node: (node, shape, wrappers, partial) => {
        this.openWrappers(wrappers, reuse)
        let wrapCount = wrappers.length
        if (node.is(Leaf.Text)) {
          while (shape instanceof Elt) {
            this.openWrapper(Elt.create(shape.tagName, shape.attrs, Elt.hole), true, reuse)
            wrapCount++
            shape = shape.children[0] as Decoration.Shape
          }
          const next =
            (reuse || this.posB == start) && !(this.new.lastChild instanceof TextTile) && this.old.tileAfter()
          if (!(next instanceof TextTile) || this.reused.has(next)) {
            this.addText(node.param)
          } else if (next.text == node.param && !(next.flags & TileFlag.Dirty)) {
            this.reused.set(next, Reused.Full)
            this.new.addChild(next)
          } else {
            this.reused.set(next, Reused.DOM)
            this.new.addChild(new TextTile(node.param, next.dom))
          }
        } else if (partial != null) {
          this.partialNode = {
            tag: node.tag,
            length: partial,
            shape,
            wrappers: wrapCount,
            reuse: (reuse ? this.old.tileAfter() : null)!
          }
          if (reuse) this.old = this.old.walk(partial, 1)
          this.posB += partial
          return
        } else {
          this.new.addChild(this.buildNodeShape(node.tag, node.length, shape, (reuse ? this.old.tileAfter() : null)!))
        }
        for (let i = 0; i < wrapCount; i++) this.up()
        if (reuse) this.old = this.old.walk(node.length, 1)
        this.posB += node.length
      },
      nodePart: (node, length, done) => {
        if (!this.partialNode) throw new Error('Continuing unknown partial node')
        this.posB += length
        this.partialNode.tag = node.tag
        if (reuse) this.old = this.old.walk(length, 1)
        if (done) {
          const { tag, shape, wrappers, reuse } = this.partialNode
          this.partialNode = null
          this.new.addChild(this.buildNodeShape(tag, node.length, shape, reuse))
          for (let i = 0; i < wrappers; i++) this.up()
        }
      },
      widget: (widget, side) => {
        const sideFlag = side < 0 ? TileFlag.PointBefore : side > 0 ? TileFlag.PointAfter : 0
        let tile = reuse
          ? this.old.matchingWidget(widget, sideFlag, this.reused)
          : startOld && this.posB == start
            ? startOld.matchingWidget(widget, sideFlag, this.reused)
            : endOld && this.posB == end
              ? endOld.matchingWidget(widget, sideFlag, this.reused)
              : null
        if (!tile) {
          const dom = widget.render(this.wg)
          if (!widget.type.editable) setUneditable(dom)
          tile = new WidgetTile(widget, null, TileFlag.Point | sideFlag, dom)
          if (widget.type.connect) this.toConnect.push(tile)
        }
        this.new.addChild(tile)
      }
    })
  }

  findReusableTile(shape: Decoration.Shape, reuse: Tile | readonly Tile[] | null, strict: boolean): Tile | null {
    if (reuse instanceof EltTile) {
      if (
        shape instanceof Elt &&
        reuse.elt.tagName == shape.tagName &&
        !this.reused.has(reuse) &&
        (!strict || Attributes.eq(reuse.elt.attrs, shape.attrs))
      ) {
        return reuse
      }
      for (const ch of reuse.children) {
        if (ch instanceof EltTile && ch.isNodeInner) {
          const found = this.findReusableTile(shape, ch, strict)
          if (found) return found
        }
      }
      return this.findReusableTile(shape, reuse.children, strict)
    } else if (
      reuse instanceof WidgetTile &&
      shape instanceof Widget &&
      !this.reused.has(reuse) &&
      shape.eq(reuse.widget)
    ) {
      return reuse
    } else if (Array.isArray(reuse)) {
      for (const tile of reuse) {
        if (tile.isNodeInner) {
          const found = this.findReusableTile(shape, tile, strict)
          if (found) return found
        }
      }
    }
    return null
  }

  // node will be null when building inner structure
  buildNodeShape(
    tag: Node.Tag | null,
    length: number,
    shape: Decoration.Shape,
    reuse: Tile | readonly Tile[] | null,
    inEditable = true,
    afterContent = TileFlag.None
  ) {
    if (shape instanceof Elt) {
      if (inEditable && !shape.hasContent) {
        if (Attributes.get(shape.attrs, 'contenteditable') == null && !/^(br|hr|img|input|wbr)$/i.test(shape.tagName)) {
          shape = Elt.create(shape.tagName, Attributes.merge(shape.attrs, ['contenteditable', 'false']), shape.children)
        }
        inEditable = false
      }
      let strict = true
      let reusable = this.findReusableTile(shape, reuse, true)
      if (!reusable) {
        strict = false
        reusable = this.findReusableTile(shape, reuse, false)
      }
      let dom: Element | undefined
      if (reusable) {
        this.reused.set(reusable, Reused.DOM)
        dom = reusable.dom as Element
        if (reusable.flags & TileFlag.Dirty) updateAttributes(dom, takeAttributes(reusable.dom as Element), shape.attrs)
        else if (!strict) updateAttributes(dom, (reusable as EltTile).elt.attrs, shape.attrs)
      }
      const flags =
        (tag
          ? shape.hasContent
            ? TileFlag.None
            : TileFlag.Atom
          : TileFlag.NodeInner | (shape.hasContent ? TileFlag.None : TileFlag.Point)) | afterContent
      const tile = EltTile.of(shape, tag, flags, tag ? length : 0, dom)
      let afterContentInner = TileFlag.None
      for (const ch of shape.children) {
        if (ch === 0) {
          afterContentInner = TileFlag.AfterContent
          tile.flags |= TileFlag.PlotContent
        } else {
          tile.addChild(
            this.buildNodeShape(
              null,
              0,
              typeof ch == 'string' ? Widget.text.of(ch) : ch,
              reusable ? reusable.children : reuse,
              inEditable,
              afterContentInner
            )
          )
        }
      }
      return tile
    } else {
      const reusable = this.findReusableTile(shape, reuse, false)
      let dom: Element | Text
      if (reusable) {
        this.reused.set(reusable, Reused.DOM)
        dom = reusable.dom
      } else {
        dom = shape.render(this.wg)
      }
      if (inEditable && !shape.type.editable) setUneditable(dom)
      const flags = (tag ? TileFlag.Atom : TileFlag.Point | TileFlag.NodeInner) | afterContent
      const tile = new WidgetTile(shape, tag, flags, dom, tag ? length : 0)
      if (shape.type.connect) this.toConnect.push(tile)
      return tile
    }
  }

  ensureHackNode() {
    let tile = this.new
    if (!tile.isPlotContent) return
    while (tile.isNodeInner) tile = tile.parent!
    const tag = tile.tag
    if (!tag || !tag.isPlot) return
    // An empty block that holds a cursor (cursorBarrier "empty") and
    // can hold a textblock gets a <br> as well, so that the browser
    // can put the caret, and typed text, in it.
    if (
      !(tag.isTextblock || tag.type.isInline) &&
      (tag.type.spec.cursorBarrier != 'empty' ||
        this.state.schema.findWrapping(tag.type, Leaf.Text)?.length != 1 ||
        this.new.children.some(child => !(child instanceof WidgetTile) || child.tag))
    ) {
      return
    }

    // Textblocks get a trailing <br> if necessary
    let hasHack = -1,
      needsHack = true
    for (let parent = this.new, i = parent.children.length; ;) {
      if (i > 0) {
        const next = parent.children[--i]!
        if (next.isNodeInner || (next instanceof WidgetTile && !next.widget.type.inFlow)) {
          // Node-inner tiles and widgets outside the text flow do not count.
        } else if (next instanceof WidgetTile && next.widget == Widget.br && parent == this.new) {
          hasHack = i
        } else if (next.dom.nodeName == 'BR') {
          break
        } else if (next instanceof CompositeTile && !next.isAtom) {
          parent = next
          i = parent.children.length
        } else {
          needsHack = false
          break
        }
      } else if (parent == this.new) {
        break
      } else {
        i = parent.parent!.children.indexOf(parent)
        parent = parent.parent!
      }
    }

    if (hasHack > -1) {
      if (!needsHack) this.new.children.splice(hasHack, 1)
    } else if (needsHack) {
      this.new.addChild(
        new WidgetTile(Widget.br, null, TileFlag.Point | TileFlag.PointAfter, Widget.br.render(this.wg))
      )
    }
  }

  up() {
    this.ensureHackNode()
    this.new = this.new.parent!
  }

  leaveNode() {
    for (let inNode = true; ;) {
      if (!inNode && (this.new.isNode || this.new.isDoc)) break
      if (inNode && this.new.isNodeOuter) inNode = false
      this.up()
    }
  }

  leaveWrappers() {
    while (!(this.new.isNode || this.new.isDoc)) this.up()
  }

  openWrappers(wrappers: readonly WrapperSource[], reuse: boolean) {
    for (const src of wrappers) {
      this.openWrapper(renderWrapper(src), src.spanning, reuse)
    }
  }

  openOldWrappers() {
    let found: EltTile[] | undefined
    const start = this.old.tile.isText ? this.old.parent! : this.old
    for (let { tile, parent } = start; !tile.isNode && !tile.isDoc; { tile, parent } = parent!) {
      ;(found || (found = [])).push(tile as EltTile)
    }
    if (found) {
      for (let i = found.length - 1; i >= 0; i--) {
        this.openWrapper(found[i]!.elt, found[i]!.isSpanning, true)
      }
    }
  }

  openWrapper(elt: DecoElt, spanning: boolean, reuse: boolean) {
    const span = spanning && this.enterSpanning(elt)
    if (span) {
      this.new = span
    } else {
      const match = reuse ? this.old.matchingWrapper(elt, spanning, this.reused) : null
      const tile = EltTile.of(elt, null, TileFlag.Wrapper | (spanning ? TileFlag.Spanning : 0), 0, match)
      this.new.addChild(tile)
      this.new = tile
    }
  }

  enterSpanning(elt: DecoElt) {
    const cur = this.new
    for (let i = cur.children.length - 1; i >= 0; i--) {
      let prev = cur.children[i] as EltTile
      if (prev.isPoint) continue
      if (!prev.isSpanning || !prev.elt.eq(elt)) break
      // If this is a node from the old tree, copy it
      if (prev.flags & TileFlag.Synced) {
        const copy = (cur.children[i] = EltTile.of(elt, null, prev.flags, 0, prev.dom))
        for (const ch of prev.children) copy.addChild(ch)
        prev = copy
        prev.parent = cur
      }
      // Move any point tiles after the wrapper into it
      for (let j = i + 1; j < cur.children.length; j++) prev.addChild(cur.children[j]!)
      return prev
    }
    return null
  }

  addText(text: string) {
    const last = this.new.lastChild
    if (!(last instanceof TextTile) || last.isComposition) {
      this.new.addChild(TextTile.of(text))
    } else if (last.flags & TileFlag.Synced) {
      this.new.children.pop()
      this.new.addChild(new TextTile(last.text + text, last.dom))
      this.reused.set(last, Reused.DOM)
    } else {
      last.text += text
      last.length += text.length
    }
  }

  finish() {
    while (!(this.new instanceof DocTile)) this.up()
    this.ensureHackNode()
    return this.new
  }
}

function takeAttributes(elt: Element): Attributes {
  const attrs: string[] = []
  for (let i = 0; i < elt.attributes.length; i++) {
    const { name, value } = elt.attributes[i]!
    Attributes.push(attrs, name, value)
  }
  return attrs.length ? attrs : Attributes.none
}

export function updateAttributes(dom: Element, a: Attributes, b: Attributes) {
  let changed = false
  for (let iA = 0, iB = 0; ;) {
    let match = false
    if (iA < a.length && iB < b.length && a[iA] == b[iB]) {
      if (a[iA + 1] != b[iB + 1]) dom.setAttribute(b[iB]!, b[iB + 1]!)
      else match = true
      iA += 2
      iB += 2
    } else if (iA < a.length && (iB == b.length || a[iA]! < b[iB]!)) {
      dom.removeAttribute(a[iA]!)
      iA += 2
    } else if (iB < b.length) {
      dom.setAttribute(b[iB]!, b[iB + 1]!)
      iB += 2
    } else {
      break
    }
    if (!match) changed = true
  }
  return changed
}
