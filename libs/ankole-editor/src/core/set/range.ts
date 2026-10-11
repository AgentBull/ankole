import { ChangeSet } from '../doc'
import { findAbove, addReplacements } from './util'
import { Set } from './set'
import { HeapCursor } from './heapcursor'

enum ChunkSize {
  Max = 512
}

class Chunk<T> {
  constructor(
    readonly start: number,
    readonly from: number[],
    readonly to: number[],
    readonly value: T[]
  ) {}

  get end() {
    return this.start + this.to[this.to.length - 1]!
  }

  move(start: number) {
    return start == this.start ? this : new Chunk(start, this.from, this.to, this.value)
  }
}

class SetBuilder<T extends RangeSet.Value> {
  chunks: Chunk<T>[] = []
  spilled: SetBuilder<T> | null = null
  lastTo = -1
  lastFrom = -1

  get next() {
    return this.spilled || (this.spilled = new SetBuilder<T>())
  }

  addChunk(chunk: Chunk<T>) {
    if (chunk.start < this.lastTo) {
      this.next.addChunk(chunk)
    } else {
      this.chunks.push(chunk)
      this.lastTo = chunk.end
    }
  }

  add(source: Set.Source<T>, pre?: (from: number, to: number) => void) {
    if (typeof source != 'function') {
      const array = source
      source = add => {
        for (const [from, to, value] of array) add(from, to, value)
      }
    }
    source((value, from, to = from) => {
      if (pre) pre(from, to)
      this.addRange(value, from, to)
    })
  }

  addRange(value: T, from: number, to: number) {
    if (from >= to) {
      throw new Error('Ranges cannot be empty')
    }
    ;(this.lastTo <= from ? this : this.next).addInner(value, from, to)
  }

  addInner(value: T, from: number, to: number) {
    let chunk: Chunk<T> | undefined
    if (this.chunks.length) {
      chunk = this.chunks[this.chunks.length - 1]
      if (chunk!.value.length >= ChunkSize.Max) chunk = undefined
    }
    if (!chunk) {
      this.chunks.push((chunk = new Chunk(from, [], [], [])))
    }
    chunk.from.push(from - chunk.start)
    chunk.to.push(to - chunk.start)
    chunk.value.push(value)
    this.lastFrom = from
    this.lastTo = to
  }

  finish(plus: RangeSet<T> | null = null): RangeSet<T> {
    const next = this.spilled ? this.spilled.finish(plus) : plus
    if (!this.chunks.length) return next || RangeSet.empty
    return RangeSet.new(this.chunks, next)
  }
}

/**
 * Data structure that stores sets of ranges, for use with {@link
 * Decoration.Range range decorations} or other data types
 * implementing {@link RangeSet.Value}.
 */
export class RangeSet<T extends RangeSet.Value> extends Set<T> {
  private constructor(
    /** @internal */
    readonly chunks: readonly Chunk<T>[],
    /** @internal */
    readonly next: RangeSet<T> | null
  ) {
    super()
  }

  /** @internal */
  static new<T extends RangeSet.Value>(chunks: readonly Chunk<T>[], next: RangeSet<T> | null) {
    return new RangeSet(chunks, next)
  }

  /**
   * Create a range set from an iterable of `[from, to, value]`
   * tuples, or a function that calls its argument for every range to
   * add.
   */
  static create<T extends RangeSet.Value>(source: Set.Source<T>): RangeSet<T> {
    const build = new SetBuilder<T>()
    build.add(source, from => {
      if (from < build.lastFrom) throw new Error('Ranges must be added in order')
    })
    return build.finish()
  }

  get length(): number {
    return Math.max(this.chunks.length ? this.chunks[this.chunks.length - 1]!.end : 0, this.next ? this.next.length : 0)
  }

  get empty() {
    return this == RangeSet.empty
  }

  cursor(from = 0): Set.Cursor<T> {
    if (!this.next) return new LayerCursor(this, this.chunks, from)
    const cursors = [new LayerCursor(this, this.chunks, from)]
    for (let layer: RangeSet<T> | null = this.next; layer; layer = layer.next) {
      cursors.push(new LayerCursor(this, layer.chunks, from))
    }
    return new HeapCursor(cmpCursor, cursors)
  }

  /** Create a cursor over a collection of range sets. */
  static cursor<T extends RangeSet.Value>(sets: readonly RangeSet<T>[], from = 0): Set.Cursor<T> {
    const cursors: LayerCursor<T>[] = []
    for (const set of sets) {
      if (!set.empty) {
        for (let layer: RangeSet<T> | null = set; layer; layer = layer.next) {
          cursors.push(new LayerCursor(set, layer.chunks, from))
        }
      }
    }
    return cursors.length == 0
      ? RangeSet.empty.cursor()
      : cursors.length == 1
        ? cursors[0]!
        : new HeapCursor(cmpCursor, cursors)
  }

  map(map: ChangeSet, replace: readonly Set.Replacement<T>[] = []): this {
    let { sections } = map
    if (replace.length) sections = addReplacements(map, replace)
    else if (map.empty) return this
    return this.mapInner(sections, map, replace) as any as this
  }

  private mapInner(sections: ChangeSet.Sections, map: ChangeSet, replace: readonly Set.Replacement<T>[]): RangeSet<T> {
    const cursor = new LayerCursor(this, this.chunks, 0)
    let replI = 0,
      posA = 0,
      posB = 0
    const build = new SetBuilder<T>()
    for (let i = 0; i < sections.length;) {
      let len = sections[i++]!
      const ins = sections[i++]!
      if (ins < 0) {
        while (i < sections.length && sections[i + 1]! < 0) {
          len += sections[i]!
          i += 2
        }
        const upto = i == sections.length ? 1e9 : posA + len,
          off = posB - posA
        // Unchanged range. Copy over ranges and chunks entirely inside.
        while (cursor.cur) {
          const chunk = cursor.cur
          if (cursor.i == 0 && chunk.end < upto) {
            build.addChunk(chunk.move(chunk.start + off))
            cursor.next(true)
          } else if (cursor.to < upto) {
            build.addRange(cursor.value!, cursor.from + off, cursor.to + off)
            cursor.next()
          } else {
            break
          }
        }
        posB += len
      } else {
        // Iterate over replacements in this change's range, copy over
        // mapped version of ranges covering its start and end before
        // and after.
        const replStartI = replI,
          endB = posB + ins
        copyMappedUpto(cursor, posA, map, build, replace, replStartI)
        while (replI < replace.length && replace[replI]!.from < endB) {
          const repl = replace[replI++]!
          if (repl.add) build.add(repl.add)
        }
        if (len) cursor.goto(posA + len - 1)
        copyMappedUpto(cursor, posA + len, map, build, replace, replStartI)
        posB = endB
      }
      posA += len
    }
    return build.finish(this.next && this.next.mapInner(sections, map, replace))
  }

  modify(spec: {
    replace?: readonly Set.Replacement<T>[]
    add?: Set.Source<T>
    filter?: (value: T, from: number, to: number) => boolean
  }): this {
    const { replace, add, filter } = spec
    const result = replace?.length
      ? this.map(ChangeSet.empty(Math.max(this.length, replace[replace.length - 1]!.to)), replace)
      : this
    return add || filter ? (result.modifyInner(add, filter) as any as this) : result
  }

  private modifyInner(
    add: Set.Source<T> | undefined,
    filter?: (value: T, from: number, to: number) => boolean
  ): RangeSet<T> {
    const build = new SetBuilder<T>()
    const cursor = new LayerCursor(this, this.chunks, 0)
    const advance = (pos: number) => {
      for (;;) {
        const { cur } = cursor
        if (!cur) return
        if (cursor.i == 0 && cur.end <= pos && !filter) {
          build.addChunk(cur)
          cursor.next(true)
        } else if (cursor.from > pos) {
          break
        } else {
          if (!filter || filter(cursor.value!, cursor.from, cursor.to)) {
            build.addRange(cursor.value!, cursor.from, cursor.to)
          }
          cursor.next()
        }
      }
    }
    if (add) build.add(add, advance)
    advance(1e9)
    return build.finish(this.next && this.next.modifyInner(add, filter))
  }

  /**
   * Compare a section of this set with a section of the same length
   * in another set. Calls `change` for any range where the two do
   * not contain identical ranges.
   */
  compareRange(fromA: number, b: RangeSet<T>, fromB: number, len: number, change: (from: number, to: number) => void) {
    if (this == b) return
    const curA = new LayerCursor(this, this.chunks, fromA),
      curB = new LayerCursor(b, b.chunks, fromB),
      off = fromB - fromA
    const end = fromB + len
    let startA = -1
    let endA = -1
    let startB = -1
    let endB = -1
    for (;;) {
      if (startA >= endA) {
        ;[startA, endA] = curA.value ? [Math.max(fromB, curA.from + off), Math.min(end, curA.to + off)] : [1e9, 1e9]
      }
      if (startB >= endB) {
        ;[startB, endB] = curB.value ? [Math.max(fromB, curB.from), Math.min(end, curB.to)] : [1e9, 1e9]
      }
      const start = Math.min(startA, startB)
      let upto
      if (start >= end) break
      if (startA < startB) {
        change(startA, (upto = Math.min(endA, startB)))
        startA = upto
      } else if (startB < startA) {
        change(startB, (upto = Math.min(endB, startA)))
        startB = upto
      } else if (curA.cur!.value == curB.cur!.value) {
        // Identical chunks. Skip
        curA.next(true)
        curB.next(true)
        startA = startB = 1e9
      } else {
        upto = Math.min(endA, endB)
        if (!curA.value!.eq(curB.value!)) change(startA, upto)
        startA = startB = upto
      }
      if (startA >= endA) curA.next()
      if (startB >= endB) curB.next()
    }
    if (this.next || b.next) {
      ;(this.next || RangeSet.empty).compareRange(fromA, b.next || RangeSet.empty, fromB, len, change)
    }
  }

  /** The empty range set. */
  static empty = new RangeSet<any>([], null)
}

function copyMappedUpto<T extends RangeSet.Value>(
  cursor: Set.Cursor<T>,
  upto: number,
  map: ChangeSet,
  build: SetBuilder<T>,
  replace: readonly Set.Replacement<T>[],
  replI: number
) {
  while (cursor.value && cursor.from <= upto) {
    const value = cursor.value!
    const from = map.mapPos(cursor.from, value.inclusiveStart ? -1 : 1)
    const to = map.mapPos(cursor.to, value.inclusiveEnd ? 1 : -1)
    let filtered = from >= to
    for (let i = replI; !filtered && i < replace.length && replace[i]!.from < to; i++) {
      if (replace[i]!.to > from) filtered = true
    }
    if (!filtered) build.addRange(value, from, to)
    cursor.next()
  }
}

class LayerCursor<T extends RangeSet.Value> implements Set.Cursor<T> {
  chunkI = 0
  i = 0

  declare cur: Chunk<T> | null
  from = 0
  declare to: number
  declare value: T | null

  constructor(
    readonly set: RangeSet<T>,
    readonly chunks: readonly Chunk<T>[],
    start: number
  ) {
    this.goto(start)
  }

  goto(pos: number) {
    if (pos < this.from) this.chunkI = this.i = 0
    else if (pos < this.to) return
    const { chunks } = this
    while (this.chunkI < chunks.length && chunks[this.chunkI]!.end <= pos) {
      this.chunkI++
      this.i = 0
    }
    if (this.chunkI == chunks.length) {
      this.i = 0
      this.from = this.to = 1e9
      this.cur = this.value = null
    } else {
      const chunk = (this.cur = chunks[this.chunkI]!)
      const i = (this.i = findAbove(chunk!.to, this.i, pos - chunk!.start))
      this.from = chunk!.from[i]! + chunk!.start
      this.to = chunk!.to[i]! + chunk!.start
      this.value = chunk!.value[i]!
    }
  }

  next(chunk?: boolean) {
    let { cur } = this
    if (!cur) return
    if (!chunk && this.i < cur.value.length - 1) {
      this.i++
    } else {
      this.chunkI++
      this.i = 0
      if (this.chunkI == this.chunks.length) {
        this.from = this.to = 1e9
        this.value = this.cur = null
        return
      } else {
        cur = this.cur = this.chunks[this.chunkI]!
      }
    }
    this.from = cur.from[this.i]! + cur.start
    this.to = cur.to[this.i]! + cur.start
    this.value = cur.value[this.i]!
  }
}

const cmpCursor = (a: Set.Cursor<RangeSet.Value>, b: Set.Cursor<RangeSet.Value>): number => {
  return a.from - b.from || (a.value!.inclusiveStart ? (b.value!.inclusiveStart ? 0 : 1) : -1) || a.to - b.to
}

export namespace RangeSet {
  /** Values stored in a range set must conform to this interface. */
  export interface Value {
    /**
     * Whether content inserted at the start of this value's range is
     * included in the range.
     */
    inclusiveStart: boolean
    /** Whether content inserted at the end is included. */
    inclusiveEnd: boolean
    /** Compare this value to another. */
    eq(other: Value): boolean
  }
}
