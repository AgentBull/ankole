import { Plot, Node } from './node'
import { Mark, subtractSet } from './mark'
import { Schema } from './schema'
import { Slice, SliceWalker, Token } from './slice'
import { Pos } from './pos'
import { validate } from './helper'
import { ValidationError } from './error'

class BuildContext {
  children: Plot[] = []
  constructor(
    readonly tag: Plot.Tag,
    readonly parent: BuildContext | null
  ) {}
}

class Builder implements Pos.Walker, SliceWalker {
  stack: BuildContext
  modifications: readonly Modification[] | null = null
  schema: Schema

  constructor(doc: Plot.Doc) {
    this.schema = doc.schema
    this.stack = new BuildContext(doc.tag, null)
  }

  add(node: Node) {
    if (this.modifications) {
      if (node.isPlot) throw new ValidationError('Invalid modification on non-leaf node')
      node = node.withMarks(applyModifications(this.modifications, node.marks))
    }
    node.pushTo(this.stack.children)
  }

  enterPlot(plot: Plot) {
    this.open(plot.tag)
  }

  leavePlot() {
    if (this.modifications) throw new ValidationError('Invalid modification on close token')
    if (!this.stack.parent) throw new ValidationError(`Surplus close token after ${this.stack.children}`)
    const top = this.stack
    this.stack = this.stack.parent
    this.add(top.tag.create(top.children))
  }

  skip(node: Node) {
    this.add(node)
  }

  open(tag: Plot.Tag) {
    if (this.modifications) tag = tag.withMarks(applyModifications(this.modifications, tag.marks))
    this.stack = new BuildContext(tag, this.stack)
  }

  close() {
    this.leavePlot()
  }

  node(node: Node) {
    this.skip(node)
  }

  finish() {
    if (this.stack.parent) throw new ValidationError('Invalid change')
    return this.schema.doc(this.stack.children)
  }
}

type Modification = { add: Mark } | { remove: Mark }

function isAdd(m: Modification): m is { add: Mark } {
  return !!(m as any).add
}
function isRemove(m: Modification): m is { remove: Mark } {
  return !!(m as any).remove
}

function applyModifications(modifications: readonly Modification[], marks: Mark.Set) {
  for (const m of modifications) {
    if (isAdd(m)) {
      marks = m.add.addToSet(marks)
    } else {
      marks = m.remove.removeFromSet(marks)
    }
  }
  return marks
}

function modificationToJSON(m: Modification): ModificationJSON {
  return isAdd(m) ? { add: m.add.name, value: m.add.value } : { remove: m.remove.name, value: m.remove.value }
}

function modificationFromJSON(schema: Schema, json: ModificationJSON): Modification {
  const { add, remove } = json as { add?: string; remove?: string }
  if (typeof add == 'string' || typeof remove == 'string') {
    const mark = schema.getMark((add || remove)!)
    if (!mark) throw new ValidationError(`Unknown mark ${add || remove}`)
    const value = mark.of(validate(mark.spec.validate, json.value))
    if (mark) return add ? { add: value } : { remove: value }
  }
  throw new ValidationError('Invalid modification JSON')
}

function compareModifications(a: readonly Modification[], b: readonly Modification[]) {
  if (a == b) return true
  if (a.length != b.length) return false
  for (let i = 0; i < a.length; i++) if (!compareModification(a[i]!, b[i]!)) return false
  return true
}

function compareModification(a: Modification, b: Modification) {
  return isAdd(a) ? isAdd(b) && a.add.eq(b.add) : isRemove(b) && a.remove.eq(b.remove)
}

function isNatNum(value: any): value is number {
  return typeof value == 'number' && Math.floor(value) == value && value >= 0
}

const noTokens = Slice.empty.content

function sliceLen(tokens: readonly Token[]) {
  return tokens.reduce((l, e) => l + (e.tokenType == Token.Type.Node ? e.length : 1), 0)
}

type SectionData = readonly Token[] | readonly Modification[] | null

const applyCache = new WeakMap<ChangeSet, { a: Plot.Doc; b: Plot.Doc }>()

/**
 * A change set contains a series of changes to a given document that
 * produce a new document. They divide the document in a number of
 * sections that are either kept as-is, have marks added or removed,
 * or are replaced entirely by a {@link Slice} of new tokens.
 *
 * Change sets store the length of their start document and will
 * raise an error if you try to apply them to a document with a
 * different length.
 */
export class ChangeSet {
  private _length = -1
  private _newLength = -1

  private constructor(
    /**
     * Pairs of integers, with the first one representing the length
     * of the section in the start document, the second either -1 for
     * a preserved, -2 for a marked range, or a non-negative
     * insertion length for a replacement.
     */
    readonly sections: ChangeSet.Sections,
    /** @internal */
    readonly data: readonly SectionData[]
  ) {}

  /** @internal */
  static new(sections: ChangeSet.Sections, data: readonly SectionData[]) {
    return new ChangeSet(sections, data)
  }

  /** The length of the start document. */
  get length() {
    if (this._length < 0) {
      this._length = 0
      for (let i = 0; i < this.sections.length; i += 2) this._length += this.sections[i]!
    }
    return this._length
  }

  /** The length of the updated document. */
  get newLength() {
    if (this._newLength < 0) {
      this._newLength = 0
      for (let i = 0; i < this.sections.length; i += 2) {
        const ins = this.sections[i + 1]!
        this._newLength += (ins < 0 ? this.sections[i] : ins)!
      }
    }
    return this._newLength
  }

  /** Returns true if this set makes no changes. */
  get empty() {
    return this.sections.length == 0 || (this.sections.length == 2 && this.sections[1] === -1)
  }

  /** Compare this change set to another one. */
  eq(other: ChangeSet) {
    if (other.sections.length != this.sections.length) return false
    for (let i = 0; i < this.sections.length; i++) if (this.sections[i] != other.sections[i]) return false
    for (let i = 0; i < this.data.length; i++) {
      const a = this.data[i] as any,
        b = (other as ChangeSet).data[i] as any
      if (a && !(this.sections[(i << 1) + 1]! < 0 ? compareModifications(a, b) : Slice.eq(a, b))) return false
    }
    return true
  }

  /**
   * Apply the changes to the given document, producing a new
   * document. Will raise an error if the document length doesn't
   * match or the change is not well-formed for this document.
   *
   * The result of this method is cached, so applying the same change
   * set to the same document multiple times is cheap.
   */
  apply(doc: Plot.Doc) {
    if (this.length != doc.length) {
      throw new ValidationError(`Trying to apply change of length ${this.length} to doc of length ${doc.length}`)
    }
    if (this.empty) return doc
    const cached = applyCache.get(this)
    if (cached && doc.eq(cached.a)) return cached.b

    const builder = new Builder(doc)
    let cursor = doc.resolve(0)
    for (let i = 0, iS = 0; i < this.data.length; i++) {
      const lenA = this.sections[iS++]!,
        lenB = this.sections[iS++]!
      if (lenB < 0) {
        builder.modifications = this.data[i] as null | readonly Modification[]
        cursor = cursor.advance(lenA, builder)
        builder.modifications = null
      } else {
        cursor = cursor.advance(lenA)
        Slice.run(this.data[i] as readonly Token[], builder)
      }
    }
    if (cursor.pos != doc.length) throw new ValidationError("Change doesn't cover the entire document")

    const newDoc = builder.finish()
    applyCache.set(this, { a: doc, b: newDoc })
    return newDoc
  }

  /** Convert this change set to a JSON-serializeable representation. */
  toJSON(): ChangeSet.JSON {
    const result: (number | [number, readonly Token.JSON[] | readonly ModificationJSON[]])[] = []
    for (let i = 0; i < this.data.length; i++) {
      const len = this.sections[i << 1]!,
        ins = this.sections[(i << 1) + 1]
      if (ins == -1) result.push(len)
      else if (ins == -2) result.push([len, (this.data[i] as readonly Modification[]).map(modificationToJSON)])
      else result.push([len, (this.data[i] as readonly Token[]).map(t => t.toJSON())])
    }
    return result
  }

  /** Parse a JSON representation into a change set. */
  static fromJSON(schema: Schema, json: ChangeSet.JSON) {
    if (!Array.isArray(json)) throw new ValidationError('Invalid ChangeSet JSON')
    const sections: number[] = [],
      data: SectionData[] = []
    for (const elt of json) {
      if (isNatNum(elt)) {
        sections.push(elt, -1)
        data.push(null)
      } else {
        if (!Array.isArray(elt) || elt.length != 2 || !isNatNum(elt[0]) || !Array.isArray(elt[1])) {
          throw new ValidationError('Invalid ChangeSet JSON')
        }
        const [len, val] = elt
        if (val.length && typeof val[0] == 'object' && ('add' in val[0] || 'remove' in val[0])) {
          sections.push(len, -2)
          data.push(val.map(m => modificationFromJSON(schema, m)))
        } else {
          if (!Array.isArray(val)) throw new ValidationError('Invalid ChangeSet JSON')
          const tokens = val.map(v => Token.fromJSON(schema, v))
          sections.push(len, sliceLen(tokens))
          data.push(tokens)
        }
      }
    }
    return new ChangeSet(sections, data)
  }

  /**
   * Perform an [operational
   * transformation](https://en.wikipedia.org/wiki/Operational_transformation)
   * on this change and the given other change. Both changes should
   * start with the given document `doc`. Returns a modified version
   * of the change that can be applied _after_ the other change has
   * been applied to `doc`.
   *
   * By default, the semantics of conflicting changes are resolved as
   * if `this` came after `other`. That means content inserted in the
   * same position by both will put the content inserted by `this`
   * last. You can set `before` to true to invert this, making `this`
   * come before `other`. Setting this correctly is necessary to make
   * the result of independently applied transformed changes converge.
   */
  transform(doc: Plot.Doc, other: ChangeSet, before: boolean = false): ChangeSet {
    const { set, fix } = transform(this, other, doc, before, true)
    return fix ? set.compose(fix) : set
  }

  /**
   * Compose two change sets, where `other` starts from the document
   * produced by `this`, into a single change set.
   */
  compose(other: ChangeSet): ChangeSet {
    const { sections, data } = compose(this.sections, other.sections, this.data, other.data)
    return new ChangeSet(sections, data!)
  }

  /**
   * Compute the inverse of this change set. `doc` is the document
   * that the change starts from. For a given change `A`,
   * `doc.apply(A).apply(A.invert(doc))` equals `doc`.
   */
  invert(doc: Plot.Doc) {
    const sections: number[] = [],
      data: SectionData[] = []
    for (let i = 0, iS = 0, pos = 0; iS < this.sections.length; iS += 2, i++) {
      const len = this.sections[iS]!,
        ins = this.sections[iS + 1]!
      if (ins >= 0) {
        addSection(sections, data, ins, len, doc.slice(pos, pos + len))
      } else {
        const mods = this.data[i] as readonly Modification[] | null
        let at = pos
        const end = pos + len
        if (mods) {
          doc.iterate(pos, end, (node, nodePos) => {
            if (node.isLeaf || (nodePos >= pos && nodePos < end)) {
              const [from, to] = node.isText
                ? [Math.max(at, nodePos), Math.min(end, nodePos + node.length)]
                : [nodePos, nodePos + 1]
              if (at < from) addSection(sections, data, from - at, -1, null)
              addSection(sections, data, to - from, -2, invertMods(mods!, node.tag))
              at = to
            }
          })
        }
        if (at < end) addSection(sections, data, end - at, -1, null)
      }
      pos += len
    }
    return new ChangeSet(sections, data)
  }

  /**
   * Returns the change itself if it can be applied to this document
   * and produce a valid new document, or a modified version of the
   * change that _is_ correct.
   */
  correct(doc: Plot.Doc, local = false) {
    const fitter = new ChangeFitter(doc, local)
    for (let i = 0, iS = 0, pos = 0; i < this.data.length; i++) {
      const len = this.sections[iS++]!,
        ins = this.sections[iS++]!
      if (ins < 0) fitter.preserved(pos, (pos += len))
      else fitter.replaced(this.data[i] as readonly Token[], pos, (pos += len))
    }
    const fit = fitter.finish()
    return fit ? this.compose(fit) : this
  }

  /**
   * Map a document position through this change, returning either
   * the adjusted position, or `null` if a the tracked position is
   * deleted.
   *
   * The `assoc` parameter, which defaults to `-1`, decides to which
   * side the position sticks. When content is inserted precisely at
   * the mapped position, it will stay before it when `assoc == -1`,
   * and move after it when `assoc == 1`.
   *
   * By default, mapping will always return a new position, even if
   * all the content around the position was deleted. You can pass a
   * {@link ChangeSet.TrackMode tracking mode} to make it return null
   * when either the token before, the token after, or both tokens
   * around the position were deleted.
   */
  mapPos(pos: number, assoc?: -1 | 1): number
  mapPos(pos: number, assoc: -1 | 1, track?: ChangeSet.TrackMode): number | null
  mapPos(pos: number, assoc = -1, track?: ChangeSet.TrackMode) {
    let posA = 0,
      posB = 0
    for (let i = 0; i < this.sections.length;) {
      const len = this.sections[i++]!,
        type = this.sections[i++]!,
        endA = posA + len
      if (type < 0) {
        if (endA > pos) return posB + (pos - posA)
        posB += len
      } else {
        if (
          track &&
          endA >= pos &&
          ((track == 'around' && posA < pos && endA > pos) ||
            (track == 'before' && posA < pos) ||
            (track == 'after' && endA > pos))
        ) {
          return null
        }
        if (endA > pos || (endA == pos && assoc < 0 && !len)) return pos == posA || assoc < 0 ? posB : posB + type
        posB += type
      }
      posA = endA
    }
    if (pos > posA) throw new RangeError(`Position ${pos} is out of range for changeset of length ${posA}`)
    return posB
  }

  /**
   * Scan through the content inserted by this change until a tag
   * that matches the predicate is found. If successful, return the
   * position (in the new document) of the tag. This can be useful
   * for when creating a new selection after a fitted change.
   */
  findInserted(pred: (tag: Node.Tag) => boolean): number | null {
    let found: number | null = null
    this.iterChanges((_f, _t, pos, _to, inserted) => {
      if (found != null) return
      for (const tok of inserted) {
        if (tok.tokenType == Token.Type.Node) {
          if (pred(tok.tag)) return (found = pos)
          pos += tok.length
        } else {
          if (tok.tokenType == Token.Type.Open && pred(tok)) return (found = pos)
          pos++
        }
      }
    })
    return found
  }

  /**
   * Returns true if any of the replaced ranges in this change set
   * overlaps or is adjacent to the given range.
   */
  touchesRange(from: number, to: number) {
    for (let i = 0, pos = 0; i < this.sections.length && pos <= to;) {
      const len = this.sections[i++]!,
        ins = this.sections[i++]!,
        end = pos + len
      if (ins >= 0 && pos <= to && end >= from) return pos < from && end > to ? 'cover' : true
      pos = end
    }
    return false
  }

  /**
   * Iterate over the ranges in this changeset, calling `replaced`
   * for ranges that have been replaced, and `preserved` for ranges
   * that are either preserved as-is (when `modifications` is null)
   * or only have marks modified.
   */
  iterChanges(
    replaced: (fromA: number, toA: number, fromB: number, toB: number, inserted: readonly Token[]) => void,
    preserved?: (
      fromA: number,
      toA: number,
      fromB: number,
      toB: number,
      modifications: readonly Modification[] | null
    ) => void
  ) {
    for (let posA = 0, posB = 0, i = 0, iS = 0; i < this.data.length;) {
      const len = this.sections[iS++]!,
        ins = this.sections[iS++]!,
        data = this.data[i++]
      if (ins < 0) {
        if (preserved) preserved(posA, posA + len, posB, posB + len, data as any)
        posA += len
        posB += len
      } else {
        replaced(posA, (posA += len), posB, (posB += ins), data as readonly Token[])
      }
    }
  }

  /**
   * Iterate over the sections of the document this change leaves
   * unchanged or which have only mark changes. `posA` provides the
   * position of the range in the original document, `posB` the
   * position in the changed document.
   */
  iterGaps(
    gap: (fromA: number, toA: number, fromB: number, toB: number, last: boolean) => void,
    change?: (fromA: number, toA: number, fromB: number, toB: number) => void
  ) {
    for (let i = 0, posA = 0, posB = 0; i < this.sections.length;) {
      let len = this.sections[i++]!,
        ins = this.sections[i++]!
      if (ins < 0) {
        while (i < this.sections.length && this.sections[i + 1]! < 0) {
          len += this.sections[i]!
          i += 2
        }
        gap(posA, posA + len, posB, posB + len, i == this.sections.length)
        posB += len
      } else {
        while (i < this.sections.length && this.sections[i + 1]! >= 0) {
          len += this.sections[i++]!
          ins += this.sections[i++]!
        }
        if (change) change(posA, posA + len, posB, posB + ins)
        posB += ins
      }
      posA += len
    }
  }

  /**
   * Iterate over the ranges changed (either replaced or modified) by
   * this change desc. Joins adjacent changed ranges together.
   */
  iterChangedRanges(range: (fromA: number, toA: number, fromB: number, toB: number) => void) {
    for (let i = 0, posA = 0, posB = 0; i < this.sections.length;) {
      let len = this.sections[i++]!,
        ins = this.sections[i++]!
      if (ins == -1) {
        posB += len
      } else {
        if (ins == -2) ins = len
        while (i < this.sections.length && this.sections[i + 1] != -1) {
          const addLen = this.sections[i++]!,
            addIns = this.sections[i++]!
          len += addLen
          ins += addIns == -2 ? addLen : addIns
        }
        range(posA, posA + len, posB, posB + ins)
        posB += ins
      }
      posA += len
    }
  }

  /**
   * Add skipped sections before and after this change set, so that
   * it can apply to a larger document. Mostly useful when
   * propagating changes from an editor displaying a smaller part of
   * a document into the full document.
   */
  pad(before: number, after: number) {
    if (this.empty) return ChangeSet.empty(this.length + before + after)
    const sections = this.sections.slice(),
      data = this.data.slice()
    if (before) {
      if (sections[1] == -1) {
        sections[0]! += before
      } else {
        sections.splice(0, 0, before, -1)
        data.splice(0, 0, null)
      }
    }
    if (after) {
      if (sections[sections.length - 1] == -1) {
        sections[sections.length - 2]! += after
      } else {
        sections.push(after, -1)
        data.push(null)
      }
    }
    return new ChangeSet(sections, data)
  }

  /**
   * Clip the set to only a sub-region. This can fail, if there are
   * replacements across the region's sides, in which case the
   * method returns null
   */
  clip(from: number, to: number): ChangeSet | null {
    const sections: number[] = [],
      data: SectionData[] = []
    for (let i = 0, pos = 0; i < this.sections.length && pos <= to;) {
      const value = this.data[i >> 1]!,
        len = this.sections[i++]!,
        ins = this.sections[i++]!
      const end = pos + len
      if (ins > 0) {
        if (pos >= from && end <= to) addSection(sections, data, end - pos, ins, value)
        else if (end > from && pos < from) return null
      } else if (pos < to && end > from) {
        addSection(sections, data, Math.min(end, to) - Math.max(pos, from), ins, value)
      }
      pos = end
    }
    return new ChangeSet(sections, data)
  }

  /**
   * Create a change set. All positions in the given change
   * description refer to positions in the starting document.
   */
  static create(doc: Plot.Doc, spec: ChangeSet.Spec): ChangeSet {
    return createChangeSet(doc, spec)
  }

  /** Returns an empty change set for a document of the given length. */
  static empty(length: number) {
    return length ? new ChangeSet([length, -1], [null]) : new ChangeSet([], [])
  }

  /** @internal */
  toString() {
    let result = ''
    for (let i = 0, iS = 0, pos = 0; i < this.data.length; i++) {
      const len = this.sections[iS++]!,
        ins = this.sections[iS++]!,
        data = this.data[i]
      let text = ''
      if (ins >= 0) {
        text += data
      } else if (data) {
        text += `[${(data as readonly Modification[]).map(mod => {
          return `${isAdd(mod) ? `+${mod.add}` : `-${mod.remove}`}`
        })}]`
      }
      if (text) result += `${result ? ',' : ''}${pos}${len ? `-${pos + len}` : ''}${text}`
      pos += len
    }
    return result
  }

  /** @internal */
  static composeSections(a: ChangeSet.Sections, b: ChangeSet.Sections): ChangeSet.Sections {
    return compose(a, b).sections
  }

  /**
   * Transform two change set starting from the same document over
   * each other, returning two transformed change sets. The returned
   * `a` can be applied after the `b` passed in, and the returned `b`
   * can be applied after the `a` passed in, resulting the same final
   * document on both sides. `a` is taken to happen before `b` when insertions
   * at the same position need to be merged.
   *
   * This method is slightly more efficient than transforming both steps
   * separately.
   */
  static transform(doc: Plot.Doc, a: ChangeSet, b: ChangeSet) {
    const { set: mA, fix } = transform(a, b, doc, true, true)
    const mB = transform(b, a, doc, false, false).set
    return fix ? { a: mA.compose(fix), b: mB.compose(fix) } : { a: mA, b: mB }
  }
}

export namespace ChangeSet {
  /**
   * Representation of a single document change, as used in {@link
   * ChangeSet.Spec}. Changes can either affect marks (when `add` or
   * `remove` is present), or replace a part of the document
   * (otherwise).
   */
  export type Change = {
    /** The start position of the change. */
    from: number
    /**
     * The end position. When not given, this defaults to `from` for
     * replacement changes, and `from + 1` for changes that add or
     * remove marks.
     */
    to?: number
    /**
     * Replace the given range with this slice. If `fit` is `true`
     * and a {@link Slice} is given here, its context will be used to
     * do the fitting.
     */
    insert?: Slice | readonly Token[]
    /**
     * For deletions or insertions where it isn't obvious that the
     * replacement will produce a valid document, set this to `true`.
     */
    fit?: boolean
    /**
     * Add the given mark to this change's range. Cannot be combined
     * with `insert`.
     */
    add?: Mark
    /** Remove the given mark from this range. */
    remove?: Mark
  }

  /**
   * This type is used to describe a {@link ChangeSet.create change
   * set}. A spec can be a single change, an existing change set, a
   * set of changes wrapped in a correction scope, or an array of the
   * same.
   *
   * The {@link ChangeSet.Change.from `from`} and {@link
   * ChangeSet.Change.to `to`} positions in the changes in a set spec
   * all refer to the origin document. It is not necessary to
   * 'compensate' for earlier changes in those specified later. If,
   * for some reason, you have changes that should be applied after
   * each other, create multiple change sets and {@link
   * ChangeSet.compose compose} them.
   *
   * By default, the provider of changes vouches for their
   * correctness. It is possible to create change sets that will
   * error when you try to apply them, because applying them does not
   * create a well formed document.
   *
   * When making changes where you cannot guarantee that they fit,
   * you should either use {@link ChangeSet.Change.fit}, which will
   * try to change the range of a change to make it fit, or the
   * `{correct}` form, which will combine the changes it is given,
   * and then process them as a whole to make sure they produce a
   * valid document. The `local` flag indicates that the effect of
   * changes should be kept as narrow as possible—for example, that
   * nodes opened but not closed by them should not extend to cover
   * content after the change.
   */
  export type Spec =
    | ChangeSet.Change
    | { correct: ChangeSet.Spec; local?: boolean }
    | ChangeSet
    | readonly ChangeSet.Spec[]

  /**
   * The sections in a change set are represented as an array, with
   * each pair of two numbers describing a changed section. The first
   * number is the length of the section in the old document. The
   * second number is `-1` for unchanged sections, `-2` for updated
   * sections, and a non-negative number (the length of the inserted
   * content) for replacements.
   */
  export type Sections = readonly number[]

  /** The JSON representation of a change set. */
  export type JSON = readonly (number | [number, readonly Token.JSON[] | readonly ModificationJSON[]])[]

  /**
   * Modes available in {@link ChangeSet.mapPos} to control whether
   * `null` is returned on nearby deletions.
   */
  export type TrackMode = 'before' | 'after' | 'around'
}

type ModificationJSON = { add: string; value: any } | { remove: string; value: any }

class ChangeSetBuilder {
  constructor(readonly docLen: number) {}

  sections: number[] = []
  data: SectionData[] = []
  pos = 0
}

function createChangeSet(doc: Plot.Doc, spec: ChangeSet.Spec, mayCorrect = true): ChangeSet {
  let cur: ChangeSetBuilder | null = null
  let accum: ChangeSet | null = null
  let doCorrect = false

  const flush = () => {
    if (cur) {
      if (cur.pos < cur.docLen) addSection(cur.sections, cur.data, cur.docLen - cur.pos, -1, null)
      push(ChangeSet.new(cur.sections, cur.data))
      cur = null
    }
  }
  const push = (set: ChangeSet) => {
    accum = accum ? accum.compose(transform(set, accum, doc, false, false).set) : set
  }
  const section = (from: number, to: number, ins: number, value: SectionData) => {
    if (!cur || from < cur.pos) {
      flush()
      cur = new ChangeSetBuilder(doc.length)
    }
    if (from > cur.pos) addSection(cur.sections, cur.data, from - cur.pos, -1, null)
    addSection(cur.sections, cur.data, to - from, ins, value)
    cur.pos = to
  }

  const build = (spec: ChangeSet.Spec) => {
    if (Array.isArray(spec)) {
      for (const elt of spec) build(elt)
    } else if (spec instanceof ChangeSet) {
      flush()
      push(spec)
    } else if ('correct' in spec) {
      flush()
      const { correct, local } = spec
      const inner = createChangeSet(doc, correct, false)
      push(mayCorrect || local ? inner.correct(doc, local) : inner)
    } else {
      const { add, remove, fit } = spec as ChangeSet.Change
      let { from, to, insert } = spec as ChangeSet.Change
      const modifies = add || remove
      if (modifies) {
        if (insert) {
          throw new ValidationError(`A Change object cannot both ${add ? 'add' : 'remove'} a mark and replace a range`)
        }
        if (to == null) to = from + 1
        if (add) {
          const mods: Modification[] = [{ add }]
          markableSections(doc, from, to, add.type.spanning, (node, from, to) => {
            if (!doc.schema.markAllowed(add.type, node.type)) return false
            const has = add.type.isInSet(node.tag.marks)
            if (add.type.set) {
              let modsHere = mods
              if (has) {
                const left = subtractSet(add.value as any[], has.value as any[], add.type.set)
                if (!left.length) return false
                modsHere = [{ add: add.type.of(left) }]
              }
              section(from, to, -2, modsHere)
            } else if (!has || !has.eq(add)) {
              section(from, to, -2, mods)
            }
            return true
          })
        }
        if (remove) {
          const mods: Modification[] = [{ remove }]
          markableSections(doc, from, to, remove.type.spanning, (node, from, to) => {
            const has = remove.type.isInSet(node.tag.marks)
            if (!has || !doc.schema.markAllowed(remove.type, node.type)) return false
            let modsHere = mods
            if (remove.type.set) {
              const values = (remove.value as any[]).filter(value =>
                (has.value as any[]).some(present => remove.type.set!(value, present) === 0)
              )
              if (!values.length) return false
              modsHere = [{ remove: remove.type.of(values) }]
            } else if (!has.eq(remove)) return false
            section(from, to, -2, modsHere)
            return true
          })
        }
      } else {
        if (to == null) to = from
        const context = insert instanceof Slice ? insert.context : Slice.empty.context
        insert = !insert ? noTokens : insert instanceof Slice ? insert.content : insert
        if (to <= from) to = from
        if (fit) {
          doCorrect = true
          ;({ from, to, tokens: insert } = fitReplacement(doc, doc.resolve(from), doc.resolve(to), insert, context))
        }
        if (insert.length || to != from) section(from, to, sliceLen(insert), insert)
      }
    }
  }
  build(spec)
  flush()
  return !accum ? ChangeSet.empty(doc.length) : doCorrect && mayCorrect ? (accum as any).correct(doc) : accum
}

function transform(setA: ChangeSet, setB: ChangeSet, doc: Plot.Doc, before: boolean, fit: boolean) {
  if (setA.length != doc.length || setB.length != doc.length) {
    throw new ValidationError("Transforming a change that doesn't match the start document")
  }
  // Produce a copy of setA that applies to the document after setB
  // has been applied. Assumes both start at the same document (`doc`).
  const sections: number[] = [],
    data: SectionData[] = []
  const fitter = fit ? new ChangeFitter(doc, false) : null
  const a = new SectionIter(setA.sections, setA.data)
  const b = new SectionIter(setB.sections, setB.data)
  let pos = 0
  // Iterate over both sets in parallel. inserted tracks, for changes
  // in A that have to be processed piece-by-piece, whether their
  // content has been inserted already, and refers to the section
  // index.
  for (let inserted = -1; ;) {
    if (a.keep && b.keep) {
      // Move across ranges skipped by both sets.
      const len = Math.min(a.len, b.len)
      const mods = before ? a.mods : filterMods(a.mods, b.mods)
      addSection(sections, data, len, mods ? -2 : -1, mods)
      a.forward(len)
      b.forward(len)
      if (fitter) fitter.preserved(pos, pos + len)
      pos += len
    } else if (
      b.ins >= 0 &&
      (a.ins < 0 || inserted == a.i || (a.off == 0 && (b.len < a.len || (b.len == a.len && !before))))
    ) {
      // If there's a change in B that comes before the next change in
      // A (ordered by start pos, then len, then before flag), skip
      // that (and process any changes in A it covers).
      const end = pos + b.len
      addSection(sections, data, b.ins, -1, null)
      if (fitter) fitter.replaced(b.tokens, pos, end, true)
      while (pos < end) {
        if (a.done) throw new ValidationError('Mismatched change sets')
        const piece = Math.min(a.len, end - pos)
        if (a.ins >= 0 && inserted < a.i && a.len <= piece) {
          addSection(sections, data, 0, a.ins, a.tokens)
          if (fitter) fitter.replaced(a.tokens, pos - a.off, pos + a.len)
          inserted = a.i
        }
        a.forward(piece)
        pos += piece
      }
      b.next()
    } else if (a.ins >= 0) {
      // Process the part of a change in A up to the start of the next
      // non-deletion change in B (if overlapping).
      const start = pos
      const end = pos + a.len
      let len = 0
      while (pos < end) {
        if (b.keep) {
          const piece = Math.min(end - pos, b.len)
          pos += piece
          len += piece
          b.forward(piece)
        } else if (b.ins == 0 && pos + b.len < end) {
          if (fitter) fitter.replaced(b.tokens, pos, pos + b.len, true)
          pos += b.len
          b.next()
        } else {
          break
        }
      }
      if (inserted < a.i) {
        addSection(sections, data, len, a.ins, a.tokens)
        if (fitter) fitter.replaced(a.tokens, start - a.off, start + a.len)
        inserted = a.i
      } else {
        addSection(sections, data, len, 0, noTokens)
      }
      a.forward(pos - start)
    } else {
      return {
        set: ChangeSet.new(sections, data),
        fix: fitter && fitter.finish()
      }
    }
  }
}

function compose(
  sectionsA: ChangeSet.Sections,
  sectionsB: ChangeSet.Sections,
  dataA?: readonly SectionData[],
  dataB?: readonly SectionData[]
): { sections: ChangeSet.Sections; data: readonly SectionData[] | null } {
  const sections: number[] = [],
    data: SectionData[] | null = dataA ? [] : null
  const a = new SectionIter(sectionsA, dataA),
    b = new SectionIter(sectionsB, dataB)
  for (let open = false; ;) {
    if (a.done && b.done) {
      return { sections, data }
    } else if (a.ins == 0) {
      // Deletion in A
      addSection(sections, data, a.len, 0, a.tokens, open)
      a.next()
    } else if (b.len == 0 && !b.done) {
      // Insertion in B
      addSection(sections, data, 0, b.ins, b.tokens, open)
      b.next()
    } else if (a.done || b.done) {
      throw new ValidationError('Mismatched change set lengths')
    } else {
      const len = Math.min(a.len2, b.len),
        sectionLen = sections.length
      if (a.keep && b.keep) {
        const mods = combineMods(a.mods, b.mods)
        addSection(sections, data, len, (data ? mods : a.ins == -2 || b.ins == -2) ? -2 : -1, mods, open)
      } else if (a.keep) {
        addSection(sections, data, len, b.off ? 0 : b.ins, b.off ? noTokens : b.tokens, open)
      } else if (b.keep) {
        addSection(
          sections,
          data,
          a.off ? 0 : a.len,
          len,
          data ? applyModsToSlice(a.slicePart(len), b.mods) : null,
          open
        )
      } else {
        addSection(sections, data, a.off ? 0 : a.len, b.off ? 0 : b.ins, b.off ? noTokens : b.tokens, open)
      }
      open = (a.ins > len || (b.ins >= 0 && b.len > len)) && (open || sections.length > sectionLen)
      a.forward2(len)
      b.forward(len)
    }
  }
}

function combineMods(
  a: null | readonly Modification[],
  b: null | readonly Modification[]
): null | readonly Modification[] {
  return !a ? b : !b ? a : a.concat(b)
}

function filterMods(mods: null | readonly Modification[], against: null | readonly Modification[]) {
  if (!mods || !against) return mods
  return mods.filter(m => !against!.some(a => modCancels(a, m)))
}

function modCancels(mod: Modification, other: Modification) {
  if (isAdd(other)) {
    return isAdd(mod) ? mod.add.type == other.add.type && !mod.add.type.set : mod.remove.eq(other.add)
  } else {
    return isAdd(mod) && mod.add.eq(isAdd(other) ? other.add : other.remove)
  }
}

function invertMods(mods: readonly Modification[], target: Node.Tag): readonly Modification[] {
  return mods.map(mod => {
    if (isRemove(mod)) return { add: mod.remove }
    if (!mod.add.type.set) {
      const existed = mod.add.type.isInSet(target.marks)
      if (existed) return { add: existed }
    }
    return { remove: mod.add }
  })
}

function applyModsToSlice(tokens: readonly Token[], mods: readonly Modification[] | null) {
  if (!mods) return tokens
  const content: Token[] = []
  for (const tok of tokens) {
    if (tok.tokenType == Token.Type.Open) {
      content.push(tok.withMarks(applyModifications(mods, tok.marks)))
    } else if (tok.tokenType == Token.Type.Node) {
      const node = tok.withMarks(applyModifications(mods, tok.marks))
      if (content.length && content[content.length - 1]!.tokenType == Token.Type.Node) node.pushTo(content as Plot[])
      else content.push(node)
    } else {
      content.push(tok)
    }
  }
  return content
}

enum FitFlag {
  None = 0,
  NeedsChild = 1,
  Synthetic = 2
}

class FitLevel {
  flags = FitFlag.None

  constructor(
    readonly tag: Plot.Tag,
    readonly next: FitLevel | null,
    // The input position of the level's close token, or -1 for a level that the input does not close
    readonly end = -1
  ) {
    if (!this.tag.type.canBeEmpty) this.flags |= FitFlag.NeedsChild
  }
}

const counter = {
  count: 0,
  skip() {},
  enterPlot() {
    this.count++
  },
  leavePlot() {
    this.count--
  },
  countDelta(pos: Pos, distance: number) {
    this.count = 0
    return pos.advance(distance, this)
  }
}

class ChangeFitter implements Pos.Walker {
  stack: FitLevel
  inputPos: Pos
  delInputPos: Pos
  pos = 0
  patches: { from: number; to: number; insert: Token[] }[] = []
  stackDelta = 0
  inputDelta = 0
  inserting = false
  activeContext: Pos | null = null
  activeContextPos = -1
  nextSync = -1
  // `pos` minus the input position, inside a preserved range
  inputOffset = 0
  schema: Schema

  constructor(
    doc: Plot.Doc,
    readonly local: boolean
  ) {
    this.schema = doc.schema
    this.stack = new FitLevel(doc.tag, null)
    this.inputPos = this.delInputPos = doc.resolve(0)
  }

  getPos(at: number) {
    const { inputPos, delInputPos } = this
    if (inputPos.pos == at) return inputPos
    if (delInputPos.pos == at) return delInputPos
    return inputPos.advance(at - inputPos.pos)
  }

  preserved(from: number, to: number) {
    const { nextSync } = this
    if (nextSync >= from && nextSync <= to) {
      this.stackDelta = 0
      this.nextSync = -1
      if (nextSync > from) this.preserved(from, nextSync)
      this.syncToContext(this.inputPos)
      if (to > nextSync) this.preserved(nextSync, to)
      return
    }

    const inputPos = this.getPos(from)
    if (!this.inputDelta && this.stackDelta) {
      this.syncToContext(inputPos)
      this.stackDelta = 0
    }
    this.activeContext = inputPos
    this.activeContextPos = this.pos
    this.inputOffset = this.pos - from
    this.inputPos = inputPos.advance(to - from, this)
  }

  lastCoverFrom = -1
  lastCoverTo = -1
  doubleDeleteDelta = 0

  replaced(tokens: readonly Token[], from: number, to: number, covering = false) {
    this.doubleDeleteDelta = 0
    if (covering) {
      this.lastCoverFrom = from
      this.lastCoverTo = to
    } else if (tokens.length) {
      const overlapFrom = Math.max(from, this.lastCoverFrom)
      const overlapTo = Math.min(to, this.lastCoverTo)
      if (overlapFrom < overlapTo) {
        counter.countDelta(this.getPos(overlapFrom), overlapTo - overlapFrom)
        this.doubleDeleteDelta = counter.count
      }
    }
    if (from != to) {
      this.delInputPos = counter.countDelta(this.getPos(from), to - from)
      this.inputDelta -= counter.count
    }
    this.inserting = true
    Slice.run(tokens, this, this.pos)
    this.inserting = false

    if (this.local) this.nextSync = Math.max(this.nextSync, localSyncPosAfter((this.inputPos = this.getPos(to))))
  }

  fit(tag: Node.Tag) {
    if (this.schema.canContain(this.stack.tag.type, tag.type)) return true
    let fix: { leave: number; enter: readonly Plot.Tag[]; cost: number; context: boolean } | null = null
    const dDelta = this.stackDelta - this.inputDelta
    for (let level: FitLevel | null = this.stack, leave = 0, leaveCost = 0; level; level = level.next, leave++) {
      if (fix && leaveCost > fix.cost) break
      const enter = this.schema.findWrapping(level.tag.type, tag.type)
      if (enter) {
        const cost = leaveCost + enter.length * 2 - Math.max(0, Math.min(-dDelta, enter.length))
        if (!fix || (fix.cost > cost && !fix.context)) fix = { leave, enter, cost, context: false }
      }
      if (this.activeContextPos == this.pos) {
        const top = this.activeContext?.parent || null
        for (let cx = top, i = 1; cx; cx = cx.parent, i++) {
          if (this.schema.canContain(level.tag.type, cx.node.type)) {
            const cost = leaveCost + i * 2 - Math.max(0, Math.min(-dDelta, i))
            if (!fix || fix.cost > cost || !fix.context) {
              const enter: Plot.Tag[] = []
              for (let scan = top; ; scan = scan!.parent) {
                enter.unshift(scan!.node.tag)
                if (scan == cx) break
              }
              fix = { leave, enter, cost, context: true }
            }
            break
          }
        }
      }
      leaveCost += level.flags & FitFlag.Synthetic ? 0 : dDelta > leave ? 1 : 2
    }
    if (!fix) return false
    for (let i = 0; i < fix.leave; i++) {
      this.insertClose()
      this.stackDelta--
    }
    for (const wrapper of fix.enter) {
      this.patch(0, wrapper)
      this.stack.flags &= ~FitFlag.NeedsChild
      this.stack = new FitLevel(wrapper, this.stack)
      this.stack.flags |= FitFlag.Synthetic
      this.stackDelta++
    }
    return true
  }

  syncToContext(context: Pos) {
    const cur = [],
      sync = []
    for (let l = this.stack as FitLevel | null; l; l = l.next) cur.push(l)
    cur.reverse()
    for (let level: Pos.Plot | null = context.parent; level; level = level.parent) sync.push(level)
    sync.reverse()
    while (cur.length > sync.length) {
      this.insertClose()
      cur.pop()
    }
    for (let d = 1; d < Math.min(sync.length, cur.length); d++) {
      const { node, end } = sync[d]!,
        { tag, end: curEnd } = cur[d]!
      // An isolating input node, such as a column, never takes the content of another one
      if (!this.schema.sharesContent(node.type, tag.type) || (node.type.isolating && curEnd >= 0 && curEnd != end)) {
        while (cur.length > d) {
          this.insertClose()
          cur.pop()
        }
        break
      }
    }
    for (let i = cur.length; i < sync.length; i++) {
      const { node, end } = sync[i]!
      // The opened level is a child of its parent, as in `enter`
      this.stack.flags &= ~FitFlag.NeedsChild
      this.stack = new FitLevel(node.tag, this.stack, end)
      this.patch(0, node.tag)
    }
  }

  insertClose() {
    if (this.stack.flags & FitFlag.NeedsChild) this.patch(0, this.schema.createDefault(this.stack.tag.type), Plot.End)
    else this.patch(0, Plot.End)
    this.stack = this.stack.next!
  }

  patch(length: number, ...insert: Token[]) {
    const prev = this.patches.length ? this.patches[this.patches.length - 1] : null
    if (prev && prev.to == this.pos) {
      prev.to += length
      for (const tok of insert) prev.insert.push(tok)
    } else {
      this.patches.push({ from: this.pos, to: this.pos + length, insert })
    }
  }

  open(tag: Plot.Tag) {
    this.enter(tag)
  }
  close() {
    this.leavePlot()
  }
  node(node: Node) {
    this.skip(node)
  }

  skip(node: Node) {
    if (this.fit(node.tag)) this.stack.flags &= ~FitFlag.NeedsChild
    else this.patch(node.length)
    this.pos += node.length
  }

  enterPlot(node: Plot) {
    this.enter(node.tag, this.pos - this.inputOffset + node.length - 1)
  }

  enter(tag: Plot.Tag, end = -1) {
    if (this.inserting) this.inputDelta++
    if (this.doubleDeleteDelta > 0) {
      this.doubleDeleteDelta--
      this.patch(1)
    } else if (this.fit(tag)) {
      this.stack.flags &= ~FitFlag.NeedsChild
      this.stack = new FitLevel(tag, this.stack, this.inserting ? -1 : end)
      if (this.inserting) this.stackDelta++
    } else {
      this.patch(1)
    }
    this.pos++
  }

  leavePlot() {
    if (this.inserting) this.inputDelta--
    if (this.doubleDeleteDelta < 0) {
      this.doubleDeleteDelta++
      this.patch(1)
    } else if (!this.inserting && this.stack.end > this.pos - this.inputOffset) {
      // The change deleted this node's open token, and the open level still has its own close
      // ahead: drop this close instead of closing that level
      this.inputDelta++
      this.patch(1)
    } else if (this.stack.next) {
      if (this.stack.flags & FitFlag.NeedsChild) this.patch(0, this.schema.createDefault(this.stack.tag.type))
      this.stack = this.stack.next
      if (this.inserting) this.stackDelta++
    } else {
      this.patch(1)
    }
    this.pos++
  }

  finish(): ChangeSet | null {
    while (this.stack.next || (this.stack.flags && FitFlag.NeedsChild)) {
      if (this.stack.flags & FitFlag.NeedsChild) {
        this.patch(0, this.schema.createDefault(this.stack.tag.type))
        this.stack.flags &= ~FitFlag.NeedsChild
      } else {
        this.patch(0, Plot.End)
        this.stack = this.stack.next!
      }
    }
    if (!this.patches.length) return null
    const sections: number[] = []
    const data: SectionData[] = []
    let pos = 0
    for (const { from, to, insert } of this.patches) {
      addSection(sections, data, from - pos, -1, null)
      addSection(sections, data, to - from, sliceLen(insert), insert)
      pos = to
    }
    addSection(sections, data, this.pos - pos, -1, null)
    return ChangeSet.new(sections, data)
  }
}

function localSyncPosAfter(pos: Pos) {
  let found = pos.pos
  // Between blocks, no node continues past the change
  if (!pos.parent.node.inlineContent) return found
  for (let cx = pos.parent, index = pos.index; ; index = cx.index, cx = cx.parent) {
    if (!cx.parent || (!cx.node.inlineContent && index != cx.node.content.length - 1)) break
    found = cx.after
  }
  return found
}

function markableSections(
  doc: Plot.Doc,
  from: number,
  to: number,
  spanning: boolean,
  f: (n: Node, from: number, to: number) => boolean
) {
  doc.iterate(from, to, (node, pos) => {
    if ((pos >= from && pos + (spanning ? node.length : 1) <= to) || node.isText) {
      if (node.isText ? f(node, Math.max(pos, from), Math.min(pos + node.length, to)) : f(node, pos, pos + 1)) {
        return false
      }
    }
  })
}

class SectionIter {
  i = 0
  len!: number
  off!: number
  ins!: number

  constructor(
    readonly sections: ChangeSet.Sections,
    readonly data?: readonly SectionData[]
  ) {
    this.next()
  }

  next() {
    const { sections } = this
    this.off = 0
    if (this.i < sections.length) {
      this.len = sections[this.i++]!
      this.ins = sections[this.i++]!
      if (this.len == 0 && this.ins < 0) this.next()
    } else {
      this.len = 0
      this.ins = -3
    }
  }

  get keep() {
    return this.ins == -1 || this.ins == -2
  }

  get done() {
    return this.ins == -3
  }

  get len2() {
    return this.ins < 0 ? this.len : this.ins
  }

  get mods() {
    return this.data ? (this.data[(this.i - 2) >> 1] as readonly Modification[] | null) : null
  }

  get tokens() {
    return this.data ? (this.data[(this.i - 2) >> 1] as readonly Token[]) : noTokens
  }

  slicePart(len?: number) {
    return Slice.slice(this.tokens, this.off, len == null ? undefined : this.off + len)
  }

  forward(len: number) {
    if (len == this.len) this.next()
    else {
      this.len -= len
      this.off += len
    }
  }

  forward2(len: number) {
    if (this.keep) this.forward(len)
    else if (len == this.ins) this.next()
    else {
      this.ins -= len
      this.off += len
    }
  }
}

function addSection(
  sections: number[],
  data: SectionData[] | null,
  len: number,
  ins: number,
  value: SectionData,
  forceJoin = false
) {
  if (len == 0 && ins <= 0) return
  const last = sections.length - 2
  if (last >= 0 && ins <= 0 && ins == sections[last + 1]) {
    // Deletion or preserved section that matches the last element in `sections`
    const lastValue = data ? data[data.length - 1] : null
    const match =
      ins == 0
        ? true
        : value
          ? lastValue && compareModifications(lastValue as readonly Modification[], value as readonly Modification[])
          : !lastValue
    if (match) {
      sections[last]! += len
      return
    }
  }
  if (forceJoin || (last >= 0 && len == 0 && sections[last] == 0)) {
    // Insertion or replacement joinable to another insertion
    sections[last]! += len
    sections[last + 1]! += ins
    if (data) data[data.length - 1] = Slice.concat(data[data.length - 1] as readonly Token[], value as readonly Token[])
  } else {
    sections.push(len, ins)
    if (data) data.push(value)
  }
}

function finishCx(cx: BuildContext, schema: Schema) {
  return cx.tag.create(cx.children.length || cx.tag.type.canBeEmpty ? cx.children : [schema.createDefault(cx.tag.type)])
}

function closeSlice(
  schema: Schema,
  tokens: readonly Token[],
  context: readonly Plot.Tag[],
  depth: number,
  closeEnd = false
) {
  const top: Token[] = []
  let stack: BuildContext | null = null
  for (let i = depth - 1; i >= 0; i--) stack = new BuildContext(context[i]!, stack)
  for (const token of tokens) {
    if (token.tokenType == Token.Type.Close) {
      if (stack) {
        const node = finishCx(stack, schema)
        stack = stack.parent
        ;(stack ? stack.children : top).push(node)
      } else {
        top.push(token)
      }
    } else if (token.tokenType == Token.Type.Open) {
      stack = new BuildContext(token, stack)
    } else {
      ;(stack ? stack.children : top).push(token)
    }
  }
  if (closeEnd) {
    while (stack) {
      const node = finishCx(stack, schema)
      stack = stack.parent
      ;(stack ? stack.children : top).push(node)
    }
  }
  if (stack) splatContext(top, stack)
  return top
}

function splatContext(top: Token[], cx: BuildContext) {
  if (cx.parent) splatContext(top, cx.parent)
  top.push(cx.tag)
  for (const ch of cx.children) top.push(ch)
}

function isFitBarrier(plot: Plot.Type) {
  return plot.isolating || plot.isInline
}

function fitReplacement(doc: Plot.Doc, from: Pos, to: Pos, tokens: readonly Token[], context: readonly Plot.Tag[]) {
  if (!tokens.length) return fitDeletion(from, to)

  let preferredContext = -1
  for (let i = 0; i < context.length; i++) {
    const next = context[i]!
    if (next.type.defining) preferredContext = i
    else if (!next.isTextblock) break
  }
  let firstType = null,
    closeCount = 0
  // Find the number of nodes this slice closes, relative to its
  // start depth.
  for (let i = 0, opened = 0; i < tokens.length; i++) {
    const tok = tokens[i]!
    if (tok.tokenType == Token.Type.Close) {
      if (opened) opened--
      else closeCount++
    } else {
      if (!i) firstType = tok.type
      if (tok.tokenType == Token.Type.Open) opened++
    }
  }

  // Scan over nodes either covered entirely, or covered from their
  // start and closed by the slice, see if the slice or one of its
  // contexts can be inserted instead of that node. If so, replace the
  // node.
  let found: { from: number; to: number; tokens: readonly Token[] } | undefined,
    foundCost = 1e8
  let neutral = true,
    toEnd = true
  scan: for (
    let cxFrom = from.parent,
      cxTo = to.parent,
      fromDepth = from.depth,
      toDepth = to.depth,
      start = from.pos,
      end = to.pos;
    cxFrom.parent;
    cxFrom = cxFrom.parent, start--, fromDepth--
  ) {
    if (cxFrom.start != start || isFitBarrier(cxFrom.node.type)) break
    while (toDepth > fromDepth) {
      if (isFitBarrier(cxTo.node.type)) break scan
      cxTo = cxTo.parent!
      toDepth--
      end++
    }
    if (cxTo.end != end) {
      if (!closeCount) break
      toEnd = false
    }
    if (!cxFrom.node.type.neutral) neutral = false
    if (fromDepth == toDepth) {
      for (let i = -1, type; i < context.length; i++) {
        if (i >= 0) type = context[i]!.type
        else if (!firstType) continue
        else type = firstType
        if (doc.schema.canContain(cxFrom.parent.node.type, type)) {
          const cost =
            (neutral ? 0 : 2) + (i < preferredContext ? context.length - i : i - preferredContext) + (toEnd ? 0 : 1e7)
          if (foundCost > cost) {
            found = {
              from: cxFrom.before,
              to: toEnd ? cxTo.after : to.pos,
              tokens: i >= 0 ? closeSlice(doc.schema, tokens, context, i + 1, toEnd) : tokens
            }
            foundCost = cost
          }
        }
      }
    }
  }
  if (found) return found

  // If the replacement range is an empty range at the start or end of
  // a plot, see if moving it out of the plot improves the fit.
  if (from.pos == to.pos && !from.inText) {
    let cx: Pos.Plot = from.parent
    for (
      let before = from.index ? -1 : from.pos, after = from.pos == from.parent.end ? from.pos : -1;
      before > -1 || after > -1;
    ) {
      for (let i = -1; i < context.length; i++) {
        const type = i >= 0 ? context[i]!.type : firstType
        if (!type) continue
        if (doc.schema.canContain(cx.node.type, type)) {
          const pos = before > -1 ? before : after
          return { from: pos, to: pos, tokens: i >= 0 ? closeSlice(doc.schema, tokens, context, i + 1, true) : tokens }
        }
      }
      if (isFitBarrier(cx.node.type) || !cx.parent) break
      before = before == cx.start ? before - 1 : -1
      after = after == cx.end ? after + 1 : -1
      cx = cx.parent
    }
  }

  for (let i = -1; i < context.length; i++) {
    if (i == preferredContext) continue
    const depth = i < 0 ? preferredContext : i
    if (doc.schema.canContain(from.parent.node.type, context[depth]!.type)) {
      tokens = closeSlice(doc.schema, tokens, context, depth + 1, true)
      break
    }
  }
  return { from: from.pos, to: to.pos, tokens }
}

function fitDeletion(from: Pos, to: Pos) {
  let toDepth = to.depth
  let covered: { from: number; to: number; tokens: readonly Token[] } | undefined
  // Walk up the contexts (catching up on cxTo whenever depth reaches
  // its depth), tracking whether there is any content between the
  // current depth's start/end and from/to by counting tokens.
  for (
    let cx = from.parent, cxTo = to.parent, depth = from.depth, start = from.pos, end = to.pos;
    cx.parent;
    start--, cx = cx.parent, depth--
  ) {
    // If there is content before from, or this is an isolating node, stop
    if (cx.start != start || isFitBarrier(cx.node.type)) break
    while (toDepth > depth) {
      cxTo = cxTo.parent!
      toDepth--
      end++
    }
    const toAtEnd = toDepth == depth && cxTo.end == end // Check for content before to
    // If this is a deletion starting at the start of a node and
    // continuing past its end (but not to the end of a node at the
    // same level), include the node's open token.
    if (cx.end < to.pos && cx.parent.end > to.pos && !toAtEnd) {
      return { from: cx.before, to: to.pos, tokens: noTokens }
    }
    // Else if this is a completely covered set of siblings with
    // non-inline content, and the range isn't inside a single
    // textblock, pick the outermost such range and delete it
    // entirely.
    if (
      !cx.node.inlineContent &&
      toAtEnd &&
      cx.parent.start == cxTo.parent!.start &&
      !(from.parent.start == to.parent.start && from.parent.node.inlineContent)
    ) {
      covered = { from: cx.before, to: cxTo.after, tokens: noTokens }
    }
  }
  return covered || { from: from.pos, to: to.pos, tokens: noTokens }
}
