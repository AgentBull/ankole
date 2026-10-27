import { ChangeSet } from '../doc'
import { findAbove, addReplacements } from './util'
import { Set } from './set'
import { HeapCursor } from './heapcursor'

enum ChunkSize {
  Max = 512
}

class Chunk<T extends PointSet.Value> {
  constructor(
    readonly start: number,
    readonly pos: number[],
    readonly value: T[]
  ) {}

  get end() {
    return this.start + this.pos[this.pos.length - 1]!
  }

  get startSide() {
    return this.value[0]!.side
  }

  get endSide() {
    return this.value[this.value.length - 1]!.side
  }

  move(start: number) {
    return start == this.start ? this : new Chunk(start, this.pos, this.value)
  }
}

class SetBuilder<T extends PointSet.Value> {
  chunks: Chunk<T>[] = []
  lastPos = -1
  lastSide = -1

  addChunk(chunk: Chunk<T>) {
    this.chunks.push(chunk)
    this.lastPos = chunk.end
    this.lastSide = chunk.endSide
  }

  add(source: Set.Source<T>, pre?: (value: T, pos: number) => void) {
    if (typeof source != 'function') {
      const array = source
      source = add => {
        for (const [value, from, to] of array) add(value, from, to)
      }
    }
    source((value, from, to) => {
      if (to != null && from != to) throw new Error('Points cannot cover content')
      if (pre) pre(value, from)
      this.addPoint(value, from)
    })
  }

  addPoint(value: T, pos: number) {
    let chunk: Chunk<T> | undefined
    if (this.chunks.length) {
      chunk = this.chunks[this.chunks.length - 1]
      if (chunk!.value.length >= ChunkSize.Max) chunk = undefined
    }
    if (!chunk) {
      this.chunks.push((chunk = new Chunk(pos, [], [])))
    }
    chunk.pos.push(pos - chunk.start)
    chunk.value.push(value)
    if ((pos - this.lastPos || value.side || this.lastSide) >= 0) {
      this.lastPos = pos
      this.lastSide = value.side
    } else {
      // Move down until sorted
      for (let i = chunk.value.length - 1, chunkI = this.chunks.length - 1; ;) {
        let nextI = i - 1,
          nextChunk: Chunk<T> = chunk
        if (nextI < 0) {
          if (!chunkI) break
          nextChunk = this.chunks[--chunkI]!
          nextI = nextChunk.value.length - 1
        }
        if ((pos - nextChunk.pos[nextI]! || value.side - nextChunk.value[nextI]!.side) >= 0) break
        chunk.pos[i] = nextChunk.pos[nextI]!
        chunk.value[i] = nextChunk.value[nextI]!
        nextChunk.pos[nextI] = pos
        nextChunk.value[nextI] = value
        i = nextI
        chunk = nextChunk
      }
    }
  }

  finish(): PointSet<T> {
    return this.chunks.length ? PointSet.new(this.chunks) : PointSet.empty
  }
}

/**
 * Data structure used to store sets of points and then track them
 * across document changes. Mostly used for {@link Decoration.Point
 * point decorations}, but can also track your own types, if you make
 * sure they implement the {@link PointSet.Value} interface.
 */
export class PointSet<T extends PointSet.Value> implements Set<T> {
  private constructor(
    /** @internal */
    readonly chunks: readonly Chunk<T>[]
  ) {}

  /** @internal */
  static new<T extends PointSet.Value>(chunks: readonly Chunk<T>[]) {
    return new PointSet(chunks)
  }

  /**
   * Create a point set from an iterable of `[position, value]`
   * tuples, or a function that calls its argument for every point to
   * add.
   */
  static create<T extends PointSet.Value>(source: Set.Source<T>): PointSet<T> {
    const build = new SetBuilder<T>()
    build.add(source, (value, from) => {
      if ((from - build.lastPos || value.side - build.lastSide) < 0) throw new Error('Points must be added in order')
    })
    return build.finish()
  }

  get length(): number {
    return this.chunks.length ? this.chunks[this.chunks.length - 1]!.end : 0
  }

  get empty() {
    return this == PointSet.empty
  }

  /**
   * Create a cursor over this point set, starting at the given
   * position and side.
   */
  cursor(from = 0, side = -1e9): Set.Cursor<T> {
    return new PointCursor(this, from, side)
  }

  /** Create a cursor over a collection of point sets. */
  static cursor<T extends PointSet.Value>(sets: readonly PointSet<T>[], from = 0, side = -1e9): Set.Cursor<T> {
    const cursors: Set.Cursor<T>[] = []
    for (const set of sets) if (!set.empty) cursors.push(set.cursor(from, side))
    return cursors.length == 0
      ? PointSet.empty.cursor()
      : cursors.length == 1
        ? cursors[0]!
        : new HeapCursor(cmpCursor, cursors)
  }

  /**
   * Get the value at the given position, if any. If there's multiple
   * values at that position, the one with the lowest side is
   * returned. If a predicate is given, only points that satisfy it
   * are returned.
   */
  at(pos: number, pred?: (value: T) => boolean): T | undefined {
    for (const chunk of this.chunks) {
      if (chunk.start > pos) break
      if (chunk.end < pos) continue
      for (
        let index = findAbove(chunk.pos, 0, pos - chunk.start - 1);
        index < chunk.pos.length && chunk.pos[index]! + chunk.start == pos;
        index++
      ) {
        if (!pred || pred(chunk.value[index]!)) return chunk.value[index]
      }
    }
    return undefined
  }

  /**
   * Adjust the points for a set of document changes. Returns a new
   * set with the adjusted points. May delete points when the content
   * around them was deleted. Optionally accepts an ordered sequence
   * of replacements.
   */
  map(map: ChangeSet, replace: readonly Set.Replacement<T>[] = []): this {
    let { sections } = map
    if (replace.length) sections = addReplacements(map, replace)
    else if (map.empty) return this
    return this.mapInner(sections, map, replace) as any as this
  }

  private mapInner(sections: ChangeSet.Sections, map: ChangeSet, replace: readonly Set.Replacement<T>[]): PointSet<T> {
    const cursor = new PointCursor(this, 0, -1e9)
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
          } else if (cursor.from < upto) {
            build.addPoint(cursor.value!, cursor.from + off)
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
        if (len) cursor.goto(posA + len, -1e9)
        copyMappedUpto(cursor, posA + len, map, build, replace, replStartI)
        posB = endB
      }
      posA += len
    }
    return build.finish()
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
  ): PointSet<T> {
    const build = new SetBuilder<T>()
    const cursor = new PointCursor(this, 0, -1e9)
    const advance = (_: any, pos: number) => {
      for (;;) {
        const { cur } = cursor
        if (!cur) return
        if (cursor.i == 0 && cur.end <= pos && !filter) {
          build.addChunk(cur)
          cursor.next(true)
        } else if (cursor.from >= pos) {
          break
        } else {
          if (!filter || filter(cursor.value!, cursor.from, cursor.to)) build.addPoint(cursor.value!, cursor.from)
          cursor.next()
        }
      }
    }
    if (add) build.add(add, advance)
    advance(null, 1e9)
    return build.finish()
  }

  /**
   * Compare a range in this set with a range in another set. Call
   * `change` for every point that exists in one but not the other.
   */
  compareRange(fromA: number, b: PointSet<T>, fromB: number, len: number, change: (pos: number, value: T) => void) {
    if (this == b) return
    const curA = new PointCursor(this, fromA, -1e9),
      curB = new PointCursor(b, fromB, -1e9)
    const off = fromB - fromA,
      endB = fromB + len
    for (;;) {
      const nextA = curA.value ? curA.from + off : 1e9,
        nextB = curB.value ? curB.from : 1e9
      if (Math.min(nextA, nextB) > endB) break
      const cmp = nextA - nextB || curA.side - curB.side
      if (cmp == 0 && curA.cur!.value == curB.cur!.value) {
        // Identical chunk. Skip
        curA.next(true)
        curB.next(true)
      } else if (cmp == 0 && curA.value!.eq(curB.value!)) {
        curA.next()
        curB.next()
      } else if (cmp < 0) {
        change(nextA, curA.value!)
        curA.next()
      } else {
        change(nextB, curB.value!)
        curB.next()
      }
    }
  }

  /** The empty point set. */
  static empty = new PointSet<any>([])
}

function copyMappedUpto<T extends PointSet.Value>(
  cursor: Set.Cursor<T>,
  upto: number,
  map: ChangeSet,
  build: SetBuilder<T>,
  replace: readonly Set.Replacement<T>[],
  replI: number
) {
  while (cursor.value && cursor.from <= upto) {
    const value = cursor.value
    const pos = map.mapPos(cursor.from, value.side < 0 ? -1 : 1, value.trackMode)
    if (pos != null) {
      let filtered = false
      for (let i = replI; !filtered && i < replace.length && replace[i]!.from <= pos; i++) {
        if (replace[i]!.to >= pos) filtered = true
      }
      if (!filtered) build.addPoint(value, pos)
    }
    cursor.next()
  }
}

class PointCursor<T extends PointSet.Value> implements Set.Cursor<T> {
  chunkI = 0
  i = 0

  declare cur: Chunk<T> | null
  from = -1
  declare value: T | null

  constructor(
    readonly set: PointSet<T>,
    start: number,
    side: number
  ) {
    this.goto(start, side)
  }

  /** @hidden */
  get to() {
    return this.from
  }

  get side() {
    return this.value ? this.value.side : 1e9
  }

  goto(pos: number, side: number) {
    const diff = pos - this.from || side - this.side
    if (diff < 0) {
      this.chunkI = this.i = 0
    } else if (diff == 0 && this.cur) {
      // Rewind over points directly before the current position, if necessary
      for (; ; this.i--) {
        if (!this.i) {
          this.chunkI = 0
          break
        }
        if ((pos - this.cur.pos[this.i - 1]! || side - this.cur.value[this.i - 1]!.side) < 0) break
      }
    }
    for (let first = true; ;) {
      if (this.chunkI == this.set.chunks.length) {
        this.from = 1e9
        this.cur = this.value = null
        break
      }
      const chunk = this.set.chunks[this.chunkI]!
      if (chunk.end < pos || this.i == chunk.value.length) {
        this.chunkI++
        this.i = 0
      } else if (first) {
        this.i = findAbove(chunk.pos, this.i, pos - chunk.start - 1)
        first = false
      } else if ((pos - (chunk.start + chunk.pos[this.i]!) || side - chunk.value[this.i]!.side) > 0) {
        this.i++
      } else {
        this.cur = chunk!
        this.from = chunk.pos[this.i]! + chunk.start
        this.value = chunk.value[this.i]!
        break
      }
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
      if (this.chunkI == this.set.chunks.length) {
        this.value = this.cur = null
        return
      } else {
        cur = this.cur = this.set.chunks[this.chunkI]!
      }
    }
    this.from = cur.pos[this.i]! + cur.start
    this.value = cur.value[this.i]!
  }
}

function cmpCursor<T extends PointSet.Value>(a: Set.Cursor<T>, b: Set.Cursor<T>): number {
  return a.from - b.from || a.value!.side - b.value!.side
}

export namespace PointSet {
  /** Objects stored in a point set must conform to this interface. */
  export interface Value {
    /**
     * The side of the point. Used to provide a sorting of points at
     * the same position, and to determine cursor position relative to
     * the points. Points with side < 0 are always displayed before a
     * cursor at their position, those with side > 0 always after, and
     * those with side == 0 before or after depending on the cursor's
     * side.
     */
    side: number
    /**
     * Configures whether the point should be deleted when content next
     * to it is deleted. See {@link ChangeSet.mapPos}.
     */
    trackMode: ChangeSet.TrackMode | undefined
    /** Method to compare this value to another. */
    eq(other: Value): boolean
  }
}
