import { ChangeSet } from '../doc'

/**
 * The interface shared between {@link RangeSet} and {@link
 * PointSet}.
 */
export abstract class Set<T> {
  /** The number of values in this set. */
  abstract length: number

  /** Returns `true` when this set is empty. */
  abstract empty: boolean

  /**
   * Create a cursor over this point set, starting at the given
   * position and side.
   */
  abstract cursor(from?: number): Set.Cursor<T>

  /**
   * Adjust this set's positions for a set of document changes.
   * Returns a new set with the adjusted positions. Will delete
   * values when the content around them was deleted. Optionally
   * accepts an ordered sequence of replacements, whose positions
   * should refer to the post-change document.
   */
  abstract map(map: ChangeSet, replace?: readonly Set.Replacement<T>[]): this

  /** Create an updated copy of this set. */
  abstract modify(spec: {
    /** If given, replace all values in these ranges. */
    replace?: readonly Set.Replacement<T>[]
    /** Add values from this source. */
    add?: Set.Source<T>
    /**
     * Optionally filter out any value where this predicate returns
     * false.
     */
    filter?: (value: T, from: number, to: number) => boolean
  }): this
}

export namespace Set {
  /** A cursor over a point or range set. */
  export interface Cursor<T> {
    /**
     * The value of the current range or point, or `null` when there
     * are no more values.
     */
    value: T | null
    /** The start position of the current range or point. */
    from: number
    /**
     * The end position of the current range. Will be equal to `from`
     * for points.
     */
    to: number
    /** Move the cursor to a given position. */
    goto(pos: number, side?: number): void
    /** Continue to the next value, if any. */
    next(): void
    /** The set object that the current value points at, if any. */
    set: any
  }

  /**
   * A source, used to create or extend a set, is either
   * an array of `[value, pos, pos?]` tuples, or a function that calls its
   * argument to add a value.
   *
   * For ranges, `to` must be given, and ranges must be provided
   * ordered by start position. For points, `to` must be omitted or
   * be the same as `from`, and the points must be ordered by
   * position and {@link PointSet.Value.side side}.
   */
  export type Source<T> = Iterable<[T, number, number?]> | ((add: (value: T, pos: number, to?: number) => void) => void)

  /** Represents a replaced section in a set. */
  export type Replacement<T> = {
    /** The start of the replacement. */
    from: number
    /** The end of the replaced range. */
    to: number
    /** An optional source of points to to this section. */
    add?: Source<T>
  }
}
