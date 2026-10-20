import { GardState, GardSelection } from '../state'
import { Mark, Mark as Mark_, Pos, Plot, Leaf, Node, Shape as Shape_, ChangeSet, Schema, Elt, Attributes } from '../doc'
import { RangeSet, PointSet, Set, findAbove } from '../set'
import { addSection, Changes, addUpdated, addRange, joinRanges } from './changes'
import { type Wordgard } from './editor'

/**
 * A widget describes a piece of DOM content that can be used to
 * render a node, a part of a node, or an extra element added via a
 * decoration. The `Widget` object is separate from its DOM
 * representation. It describes how the DOM widget is to be rendered
 * and how it behaves, but it itself is an immutable value.
 */
export class Widget<Param = unknown> {
  private constructor(
    type: Widget.Type<Param>,
    /** The parameter for this widget. */
    readonly value: Param
  ) {
    this.type = type as any
  }

  /** @internal */
  static new<Param>(type: Widget.Type<Param>, value: Param) {
    return new Widget(type, value)
  }

  /** Compare this widget to another widget object. */
  eq(other: any) {
    return other instanceof Widget && other.type == this.type && this.type.eq(this.value as any, other.value)
  }

  /** Define a widget type. */
  static define<Param>(spec: Widget.Spec<Param>) {
    return Widget.Type.new(spec)
  }

  /** Create a singleton widget. */
  static create(spec: Widget.Spec<null>) {
    return Widget.Type.new<null>(spec).of(null)
  }

  /**
   * This widget's type. The type mangling is a kludge to make sure
   * `Widget<Param>` is a subtype of `Widget<unknown>`.
   */
  readonly type: Widget.Type<unknown extends Param ? any : Param>

  /** @internal */
  render(wg: Wordgard) {
    return this.type.render(this.value, wg)
  }

  /** @internal */
  get hasContent() {
    return false
  }
}

export namespace Widget {
  /** Specifies a widget type. */
  export type Spec<Param> = {
    /** How to render the widget as DOM content. */
    render: (value: Param, wg: Wordgard) => Element | Text
    /** Compare the widget value for equality. Will default to `===`. */
    eq?: (a: Param, b: Param) => boolean
    /**
     * Called when a widget of this type is added to an editor that
     * is connected to a DOM document, or an editor with the widget
     * in it is connected.
     */
    connect?: (value: Param, dom: Element | Text) => void
    /**
     * Called when a widget of this type is removed from an editor
     * that is connected to a document, or when the editor containing
     * the widget is disconnected.
     */
    disconnect?: (value: Param, dom: Element | Text) => void
    /**
     * Used to determine whether events originating from the widget's
     * DOM should ignored by the editor. `false` or a function that
     * returns `false` for the event will prevent the editor's
     * regular event handling for the event.
     */
    propagateEvent?: boolean | ((event: Event) => boolean)
    /**
     * Set this to false for widgets that either aren't visible or
     * are positioned outside of the regular document flow.
     */
    inFlow?: boolean
    /**
     * By default, widgets are set to be ineditable. Set this to
     * `true` to suppress that.
     */
    editable?: boolean
  }

  /**
   * Each widget has an associated type that describes how it
   * behaves.
   */
  export class Type<Param> {
    private constructor(
      /** @internal */
      readonly render: (value: Param, wg: Wordgard) => Element | Text,
      /** @internal */
      readonly eq: (a: Param, b: Param) => boolean,
      /** @internal */
      readonly propagateEvent: (event: Event) => boolean,
      /** @internal */
      readonly connect: ((value: Param, dom: Element | Text) => void) | null,
      /** @internal */
      readonly disconnect: ((value: Param, dom: Element | Text) => void) | null,
      /** @internal */
      readonly inFlow: boolean,
      /** @internal */
      readonly editable: boolean
    ) {}

    /** @internal */
    static new<Param>(spec: Widget.Spec<Param>) {
      const prop = spec.propagateEvent
      const propEvent = typeof prop == 'function' ? prop : prop == null ? () => true : () => prop
      return new Type(
        spec.render,
        spec.eq || ((a, b) => a === b),
        propEvent,
        spec.connect ?? null,
        spec.disconnect ?? null,
        spec.inFlow !== false,
        spec.editable === true
      )
    }

    /** Create an instance of this widget type. */
    of(value: Param) {
      return Widget.new(this, value)
    }
  }

  /** @internal */
  export const text = Widget.define<string>({
    render: s => document.createTextNode(s)
  })

  /** @internal */
  export const editableText = Widget.define<string>({
    render: s => document.createTextNode(s)
  })

  /** @internal */
  export const img = Widget.create({
    render() {
      const img = document.createElement('img')
      img.className = 'wg-buffer'
      return img
    },
    editable: true
  })

  /** @internal */
  export const br = Widget.create({
    render() {
      return document.createElement('br')
    },
    editable: true
  })
}

export type DecoElt = Elt<Widget | string>

export namespace Decoration {
  /**
   * Node shapes can be either a widget or an element which may
   * contain widgets.
   */
  export type Shape = Widget | DecoElt

  export namespace Tag {
    /**
     * Override the way a given node type is drawn in the editor. By
     * default, the {@link doc.Node.Spec.shape `shape`} field in the
     * type's definition will be used, but extensions created with
     * this function can provide an alternative shape for a given
     * type.
     *
     * When providing a function for the shape, keep in mind that the
     * result will be cached by tag, and you should make sure your
     * function is pure.
     *
     * When providing a function that returns a shape that changes
     * whether the node is rendered as an atom, you need to provide
     * the `atom`.
     */
    export function shape<T extends Node.Type.Ref<any>>(
      type: T,
      shape: Shape | ((tag: Node.Tag.For<T>) => Shape),
      config?: { atom?: boolean }
    ) {
      const tp = Node.Type.get(type)
      const shapeFunc: (tag: Node.Tag) => Shape =
        typeof shape == 'function' ? memo(tag => shape(tag as any)) : () => shape
      const atom = typeof shape == 'function' ? config?.atom : !shape.hasContent
      let ext: GardState.Extension = tagShape.of({ type: tp, shape: shapeFunc })
      if (tp.isPlot && atom != null) ext = [ext, GardState.isAtom.of([tp, atom])]
      return ext
    }

    export namespace shape {
      /**
       * This function allows you to define a {@link Decoration.Tag.shape
       * custom node shape} that depends on the editor state. It will
       * automatically track which state slots (see {@link
       * GardState.Facet.derive}) you use, and make sure the nodes
       * are redrawn when those change.
       *
       * If your shape function returns a function from a tag, you
       * must be careful do any state access you need in the _outer_
       * function, not the returned function, or it won't be tracked.
       *
       * You generally don't want to make your shapes depend on
       * constantly-changing slots like the document or selection,
       * because when the document is big, there's a non-trivial
       * amount of work involved when a node shape changes (or may
       * have changed).
       *
       * When providing a shape for a plot that changes whether it is
       * rendered as an atom, provide the `atom` option.
       */
      export function derived<T extends Node.Type<any>>(
        type: T,
        shape: (state: GardState) => Shape | ((tag: Node.Tag.For<T>) => Shape),
        config?: { atom?: boolean }
      ) {
        const tp = Node.Type.get(type)
        let ext = tagShape.derive(state => {
          const s = shape(state)
          return { type: tp, shape: typeof s == 'function' ? memo(s as any) : () => s }
        })
        const atom = config?.atom
        if (tp.isPlot && atom != null) ext = [ext, GardState.isAtom.of([tp, atom])]
        return ext
      }
    }

    /**
     * Define a wrapper to be added around a given node type, or some
     * part of it. The given elt should include a hole (`0`) to
     * indicate where the original shape goes.
     *
     * If a `target` option is given, and matching some element in
     * the node's existing shape, only that element will be wrapped.
     * Uses a subset of CSS selectors that supports only tag name and
     * class names (`img.x.y`).
     */
    export function wrapper(
      type: Node.Type.Ref<any>,
      wrapper: DecoElt,
      options?: {
        target?: string
      }
    ) {
      if (!wrapper.hasContent) throw new Error('Wrapper elements should have a content hole')
      return tagWrapper.of({
        type: Node.Type.get(type),
        elt: wrapper,
        target: options && options.target ? Elt.Selector.parse(options.target) : null
      })
    }

    function getPlace(place: 'before' | 'after' | 'start' | 'end') {
      return place == 'before'
        ? WidgetPlace.Before
        : place == 'after'
          ? WidgetPlace.After
          : place == 'end'
            ? WidgetPlace.End
            : WidgetPlace.Start
    }

    /**
     * Add a widget to every instance of the given node type. Such
     * widgets can appear before or after the node, and for plots
     * that aren't rendered as atoms, at its start or end.
     *
     * When a function, `widget` will be cached by tag, and should be
     * pure.
     */
    export function widget<T extends Node.Type.Ref<any>>(
      type: T,
      place: 'before' | 'after' | 'start' | 'end',
      widget: Widget | ((tag: Node.Tag.For<T>) => Widget)
    ) {
      return tagWidget.of({
        type: Node.Type.get(type),
        place: getPlace(place),
        widget: typeof widget == 'function' ? memo(widget as any) : widget
      })
    }

    export namespace widget {
      /**
       * Define a node widget decoration that depends on some aspect
       * of the editor state. See the notes for {@link
       * Decoration.Tag.shape.derived}.
       */
      export function derived<T extends Node.Type.Ref<any>>(
        type: T,
        place: 'before' | 'after' | 'start' | 'end',
        widget: (state: GardState) => Widget | ((tag: Node.Tag.For<T>) => Widget)
      ) {
        const tp = Node.Type.get(type)
        const p = getPlace(place)
        return tagWidget.derive(state => {
          const w = widget(state)
          return {
            type: tp,
            place: p,
            widget: typeof w == 'function' ? memo(w as any) : w
          }
        })
      }
    }

    /**
     * Add an attribute to the representation of a given node type.
     *
     * By default, the attribute is added to the outer element (or a
     * wrapper element if the node is rendered as a widget). If the
     * `target` option is given, and
     * [matches](#editor.Decoration.Tag.wrapper.options.target) an
     * element in the representation, it will be added to that
     * element instead.
     */
    export function attribute<T extends Node.Type.Ref<any>>(
      type: T,
      attr: string,
      value: string | ((tag: Node.Tag.For<T>) => string),
      options?: { target?: string }
    ) {
      const tp = Node.Type.get(type)
      return tagAttribute.of({
        type: tp,
        attr,
        value: typeof value == 'string' ? () => value : (value as any),
        target: options?.target ? Elt.Selector.parse(options.target) : null
      })
    }
  }

  export namespace Mark {
    /** Override the shape used for a given mark inside the editor. */
    export function shape<V>(
      type: Mark_.Type<V>,
      shape: Shape_.Element<V> | Shape_.Attribute<V> | Shape_.Attributes<V>
    ): GardState.Extension
    export function shape(
      mark: Mark_<null>,
      shape: Shape_.Element<null> | Shape_.Attribute<null> | Shape_.Attributes<null>
    ): GardState.Extension
    export function shape(
      type: Mark_.Type<any> | Mark_<null>,
      shape: Shape_.Element<any> | Shape_.Attribute<any> | Shape_.Attributes<any>
    ) {
      if (type instanceof Mark_) type = type.type
      if (type.spanning && !('element' in shape)) throw new Error('Spanning marks must have an element shape')
      return markShape.of({ type, modified: Mark_.Type.define(type.name, { ...type.spec, shape } as any) })
    }
  }

  /**
   * A point decoration is a decoration that targets a given position
   * in the document, or the node after a given position. Sets of
   * point decorations can be provided as point sets through {@link
   * Decoration.Point.source}.
   */
  export abstract class Point implements PointSet.Value {
    /** @internal */
    constructor() {}

    abstract eq(other: PointSet.Value): boolean
    abstract side: number
    abstract trackMode: ChangeSet.TrackMode | undefined

    /** Display a widget at this point. */
    static widget(
      widget: Widget,
      options?: {
        /**
         * Determines where this widget appears relative to the cursor
         * (negative means before, positive after, zero means to make
         * it depend on the cursor's own side) and other widgets in the
         * same position. Defaults to zero.
         */
        side?: number
        /**
         * What side to track when changes happen around the widget.
         * The default is to keep the widget around unless the content
         * on both sides is deleted. You can pass undefined to indicate
         * the widget should not be deleted by changes, or
         * `"before"`/`"after"` to use one specific side.
         */
        trackMode?: ChangeSet.TrackMode | undefined
      }
    ): Point {
      return new WidgetDecoration(
        widget,
        options?.side || 0,
        options && 'trackMode' in options ? options.trackMode : 'around'
      )
    }

    /**
     * Add a set of attributes to the node after this decoration's
     * position.
     *
     * You can target a [specific
     * element](#editor.Decoration.Tag.wrapper.options.target) in the
     * node's representation with the `target` option.
     */
    static attributes(attrs: Record<string, string>, options?: { target?: string }): Point {
      return new AttributeDecoration(
        Attributes.read(attrs),
        options?.target ? Elt.Selector.parse(options.target) : null
      )
    }

    /**
     * Override the shape of the node after the decoration's point
     * with the given one.
     */
    static shape(shape: Shape): Point {
      return new ShapeDecoration(shape)
    }

    /**
     * Wrap the node, or inner node selected with `target`, at the
     * given position with a wrapper.
     */
    static wrapper(wrapper: DecoElt, spec?: { target?: string }): Point {
      if (!wrapper.hasContent) throw new Error('Wrapper decoration elements must have a content hole')
      return new WrapperDecoration(wrapper, spec?.target ? Elt.Selector.parse(spec.target) : null)
    }

    /**
     * The facet used to register a point decoration source.
     * Functions provided in this way will be called on every editor
     * update, so computing the set on the fly will only perform well
     * for very simple decoration sets, and you'll usually want to
     * keep your set in a state field and update it incrementally.
     */
    static source = GardState.Facet.define<(state: GardState) => PointSet<Point>>({
      combine: sources => sources.concat(nodeSelection)
    })

    /**
     * Create a {@link PointSet} from an array or source function of
     * point decorations.
     */
    static set(source: Set.Source<Point>): Point.Set {
      return PointSet.create<Point>(source)
    }

    /** The empty set of point decorations. */
    static none: Point.Set = PointSet.empty
  }

  export namespace Point {
    /** The type used for sets of point decorations. */
    export type Set = PointSet<Point>
  }

  /**
   * Range decorations apply to a document range. They are stored in
   * {@link RangeSet}s and registered in an editor configuration with
   * {@link Decoration.Range.source}.
   */
  export abstract class Range implements RangeSet.Value {
    /** @internal */
    readonly query: Node.Query | null
    /** @internal */
    readonly scope: DecorationScope
    /** @internal */
    readonly inc: Inc

    /** @hidden */
    protected constructor(spec: Decoration.Range.Spec) {
      const { query, inclusive } = spec
      this.query = query || null
      this.scope =
        spec.scope == 'inlineatom'
          ? DecorationScope.InlineAtom
          : spec.scope == 'all'
            ? DecorationScope.All
            : DecorationScope.Atom
      this.inc =
        inclusive === 'start' ? Inc.Start : inclusive === 'end' ? Inc.End : inclusive ? Inc.Start | Inc.End : Inc.None
    }

    get inclusiveStart() {
      return (this.inc & Inc.Start) > 0
    }
    get inclusiveEnd() {
      return (this.inc & Inc.End) > 0
    }

    abstract eq(other: RangeSet.Value): boolean

    /**
     * Create a range decoration that wraps nodes in a range with
     * an element, using the given tag name.
     */
    static wrapper(tagName: string, spec: Decoration.Range.WrapperSpec): Range {
      return new WrapperRangeDecoration(tagName, spec)
    }

    /**
     * Create a range decoration that adds an attribute to nodes in a
     * range.
     */
    static attribute(attr: string, value: string, options: Decoration.Range.Spec = {}): Range {
      return new AttributeRangeDecoration(attr, value, options)
    }

    /**
     * The facet used to register range decoration sources. The
     * source function will be called on every update. Generating big
     * range sets on the fly will not perform well, so you'll often
     * want to store these in a state field.
     */
    static source = GardState.Facet.define<(state: GardState) => Range.Set>()

    /**
     * Create a {@link RangeSet} from an array or source function of
     * range decorations.
     */
    static set(source: Set.Source<Range>): Range.Set {
      return RangeSet.create<Range>(source)
    }

    /** The empty set of range decorations. */
    static none: Range.Set = RangeSet.empty
  }

  export namespace Range {
    /** Configuration object for range decorations. */
    export interface Spec {
      /**
       * Determines whether content inserted next to the range is
       * included when mapping the range through a change. Defaults
       * to false.
       */
      inclusive?: boolean | 'start' | 'end'
      /** If given, apply this decoration only to matching nodes. */
      query?: Node.Query
      /**
       * The type of nodes in the range to apply the decoration to.
       * Defaults to `"atom"`.
       */
      scope?: 'atom' | 'inlineatom' | 'all'
    }

    /** Configuration object for wrapper range decorations. */
    export interface WrapperSpec extends Decoration.Range.Spec {
      /** Attributes to add to the wrapper element. */
      attributes?: Record<string, string>
      /**
       * A wrapper's rank determines the nesting order between it and
       * other wrappers created by range decorations or marks. Should be
       * a number between 0 and 100, if given.
       */
      rank?: number
      /**
       * Whether this wrapper may span multiple sibling nodes.
       * Non-spanning wrappers will be created separately for each
       * node. Defaults to true.
       */
      spanning?: boolean
    }

    /** The type used for sets of point decorations. */
    export type Set = RangeSet<Range>
  }
}

type TagShape = { type: Node.Type; shape: (tag: Node.Tag) => Decoration.Shape }

const tagShape = GardState.Facet.define<TagShape, Map<Node.Type, (tag: Node.Tag) => Decoration.Shape>>({
  combine: shapes => new Map(shapes.map(s => [s.type, s.shape] as const).reverse())
})

type TagWrapper = { type: Node.Type; elt: DecoElt; target: Elt.Selector | null }

const tagWrapper = GardState.Facet.define<TagWrapper>()

enum WidgetPlace {
  Before,
  After,
  Start,
  End
}

type TagWidget = { type: Node.Type; place: WidgetPlace; widget: Widget | ((tag: Node.Tag) => Widget) }

const tagWidget = GardState.Facet.define<TagWidget>()

type TagAttribute = {
  type: Node.Type
  attr: string
  value: (tag: Node.Tag) => string
  target: Elt.Selector | null
}

const tagAttribute = GardState.Facet.define<TagAttribute>()

type MarkShape = {
  type: Mark.Type
  modified: Mark.Type
}

const markShape = GardState.Facet.define<MarkShape, Map<Mark.Type, Mark.Type>>({
  combine: shapes => new Map(shapes.map(s => [s.type, s.modified] as const).reverse())
})

function memo<T, A extends object>(f: (arg: A) => T) {
  const map = new WeakMap<A, T>()
  return (arg: A) => {
    let found = map.get(arg)
    if (found === undefined) map.set(arg, (found = f(arg)))
    return found
  }
}

function addMarkAttributes(overrides: Map<Mark.Type, Mark.Type>, shape: Decoration.Shape, tag: Node.Tag) {
  let attrs: readonly string[] | undefined
  for (const mark of tag.marks) {
    const type = overrides.get(mark.type) || mark.type
    if (type.attribute && (mark.spanning || !tag.isText)) {
      const { get, target } = type.attribute
      const markAttrs = get(mark.value)
      if (markAttrs.length) {
        if (target && shape instanceof Elt) shape = shape.addAttrs(markAttrs, target)
        else attrs = attrs ? Attributes.merge(attrs, markAttrs) : markAttrs
      }
    }
  }
  return attrs ? addAttrs(shape, attrs, tag.type.isInline) : shape
}

function addAttrs(shape: Decoration.Shape, attrs: Attributes, inline: boolean) {
  return shape instanceof Elt ? shape.addAttrs(attrs) : Elt.create(inline ? 'span' : 'div', attrs, [shape])
}

function applyDeco(shape: Decoration.Shape, deco: Decoration.Point, tag: Node.Tag) {
  if (deco instanceof AttributeDecoration) {
    return deco.selector && shape instanceof Elt
      ? shape.addAttrs(deco.attrs, deco.selector)
      : addAttrs(shape, deco.attrs, tag.type.isInline)
  } else if (deco instanceof WrapperDecoration) {
    return deco.selector && shape instanceof Elt ? shape.wrap(deco.elt, deco.selector) : deco.elt.fill([shape])
  }
  return shape
}

const baseTagShape = memo((tag: Node.Tag): Decoration.Shape => {
  return tag.is(Leaf.Text) ? Widget.editableText.of(tag.param as string) : tag.type.shape.create(tag.param)
})

export function renderMarks(state: GardState, marks: Mark.Set, around: string) {
  const markShapes = state.facet(markShape)
  let result = addMarkAttributes(markShapes, Elt.create('span', Attributes.none, [around]), Leaf.text(around, marks))
  for (let i = marks.length - 1; i >= 0; i--) {
    let mark = marks[i]!
    const shape = markShapes.get(mark.type)
    if (shape) mark = shape.of(mark.value)
    if (mark.type.element) result = renderMarkWrapper(mark).fill([result])
  }
  return (result as Elt<string>).toDOM()
}

enum DecorationScope {
  Atom = 1,
  InlineAtom = 2,
  All = 4
}

enum Inc {
  None = 0,
  Start = 1,
  End = 2
}

class AttributeRangeDecoration extends Decoration.Range {
  constructor(
    readonly attribute: string,
    readonly value: string,
    options: Decoration.Range.Spec
  ) {
    super(options)
  }

  eq(other: RangeSet.Value): boolean {
    return (
      this == other ||
      (other instanceof AttributeRangeDecoration &&
        other.attribute == this.attribute &&
        other.value == this.value &&
        other.inc == this.inc)
    )
  }
}

class WrapperRangeDecoration extends Decoration.Range {
  readonly elt: Elt
  readonly rank: number
  readonly spanning: boolean

  constructor(element: string, spec: Decoration.Range.WrapperSpec) {
    super(spec)
    const { attributes } = spec
    this.rank = Math.max(0, Math.min(spec.rank ?? 100))
    this.spanning = spec.spanning !== false
    this.elt = Elt.create(element, attributes ? Attributes.read(attributes) : Attributes.none, Elt.hole)
  }

  eq(other: RangeSet.Value): boolean {
    return (
      this == other ||
      (other instanceof WrapperRangeDecoration &&
        other.elt.eq(this.elt) &&
        other.rank == this.rank &&
        other.spanning == this.spanning &&
        other.inc == this.inc)
    )
  }
}

enum Side {
  After = 1e9
}

class ShapeDecoration extends Decoration.Point {
  constructor(readonly shape: Decoration.Shape) {
    super()
  }

  eq(other: PointSet.Value): boolean {
    return this == other || (other instanceof ShapeDecoration && other.shape.eq(this.shape))
  }

  get trackMode() {
    return 'after' as const
  }
  get side() {
    return Side.After
  }
}

class WidgetDecoration extends Decoration.Point {
  constructor(
    readonly widget: Widget,
    readonly side: number,
    readonly trackMode: ChangeSet.TrackMode | undefined
  ) {
    super()
    if (side >= Side.After) throw new Error('Invalid widget side')
  }

  eq(other: PointSet.Value): boolean {
    return (
      this == other ||
      (other instanceof WidgetDecoration &&
        other.widget.eq(this.widget) &&
        other.side == this.side &&
        other.trackMode == this.trackMode)
    )
  }
}

function selectorEq(a: Elt.Selector | null, b: Elt.Selector | null) {
  return a ? !!b && a.eq(b) : !b
}

class AttributeDecoration extends Decoration.Point {
  constructor(
    readonly attrs: Attributes,
    readonly selector: Elt.Selector | null
  ) {
    super()
  }

  eq(other: PointSet.Value): boolean {
    return (
      this == other ||
      (other instanceof AttributeDecoration &&
        Attributes.eq(other.attrs, this.attrs) &&
        selectorEq(other.selector, this.selector))
    )
  }

  get trackMode() {
    return 'after' as const
  }
  get side() {
    return Side.After
  }
}

class WrapperDecoration extends Decoration.Point {
  constructor(
    readonly elt: DecoElt,
    readonly selector: Elt.Selector | null
  ) {
    super()
  }

  eq(other: PointSet.Value): boolean {
    return (
      this == other ||
      (other instanceof WrapperDecoration && other.elt.eq(this.elt) && selectorEq(other.selector, this.selector))
    )
  }

  get trackMode() {
    return 'after' as const
  }
  get side() {
    return Side.After
  }
}

const nodeSelectionDeco = Decoration.Point.attributes({ class: 'wg-selected-node' })

function nodeSelection(state: GardState) {
  if (state.selection instanceof GardSelection.Node) return PointSet.create([[nodeSelectionDeco, state.selection.from]])
  return PointSet.empty
}

const none: readonly any[] = []

export type DecoSet = {
  points: Map<(state: GardState) => Decoration.Point.Set, Decoration.Point.Set>
  ranges: Map<(state: GardState) => Decoration.Range.Set, Decoration.Range.Set>
}

export function getDecoSet(state: GardState) {
  const set: DecoSet = { points: new Map(), ranges: new Map() }
  for (const src of state.facet(Decoration.Point.source)) set.points.set(src, src(state))
  for (const src of state.facet(Decoration.Range.source)) set.ranges.set(src, src(state))
  return set
}

function compareDecoSet<T>(
  setA: Map<(state: GardState) => T, T>,
  setB: Map<(state: GardState) => T, T>,
  cmp: (a: T | null, b: T | null) => void
) {
  for (const [srcA, valA] of setA) cmp(valA, setB.get(srcA) || null)
  for (const [srcB, valB] of setB) if (!setA.has(srcB)) cmp(null, valB)
}

const globalDecoFacets: readonly GardState.Facet<any, any>[] = [
  tagShape,
  tagWidget,
  tagWrapper,
  tagAttribute,
  markShape
]

// Compare ranges and points in decoration facets for unchanged ranges
// in the given change desc. Returns an array using the section format
// used in change descs.
export function findChangedRanges(
  prevState: GardState,
  prevDeco: DecoSet,
  state: GardState,
  deco: DecoSet,
  sections: ChangeSet.Sections
): Changes {
  const result: number[] = []
  const globalChange = globalDecoFacets.some(facet => prevState.facet(facet) !== state.facet(facet))
  // When node shapes change, we need a separate pass to see whether
  // their atomicity changed, and mark a replace for the whole node if
  // it did.
  const shapeChanges: number[] = []
  for (let i = 0, posA = 0, posB = 0; i < sections.length;) {
    const len = sections[i++]!,
      ins = sections[i++]!
    if (ins == -1 && globalChange) {
      addSection(result, len, -2)
    } else if (ins == -1) {
      const endB = posB + len
      // Unchanged section. See which parts have potentially updated
      // decorations, and tag those as changed
      let cur: number[] = []
      let curPos = 0
      const ranges: number[][] = [cur]
      const add = (from: number, to: number) => {
        if (from < curPos) {
          ranges.push((cur = []))
          curPos = 0
        }
        addRange(cur, from, to)
        curPos = to
      }
      compareDecoSet(prevDeco.ranges, deco.ranges, (a, b) => {
        ;(a || RangeSet.empty).compareRange(posA, b || RangeSet.empty, posB, len, add)
      })
      compareDecoSet(prevDeco.points, deco.points, (a, b) => {
        ;(a || PointSet.empty).compareRange(posA, b || PointSet.empty, posB, len, (pos, val) => {
          add(pos, Math.min(pos + (val instanceof WidgetDecoration ? 0 : 1), endB))
          if (val instanceof ShapeDecoration && !globalChange) {
            const idx = findAbove(shapeChanges, 0, pos - 1)
            if (idx == shapeChanges.length || shapeChanges[idx] != pos) shapeChanges.splice(idx, 0, pos)
          }
        })
      })
      const joined = joinRanges(ranges)
      let pos = posB
      const end = pos + len
      let j = 0
      // Skip empty update if not after a preserved section.
      if (
        joined!.length &&
        joined![0] == pos &&
        joined![1] == pos &&
        result.length &&
        result[result.length - 1] != -1
      ) {
        j = 2
      }
      for (; j < joined!.length;) {
        const from = Math.max(pos, joined![j++]!),
          to = Math.min(end, joined![j++]!)
        if (from > pos) addSection(result, from - pos, -1)
        if (from <= to) addSection(result, to - from, -2)
        pos = to
      }
      if (pos < end) addSection(result, end - pos, -1)
      posA += len
      posB = endB
    } else {
      posA += len
      posB += (ins < 0 ? len : ins)!
      if (ins >= 0 && result.length && result[result.length - 2] == 0 && result[result.length - 1] == -2) {
        result.pop()
        result.pop()
      }
      addSection(result, len, ins)
    }
  }
  if (shapeChanges.length) return addAtomicityChanges(result, prevState, shapeChanges)
  return result
}

function addAtomicityChanges(changes: Changes, prev: GardState, nodes: number[]): Changes {
  const added: number[] = []
  let scan = prev.doc.resolve(0),
    sectionPos = 0,
    sectionI = 0,
    off = 0
  for (const posB of nodes) {
    while (posB >= sectionPos) {
      const len = changes[sectionI++]!,
        ins = changes[sectionI++]!
      if (ins < 0) {
        sectionPos += len
      } else {
        sectionPos += ins
        off += len - ins
      }
    }
    const posA = posB - off
    if (scan.pos < posA) scan = scan.advance(posA - scan.pos)
    const node = scan.nodeAfter
    if (!node) continue
    added.push(posA, posA + node.length)
  }
  return added.length ? addUpdated(changes, added) : changes
}

export interface DecoWalker {
  enter(node: Plot, shape: DecoElt, wrappers: readonly WrapperSource[]): void
  leave(): void
  node(node: Node, shape: Decoration.Shape, wrappers: readonly WrapperSource[], partial: number | undefined): void
  nodePart(node: Node, length: number, done: boolean): void
  widget(widget: Widget, side: number): void
}

class SpanIterator<R extends RangeSet.Value, P extends PointSet.Value> {
  active: R[] = []
  activeEnd: number[] = []
  from: number
  to: number
  point: P | null = null
  pointSource: PointSet<P> | null = null
  done = false

  constructor(
    readonly ranges: Set.Cursor<R>,
    readonly points: Set.Cursor<P>,
    start: number,
    readonly end: number
  ) {
    this.from = this.to = start
  }

  next() {
    if (this.done) return this
    if (this.point) this.point = null
    const { ranges, points, active, activeEnd } = this
    while (true) {
      const [startPos, startSide] = ranges.value ? [ranges.from, ranges.value.inclusiveStart ? -1 : 1] : [1e9, 0]
      let endPos = 1e9,
        endSide = 0,
        nextActive = -1
      for (let i = 0; i < active.length; i++) {
        const pos = activeEnd[i]!,
          side = active[i]!.inclusiveEnd ? 1 : -1
        if ((pos - endPos || side - endSide) < 0) {
          endPos = pos!
          endSide = side
          nextActive = i
        }
      }
      const [pointPos, pointSide] = points.value ? [points.from, points.value.side] : [1e9, 1]
      const nextPos = Math.min(startPos, endPos, pointPos)
      if (this.to == this.end && nextPos > this.to) {
        this.done = true
        break
      } else if (nextPos > this.to) {
        this.from = this.to
        this.to = Math.min(this.end, nextPos)
        break
      } else if (
        pointPos == nextPos &&
        (startPos > pointPos || pointSide < 0) &&
        (endPos > pointPos || pointSide < 0)
      ) {
        this.point = this.points.value!
        this.pointSource = this.points.set
        this.from = this.to = this.points.from
        this.points.next()
        break
      } else if ((startPos - endPos || startSide - endSide) < 0) {
        active.push(this.ranges.value!)
        activeEnd.push(this.ranges.to)
        this.ranges.next()
      } else {
        active.splice(nextActive, 1)
        activeEnd.splice(nextActive, 1)
      }
    }
    return this
  }
}

export type WrapperSource = Mark<any> | WrapperRangeDecoration

function tagScope(tag: Node.Tag, atom: boolean): DecorationScope {
  return DecorationScope.All | (atom ? DecorationScope.Atom | (tag.type.isInline ? DecorationScope.InlineAtom : 0) : 0)
}

export function renderWrapper(src: WrapperSource): DecoElt {
  if (src instanceof WrapperRangeDecoration) return src.elt
  return renderMarkWrapper(src)
}

export const renderMarkWrapper = memo((mark: Mark<any>): DecoElt => {
  const shape = mark.type.element!
  return Elt.create(shape.name, shape.attrs(mark.value), Elt.hole)
})

export class DecoIterator {
  tagShapes: Map<Node.Type, (tag: Node.Tag) => Decoration.Shape>
  globalWidgets: readonly TagWidget[]
  globalWrappers: readonly TagWrapper[]
  globalAttrs: readonly TagAttribute[]
  markShapes: Map<Mark.Type, Mark.Type>
  schema: Schema
  pos: Pos
  rangeCursor: Set.Cursor<Decoration.Range>
  pointSets: readonly Decoration.Point.Set[]
  pointCursor: Set.Cursor<Decoration.Point>
  endWidgets: boolean

  constructor(
    readonly state: GardState,
    readonly decoSet: DecoSet
  ) {
    this.tagShapes = state.facet(tagShape)
    this.globalWidgets = state.facet(tagWidget)
    this.endWidgets = this.globalWidgets.some(
      w => (w.place == WidgetPlace.After || w.place == WidgetPlace.End) && typeof w.widget == 'function'
    )
    this.globalWrappers = state.facet(tagWrapper)
    this.globalAttrs = state.facet(tagAttribute)
    this.markShapes = state.facet(markShape)
    this.pos = state.doc.resolve(0)
    this.schema = state.schema
    this.rangeCursor = RangeSet.cursor(state.facet(Decoration.Range.source).map(s => s(state)))
    this.pointSets = state.facet(Decoration.Point.source).map(s => s(state))
    this.pointCursor = PointSet.cursor(this.pointSets)
  }

  widgets(tag: Node.Tag, place: WidgetPlace, walker: DecoWalker) {
    if (place == WidgetPlace.Start && tag.type.isInline) walker.widget(Widget.img, -1)
    for (const src of this.globalWidgets) {
      if (src.place == place && tag.type == src.type) {
        const widget = typeof src.widget == 'function' ? src.widget(tag) : src.widget
        if (widget) walker.widget(widget, place == WidgetPlace.Before || place == WidgetPlace.End ? 1 : -1)
      }
    }
    if (place == WidgetPlace.End && tag.type.isInline) walker.widget(Widget.img, 1)
  }

  hasEndWidget(type: Node.Type) {
    return this.globalWidgets.some(
      tw =>
        tw.type == type &&
        (tw.place == WidgetPlace.End || tw.place == WidgetPlace.After) &&
        typeof tw.widget == 'function'
    )
  }

  // Enumerate all wrapper elements for a given node. Spanning wrappers
  // are always moved to the front of the result. Within the
  // spanning/non-spanning wrappers, the ordering is determined by rank.
  //
  // Note that the return value contains range iterators, and those will
  // become invalid as soon as they are advanced further.
  nodeWrappers(tag: Node.Tag, active: readonly Decoration.Range[], atom: boolean): readonly WrapperSource[] {
    let wrappers: WrapperSource[] | undefined

    for (const mark of tag.marks) {
      const shape = this.markShapes.get(mark.type) || mark.type
      if (shape.element) (wrappers || (wrappers = [])).push(shape == mark.type ? mark : shape.of(mark.value))
    }
    if (active.length) {
      for (const val of active) {
        if (
          val instanceof WrapperRangeDecoration &&
          tagScope(tag, atom) & val.scope &&
          (!val.query || this.schema.matchNode(tag.type, val.query))
        ) {
          ;(wrappers || (wrappers = [])).push(val)
        }
      }
    }

    if (!wrappers) return none
    if (wrappers.length > 1) {
      wrappers.sort((a, b) => (a.spanning == b.spanning ? 0 : a.spanning ? -1 : 1) || a.rank - b.rank)
    }
    return wrappers
  }

  walk(from: number, inclusiveStart: boolean, to: number, walker: DecoWalker) {
    this.rangeCursor.goto(from)
    this.pointCursor.goto(from, inclusiveStart ? -1e9 : Side.After)
    const iter = new SpanIterator<Decoration.Range, Decoration.Point>(this.rangeCursor, this.pointCursor, from, to)
    let pos = this.pos.advance(from - this.pos.pos),
      started = inclusiveStart
    let atomParent: Pos.Plot | undefined
    for (let p: Pos.Plot | null = pos.parent; p; p = p.parent) if (this.state.isAtom(p.node.type)) atomParent = p

    // Track points that may apply to the node at the start of the next range
    const pendingDeco: Decoration.Point[] = []
    let pendingPos = -1
    let pendingShape: ShapeDecoration | null = null,
      pendingShapeSet: Decoration.Point.Set | null = null

    const wrap: Pos.Walker = {
      skip: (node, pos) => {
        // Only done for leaf nodes.
        if (started) this.widgets(node.tag, WidgetPlace.Before, walker)
        else started = true
        const hasPending = pendingPos == pos && !node.isText
        let shape = hasPending && pendingShape ? pendingShape.shape : this.tagShape(node.tag, iter.active)
        if (hasPending) for (const deco of pendingDeco) shape = applyDeco(shape, deco, node.tag)
        if (shape.hasContent) throw new Error("Leaf nodes shapes shouldn't have a content hole")
        walker.node(node, shape, this.nodeWrappers(node.tag, iter.active, true), undefined)
        this.widgets(node.tag, WidgetPlace.After, walker)
      },
      enterPlot: (node, pos) => {
        if (started) this.widgets(node.tag, WidgetPlace.Before, walker)
        else started = true
        let shape = pendingShape && pendingPos == pos ? pendingShape.shape : this.tagShape(node.tag, iter.active)
        if (pendingPos == pos) for (const deco of pendingDeco) shape = applyDeco(shape, deco, node.tag)
        const wrappers = this.nodeWrappers(node.tag, iter.active, !shape.hasContent)
        const atom = !shape.hasContent
        if (atom) walker.node(node!, shape, wrappers, pos + node.length > to ? to - pos : undefined)
        else walker.enter(node!, shape as DecoElt, wrappers)
        this.widgets(node.tag, WidgetPlace.Start, walker)
        return !atom
      },
      leavePlot: tag => {
        if (started) this.widgets(tag, WidgetPlace.End, walker)
        else started = true
        walker.leave()
        this.widgets(tag, WidgetPlace.After, walker)
      }
    }

    if (inclusiveStart) {
      const before = pos.nodeBefore
      if (before) this.widgets(before.tag, WidgetPlace.After, walker)
      else this.widgets(pos.parent.node.tag, WidgetPlace.Start, walker)
    }

    for (; !iter.next().done;) {
      if (atomParent) {
        const end = Math.min(to, atomParent.after),
          done = atomParent.after <= to
        walker.nodePart(atomParent.node, end - pos.pos, done)
        pos = pos.advance(end - pos.pos)
        if (done) this.widgets(atomParent.node.tag, WidgetPlace.After, walker)
        atomParent = undefined
        while (iter.point && iter.from < end) iter.next()
      } else if (iter.point) {
        const value = iter.point
        if (value instanceof WidgetDecoration) {
          walker.widget(value.widget, value.side)
        } else {
          if (pendingPos < pos.pos) {
            pendingDeco.length = 0
            pendingShape = null
            pendingPos = pos.pos
          }
          if (
            value instanceof ShapeDecoration &&
            (!pendingShape || compareSetPrec(pendingShapeSet!, iter.pointSource!, this.pointSets))
          ) {
            pendingShape = value
            pendingShapeSet = iter.pointSource
          } else {
            pendingDeco.push(value)
          }
        }
      } else {
        pos = pos.walk(iter.to - iter.from, wrap)
      }
    }
    if (pos.pos < to) pos = pos.walk(to - pos.pos, wrap)

    if (atomParent) {
      walker.nodePart(atomParent.node, 0, atomParent.after == to)
    } else {
      const after = pos.nodeAfter
      if (after) this.widgets(after!.tag, WidgetPlace.Before, walker)
      else this.widgets(pos.parent.node.tag, WidgetPlace.End, walker)
    }
    this.pos = pos
  }

  tagShape(tag: Node.Tag, active: Decoration.Range[]) {
    const override = this.tagShapes.get(tag.type)
    let shape = override ? override(tag) : baseTagShape(tag)
    if (tag.marks.length) shape = addMarkAttributes(this.markShapes, shape, tag)
    let add: string[] | undefined
    for (const src of this.globalAttrs) {
      if (tag.type == src.type) {
        if (src.target && shape instanceof Elt) shape = shape.addAttrs([src.attr, src.value(tag)], src.target)
        else Attributes.push(add || (add = []), src.attr, src.value(tag))
      }
    }
    const scope = tagScope(tag, !shape.hasContent)
    for (const { type, elt, target } of this.globalWrappers) {
      if (tag.type == type) {
        shape = target && shape instanceof Elt ? shape.wrap(elt, target) : elt.fill([shape])
      }
    }
    for (const deco of active) {
      if (
        deco instanceof AttributeRangeDecoration &&
        scope & deco.scope &&
        (!deco.query || this.schema.matchNode(tag.type, deco.query))
      ) {
        Attributes.push(add || (add = []), deco.attribute, deco.value)
      }
    }
    if (add) {
      if (shape instanceof Elt) shape = Elt.create(shape.tagName, Attributes.merge(shape.attrs, add), shape.children)
      else shape = Elt.create(tag.type.isBlock ? 'div' : 'span', add, [shape])
    }
    return shape
  }
}

function compareSetPrec(
  setA: Decoration.Point.Set,
  setB: Decoration.Point.Set,
  array: readonly Decoration.Point.Set[]
) {
  if (setA != setB) {
    for (const set of array) {
      if (set == setA) return -1
      if (set == setB) return 1
    }
  }
  return 0
}
