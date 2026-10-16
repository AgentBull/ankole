import type { Node, Plot, Leaf } from './node'
import { Mark } from './mark'
import { none } from './helper'

/**
 * This class represents a {@link Plot.Doc.resolve resolved}
 * position.
 */
export class Pos {
  private constructor(
    /** The plot that the position points into. */
    readonly parent: Pos.Plot,
    /** The position itself. */
    readonly pos: number,
    /**
     * The index into its parent's content array. Note that if
     * `inText` is non-zero, this is the index of the text node.
     */
    readonly index: number,
    /**
     * Text nodes don't count as parent plots. Rather, positions that
     * fall inside a text node have a non-zero value here that
     * provides the offset into the text node.
     */
    readonly inText: number
  ) {}

  /** @internal */
  static create(parent: Pos.Plot, pos: number, index: number, inText: number) {
    return new Pos(parent, pos, index, inText)
  }

  /**
   * Find the innermost parent plot for which the given predicate
   * returns true.
   */
  matchingParent(pred: (plot: _Plot) => boolean) {
    for (let { parent } = this; ;) {
      if (pred(parent.node)) return parent
      if (!parent.parent) {
        return null
      }
      ;({ parent } = parent)
    }
  }

  /**
   * Move ahead through the document the given number of positions.
   * Don't descend into nodes that fall entirely within the skipped
   * range. If `walk` is given, call methods on it for each node
   * entered, skipped, or left. Return a new position at the end of
   * the range.
   */
  advance(distance: number, walk?: Pos.Walker) {
    return distance ? advancePos(distance, this.parent, this.pos, this.index, this.inText, walk) : this
  }

  /**
   * Move ahead through the document, always entering every plot. If
   * `walk` is given, call methods on it for each node or node
   * boundary passed. Return a new position.
   */
  walk(distance: number, walk: Pos.Walker) {
    return distance ? advancePos(distance, this.parent, this.pos, this.index, this.inText, walk, true) : this
  }

  /**
   * Get the node directly after this position. If `inText` is
   * non-zero, return only the part of the text node that's after the
   * position.
   */
  get nodeAfter(): Node | null {
    if (this.index == this.parent.node.content.length) return null
    const node = this.parent.node.content[this.index]
    return this.inText ? (node as Leaf<string>).sliceText(this.inText) : node!
  }

  /**
   * Get the node directly before this position. If `inText` is
   * non-zero, return only the part of the text node before the
   * position.
   */
  get nodeBefore(): Node | null {
    if (this.inText) return (this.parent.node.content[this.index] as Leaf<string>).sliceText(0, this.inText)
    return this.index ? this.parent.node.content[this.index - 1]! : null
  }

  /**
   * Get the nearest parent that is a {@link Plot.isTextblock
   * textblock}.
   */
  get textblockParent() {
    for (let p: Pos.Plot | null = this.parent; ; p = p.parent) {
      if (!p || !p.node.inlineContent) return null
      if (p.node.isTextblock) return p
    }
  }

  /**
   * Get the depth of this position (the amount of plots that wrap
   * it, not counting the document).
   */
  get depth() {
    return this.parent.depth
  }

  /** Get the parent plot at the given depth. */
  parentAt(depth: number) {
    const d = this.depth
    if (depth > d) throw new RangeError('Asking for parent deeper than position depth')
    for (let d = this.depth, p = this.parent; ; p = p.parent!) if (d == depth) return p
  }

  /**
   * Returns true if this position is right at the start of the given
   * parent plot, or transitively at the start of its first child.
   */
  isAtStart(parent: Pos.Plot) {
    if (this.inText) return false
    for (let p: Pos.Plot | null = this.parent, index = this.index; ; index = p.index, p = p.parent) {
      if (!p || index) return false
      if (p.pos == parent.pos) return true
    }
  }

  /**
   * Returns true if this position is right at the end of the given
   * parent plot, or transitively at the end of its last child.
   */
  isAtEnd(parent: Pos.Plot) {
    if (this.inText) return false
    for (let p: Pos.Plot | null = this.parent, index = this.index; ; index = p.index + 1, p = p.parent) {
      if (!p || index < p.node.content.length) return false
      if (p.pos == parent.pos) return true
    }
  }

  /** Get the document that this position points into. */
  get doc() {
    return this.parent.doc
  }

  /**
   * Get the set of active inline marks at this position or, if
   * `across` is given, the marks that would apply to content
   * replacing the range between that `this` and `across`.
   */
  marks(across?: Pos) {
    if (this.inText && (!across || across.pos == this.pos)) return this.parent.node.content[this.index]!.tag.marks
    const [from, to] = !across ? [this, this] : across.pos > this.pos ? [this, across] : [across, this]
    if (!from.parent.node.inlineContent || !to.parent.node.inlineContent) return Mark.none
    const before = from.nodeBefore,
      after = to.nodeAfter
    const [main, sec]: [Mark.Set, Mark.Set] = before
      ? [before.tag.marks, after ? after.tag.marks : none]
      : [after ? after.tag.marks : none, none]
    return main.filter(p => p.spanning && (p.type.inclusive || p.isInSet(sec)))
  }

  /** @internal */
  static resolve(doc: _Doc, pos: number): Pos {
    if (pos < 0 || pos > doc.length) throw new RangeError(`Resolving invalid position ${pos}`)
    const { top, cache } = cacheFor(doc)
    let nearest: Pos | undefined
    let nearestDist = 0
    let result
    if (pos == 0) return Pos.create(top, 0, 0, 0)
    for (const elt of cache) {
      if (elt.pos == pos) return elt
      const dist = Math.abs(elt.pos - pos)
      if (!nearest || dist < nearestDist) {
        nearest = elt
        nearestDist = dist
      }
    }
    if (nearest) {
      let { parent } = nearest
      while (parent.start > pos || parent.end < pos) parent = parent.parent!
      result = advancePos(pos - parent.start, parent, parent.start, 0, 0)
    } else {
      result = advancePos(pos, top, 0, 0, 0)
    }
    return (cache[cache.length < cacheSize ? cache.length : (cachePos = (cachePos + 1) % cacheSize)] = result)
  }

  /** @internal */
  static resolveNode(doc: _Doc, pos: number) {
    const base = this.resolve(doc, pos)
    if (base.inText) return null
    const after = base.nodeAfter
    return !after || after.isText
      ? null
      : after.isLeaf
        ? Pos.Node.create(base.parent, after, pos, base.index)
        : Pos.Plot.create(base.parent, after, pos, base.index)
  }
}

type _Node = Node
type _Plot = Plot
type _Doc = Plot.Doc
type _Tag = Plot.Tag

export namespace Pos {
  /**
   * Interface for the walker object that can be passed to {@link
   * Pos.advance `Pos.advance`} and {@link Pos.walk}.
   */
  export interface Walker {
    /**
     * Called when a node is skipped over. Will only be called for
     * leaves when using {@link Pos.walk}.
     */
    skip(node: _Node, pos: number, parent: Pos.Plot, index: number): void
    /** Called when a plot is entered. */
    enterPlot(node: _Plot, pos: number, parent: Pos.Plot, index: number): void | boolean
    /** Called when leaving a plot. */
    leavePlot(tag: _Tag, pos: number, parent: Pos.Plot, index: number): void
  }

  /**
   * Represents the position of a node, with information about its
   * parent plots.
   */
  export class Node {
    /** @hidden */
    protected constructor(
      /** The node's direct parent. */
      readonly parent: Pos.Plot | null,
      /** The node object. */
      readonly node: _Node,
      /** @internal */
      readonly pos: number,
      /** The node's index in its parent plot. */
      readonly index: number
    ) {}

    /** @internal */
    static create(parent: Pos.Plot | null, node: _Node, pos: number, index: number) {
      return new Node(parent, node, pos, index)
    }

    /**
     * The position before the node. Will raise an error if this is
     * the document top node.
     */
    get before() {
      if (this.pos < 0) throw new RangeError('Accessing `before` on the top level node')
      return this.pos
    }

    /** The position after the node. Throws if this is a document. */
    get after() {
      if (this.pos < 0) throw new RangeError('Accessing `after` on the top level node')
      return this.pos + this.node.length
    }

    /**
     * The depth of this node (the number of parent nodes, not
     * counting the document).
     */
    get depth() {
      let d = 0
      for (let n = this.parent; n; n = n.parent) d++
      return d
    }

    /** The document that this position points into. */
    get doc(): _Doc {
      if (this.parent) return this.parent.doc
      const { node } = this
      if (!node.isPlot || !node.isDoc) throw new Error('Outer parent not a document')
      return node as _Doc
    }

    /**
     * Returns true if this is either a document node or the first
     * node in its parent.
     */
    get isFirst() {
      return !this.parent || this.index == 0
    }
    /** Returns true if this is a document node or the last node in its parent. */
    get isLast() {
      return !this.parent || this.index == this.parent.node.content.length - 1
    }

    /** The node before this one, if any. */
    get nextSibling(): _Node | null {
      return this.isLast ? null : this.parent!.node.content[this.index + 1]!
    }
    /** The node after this node, if any. */
    get previousSibling(): _Node | null {
      return this.isFirst ? null : this.parent!.node.content[this.index - 1]!
    }
  }

  /** Subclass of {@link Pos.Node} that points at a plot node. */
  export class Plot extends Pos.Node {
    declare node: _Plot

    private constructor(parent: Pos.Plot | null, node: _Plot, pos: number, index: number) {
      super(parent, node, pos, index)
    }

    /** @internal */
    static create(parent: Pos.Plot | null, node: _Plot, pos: number, index: number) {
      return new Plot(parent, node, pos, index)
    }

    /** The position at the start of this plot's content. */
    get start() {
      return this.pos + 1
    }

    /** The position at end of this plot's content. */
    get end() {
      return this.pos + 1 + this.node.contentLength
    }
  }
}

const posCache = new WeakMap<Plot.Doc, { top: Pos.Plot; cache: Pos[] }>(),
  cacheSize = 8
let cachePos = 0

function cacheFor(doc: Plot.Doc) {
  let found = posCache.get(doc)
  if (!found) posCache.set(doc, (found = { top: Pos.Plot.create(null, doc, -1, 0), cache: [] }))
  return found
}

function advancePos(
  distance: number,
  parent: Pos.Plot,
  pos: number,
  index: number,
  inText: number,
  walk?: Pos.Walker,
  full = false
) {
  const target = pos + distance
  let { node } = parent
  if (inText) {
    const text = node.content[index] as Leaf<string>
    const textStart = pos - inText,
      textEnd = textStart + text.length
    if (walk) walk.skip(text.sliceText(inText, Math.min(text.length, target - textStart)), pos, parent, index)
    if (target < textEnd) return Pos.create(parent, target, index, target - textStart)
    pos = textEnd
    index++
  }
  while (pos < target) {
    if (index == node.content.length) {
      if (!parent.parent) throw new Error('Moving past end of document')
      if (walk) {
        walk.leavePlot(node.tag, pos, parent.parent, parent.index)
      }
      ;({ index, parent } = parent)
      node = parent.node
      index++
      pos++
    } else {
      const next = node.content[index]!,
        end = pos + next.length
      if (next.isLeaf) {
        if (next.isText && target < end) {
          if (walk) walk.skip(next.sliceText(0, target - pos), pos, parent, index)
          return Pos.create(parent, target, index, target - pos)
        } else {
          if (walk) walk.skip(next, pos, parent, index)
          pos = end
          index++
        }
      } else {
        let enter = full || target < end
        if (walk) {
          if (!enter) walk.skip(next, pos, parent, index)
          else if (walk.enterPlot(next, pos, parent, index) === false && target >= end) enter = false
        }
        if (enter) {
          parent = Pos.Plot.create(parent, next, pos, index)
          pos++
          node = next!
          index = 0
        } else {
          pos = end
          index++
        }
      }
    }
  }
  return Pos.create(parent, pos, index, 0)
}
