import { Token } from './slice'
import { TextOutput } from './text'
import { NodeShape } from './shape'
import type { Schema } from './schema'
import { Pos } from './pos'
import { Mark } from './mark'
import { eqArray, none, compareDeep } from './helper'
import { Shape } from './shape'
import { type parse } from './parse'
import { SchemaError } from './error'

enum NodeFlag {
  None = 0,
  Inline = 1,
  InlineContent = 2,
  Atom = 4,
  Doc = 8,
  NullParam = 16,
  Selectable = 32,
  CanBeEmpty = 64
}

/**
 * A node in the document is either a plot (which may have content)
 * or a leaf node.
 */
export type Node = Plot | Leaf

// Base class of types. Not public, though some of its properties are.
export abstract class BaseType<Param> {
  /** @internal */
  readonly roles: Set<Node.Role> = new Set()

  /** @internal */
  constructor(
    /** The name of this node type. */
    readonly name: string,
    /** @internal */
    readonly flags: NodeFlag,
    spec: Node.Spec<Param>,
    /** @internal */
    readonly shape: NodeShape
  ) {
    if (spec.role instanceof Node.Role) this.roles.add(spec.role)
    else if (spec.role) for (const role of spec.role) this.roles.add(role)
    if (this.shape.atom) this.flags |= NodeFlag.Atom
  }

  /** Test whether this node has the given role. */
  hasRole(role: Node.Role) {
    return this.roles.has(role)
  }

  /** True when this is an inline node type. */
  get isInline() {
    return (this.flags & NodeFlag.Inline) > 0
  }
  /** True when this is a block node type. */
  get isBlock() {
    return (this.flags & NodeFlag.Inline) == 0
  }
  /** @internal used by Configuration.isAtom */
  get isAtom() {
    return (this.flags & NodeFlag.Atom) > 0
  }
  abstract isLeaf: boolean
  abstract isPlot: boolean

  /** Whether this node is {@link Node.Spec.selectable selectable}. */
  get isSelectable() {
    return (this.flags & NodeFlag.Selectable) > 0
  }
}

export abstract class BaseTag<Param> {
  abstract type: Node.Type<Param>

  constructor(
    readonly param: Param,
    readonly marks: Mark.Set
  ) {}

  mark<Value>(mark: Mark.Type<Value>): Value | undefined {
    for (const v of this.marks) if (v.type == mark) return v.value as Value
    return undefined
  }

  get name() {
    return this.type.name
  }

  abstract eq(other: Node | Node.Tag): boolean

  abstract isLeaf: boolean
  abstract isPlot: boolean
  get isText(): boolean {
    return this.type == Leaf.Text
  }

  is<T>(type: Leaf.Type<T>): this is Leaf<T>
  is<T>(type: Plot.Type<T>): this is Plot.Tag<T>
  is(type: any) {
    return this.type == type
  }

  toJSON(): Node.JSON {
    const result: Node.JSON = { type: this.name }
    if (this != (this.type.default as any)) result.param = this.param
    if (this.marks.length) {
      result.marks = Object.create(null)
      for (const { name, value } of this.marks) result.marks![name] = value
    }
    return result
  }
}

export namespace Node {
  /** The interface shared by both {@link Leaf} and {@link Plot}. */
  export interface Shared {
    /** The name of this node's type. */
    name: string
    /**
     * The node's {@link Node.Tag tag}. For leaves, this is the leaf
     * itself, for plots, the {@link Plot.Tag plot tag}.
     */
    tag: Node.Tag
    /**
     * The length of this node. For a plot, this is its {@link
     * Plot.contentLength} plus 2 (for the open and close tokens),
     * for leaves this is 1, except for text leaves, where it is the
     * length of the text.
     */
    length: number
    /** The set of marks for this node. */
    marks: Mark.Set
    /** Get the value of the given mark for this node, if any. */
    mark<Value>(mark: Mark.Type<Value>): Value | undefined
    /** Compare this node to another node. */
    eq(other: Node): boolean
    /**
     * Create a copy of this node with the given set of marks instead
     * of its current mark set.
     */
    withMarks(marks: Mark.Set): Node
    /** @internal */
    pushTo(nodes: Node[]): void
    /**
     * True when this is a leaf node. TypeScript will automatically
     * narrow from {@link Node} to {@link Leaf} after you check this.
     */
    isLeaf: boolean
    /** Tests whether this is a {@link Leaf.Text text leaf}. */
    isText: boolean
    /** True when this is a {@link Plot}. */
    isPlot: boolean
    /** True when this node is a block node. */
    isBlock: boolean
    /** Indicate whether this is an inline node. */
    isInline: boolean
    /** Convert this node to its JSON-serializeable representation. */
    toJSON(): Node.JSON
  }

  /** A node type can be either a leaf type or a plot type. */
  export type Type<T = unknown> = Leaf.Type<T> | Plot.Type<T>

  export namespace Type {
    /**
     * Used as input type by some functions acting on node types, so
     * that you can pass either a bare type or a singleton leaf or
     * plot tag.
     */
    export type Ref<T> = Plot.Type<T> | Leaf.Type<T> | Plot.Tag<T> | Leaf<T>

    /** Get the type referred to by a {@link Node.Type.Ref reference}. */
    export function get<T>(ref: Ref<T>): Node.Type<T> {
      return ref instanceof BaseType ? (ref as Node.Type<T>) : ref.type
    }
  }

  /**
   * A tag is a node type with a parameter and a set of marks. For
   * leaves, the entire node is the tag. For plots, it is a separate
   * object in the {@link Plot.tag `tag` property}.
   */
  export type Tag = Leaf | Plot.Tag

  export namespace Tag {
    /**
     * The interface shared by {@link Leaf leaves} and {@link
     * Plot.Tag plot tags}.
     */
    export interface Shared<Param> {
      /** The type of the tag. */
      type: Node.Type<Param>
      /** The tag parameter. Will be `null` for parameter-less types. */
      param: Param
      /** The set of marks for this tag. */
      marks: Mark.Set
      /** The name of the tag's type. */
      name: string

      /**
       * Find the value of the given given make type in this tag's
       * set of marks, or return `undefined` if it isn't present.
       */
      mark<Value>(mark: Mark.Type<Value>): Value | undefined

      /** Compare this tag to another tag. */
      eq(other: Node.Tag): boolean

      /** Test whether this is a leaf. */
      isLeaf: boolean
      /** Test whether this is a plot tag. */
      isPlot: boolean

      /** Test whether this tag is of the given type. */
      is<T>(type: Leaf.Type<T>): this is Leaf<T>
      is<T>(type: Plot.Type<T>): this is Plot.Tag<T>

      /** Holds `true` when this is a text leaf. */
      isText: boolean

      /** Convert this tag to a JSON-serializeable object. */
      toJSON(): Node.JSON
    }

    /** Deduce a tag type for a given node type or tag. */
    export type For<Type extends Node.Type.Ref<any>> =
      Type extends Leaf.Type<infer T> ? Leaf<T> : Type extends Plot.Type<infer T> ? Plot.Tag<T> : Type
  }

  /** Shared fields between {@link Leaf.Spec} and {@link Plot.Spec}. */
  export interface Spec<Param> {
    /**
     * Whether this node is an inline or a block node. Defaults to
     * block.
     */
    inline?: boolean
    /**
     * The default parameter value for the node type. Only meaningful
     * when the type is being defined directly, rather than as a
     * singleton tag.
     */
    defaultParam?: Param
    /**
     * A function or type name used to validate this tag's parameter
     * value. This will be used when deserializing the attribute from
     * JSON. When a string, it should be a `|`-separated string of
     * primitive types (`"number"`, `"string"`, `"boolean"`, `"null"`,
     * and `"undefined"`). The library will raise an error when the
     * value is not one of those types. When a function, it should
     * raise an error if the value doesn't have the expected type or
     * shape.
     */
    validate?: string | ((param: Param) => void)
    /**
     * Assign one or more groups to this node type. Groups are used
     * when specifying allowed content for a plot. Schema overrides
     * can {@link Schema.Override.nodeGroup change} a node's set of
     * groups.
     */
    group?: Group | readonly Group[]
    /**
     * Roles to add to this node type, which mark it as having a
     * certain semantic role, such as being a list.
     */
    role?: Node.Role | readonly Node.Role[]
    /**
     * The default DOM/HTML shape of this node. This will determine
     * what the node looks like, both in an editor an in serialized
     * HTML form. In most cases, this also specifies the way the node
     * is parsed when reading HTML content.
     */
    shape: Shape.Element<Param> | Shape.Structure<Param>
    /** Extra parse rules to associate with this node type. */
    parseRules?: readonly parse.Rule.Element<Param>[]
    /**
     * When set to `true`, nodes of this type, if they are a leaf or
     * atom, can be selected by clicking them or moving the selection
     * into them with the keyboard.
     */
    selectable?: boolean
  }

  /** The JSON representation for a node or tag. */
  export interface JSON {
    type: string
    param?: any
    marks?: { [name: string]: any }
    content?: readonly Node.JSON[]
  }

  /**
   * Groups are used to specify parent-child relationships between
   * nodes, and valid targets for marks. You can use predefined
   * groups provided as static properties on the class, or define
   * your own for custom categories.
   */
  export class Group {
    declare private tag: Node.Group

    private constructor(
      /**
       * Groups may have a parent group. Membership of a group
       * implies membership of its parent groups.
       */
      readonly parent: Group | undefined
    ) {}

    /** Define a custom node group. */
    static define(parent?: Group) {
      return new Group(parent)
    }

    /** A group that contains every node type. */
    static All = Group.define()
    /** All inline nodes are automatically assigned to this group. */
    static Inline = Group.define()
    /** Block elements automatically get assigned to this group. */
    static Block = Group.define()
    /** The group of all leaf nodes. */
    static Leaf = Group.define()
    /** The group of all non-leaf nodes. */
    static Plot = Group.define()
    /** Block plots with inline content are tagged as textblocks. */
    static Textblock = Group.define()
    /**
     * A group used for generic block content, such as paragraphs and
     * lists. The basic schema uses this as the content type for the
     * top level document, blockquotes, and list items.
     */
    static Content = Group.define()
    /** Group for the cell nodes in tables. */
    static TableCell = Group.define()
    /** Generic list item group. */
    static ListItem = Group.define()

    /** @internal */
    static builtin = [Group.All, Group.Inline, Group.Block, Group.Leaf, Group.Plot, Group.Textblock]
  }

  /**
   * Describes a set of node types. Can be either a single tag or
   * type, which matches exactly that type (tags are assumed to be
   * singleton tags—only their type is used), a reference to a {@link
   * Node.Group node group}, or a combination of multiple of those.
   * An array indicates the union of all the groups in the array
   * (matches types that match any of the queries). An object with an
   * `and` property indicates an intersection (must match all the
   * queries).
   */
  export type Query = Node.Tag | Node.Type | Group | readonly Node.Query[] | { and: readonly Node.Query[] }

  /**
   * Roles are used to add some semantic information to node types.
   * You can define your own, and use the `hasRole` method to check
   * whether a given node has the role attached.
   */
  export class Role {
    private constructor() {}

    /** @internal */
    declare private tag: 'Node.Role'

    /** Define a new role. */
    static define() {
      return new Role()
    }

    /**
     * This role indicates that a plot contains code, and makes some
     * commands behave differently inside such a plot.
     */
    static Code = Role.define()

    /**
     * Identifies a plot as a list container. This makes some
     * commands treat the plot specially.
     */
    static List = Role.define()

    /**
     * Identifies a plot as a table, which holds rows. Table cell
     * selection works with the plots that have this role.
     */
    static Table = Role.define()

    /** Identifies a plot as a table row, which holds table cells. */
    static TableRow = Role.define()

    /**
     * A single leaf type in a schema may have the `LineBreak` role,
     * which identifies it as the canonical node that represents a
     * line break. Nodes marked as line breaks will be parsed from
     * and serialized to newline characters inside {@link
     * Plot.Spec.preserveWhitespace whitespace-preserving} nodes.
     */
    static LineBreak = Role.define()
  }
}

/**
 * A leaf node, which is a node with no content nodes. Used for
 * things like text, images, line breaks, and so on. Counts as a
 * {@link Node.Tag}.
 */
export class Leaf<Param = unknown> extends BaseTag<Param> implements Node.Shared, Node.Tag.Shared<Param> {
  private constructor(
    /** This leaf's type. */
    readonly type: Leaf.Type<Param>,
    param: Param,
    marks: Mark.Set
  ) {
    super(param, marks)
  }

  /** @internal */
  static new<Param>(type: Leaf.Type<Param>, param: Param, marks: Mark.Set) {
    return new Leaf(type, param, marks)
  }

  get tag() {
    return this
  }

  eq(other: Node | Node.Tag): boolean {
    return (
      this == other ||
      (other.isLeaf &&
        this.type == other.type &&
        compareDeep(this.param, other.param) &&
        Mark.sameSet(this.marks, other.marks))
    )
  }

  /**
   * Define a singleton leaf type, without parameter. If you need to
   * store a parameter value in each leaf of the type, use {@link
   * Leaf.Type.define} instead.
   */
  static define(name: string, spec: Leaf.Spec<null>): Leaf<null> {
    return Leaf.Type.new<null>(name, flagsFor(spec) | NodeFlag.NullParam, spec).default!
  }

  withMarks(marks: Mark.Set) {
    return Mark.sameSet(this.marks, marks) ? this : this.type.of(this.param, marks)
  }

  /**
   * In {@link Slice slices}, leaf nodes count as node {@link Token
   * tokens}.
   */
  get tokenType(): Token.Type.Node {
    return Token.Type.Node
  }

  get isLeaf(): true {
    return true
  }
  get isPlot(): false {
    return false
  }
  get isInline() {
    return this.type.isInline
  }
  get isBlock() {
    return this.type.isBlock
  }

  get length(): number {
    return this.is(Leaf.Text) ? this.param.length : 1
  }

  /** @internal */
  pushTo(nodes: Node[]) {
    if (this.is(Leaf.Text)) {
      const prevI = nodes.length - 1,
        prev = prevI >= 0 ? nodes[prevI] : null
      if (prev && prev.is(Leaf.Text) && Mark.sameSet(prev.marks, this.marks)) {
        nodes[prevI] = Leaf.text(prev.param + this.param, this.marks)
        return
      }
    }
    nodes.push(this)
  }

  /** @internal */
  sliceInner(from: number, to: number): readonly Token[] {
    return from == to ? [] : [this.is(Leaf.Text) ? this.sliceText(from, to) : this]
  }

  /** @internal */
  sliceText(from: number, to?: number): Leaf<string> {
    if (!this.is(Leaf.Text)) throw new Error('Calling sliceText on a non-text node')
    if (to == null) to = this.param.length
    if (!from && to == this.param.length) return this
    return Leaf.Text.of(this.param.slice(Math.max(from, 0), Math.max(0, to)), this.marks)
  }

  /** Create a text node with the given text and mark set. */
  static text(text: string, marks: Mark.Set = Mark.none) {
    if (!text) throw new Error('Cannot create empty text nodes')
    return Leaf.Text.of(text, marks)
  }

  /** @internal */
  toString() {
    return (this.is(Leaf.Text) ? JSON.stringify(this.param) : (this as Leaf).name) + markString(this.marks)
  }
}

export namespace Leaf {
  /** Node type for leaves. */
  export class Type<Param = unknown> extends BaseType<Param> {
    /**
     * A default leaf for this type. Available if the leaf was
     * defined with {@link Leaf.define}, or a {@link
     * Node.Spec.defaultParam} was given.
     */
    default: Leaf<Param> | null

    /**
     * The spec used to define this type. Its type parameter is
     * cleared to avoid this field making the class invariant (in the
     * type system sense), which would prevent `Leaf.Type<unknown>`
     * from being a supertype of specific leaf types.
     */
    readonly spec: Leaf.Spec<any>

    private constructor(name: string, flags: NodeFlag, spec: Leaf.Spec<Param>) {
      super(name, flags, spec, NodeShape.from(name, true, spec.shape))
      this.spec = spec
      this.default =
        'defaultParam' in spec
          ? Leaf.new(this, spec.defaultParam!, none)
          : flags & NodeFlag.NullParam
            ? Leaf.new(this, null as any, none)
            : null
    }

    /** @internal */
    static new<Param>(name: string, flags: NodeFlag, spec: Leaf.Spec<Param>) {
      return new Type(name, flags, spec)
    }

    /** Define a new leaf type. */
    static define<T>(name: string, spec: Leaf.Spec<T>) {
      return new Leaf.Type<T>(name, flagsFor(spec), spec)
    }

    /** Create a leaf with this type. */
    of(param: Param, marks: Mark.Set = Mark.none) {
      if (!marks.length && this.default && compareDeep(this.default.param, param)) return this.default
      return Leaf.new(this, param, marks)
    }

    /** Used to narrow {@link Node.Type} values to {@link Leaf}. */
    get isLeaf(): true {
      return true
    }

    /** Leaves are not plots. */
    get isPlot(): false {
      return false
    }
  }

  export interface Spec<Param> extends Node.Spec<Param> {
    /**
     * Can be used to make leaves of this type show up in the output
     * of {@link Plot.textContent}.
     */
    toText?: (node: Leaf) => string
  }

  /**
   * The type of text leaves. Represents a series of characters with
   * a given set of marks. The only leaf with a length that isn't
   * always 1. Adjacent text leaves with the same marks are merged
   * automatically.
   *
   * Text leaves must not include newline or return characters. Line
   * breaks in the document are modeled with {@link LineBreak} nodes.
   */
  export const Text: Leaf.Type<string> = Leaf.Type.new<string>('Text', NodeFlag.Inline, {
    shape: { element: '' }
  })
}

/**
 * Plots delimit parts of the document, giving a special meaning to
 * the nodes inside them. They are defined by a {@link Plot.Tag tag}
 * and an array of {@link Plot.content content}.
 */
export class Plot implements Node.Shared {
  /** @internal */
  protected constructor(
    /** The tag that identifies this plot. */
    readonly tag: Plot.Tag,
    /** The nodes in this plot. */
    readonly content: readonly Node[]
  ) {
    this.contentLength = content.reduce((s, c) => s + c.length, 0)
  }

  /** The sum of the length of this plot's content nodes. */
  contentLength: number

  /** @internal */
  static create(tag: Plot.Tag, content: readonly Node[]) {
    return new Plot(tag, content)
  }

  get name() {
    return this.tag.name
  }
  /** The type of this plot's tag. */
  get type() {
    return this.tag.type
  }
  get marks() {
    return this.tag.marks
  }

  get length() {
    return 2 + this.contentLength
  }

  eq(other: Node): boolean {
    return this == other || (other instanceof Plot && this.tag.eq(other.tag) && this.contentEq(other))
  }

  /**
   * Compare the content of this plot to the content of the given
   * plot.
   */
  contentEq(other: Plot): boolean {
    return eqArray(this.content, other.content)
  }

  /** @internal */
  sliceInner(from: number, to: number): readonly Token[] {
    if (from == to) return []
    const content: Token[] = []
    this.slicePlot(content, from, to)
    return content
  }

  /** @internal */
  slicePlot(out: Token[], from: number, to: number) {
    if (from <= 0) {
      if (to >= this.length) {
        out.push(this)
        return
      }
      out.push(this.tag)
    }
    sliceContent(out, this.content, from - 1, to - 1)
    if (to >= this.length) out.push(Plot.End)
  }

  /** @hidden */
  is<T>(_type: Leaf.Type<T>): false {
    return false
  }

  get isText(): false {
    return false
  }

  /** Tells you whether the content of this plot is inline. */
  get inlineContent() {
    return this.type.inlineContent
  }
  /** True if this is a block node with inline content. */
  get isTextblock() {
    return this.type.isTextblock
  }
  get isLeaf(): false {
    return false
  }
  get isPlot(): true {
    return true
  }
  get isInline() {
    return this.type.isInline
  }
  get isBlock() {
    return this.type.isBlock
  }
  /** True if this is a document node. */
  get isDoc() {
    return this.type.isDoc
  }

  /** Get the plot's first child, if any. */
  get firstChild(): Node | null {
    return this.content.length ? this.content[0]! : null
  }

  /** Get the plot's first child. */
  get lastChild(): Node | null {
    const last = this.content.length - 1
    return last < 0 ? null : this.content[last]!
  }

  /**
   * Iterate though the given range (or the entire document, when
   * given only one argument), and call the given function on every
   * node that overlaps the given range, outer nodes before inner
   * nodes. When the function returns `false` for a node, descendents
   * of that node are not iterated.
   *
   * When `from` is greater than `to`, iteration happens in inverted
   * order, yielding later siblings before earlier ones.
   *
   * Note that positions passed to the callback are relative to the
   * start of the node this method is called on. That will usually be
   * the document, in which case they are normal document positions,
   * but you can also call it on an arbitrary plot, in which case
   * they are local positions.
   */
  iterate(
    from: number,
    to: number,
    f: (node: Node, pos: number, parent: Plot | null, index: number) => boolean | void
  ): void
  iterate(f: (node: Node, pos: number, parent: Plot | null, index: number) => boolean | void): void
  iterate(
    a: number | ((node: Node, pos: number, parent: Plot | null, index: number) => boolean | void),
    b?: number,
    c?: (node: Node, pos: number, parent: Plot | null, index: number) => boolean | void
  ): void {
    const [from, to, f] = typeof a == 'number' ? [a, b!, c!] : [0, this.length, a]
    if (this.isDoc || f(this, 0, null, 0) !== false) {
      if (to < from) this.iterBack(this.contentLength, to, from, f)
      else this.iterInner(0, from, to, f)
    }
  }

  /**
   * Return the node that starts at the given offset from this node's
   * content start, if any. Will not return text nodes.
   */
  nodeAt(pos: number): Node | null {
    for (const node of this.content) {
      if (pos == 0) return node.isText ? null : node
      if (pos < node.length) return node.isLeaf ? null : node.nodeAt(pos - 1)
      pos -= node.length
    }
    return null
  }

  /** Return the plot at the given offset, if any. */
  plotAt(pos: number): Plot | null {
    const node = this.nodeAt(pos)
    return node instanceof Plot ? node : null
  }

  /** Return the text content of this plot. */
  textContent(
    options: {
      /**
       * An optional start position, as an offset from the plot's
       * content start.
       */
      from?: number
      /** An optional end position. */
      to?: number
      /**
       * Text to separate blocks with. Defaults to a single newline
       * character.
       */
      blockSeparator?: string
      /** Override the way non-text leaves are converted to string. */
      leafText?: string | ((node: Leaf) => string)
    } = {}
  ) {
    const { from = 0, to = this.length, blockSeparator = '\n', leafText } = options
    const out = new TextOutput(
      blockSeparator,
      leafText == null ? undefined : typeof leafText == 'string' ? () => leafText : leafText
    )
    this.iterate(from, to, (node, pos) => {
      return !out.serialize(
        node.is(Leaf.Text) ? node.sliceText(Math.max(0, from - pos), Math.min(node.length, to - pos)) : node
      )
    })
    return out.text
  }

  /** @internal */
  iterInner(
    contentStart: number,
    from: number,
    to: number,
    f: (node: Node, pos: number, parent: Plot | null, index: number) => boolean | void
  ) {
    for (let pos = contentStart, i = 0; i < this.content.length; i++) {
      if (pos >= to) break
      const node = this.content[i]!,
        start = pos
      pos += node.length
      if (pos > from && f(node, start, this, i) !== false && node.isPlot) node.iterInner(start + 1, from, to, f)
    }
  }

  /** @internal */
  iterBack(
    contentEnd: number,
    from: number,
    to: number,
    f: (node: Node, pos: number, parent: Plot | null, index: number) => boolean | void
  ) {
    for (let pos = contentEnd, i = this.content.length - 1; i >= 0; i--) {
      if (pos <= from) break
      const node = this.content[i]!,
        end = pos
      pos -= node.length
      if (pos < to && f(node, pos, this, i) !== false && node.isPlot) node.iterBack(end - 1, from, to, f)
    }
  }

  /** @internal */
  toString() {
    return `${this.name + markString(this.tag.marks)}(${this.content.join()})`
  }

  toJSON(): Node.JSON {
    const result = this.tag.toJSON()
    result.content = this.content.map(c => c.toJSON())
    return result
  }

  mark<Value>(mark: Mark.Type<Value>): Value | undefined {
    return this.tag.mark(mark)
  }

  /** @internal */
  pushTo(nodes: Node[]) {
    nodes.push(this)
  }

  withMarks(marks: Mark.Set) {
    return Mark.sameSet(this.tag.marks, marks) ? this : this.tag.withMarks(marks).create(this.content)
  }

  /**
   * Plot nodes count as node {@link Token tokens} in a {@link
   * Slice}.
   */
  get tokenType(): Token.Type.Node {
    return Token.Type.Node
  }

  /**
   * Define a singleton plot type. If the plot needs a parameter
   * value, use {@link Plot.Type.define} instead.
   */
  static define(name: string, spec: Plot.Spec<null>): Plot.Tag<null> {
    return Plot.Type.new<null>(name, flagsFor(spec) | NodeFlag.NullParam, spec).default!
  }

  /** Define a document plot type. Exactly one of these must occur in a schema. */
  static defineDoc(spec: { inlineContent?: Node.Query | true; blockContent?: Node.Query; canBeEmpty?: boolean }) {
    if (!spec.inlineContent && !spec.blockContent) throw new SchemaError('Doc nodes must allow content')
    let flags = NodeFlag.NullParam | NodeFlag.Doc | NodeFlag.NullParam
    if (spec.inlineContent) flags |= NodeFlag.InlineContent
    if (spec.inlineContent || spec.canBeEmpty) flags |= NodeFlag.CanBeEmpty
    return Plot.Type.new<null>('Doc', flags, {
      ...spec,
      shape: { element: '' }
    })
  }
}

export namespace Plot {
  /** The end token for a plot. Used in {@link Slice slices}. */
  export const End = Token.End

  /**
   * A plot tag holds the type of the plot, its parameter (if any),
   * and a set of marks.
   */
  export class Tag<Param = unknown> extends BaseTag<Param> implements Node.Tag.Shared<Param> {
    private constructor(
      readonly type: Plot.Type<Param>,
      param: Param,
      marks: Mark.Set
    ) {
      super(param, marks)
    }

    /** @internal */
    static new<Param>(type: Plot.Type<Param>, param: Param, marks: Mark.Set) {
      return new Tag(type, param, marks)
    }

    eq(other: Node | Node.Tag): boolean {
      return (
        this == other ||
        (other instanceof Plot.Tag &&
          this.type == other.type &&
          compareDeep(this.param, other.param) &&
          Mark.sameSet(this.marks, other.marks))
      )
    }

    /** Create a plot with this tag and the given content. */
    create(content?: readonly Node[]): Plot {
      if (this.isDoc) throw new Error('Document nodes must be created with schema.doc()')
      return Plot.create(this, content ? joinText(content) : none)
    }

    /** Create a copy of this tag with the given marks. */
    withMarks(marks: Mark.Set) {
      return Mark.sameSet(this.marks, marks) ? this : this.type.of(this.param, marks)
    }

    /**
     * Return a tag that represents content split off from the plot
     * with this tag. Will respect the {@link Mark.Spec.keepOnSplit}
     * mark property. `atEnd` should be set to true if the split
     * happens at the end of the plot's content.
     */
    split(atEnd: boolean): Tag<Param> {
      return this.marks.length
        ? this.withMarks(
            this.marks.filter(p => {
              const { keepOnSplit } = p.type.spec
              return keepOnSplit && (keepOnSplit === true || keepOnSplit(this, atEnd))
            })
          )
        : this
    }

    /**
     * A plot tag counts as an open {@link Token token} in a {@link
     * Slice slice}.
     */
    get tokenType(): Token.Type.Open {
      return Token.Type.Open
    }

    /** True when this plot type contains inline content. */
    get inlineContent() {
      return this.type.inlineContent
    }
    /** True when this is a block plot with inline content. */
    get isTextblock() {
      return this.type.isTextblock
    }
    get isLeaf(): false {
      return false
    }
    get isPlot(): true {
      return true
    }
    /** Test whether this is a document plot. */
    get isDoc() {
      return this.type.isDoc
    }

    /** @internal */
    toString() {
      return this.type.name + markString(this.marks)
    }
  }

  /** A type of {@link Plot plot}. */
  export class Type<Param = unknown> extends BaseType<Param> {
    /** A default tag for this plot type. */
    readonly default: Plot.Tag<Param> | null
    /**
     * Whether the {@link Plot.Spec.isolating} flag is set on this
     * plot type.
     */
    readonly isolating: boolean
    /** The plot's {@link Plot.Spec.defining} flag. */
    readonly defining: boolean
    /** The plot's {@link Plot.Spec.neutral} flag. */
    readonly neutral: boolean
    /** Whether whitespace should be preserved inside this plot. */
    readonly preserveWhitespace: boolean
    /**
     * The orientation of the content of the plot. Will be `"row"`
     * for plots with inline content, and defaults to `"column"` for
     * plots with block content unless explicitly {@link
     * Plot.Spec.orientation set}.
     */
    readonly orientation: 'row' | 'column'

    /** The spec used to define this plot type. */
    readonly spec: Plot.Spec<any>

    private constructor(name: string, flags: NodeFlag, spec: Plot.Spec<Param>) {
      super(name, flags, spec, NodeShape.from(name, false, spec.shape))
      this.spec = spec
      if (!spec.inlineContent && !spec.blockContent) {
        throw new SchemaError('Plot definitions must specify either inlineContent or blockContent')
      }
      this.isolating = !!spec.isolating
      this.defining = !!spec.defining
      this.neutral = spec.neutral ?? !this.defining
      this.preserveWhitespace = spec.preserveWhitespace ?? !!this.hasRole(Node.Role.Code)
      this.orientation = flags & NodeFlag.InlineContent ? 'row' : spec.orientation || 'column'
      this.default =
        'defaultParam' in spec
          ? Plot.Tag.new(this, spec.defaultParam!, none)
          : flags & NodeFlag.NullParam
            ? Plot.Tag.new(this, null as any, none)
            : null
      if (!this.shape.atom && this.isInline && !this.inlineContent) {
        throw new SchemaError('Inline tags with block content must be marked as atoms')
      }
    }

    /** @internal */
    static new<Param>(name: string, flags: NodeFlag, spec: Plot.Spec<Param>) {
      return new Type(name, flags, spec)
    }

    /** Define a plot type. */
    static define<T>(name: string, spec: Plot.Spec<T>) {
      return new Plot.Type<T>(name, flagsFor(spec), spec)
    }

    /**
     * Create a plot tag of this type with the given parameter and
     * mark set.
     */
    of(param: Param, marks: Mark.Set = Mark.none) {
      if (!marks.length && this.default && compareDeep(this.default.param, param)) return this.default
      return Plot.Tag.new(this, param, marks)
    }

    /** Tells you whether this plot type has inline content. */
    get inlineContent() {
      return (this.flags & NodeFlag.InlineContent) > 0
    }
    /** True if this is a block plot with inline content. */
    get isTextblock() {
      return this.isBlock && this.inlineContent
    }
    /** True if this is a document plot type. */
    get isDoc() {
      return (this.flags & NodeFlag.Doc) > 0
    }
    /** Tells you that this is not a leaf type. */
    get isLeaf(): false {
      return false
    }
    /**
     * This is a plot type. Can be used to narrow `Node.Type` to
     * `Plot.Type`.
     */
    get isPlot(): true {
      return true
    }

    /**
     * Tells you whether this plot type is allowed {@link
     * Plot.Spec.canBeEmpty to be empty}.
     */
    get canBeEmpty() {
      return (this.flags & NodeFlag.CanBeEmpty) > 0
    }
  }

  /** Object used to define a plot type. */
  export interface Spec<Param> extends Node.Spec<Param> {
    /**
     * When this node has block-level content, provide a query
     * matching the nodes it may contain here. You generally don't
     * want to use `Node.Group.Block` here, since specialized block
     * types (like table cells or list items) should probably only be
     * allowed in their designated parent plots.
     */
    blockContent?: Node.Query
    /**
     * When this node has inline content, provide a query specifying
     * valid content. If set to `true`, any inline node may appear in
     * this node.
     */
    inlineContent?: Node.Query | true
    /**
     * Plots with block content, by default, require at least one
     * child. You can set this to true to allow them to be empty.
     * Plots with inlne content can always be empty.
     */
    canBeEmpty?: boolean
    /**
     * Whether the sides of this plot act as a 'barrier' when {@link
     * state.GardSelection.nextNormalCursor normalizing} a cursor
     * position, which means that a separate cursor position exists
     * at its boundary. By default, nodes that are {@link
     * Plot.Spec.isolating isolating}, {@link
     * Plot.Spec.preserveWhitespace whitespace-preserving}, or both
     * a {@link Leaf leaf} and a block count as barriers. `"empty"`
     * makes the plot a barrier only while it has no content, so that
     * an empty container holds a cursor position, but no position
     * appears between two filled containers.
     */
    cursorBarrier?: boolean | 'empty'
    /**
     * Indicates that this type of block is the default generic block
     * type in parent nodes where it may occur (which is appropriate
     * for, for example, paragraphs tags). Default blocks should not
     * have a required param. When not specified, the configuration
     * precedence order determines which child type is the default.
     */
    defaultBlock?: boolean
    /**
     * Controls whether whitespace inside this type of node should be
     * preserved. Disables whitespace collapsing and the replacement
     * of newlines with line break nodes in the parser and
     * serializer. Defaults to false, unless the node has the {@link
     * Node.Role.Code} role.
     */
    preserveWhitespace?: boolean
    /**
     * Isolating plots disallow some kinds of editing across their
     * borders (such as backspacing or unwrapping). A table cell is
     * an example of a node that you'd use this for.
     */
    isolating?: boolean
    /**
     * Block containers are, by default, assumed to arrange their
     * children vertically below each other (`"column"`). You can set this
     * to `"row"` to tell the editor that this container's children
     * are horizontally next to each other.
     */
    orientation?: 'row' | 'column'
    /**
     * Defining nodes are preserved (when possible) when their content
     * is duplicated (dragged, pasted, etc) into a new position.
     * Defaults to false.
     */
    defining?: boolean
    /**
     * Neutral nodes may be completely replaced when their entire
     * content gets replaced. Defaults to `!`{@link
     * Plot.Spec.defining}.
     */
    neutral?: boolean
    /**
     * Whether block nodes of this type should be automatically
     * joined when they become adjacent through an edit. Defaults to
     * false. Note that editing commands need to explicitly call
     * {@link command.autoJoinBlocks} for joining to happen.
     */
    autoJoin?: boolean | ((before: Plot.Tag, after: Plot.Tag) => boolean)
    /**
     * By default, splitting a textblock at the end will revert the new
     * block to the default type of textblock at that position. Setting
     * this to true on a textblock type will prevent that behavior.
     */
    preserveOnSplitAtEnd?: boolean
  }

  let validate = true

  /**
   * Document plots are used as the top level plot in a document.
   * They offer some additional methods and, unlike normal plots,
   * their {@link Plot.Doc.length `length` property} reports only the
   * length of their content, without counting open/close tokens
   * (because those are not part of the document).
   */
  export class Doc extends Plot {
    private constructor(
      /** The document's schema. */
      readonly schema: Schema,
      children: readonly Node[]
    ) {
      super(schema.docTag, children)
      if (validate) schema.validate(this)
    }

    /** @internal */
    static new(schema: Schema, children: readonly Node[]) {
      return new Doc(schema, children)
    }

    /** The length of the document's content. */
    get length() {
      return this.contentLength
    }

    /** @internal */
    slicePlot(content: Token[], from: number, to: number) {
      sliceContent(content, this.content, from, to)
    }

    /**
     * Resolve the given position in the document, returning an
     * object describing its context.
     */
    resolve(pos: number) {
      return Pos.resolve(this, pos)
    }

    /**
     * Resolve the node at the given position, providing information
     * about its context.
     */
    resolveNode(pos: number) {
      return Pos.resolveNode(this, pos)
    }

    /**
     * Like {@link Plot.Doc.resolveNode}, but only resolves plot
     * nodes.
     */
    resolvePlot(pos: number) {
      const r = this.resolveNode(pos)
      return r instanceof Pos.Plot ? r : null
    }

    /**
     * Get the context stack (the array of wrapping plot tags,
     * inner-to-outer) at the given position.
     */
    contextAt(pos: number, maxDepth?: number): readonly Plot.Tag[] {
      for (let { parent } = this.resolve(pos), context = []; ;) {
        if (!parent.parent || (maxDepth != null && context.length == maxDepth)) return context
        context.push(parent.node.tag)
        parent = parent.parent
      }
    }

    /** Create a token slice of the content between `from` and `to`. */
    slice(from: number, to?: number) {
      return this.sliceInner(from, to ?? this.length)
    }

    /** @internal */
    static noValidate<T>(f: () => T): T {
      const prev = validate
      validate = false
      try {
        return f()
      } finally {
        validate = prev
      }
    }
  }
}

function flagsFor(spec: Plot.Spec<any>) {
  let flags = spec.inline ? NodeFlag.Inline : NodeFlag.None
  if (spec.inlineContent && spec.blockContent) throw new SchemaError('A tag cannot have both block and inline content')
  if (spec.inlineContent) flags |= NodeFlag.InlineContent
  if (spec.inlineContent || spec.canBeEmpty) flags |= NodeFlag.CanBeEmpty
  if (spec.selectable) flags |= NodeFlag.Selectable
  return flags
}

function markString(marks: Mark.Set) {
  const values: string[] = []
  for (const mark of marks) {
    if (mark.type.default == mark) values.push(mark.type.name)
    else values.push(`${mark.type.name}=${mark.value}`)
  }
  return values.length ? `[${values.join()}]` : ''
}

function sliceContent(out: Token[], content: readonly Node[], from: number, to: number) {
  let off = 0
  for (const child of content) {
    if (off >= to) break
    const start = off
    off += child.length
    if (off <= from) continue
    if (child.isPlot) {
      child.slicePlot(out, from - start, to - start)
    } else if (child.isText) {
      out.push(child.sliceText(from - start, to - start))
    } else {
      out.push(child)
    }
  }
}

function joinText(nodes: readonly Node[]) {
  if (!nodes.length || nodes[0]!.isBlock) return nodes
  let joined: Node[] | undefined
  for (let i = 0, last: Leaf<string> | null = null; i < nodes.length; i++) {
    const node = nodes[i]!
    if (node.is(Leaf.Text)) {
      if (last && Mark.sameSet(last.marks, node.marks)) {
        if (!joined) joined = nodes.slice(0, i)
        last = joined[joined.length - 1] = Leaf.text(last.param + node.param, node.marks)
        continue
      } else {
        last = node
      }
    } else {
      last = null
    }
    if (joined) joined.push(node)
  }
  return joined || nodes
}
