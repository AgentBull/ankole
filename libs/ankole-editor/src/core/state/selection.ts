import { Plot, Node, Leaf, ChangeSet, Mark, Pos, ValidationError } from '../doc'
import { findClusterBreak } from '@marijn/find-cluster-break'
import { TextblockMap } from './textblock'
import type { GardState } from './state'

type wgNode = Node

export class SelectionType {
  constructor(
    readonly tag: string,
    readonly cls: any,
    readonly toJSON: (sel: GardSelection) => unknown,
    readonly fromJSON: (doc: Plot.Doc, json: any) => GardSelection
  ) {}
}

/**
 * The base class for editor selections. Actual selections will be a
 * subclass of this—usually {@link GardSelection.Text} or {@link
 * GardSelection.Node}.
 */
export abstract class GardSelection {
  protected constructor(
    /**
     * The anchor of the selection—the side that doesn't move when
     * you extend it.
     */
    readonly anchor: number,
    /**
     * The head of the selection, which is moved when it is extended
     * (for example by moving the cursor while holding Shift).
     */
    readonly head: number,
    /**
     * The goal column (stored vertical offset) associated with a
     * selection. This is used to preserve the vertical position when
     * moving across lines of different length.
     */
    readonly goalColumn?: number
  ) {}

  /** The lower boundary of the selected range. */
  get from() {
    return Math.min(this.anchor, this.head)
  }

  /** The upper boundary of the range. */
  get to() {
    return Math.max(this.anchor, this.head)
  }

  /** True when `anchor` and `head` are at the same position. */
  get empty(): boolean {
    return this.anchor == this.head
  }

  /** Returns true when this is an empty text selection. */
  get isCursor(): boolean {
    return this.empty && this instanceof GardSelection.Text
  }

  /**
   * The set of ranges covered by this selection, sorted. By default,
   * this is just the selection's main `from` to `to`, but custom
   * selection implementations can override it.
   */
  get ranges(): readonly { from: number; to: number }[] {
    return [this]
  }

  /**
   * The range that should be used when replacing this selection with
   * other content (for example when typing or pasting over it) or
   * deleting it. The default implementation returns `this.from` to
   * `this.to`.
   */
  get replacementRange(): { from: number; to: number } {
    return this
  }

  /**
   * This can be overridden to control the DOM selection created for
   * a selection. The default is to just return the selection's own
   * head and anchor.
   */
  get domSelection(): { head: number; headSide: -1 | 1; anchor: number; anchorSide: -1 | 1 } {
    return this
  }

  /**
   * The side that the selection head is associated with. -1 means it
   * is after the element before its position, 1 means it is before
   * the element after its position. This influences where the
   * cursor is drawn (for example when on a line wrapping boundary
   * or in bidirectional text) and where further motion takes it. It
   * is valid for it to point in a direction where the is no element
   * (say, -1 when at the start of its parent node).
   *
   * By default, this points in the direction of the anchor or
   * forward if that is equal to the head, but selection types like
   * {@link GardSelection.Text} can override it.
   */
  get headSide(): -1 | 1 {
    return this.head > this.anchor ? -1 : 1
  }

  /**
   * The {@link GardSelection.headSide side} associated with the
   * selection anchor. Also by default points towards the head, or if
   * that is the same position, forward.
   */
  get anchorSide(): -1 | 1 {
    return this.anchor > this.head ? -1 : 1
  }

  /** Compare this selection to another selection. */
  abstract eq(other: GardSelection): boolean

  /**
   * Returns true if this selection has the same head and anchor as
   * the given selection.
   */
  eqPos(other: GardSelection) {
    return this.anchor == other.anchor && this.head == other.head
  }

  /**
   * Map a selection through a change. Used to adjust the selection
   * position for changes.
   */
  abstract map(change: ChangeSet, cx: GardSelection.Context, assoc?: -1 | 1): GardSelection

  /** @internal */
  check(config: GardState.Configuration, doc: Plot.Doc) {
    if (!config.staticFacet(GardSelection.selectionType).some(t => this instanceof t.cls)) {
      throw new RangeError('Unsupported selection type')
    }
    for (const { from, to } of this.ranges) {
      if (from < 0 || to > doc.length) throw new RangeError(`Selection out of document range`)
    }
  }

  /** @internal */
  resolve(doc: Plot.Doc) {
    return GardSelection.Resolved.create(doc, this)
  }

  /**
   * Convert this selection to an object that can be serialized to
   * JSON. Each selection type may define its own JSON representation
   * format.
   */
  toJSON(state: GardState): unknown {
    const type = state.facet(GardSelection.selectionType).find(tp => this instanceof tp.cls)
    if (!type) throw new Error('Selection type not enabled in state given to GardSelection.toJSON')
    const result = type.toJSON(this) as any
    result.type = type.tag
    return result
  }

  /**
   * Deserialize a selection. The configuration is used to associate
   * custom selection types with their implementation.
   */
  static fromJSON(cx: GardSelection.Context, json: unknown): GardSelection {
    const { doc, config } = cx,
      tag = (json as any).type as string
    const types = config.staticFacet(GardSelection.selectionType)
    const type = types.find(tp => tp.tag == tag)
    if (!type) throw new Error(`Unknown selection type '${tag}' in GardSelection.fromJSON`)
    return type.fromJSON(doc, json)
  }

  /** Create a cursor text selection at the given position. */
  static cursor(pos: number, side?: -1 | 1, goalColumn?: number) {
    return GardSelection.Text.createInner(pos, pos, side, goalColumn)
  }

  /** Find a normal cursor near the given position. */
  static near(cx: GardSelection.Context, pos: number, side: -1 | 1 = 1, goalColumn?: number) {
    const norm = findNormalAt(cx, pos, side)
    return GardSelection.cursor(norm.pos, norm.side, goalColumn)
  }

  /** Create a text selection. */
  static range(anchor: number, head?: number, headSide?: -1 | 1, goalColumn?: number) {
    return GardSelection.Text.createInner(anchor, head ?? anchor, headSide, goalColumn)
  }

  /** Create a node selection. */
  static node(pos: number, node: wgNode, goalColumn?: number) {
    return GardSelection.Node.create(pos, node, goalColumn)
  }

  /**
   * Find the next normal cursor position after or before this selection's
   * head. Normal cursor positions are:
   *
   * - Any inline position.
   *
   * - Positions between two cursor barriers, if not already an
   *   inline position. Cursor barriers are the sides of the
   *   document, any block leaves, or plots that are {@link
   *   Plot.Spec.isolating isolating}, {@link
   *   Plot.Spec.preserveWhitespace whitespace-preserving}, or
   *   explicitly defined as a {@link Plot.Spec.cursorBarrier
   *   cursor barrier}.
   */
  nextNormalCursor(cx: GardSelection.Context, forward = true): GardSelection.Text | null {
    const found = scanNormalFrom(cx, this.head, this.headSide, forward)
    return found && GardSelection.cursor(found.pos, found.side)
  }

  /** Move across one word starting from this selection's head. */
  skipWord(cx: GardSelection.Context, forward = true): GardSelection.Text | null {
    const found = skipWord(cx, this.head, this.headSide, forward)
    return found && GardSelection.cursor(found.pos, found.side)
  }

  /**
   * Find a normal selection at the start of the document or the
   * given textblock.
   */
  static atStart(cx: GardSelection.Context, block?: Pos.Plot) {
    return cursorAtStart(cx, block)
  }

  /**
   * Find a normal selection at the end of the document or the given
   * textblock.
   */
  static atEnd(cx: GardSelection.Context, block?: Pos.Plot) {
    const found = block
      ? TextblockMap.get(cx, block.start, block.node).visualSide(false)
      : cx.doc.inlineContent
        ? TextblockMap.get(cx, 0, cx.doc).visualSide(false)
        : findNormalAt(cx, cx.doc.length, -1)
    return GardSelection.cursor(found.pos, found.side)
  }

  /** @internal */
  declare static selectionType: GardState.Facet<SelectionType>
}

export namespace GardSelection {
  /**
   * Create an extension that registers a custom selection type using
   * the given class. Such a selection is only valid in a state that
   * has the extension active. The JSON representation of a selection
   * will be tagged with the `tag` string, and created and read via
   * the functions passed here.
   */
  export function define<T extends GardSelection, JSON extends object>(
    tag: string,
    cls: { new (...args: any[]): T },
    toJSON: (sel: T) => JSON,
    fromJSON: (doc: Plot.Doc, json: JSON) => T
  ) {
    return GardSelection.selectionType.of(new SelectionType(tag, cls, toJSON as any, fromJSON as any)) as any
  }

  /**
   * Text selections hold a single arbitrary range in the document.
   * They represent a cursor when their anchor and head are the same
   * position.
   */
  export class Text extends GardSelection {
    private constructor(
      anchor: number,
      head: number,
      private _headSide: -1 | 1,
      goalColumn: number | undefined,
      /**
       * A set of active marks that should be applied to content
       * inserted at this selection (replacing the contextual marks).
       * Used mostly for making the effect of toggling inline styles
       * stick until something is inserted. Marks that aren't valid for
       * the inserted content will be ignored.
       */
      readonly marks: Mark.Set | undefined
    ) {
      super(anchor, head, goalColumn)
    }

    /** @internal */
    static createInner(anchor: number, head: number, side?: -1 | 1, goalColumn?: number, marks?: Mark.Set) {
      return new Text(anchor, head, side ?? (head > anchor ? -1 : 1), goalColumn, marks)
    }

    get headSide() {
      return this._headSide
    }

    get anchorSide() {
      return this.anchor == this.head ? this._headSide : super.anchorSide
    }

    /** Create a text selection. */
    static create(spec: GardSelection.Text.Spec) {
      const { anchor, head = anchor } = spec
      return Text.createInner(anchor, head, spec.headSide, spec.goalColumn, spec.marks)
    }

    map(change: ChangeSet, _cx: GardSelection.Context, assoc: -1 | 1 = -1): GardSelection {
      let from, to
      if (this.empty) {
        from = to = change.mapPos(this.from, assoc)
      } else {
        from = change.mapPos(this.from, 1)
        to = Math.max(from, change.mapPos(this.to, -1))
      }
      // Keep the direction: the head of a backward selection stays in front.
      return this.head < this.anchor
        ? Text.createInner(to, from, this.headSide, this.goalColumn, this.marks)
        : Text.createInner(from, to, this.headSide, this.goalColumn, this.marks)
    }

    eq(other: GardSelection) {
      return (
        other instanceof Text &&
        this.eqPos(other) &&
        this.headSide == other.headSide &&
        (this.marks == other.marks ||
          !!(
            this.marks &&
            other.marks &&
            this.marks.length == other.marks.length &&
            this.marks.every((p, i) => p.eq(other.marks![i]!))
          ))
      )
    }
  }

  export namespace Text {
    /** Description of a text selection. */
    export type Spec = {
      /**
       * The anchor point of the selection. This is the side that doesn't
       * move when extending the selection (for example by moving the
       * cursor while holding shift).
       */
      anchor: number
      /**
       * The moving side of the selection. This will default to `anchor`
       * when not given.
       */
      head?: number
      /**
       * The side of the head position that the selection is associated
       * with, if any. `-1` points at the element before the position,
       * `1` at the element after. This is only meaningful for
       * empty/cursor selections. It will influence where the cursor is
       * drawn.
       */
      headSide?: -1 | 1
      /**
       * Associates a horizontal position with this selection for use
       * during vertical cursor motion.
       */
      goalColumn?: number
      /**
       * Marks associated with a cursor selection, which will determine
       * the marks of inline content inserted at that selection. This is
       * used for things like toggling emphasis on a cursor selection.
       */
      marks?: Mark.Set
    }

    /** The representation of a text selection when serialized to JSON. */
    export type JSON = {
      anchor: number
      head?: number
      side?: -1 | 1
      marks?: Record<string, any>
    }

    /** @internal */
    export const type = new SelectionType(
      'text',
      Text,
      ((sel: Text): JSON => {
        const result: JSON = { anchor: sel.anchor }
        if (sel.headSide != (sel.head > sel.anchor ? -1 : 1)) result.side = sel.headSide
        if (!sel.empty) result.head = sel.head
        if (sel.marks) {
          result.marks = {}
          for (const mark of sel.marks) result.marks[mark.name] = mark.value
        }
        return result
      }) as any,
      ((doc: Plot.Doc, json: JSON) => {
        if (!json || typeof json.anchor != 'number') {
          throw new ValidationError('Invalid JSON representation for GardSelection.Text')
        }
        const anchor = json.anchor,
          head = typeof json.head == 'number' ? json.head : anchor
        const marks = json.marks ? doc.schema.marksFromJSON(json.marks) : undefined
        return Text.createInner(
          anchor,
          head,
          json.side == 1 || json.side == -1 ? json.side : undefined,
          undefined,
          marks
        )
      }) as any
    )
  }

  /**
   * Node selections select a single node. They are created, for
   * example, when clicking on or moving into a {@link
   * Node.Spec.selectable selectable} leaf node. Use {@link
   * GardSelection.node} to create one.
   */
  export class Node extends GardSelection {
    private constructor(
      from: number,
      to: number,
      /** The selected node. */
      readonly node: wgNode,
      goalColumn?: number
    ) {
      super(from, to, goalColumn)
    }

    /** @internal */
    static create(pos: number, node: wgNode, goalColumn?: number) {
      return new Node(pos, pos + node.length, node, goalColumn)
    }

    map(change: ChangeSet, cx: GardSelection.Context, assoc: -1 | 1 = -1) {
      const newPos = change.mapPos(this.anchor, 1, 'after')
      if (newPos == null) return GardSelection.near(cx, change.mapPos(this.anchor, assoc), assoc)
      return Node.create(newPos, cx.doc.nodeAt(newPos) as Leaf)
    }

    eq(other: GardSelection) {
      return other instanceof Node && other.anchor == this.anchor
    }
  }

  export namespace Node {
    /** The representation of a node selection when serialized to JSON. */
    export type JSON = {
      pos: number
    }

    /** @internal */
    export const type = new SelectionType(
      'node',
      Node,
      (sel): JSON => ({ pos: sel.anchor }),
      (doc, json: JSON) => {
        const node = json && typeof json.pos == 'number' && doc.nodeAt(json.pos)
        if (!node || node.isText || !node.type.isSelectable) {
          throw new ValidationError('Invalid GardSelection.Node JSON representation')
        }
        return Node.create(json.pos, node)
      }
    )
  }

  /**
   * A selection object where the selection positions have been
   * {@link Plot.Doc.resolve resolved}. For convenience, an editor
   * state's {@link GardState.sel `sel` property} provides an
   * instance of this, derived from the state's regular selection.
   */
  export class Resolved {
    /** The selection anchor. */
    anchor: Pos
    /** The head of the selection. */
    head: Pos

    private _ranges: readonly { from: Pos; to: Pos }[] | null = null

    private constructor(
      /** @internal */
      readonly doc: Plot.Doc,
      /** The original selection. */
      readonly selection: GardSelection
    ) {
      this.anchor = doc.resolve(selection.anchor)
      this.head = selection.empty ? this.anchor : doc.resolve(selection.head)
    }

    /** @internal */
    static create(doc: Plot.Doc, selection: GardSelection) {
      return new Resolved(doc, selection)
    }

    /** The lower bound of the selection. */
    get from() {
      return this.anchor.pos < this.head.pos ? this.anchor : this.head
    }
    /** The upper bound of the selection. */
    get to() {
      return this.anchor.pos > this.head.pos ? this.anchor : this.head
    }

    /** The selection ranges. */
    get ranges() {
      return this._ranges || (this._ranges = this.resolveRanges())
    }

    private resolveRanges(): readonly { from: Pos; to: Pos }[] {
      return this.selection.ranges.map(({ from, to }) => ({ from: this.doc.resolve(from), to: this.doc.resolve(to) }))
    }

    /** The resolved replacement range. */
    get replacementRange(): { from: Pos; to: Pos } {
      const repl = this.selection.replacementRange
      if (repl.from == this.selection.from && repl.to == this.selection.to) return this
      return { from: this.doc.resolve(repl.from), to: this.doc.resolve(repl.to) }
    }

    /**
     * The active marks for this selection. If this is a cursor
     * selection with explicitly stored {@link
     * GardSelection.Text.Spec.marks marks}, those are returned.
     * Otherwise, this computes the marks that should be applied to
     * content inserted in the selection's position, based on
     * spanning marks on the surrounding nodes.
     */
    get activeMarks(): Mark.Set {
      const repl = this.replacementRange
      return (this.selection instanceof GardSelection.Text && this.selection.marks) || repl.from.marks(repl.to)
    }
  }

  /**
   * Many selection related functions need access to a configuration
   * (to determine text direction and visual motion behavior) and a
   * document. Note that {@link GardState} is a subtype of this.
   */
  export type Context = { doc: Plot.Doc; config: GardState.Configuration }
}

export function cursorAtStart(cx: GardSelection.Context, block?: Pos.Plot) {
  const found = block
    ? TextblockMap.get(cx, block.start, block.node).visualSide(true)
    : cx.doc.inlineContent
      ? TextblockMap.get(cx, 0, cx.doc).visualSide(true)
      : findNormalAt(cx, 0, 1)
  return GardSelection.cursor(found.pos, found.side)
}

function isBarrier(cx: GardSelection.Context, node: wgNode) {
  if (node.isLeaf) return node.isBlock
  const override = node.type.spec.cursorBarrier
  if (override == 'empty') return !node.content.length
  if (override != null) return override
  return node.isBlock && (node.type.isolating || node.type.preserveWhitespace || cx.config.isAtom(node.type))
}

// Find the next 'normal' cursor position from the given position. Any
// inline position not inside a surrogate pair, unicode cluster, or
// atomic node counts as a normal position, except when it is at the
// side of a non-cursor-inside inline plot. Positions between a block
// node that counts as a barrier and another such block node, or the
// end/start of the document, also count as normal positions.
function scanNormalFrom(
  cx: GardSelection.Context,
  from: number,
  side: -1 | 1,
  forward: boolean
): { pos: number; side: -1 | 1 } | null {
  let pos = cx.doc.resolve(from),
    pastBarrier = false
  if (pos.parent.node.inlineContent) {
    const block = pos.textblockParent!
    const map = TextblockMap.get(cx, block.start, block.node)
    const next = cx.config.visualCursorMotion
      ? map.moveVisually(pos.pos, side, forward)
      : map.moveLogically(pos.pos, forward)
    if (next != null) return next
    if (!block.parent) return null
    pos = Pos.create(block.parent, forward ? block.after : block.before, block.index + (forward ? 1 : 0), 0)
    pastBarrier = isBarrier(cx, block.node)
  } else {
    pastBarrier = !pos.parent.parent && pos.index == (forward ? 0 : pos.parent.node.content.length)
    for (
      let {
        parent: { node },
        index
      } = pos;
      !pastBarrier && (forward ? index : index < node.content.length);
    ) {
      const next = node.content[forward ? index - 1 : index]!
      if (isBarrier(cx, next)) pastBarrier = true
      if (next.isLeaf) {
        index += forward ? 1 : -1
      } else {
        if (next.inlineContent) break
        node = next!
        index = forward ? next.content.length : 0
      }
    }
  }

  let bottom = pos.pos
  const step = forward ? 1 : -1
  for (let { parent, index } = pos, p = pos.pos; ;) {
    const { node, parent: next } = parent
    if (node.inlineContent) {
      if (cx.config.visualCursorMotion) return TextblockMap.get(cx, parent.start, parent.node).visualSide(forward)
      return { pos: p, side: forward ? 1 : -1 }
    }
    if (index == (forward ? node.content.length : 0)) {
      const barrier = !next || isBarrier(cx, node)
      if (bottom != from && pastBarrier && barrier) return { pos: bottom, side: forward ? -1 : 1 }
      if (!next) return null
      index = parent.index + (forward ? 1 : 0)
      parent = next
      p += step
      bottom = p
      if (barrier) pastBarrier = true
    } else {
      const nextNode = node.content[index - (forward ? 0 : 1)]!
      const barrier = isBarrier(cx, nextNode)
      if (pastBarrier && bottom != from && barrier) return { pos: bottom, side: forward ? -1 : 1 }
      if (nextNode.isLeaf || cx.config.isAtom(nextNode.type)) {
        index += step
        p += nextNode.length * step
      } else {
        if (!forward) index--
        parent = Pos.Plot.create(parent, nextNode, forward ? p : p - nextNode.length, index)
        p += step
        index = forward ? 0 : nextNode.content.length
      }
      if (barrier) {
        pastBarrier = true
        bottom = p
      }
    }
  }
}

function findNormalAt(cx: GardSelection.Context, pos: number, bias: -1 | 1): { pos: number; side: -1 | 1 } {
  let res = cx.doc.resolve(pos),
    lowest = pos
  if (res.inText) {
    const text = res.parent.node.content[res.index]!.tag.param as string
    const off = bias > 0 ? findClusterBreak(text, res.inText - 1) : findClusterBreak(text, res.inText + 1, false)
    pos += off - res.inText
    if (off > 0 && off < text.length) return { pos, side: bias }
    res = Pos.create(res.parent, pos, res.index + (off ? 1 : 0), 0)
  }
  // Scan first in direction bias, then the other one, looking for a
  // valid inline position, and tracking the lowest block pos between
  // the nearest barriers as fallback.
  for (let pass = 0; pass < 2; pass++) {
    const dir = !pass ? bias : -bias
    let { parent, index } = res,
      curPos = pos
    for (;;) {
      if (parent.node.inlineContent) return { pos: curPos, side: bias }
      if (index == (dir > 0 ? parent.node.content.length : 0)) {
        if (isBarrier(cx, parent.node) || !parent.parent) break
        lowest = curPos = curPos + dir
        index = parent.index + (dir > 0 ? 1 : 0)
        parent = parent.parent
      } else {
        const nextIndex = index + (dir > 0 ? 0 : -1),
          next = parent.node.content[nextIndex]!
        if (next.isLeaf || isBarrier(cx, next)) break
        if (!parent.node.inlineContent && next.inlineContent && cx.config.visualCursorMotion) {
          const startPos = curPos - (dir > 0 ? 0 : next.length) + 1
          return TextblockMap.get(cx, startPos, next).visualSide(dir > 0)
        }
        parent = Pos.Plot.create(parent, next, curPos, nextIndex)
        index = dir > 0 ? 0 : next.content.length
        curPos += dir
      }
    }
  }
  return { pos: lowest, side: bias }
}

function skipWord(cx: GardSelection.Context, start: number, side: -1 | 1, forward: boolean) {
  let last: { pos: number; side: -1 | 1 } | null = null
  for (let pos = start, visually = cx.config.visualCursorMotion; ;) {
    const block = cx.doc.resolve(pos).textblockParent
    if (!block) {
      const next = scanNormalFrom(cx, pos, side, forward)
      if (!next) {
        return last
      }
      ;({ pos, side } = next)
    } else {
      const map = TextblockMap.get(cx, block.start, block.node)
      const next = map.skipWord(pos, side, forward, visually)
      if (next) return next
      if (!block.parent) return last
      const end: { pos: number; side: -1 | 1 } = visually
        ? map.visualSide(!forward)
        : forward
          ? { pos: block.end, side: -1 }
          : { pos: block.start, side: 1 }
      if (end.pos != start) last = end
      pos = forward ? block.after : block.before
    }
  }
}

export function wordAt(state: GardState, pos: number, bias: -1 | 1) {
  const res = state.doc.resolve(pos)
  if (!res.parent.node.inlineContent) return GardSelection.cursor(pos, bias)
  let start = pos,
    end = pos,
    text = ''
  scanBack: for (let i = res.index - (res.inText ? 0 : 1), cur = res.nodeBefore; cur;) {
    if (!cur.is(Leaf.Text)) break
    for (let j = cur.length; j > 0;) {
      const next = findClusterBreak(cur.param, j, false)
      const ch = cur.param.slice(next, j)
      if (!/\p{L}|\p{N}/u.test(ch)) break scanBack
      text = ch + text
      start -= j - next
      j = next
    }
    if (!i) break
    cur = res.parent.node.content[--i]!
  }
  scanForward: for (let i = res.index + 1, cur = res.nodeAfter; cur;) {
    if (!cur.is(Leaf.Text)) break
    for (let j = 0; j < cur.length;) {
      const next = findClusterBreak(cur.param, j, true)
      const ch = cur.param.slice(j, next)
      if (!/\p{L}|\p{N}/u.test(ch)) break scanForward
      text += ch
      end += next - j
      j = next
    }
    if (i == res.parent.node.content.length) break
    cur = res.parent.node.content[i++]!
  }
  let best: Intl.SegmentData | null = null
  const local = pos - start
  for (const segment of new Intl.Segmenter(undefined, { granularity: 'word' }).segment(text)) {
    if (
      segment.isWordLike &&
      segment.index <= local &&
      segment.index + segment.segment.length >= local &&
      (!best || bias > 0)
    ) {
      best = segment
    }
  }
  return best
    ? GardSelection.range(start + best.index, start + best.index + best.segment.length)
    : GardSelection.cursor(pos, bias)
}
