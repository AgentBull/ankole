import { Plot, Leaf } from '../doc'
import { BidiSpan, computeOrder } from './bidi'
import { type GardSelection } from './selection'
import { type GardState } from './state'
import { findClusterBreak } from '@marijn/find-cluster-break'

const cache: WeakMap<Plot, TextblockMap> = new WeakMap()

enum Section {
  Text = 0,
  Atom = 1,
  BoundBefore = 2,
  BoundAfter = 3
}

// A section is stored as its length shifted left by `sectionShift`, with its kind in the low bits.
const sectionShift = 2,
  sectionKind = 3

/**
 * A textblock map contains the text in a textblock as a string, and
 * can help convert between string offsets and document positions.
 *
 * Note that this is not the way to convert a piece of document to a
 * string. Use {@link doc.Plot.textContent} for that.
 */
export class TextblockMap {
  private constructor(
    /** The start position of the textblock content. */
    readonly start: number,
    /** The textblock's document node. */
    readonly node: Plot,
    /** Whether the base direction of this block is left-to-right. */
    readonly ltr: boolean,
    /**
     * The text in the block. Non-text leaf nodes and nodes with
     * block content will be replaced by a single `0xfffc` character
     * in this string.
     */
    readonly text: string,
    private _order: readonly BidiSpan[] | null,
    private config: GardState.Configuration,
    // Describe the correspondence between the indices and document
    // positions. Each number starts with 2 bits holding a Section
    // flag, followed by the length of the section.
    private sections: number[]
  ) {}

  /**
   * The text order of the text in this block. Will generally be a
   * single span, but if the block mixes left-to-right and
   * right-to-left text, this describes the individual sections,
   * ordered from the block's start to its end.
   */
  get order() {
    return this._order || (this._order = computeOrder(this.text, this.ltr, []))
  }

  /**
   * Get the map for the given textblock. Will use a cache to reuse
   * results for unchanged blocks.
   */
  static get(cx: GardSelection.Context, start: number, node: Plot) {
    // Bidirectional isolates are not taken into account.
    const cached = cache.get(node)
    if (cached && cached.config == cx.config) {
      return cached.start == start
        ? cached
        : new TextblockMap(start, node, cached.ltr, cached.text, cached._order, cx.config, cached.sections)
    }
    const result = TextblockMap.create(start, node, cx.config)
    cache.set(node, result)
    return result
  }

  private static create(start: number, node: Plot, config: GardState.Configuration) {
    let text = ''
    const sections: number[] = []
    let sectionPos = 0
    const flush = (upto: number) => {
      if (upto > sectionPos) sections.push((upto - sectionPos) << sectionShift)
    }
    const scan = (node: Plot, pos: number) => {
      for (const ch of node.content) {
        if (ch.is(Leaf.Text)) {
          text += ch.param
        } else if (ch.isLeaf || config.isAtom(ch.type)) {
          text += '\ufffc'
          if (ch.length > 1) {
            flush(pos)
            sections.push((ch.length << sectionShift) | Section.Atom)
            sectionPos = pos + ch.length
          }
        } else {
          text += ' '
          scan(ch, pos + 1)
          text += ' '
        }
        pos += ch.length
      }
    }
    scan(node, 0)
    flush(node.contentLength)
    return new TextblockMap(start, node, config.textblockLTR(node), text, null, config, sections)
  }

  /**
   * Get the string index for a document position. Positions outside
   * of the textblock will be clipped to its start or end.
   */
  toIndex(pos: number) {
    if (pos < this.start) return 0
    let off = pos - this.start,
      idx = 0
    for (const n of this.sections) {
      const len = n >> sectionShift,
        flag = n & sectionKind
      if (flag == Section.Text) {
        if (off <= len) return idx + off
        off -= len
        idx += len
      } else if (flag == Section.Atom) {
        off = Math.max(0, off - len)
        if (off < 0) return idx
        idx++
      } else {
        if (off > 0) off--
      }
    }
    return idx
  }

  /** Get the document position for a given string index. */
  fromIndex(index: number) {
    let off = this.start
    for (const n of this.sections) {
      const len = n >> sectionShift,
        flag = n & sectionKind
      if (flag == Section.Text) {
        if (len > index) return off + index
        index -= len
      } else if (flag == Section.Atom) {
        if (!index) return off
        index--
      } else {
        if (!index) return off + (flag == Section.BoundBefore ? 1 : 0)
      }
      off += len
    }
    return off
  }

  /** @internal */
  moveVisually(
    start: number,
    side: number,
    forward: boolean,
    skipped?: string[]
  ): { pos: number; side: -1 | 1 } | null {
    // This implementation moves strictly visually, without concern
    // for a traversal visiting every logical position in the string.
    // It will still do so for simple input, but situations like
    // multiple isolates with the same level next to each other will
    // make some positions unreachable with this motion. Each visible
    // cursor position will correspond to the lower-level bidi span
    // that touches it.
    //
    // Positions at the start/end of the block with a direction
    // pointing away from the content indicate the first and last
    // position, even if there's a span not in the dominant direction
    // next to them (and thus the first/last character is not actually
    // visually at the start or end of line).
    //
    // Accumulates character skipped over in `skipped[0]`, when given.
    if (!this.text.length) return null
    let startIndex = this.toIndex(start)
    const { order, ltr } = this
    let spanI: number
    if (startIndex == 0 && side < 0) {
      // Start of line.
      if (!forward) return null
      spanI = 0
      startIndex = order[spanI]!.side(false, ltr)
    } else if (startIndex == this.text.length && side > 0) {
      // End of line.
      if (forward) return null
      spanI = order.length - 1
      startIndex = order[spanI]!.side(true, ltr)
    } else {
      spanI = BidiSpan.find(order, startIndex, side)
    }
    let span = order[spanI]!,
      spanEnd = span.side(forward, ltr)
    // End of span
    if (startIndex == spanEnd) {
      const nextI = (spanI += forward ? 1 : -1)
      if (nextI < 0 || nextI >= order.length) return null
      span = order[(spanI = nextI)]!
      startIndex = span.side(!forward, ltr)
      spanEnd = span.side(forward, ltr)
    }
    let nextIndex = findClusterBreak(this.text, startIndex, span.forward(forward, ltr))
    if (nextIndex == startIndex) return null
    if (nextIndex < span.from || nextIndex > span.to) nextIndex = spanEnd
    if (skipped) skipped[0] = this.text.slice(Math.min(startIndex, nextIndex), Math.max(startIndex, nextIndex))

    const nextSpan = spanI == (forward ? order.length - 1 : 0) ? null : order[spanI + (forward ? 1 : -1)]
    if (nextIndex == spanEnd) {
      // End of line.
      if (!nextSpan) {
        return forward ? { pos: this.start + this.node.contentLength, side: 1 } : { pos: this.start, side: -1 }
      }
      if (nextSpan.level + (forward ? 0 : 1) < span.level) {
        return { pos: this.fromIndex(nextSpan.side(!forward, ltr)), side: nextSpan.forward(forward, ltr) ? 1 : -1 }
      }
    }
    return { pos: this.fromIndex(nextIndex), side: nextIndex != spanEnd ? 1 : span.forward(forward, ltr) ? -1 : 1 }
  }

  /** @internal */
  skipWord(start: number, side: number, forward: boolean, visually: boolean): { pos: number; side: -1 | 1 } | null {
    let word = ''
    const skipped = ['']
    let cur: { pos: number; side: -1 | 1 } | null = null
    const history = new Map<number, { pos: number; side: -1 | 1 }>()
    for (;;) {
      let next
      let char
      const from = cur ? cur.pos : start
      if (visually) {
        next = this.moveVisually(from, cur ? cur.side : side, forward, skipped)
        char = skipped[0]
      } else {
        next = this.moveLogically(from, forward)
        char = next ? this.text.slice(Math.min(next.pos, from), Math.max(next.pos, from)) : ''
      }
      if (!next) break
      if (/\p{L}|\p{N}/u.test(char!)) {
        if (forward) word += char
        else word = skipped[0] + word
        history.set(word.length, next)
      } else if (word) {
        break
      }
      cur = next
    }
    if (!word) return null
    const segments = [...new Intl.Segmenter(undefined, { granularity: 'word' }).segment(word)]
    return history.get(segments[forward ? 0 : segments.length - 1]!.segment.length) || cur
  }

  /** @internal */
  moveLogically(start: number, forward: boolean): { pos: number; side: -1 | 1 } | null {
    const index = this.toIndex(start)
    const next = findClusterBreak(this.text, index, forward)
    return next == index ? null : { pos: this.fromIndex(next), side: 1 }
  }
}
