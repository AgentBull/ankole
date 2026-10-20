import { Shape, Elt, Attributes } from './shape'
import { type parse } from './parse'
import { compareDeep, eqArray, none } from './helper'
import type { Node, Plot } from './node'
import { SchemaError } from './error'

function remove<T>(arr: readonly T[], index: number) {
  return arr.length == 1 ? none : arr.filter((_, i) => i != index)
}

export function addSet<T>(a: readonly T[], b: readonly T[], compare: (a: T, b: T) => number) {
  const result: T[] = []
  for (let i = 0, j = 0; ;) {
    if (i == a.length) {
      if (j == b.length) return result
      result.push(b[j++]!)
    } else if (j == b.length) {
      result.push(a[i++]!)
    } else {
      const cmp = compare(a[i]!, b[j]!)
      if (cmp == 0) i++
      else if (cmp < 0) result.push(a[i++]!)
      else result.push(b[j++]!)
    }
  }
}

export function subtractSet<T>(a: readonly T[], b: readonly T[], compare: (a: T, b: T) => number) {
  const result: T[] = []
  for (let i = 0, j = 0; ;) {
    if (i == a.length) return result
    if (j == b.length) {
      result.push(a[i++]!)
    } else {
      const cmp = compare(a[i]!, b[j]!)
      if (cmp == 0) i++
      else if (cmp < 0) result.push(a[i++]!)
      else j++
    }
  }
}

/**
 * A mark has a type and a value. Some mark types without a
 * meaningful parameter value (such as {@link types.Emphasis}),
 * will only use a single mark object.
 */
export class Mark<Value = unknown> {
  private constructor(
    /** The type of the mark. */
    readonly type: Mark.Type<Value>,
    /**
     * The parameter value. This may be something like the link
     * target for a link mark, or the alignment side for a text
     * alignment mark.
     */
    readonly value: Value
  ) {}

  /** @internal */
  static create<Value>(type: Mark.Type<Value>, value: Value) {
    return new Mark(type, value)
  }

  /**
   * Compare this mark to another one. Parameter values are compared
   * by structure.
   */
  eq(other: Mark) {
    return this.type == other.type && compareDeep(this.value, other.value)
  }

  /** The name of this mark's type. */
  get name() {
    return this.type.name
  }

  /** @internal */
  get rank() {
    return this.type.rank
  }

  /** @internal */
  get spanning() {
    return this.type.spanning
  }

  /** @internal */
  toString() {
    return this.value == null ? this.name : `${this.name}=${JSON.stringify(this.value)}`
  }

  /** Define a singleton mark, without parameter. */
  static define(name: string, spec: Mark.Spec<null>): Mark<null> {
    return Mark.Type.define<null>(name, spec, true).default!
  }

  /**
   * Add this mark to the given set. Will overwrite existing
   * instances of the mark in the set, unless this is a {@link
   * Mark.Spec.set set-valued} mark.
   */
  addToSet(set: Mark.Set): Mark.Set {
    let placed = false
    const copy: Mark[] = []
    for (let i = 0; i < set.length; i++) {
      const other = set[i]!
      if (this.eq(other)) return set
      if (other.type != this.type) {
        if (!placed && this.type.compareRank(other.type) < 0) {
          copy.push(this)
          placed = true
        }
        copy.push(other)
      } else if (this.type.set) {
        copy.push(new Mark(this.type, addSet(other.value as any[], this.value as any[], this.type.set) as any))
        placed = true
      }
    }
    if (!placed) copy.push(this)
    return copy
  }

  /** Remove this mark from the given set. */
  removeFromSet(set: Mark.Set): Mark.Set {
    const type = this.type
    for (let i = 0; i < set.length; i++) {
      if (set[i]!.type == type) {
        const val = set[i]!
        let newSet: Mark.Set
        if (type.set) {
          const rest = subtractSet(val.value as any[], this.value as any[], type.set)
          if (!rest.length) {
            newSet = remove(set, i)
          } else {
            newSet = set.slice()
            ;(newSet as Mark[])[i] = new Mark(type, rest as any)
          }
        } else if (!val.eq(this as any)) {
          continue
        } else {
          newSet = remove(set, i)
        }
        return newSet
      }
    }
    return set
  }

  /** Test whether this mark is in the given set. */
  isInSet(set: Mark.Set): Mark<Value> | null {
    for (const v of set) if (v.eq(this)) return v as Mark<Value>
    return null
  }

  /** Compare two sets of marks. */
  static sameSet(a: Mark.Set, b: Mark.Set): boolean {
    return eqArray(a, b)
  }

  /** The empty mark set. */
  static none: Mark.Set = none
}

export namespace Mark {
  export class Type<Param = unknown> {
    /** @internal */
    readonly rank: number
    /** @internal */
    readonly set: null | ((a: any, b: any) => number)
    /**
     * The {@link Mark.Spec.defaultParam default} mark for this type,
     * if any.
     */
    readonly default: Mark<Param> | null
    /** Whether this is an {@link Mark.Spec.inclusive inclusive} mark. */
    readonly inclusive: boolean
    /** @internal */
    readonly element: { name: string; attrs(value: Param): Attributes } | null = null
    /** @internal */
    readonly attribute: { get(value: Param): Attributes; target: Elt.Selector | null } | null = null
    /** Whether this is a {@link Mark.Spec.spanning spanning} mark. */
    readonly spanning: boolean

    /**
     * The spec used to define this mark. (Its type parameter is set
     * to `any` to circumvent a typing issue where `Mark<T>` isn't a
     * subtype of `Mark<unknown>`.)
     */
    readonly spec: Mark.Spec<any>

    private constructor(
      /** The name of the mark's type. */
      readonly name: string,
      spec: Mark.Spec<Param>,
      isFlag: boolean
    ) {
      this.spec = spec
      this.rank = Math.max(0, Math.min(spec.rank ?? 100, 100))
      this.set = spec.set ? spec.set.compare : null
      this.default =
        isFlag || 'defaultParam' in spec ? Mark.create(this, isFlag ? (null as any) : spec.defaultParam!) : null
      this.inclusive = spec.inclusive !== false
      if ('element' in spec.shape) this.element = new ElementShape(spec.shape)
      else this.attribute = new AttributeShape(spec.shape, this)
      this.spanning = this.element ? spec.spanning !== false : !!spec.spanning
    }

    /** Create a mark of this type. */
    of(value: Param) {
      return Mark.create(this, value)
    }

    /** @internal */
    compareRank(other: Mark.Type) {
      return this.rank - other.rank || (other.name < this.name ? 1 : -1)
    }

    /** Remove the mark of this type from the given set, if present. */
    removeFromSet(set: Mark.Set): Mark.Set {
      for (let i = 0; i < set.length; i++) if (set[i]!.type == this) return remove(set, i)
      return set
    }

    /**
     * Test whether there is a mark of this type in the given set. If
     * so, return it.
     */
    isInSet(set: Mark.Set): Mark<Param> | null {
      for (const v of set) if (v.type == this) return v as Mark<Param>
      return null
    }

    /** Whether this mark is rendered with an element. */
    get isElement() {
      return !!this.element
    }

    /** Define a mark type with the given parameter type. */
    static define<Param>(
      name: string,
      spec: Mark.Spec<Param>,
      /** @internal */
      isFlag = false
    ) {
      return new Mark.Type<Param>(name, spec, isFlag)
    }
  }

  /** Configuration for marks. */
  export interface Spec<Param> {
    /**
     * Which node tags this mark may apply to, as node {@link Node.Query query}.
     * The default is `{and: [Node.Group.Inline, Node.Group.Leaf]}`.
     */
    target?: Node.Query
    /**
     * Determines the position of this mark relative to other marks.
     * Should be a number between 0 and 100. Marks with lower rank
     * appear first in mark set arrays, and are rendered around
     * higher rank marks when rendered as an element. Ties are broken
     * by name. Defaults to 100.
     */
    rank?: number
    /**
     * Whether this mark should be active when the cursor is positioned
     * at its end (or at its start when that is also the start of the
     * parent node). Defaults to true.
     */
    inclusive?: boolean
    /**
     * Whether this mark can span across multiple nodes, or refers to
     * an individual node. Only spanning marks can be added to text.
     * Spanning marks with an element representation can be drawn as
     * elements containing multiple nodes, unless another, lower-ranked
     * mark requires the nodes to be wrapped separately. Defaults to
     * true for specs with an element representation, false
     * for specs with an attribute representation.
     */
    spanning?: boolean
    /**
     * Used by {@link Plot.Tag.split `Plot.Tag.split`} to determine
     * whether to keep this mark in the split-off tag. `atEnd` will
     * be true if the split happens at the end of the node's content.
     */
    keepOnSplit?: boolean | ((tag: Plot.Tag, atEnd: boolean) => boolean)
    /**
     * Used by {@link Schema.withMarksFrom} to decide whether marks
     * of this type are preserved after the type change.
     */
    keepOnTypeChange?: boolean | ((from: Node.Tag, to: Node.Tag) => boolean)
    /**
     * A default value for the parameter. If given, a mark with this
     * parameter will be stored in {@link Mark.Type.default
     * `Mark.Type.default`}.
     */
    defaultParam?: Param
    /**
     * A function or type name used to validate parameters of this
     * mark. See {@link Node.Spec.validate `Node.Spec.validate`}.
     */
    validate?: string | ((value: Param) => void)
    /**
     * A mark parameter can be set-valued, which changes how adding
     * and removing marks of that type works. This requires the mark
     * parameter to be an array type. When adding a set-valued mark
     * to a mark set, the value of the mark in the new set is the
     * union of the values of its original value and the added mark.
     * Similarly, when removing such a mark, only the values in the
     * parameter of the removed mark are removed from the mark in the
     * set (except when there are none left, in which case the mark
     * is removed entirely).
     *
     * `compare` should be a function that compares two values and
     * returns 0 if they are the same, or an ordering number
     * otherwise. This is used to sort and compare the values.
     */
    set?: Param extends ReadonlyArray<infer Content> ? { compare: (a: Content, b: Content) => number } : never
    /**
     * A mark can be either represented with a wrapping element, or
     * with one or more attributes added to the affected nodes.
     */
    shape: Shape.Element<Param> | Shape.Attribute<Param> | Shape.Attributes<Param>
    /**
     * A set of parse rules for this mark. The `mark` field for these
     * will automatically be defaulted to the mark type itself.
     */
    parseRules?: readonly parse.Rule<Param>[]
  }

  /**
   * A set of marks is a sorted array in which a given mark type can
   * occur at most once.
   */
  export type Set = readonly Mark[]
}

class ElementShape<Param> {
  readonly name: string
  readonly attrs: (value: Param) => Attributes

  constructor(spec: Shape.Element<Param>) {
    this.name = spec.element
    const { attributes } = spec
    if (typeof attributes == 'function') {
      this.attrs = (value: Param) => Attributes.read(attributes(value))
    } else {
      const attrs = attributes ? Attributes.read(attributes) : Attributes.none
      this.attrs = () => attrs
    }
  }
}

export class AttributeShape<Param> {
  readonly get: (param: Param) => Attributes
  readonly target: Elt.Selector | null

  constructor(spec: Shape.Attribute<Param> | Shape.Attributes<Param>, type: Mark.Type<Param>) {
    if ('attribute' in spec) {
      const { value, attribute } = spec,
        style = attribute.startsWith('style/') ? `${attribute.slice(6)}: ` : null
      if (value === 0) {
        if (type.default) throw new SchemaError('Attribute shapes for parameter-less marks cannot use 0 as value')
        if (style) this.get = param => ['style', style + param]
        else this.get = param => [attribute, String(param)]
      } else if (typeof value == 'function') {
        if (style) {
          this.get = param => {
            const val = value(param)
            return val == null ? Attributes.none : ['style', style + val]
          }
        } else {
          this.get = param => {
            const val = value(param)
            return val == null ? Attributes.none : [attribute, val]
          }
        }
      } else {
        const attrs = style ? ['style', style + value] : [attribute, value]
        this.get = () => attrs
      }
    } else {
      const { attributes } = spec
      if (typeof attributes == 'function') {
        this.get = param => Attributes.read(attributes(param))
      } else {
        const attrs = Attributes.read(attributes)
        this.get = () => attrs
      }
    }
    this.target = spec.preferTarget ? Elt.Selector.parse(spec.preferTarget) : null
  }
}
