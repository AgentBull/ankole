import { Schema, Plot, Node, Pos, parse, SchemaError, ValidationError } from '../doc'
import { SelectionType, GardSelection, wordAt, cursorAtStart } from './selection'
import { Transaction, resolveTransaction, asArray } from './transaction'
import { TextblockMap } from './textblock'

let nextID = 0

const none: readonly any[] = []

function readHTML(html: string): HTMLElement {
  if (typeof document != 'object' || !document.implementation) {
    throw new Error('Trying to parse an HTML string in a non-browser context.')
  }
  const detachedDoc = document.implementation.createHTMLDocument('title')
  const trustedTypes = (window as any).trustedTypes
  if (trustedTypes) {
    // With the require-trusted-types-for CSP, Chrome will block
    // innerHTML, even on a detached document. This wraps the string in
    // a way that makes the browser allow us to use its parser again.
    html = trustedTypes.createPolicy('detachedDocument', { createHTML: (s: string) => s }).createHTML(html)
  }
  const elt = detachedDoc.createElement('div')
  elt.innerHTML = html
  return elt
}

function readDoc(schema: Schema, doc?: DocSource): Plot.Doc {
  if (!doc) {
    return schema.doc(
      schema.docTag.type.canBeEmpty ? [] : [schema.createAndFill(schema.defaultContentTag(schema.docTag.type)!)]
    )
  }
  if (doc instanceof Plot.Doc) return doc.schema == schema ? doc : schema.doc(doc.content)
  if (typeof doc == 'function') return doc(schema)
  if (typeof doc == 'string') doc = readHTML(doc)
  const { nodeType } = doc as any
  if (nodeType === 1 || nodeType === 11) return parse(schema, doc as HTMLElement | DocumentFragment)
  return schema.docFromJSON(doc as Node.JSON)
}

type DocSource = Plot.Doc | HTMLElement | DocumentFragment | string | Node.JSON | ((schema: Schema) => Plot.Doc)

/**
 * The editor state tracks things like the current document, the
 * selection, the configuration of the editor, and any extra state
 * defined by extensions.
 *
 * The state is a persistent (immutable) data structure. To update a
 * state, you {@link GardState.update create} a {@link Transaction
 * transaction}, which produces a _new_ state instance, without
 * modifying the original object.
 */
export class GardState {
  /** @internal */
  readonly status: SlotStatus[]
  /** @internal */
  computeSlot: null | ((state: GardState, slot: DynamicSlot) => SlotStatus)
  private resolvedSel: GardSelection.Resolved | null = null
  private trackAccess: Slot[] | null = null

  /**
   * Create a new state. You'll usually only need this when
   * initializing an editor or loading a new document—updated states
   * are created by applying transactions.
   *
   * The schema of the state can be provided either via the {@link
   * GardState.schemaElement configuration} or by passing in an
   * initialized document (which will have its own schema). If the
   * configuration contains a document plot type, the schema from the
   * configuration will be used, even if a document was provided.
   */
  static create(spec: GardState.Spec): GardState {
    const config =
      spec.config instanceof GardState.Configuration
        ? spec.config
        : GardState.Configuration.resolve(spec.config || [], new Map())
    let schema = config.schema
    if (!schema) {
      if (spec.doc instanceof Plot.Doc) schema = spec.doc.schema
      else throw new SchemaError(`No document plot provided, unable to create schema`)
    }
    const doc = readDoc(schema, spec.doc)
    const selection = !spec.selection
      ? cursorAtStart({ doc, config })
      : typeof spec.selection == 'function'
        ? spec.selection({ doc, config })
        : spec.selection instanceof GardSelection
          ? spec.selection
          : GardSelection.Text.create(spec.selection)
    return GardState.fromConfig(config, doc, selection)
  }

  private constructor(
    /** The configuration for this state. */
    readonly config: GardState.Configuration,
    private _doc: Plot.Doc,
    private _selection: GardSelection,
    /** @internal */
    readonly values: any[],
    computeSlot: (state: GardState, slot: DynamicSlot) => SlotStatus,
    tr: Transaction | null
  ) {
    this.status = config.statusTemplate.slice()
    this.computeSlot = computeSlot
    // Fill in the computed state immediately, so that further queries
    // for it made during the update return this state
    if (tr) tr._state = this
    for (let i = 0; i < this.config.dynamicSlots.length; i++) ensureAddr(this, i << 1)
    this.computeSlot = null
  }

  /** The current document. */
  get doc() {
    if (this.trackAccess) addValue(this.trackAccess, 'doc')
    return this._doc
  }

  /** The document's schema. */
  get schema() {
    if (this.trackAccess) addValue(this.trackAccess, 'schema')
    return this._doc.schema
  }

  /** The current selection. */
  get selection() {
    if (this.trackAccess) addValue(this.trackAccess, 'selection')
    return this._selection
  }

  /**
   * A resolved form of the state's selection. Instead of raw
   * positions, this object holds {@link Pos document position}
   * objects for `head`, `anchor`, `from`, and `to`.
   */
  get sel() {
    return this.resolvedSel || (this.resolvedSel = this.selection.resolve(this.doc))
  }

  /**
   * Retrieve the value of a {@link GardState.Field state field} or
   * {@link GardState.Field.Derived derived field}. Throws an error
   * when the state doesn't have that field, unless you pass `false`
   * as second parameter, in which case you'll get `undefined` for a
   * regular field, or the value will be eagerly computed for a
   * derived field.
   */
  field<T>(field: GardState.Field<T> | GardState.Field.Derived<T>): T
  field<T>(field: GardState.Field<T>, require: false): T | undefined
  field<T>(field: GardState.Field.Derived<T>, require: false): T
  field<T>(field: GardState.Field<T> | GardState.Field.Derived<T>, require: boolean = true): T | undefined {
    const addr = this.config.address[field.id]
    if (addr == null) {
      if (require) throw new RangeError('Field is not present in this state')
      return field instanceof GardState.Field ? undefined : field.value(this)
    }
    let track = this.trackAccess
    if (track) {
      addValue(track, field)
      track = null
    }
    ensureAddr(this, addr)
    if (track) this.trackAccess = track
    return getAddr(this, addr)
  }

  /** Get the value of a state {@link GardState.Facet facet}. */
  facet<Output>(facet: GardState.Facet.Reader<Output>): Output {
    if (this.trackAccess) addValue(this.trackAccess, facet)
    const addr = this.config.address[facet.id]
    if (addr == null) return facet.default
    ensureAddr(this, addr)
    return getAddr(this, addr)
  }

  /**
   * Create a {@link Transaction transaction} that updates this
   * state.
   */
  update(spec: Transaction.Spec): Transaction {
    return resolveTransaction(this, spec)
  }

  /** @internal */
  applyTransaction(tr: Transaction) {
    let conf: GardState.Configuration | null = this.config,
      { base, compartments } = conf
    for (const effect of tr.effects) {
      if (effect.is(GardState.Compartment.reconfigureCompartment)) {
        if (conf) {
          compartments = new Map()
          conf.compartments.forEach((val, key) => compartments!.set(key, val))
          conf = null
        }
        compartments.set(effect.value.compartment, effect.value.extension)
      } else if (effect.is(GardState.reconfigure)) {
        conf = null
        base = effect.value
      } else if (effect.is(GardState.appendConfig)) {
        conf = null
        base = asArray(base).concat(effect.value)
      }
    }
    let startValues,
      doc = tr.newDoc
    if (!conf) {
      conf = GardState.Configuration.resolve(base, compartments, this)
      const intermediateState = new GardState(
        conf,
        this.doc,
        this.selection,
        conf.dynamicSlots.map(() => null),
        (state, slot) => slot.reconfigure(state, this),
        null
      )
      startValues = intermediateState.values
      if (conf.staticFacet(GardState.schemaElement) != this.facet(GardState.schemaElement)) {
        const schema = conf.schema
        if (schema) doc = schema.doc(doc.content)
      }
    } else {
      startValues = tr.startState.values.slice()
    }
    new GardState(conf, doc, tr.newSelection, startValues, (state, slot) => slot.update(state, tr), tr)
  }

  /** @internal */
  recordAccess<T>(slots: Slot[] | null, f: (state: GardState) => T): T {
    const prev = this.trackAccess
    this.trackAccess = slots
    const result = f(this)
    this.trackAccess = prev
    return result
  }

  /**
   * Compute the textblock map for the given plot (which should be a
   * textblock).
   */
  textblockMap(node: Pos.Plot) {
    return TextblockMap.get(this, node.start, node.node)
  }

  /**
   * Convert this state to a JSON-serializable object. When custom
   * fields should be serialized, you can pass them in as an object
   * mapping property names (in the resulting object, which should
   * not use `doc` or `selection`) to fields.
   */
  toJSON(fields?: { [prop: string]: GardState.Field<any> }): any {
    const result: any = {
      doc: this.doc.toJSON(),
      selection: this.selection.toJSON(this)
    }
    if (fields) {
      for (const prop in fields) {
        const value = fields[prop]
        if (value instanceof GardState.Field && this.config.address[value.id] != null) {
          result[prop] = value.spec.toJSON!(this.field(fields[prop]!), this)
        }
      }
    }
    return result
  }

  /**
   * Deserialize a state from its JSON representation. When custom
   * fields should be deserialized, pass the same object you passed
   * to {@link GardState.toJSON `toJSON`} when serializing as third
   * argument.
   */
  static fromJSON(
    json: any,
    extensions: GardState.Extension,
    fields?: { [prop: string]: GardState.Field<any> }
  ): GardState {
    if (!json) throw new ValidationError('Invalid JSON representation for GardState')
    const fieldInit = []
    if (fields) {
      for (const prop in fields) {
        if (Object.prototype.hasOwnProperty.call(json, prop)) {
          const field = fields[prop]!,
            value = json[prop]
          fieldInit.push(field.init(state => field.spec.fromJSON!(value, state)))
        }
      }
    }
    const config = GardState.Configuration.create([extensions, fieldInit])
    const schema = config.schema
    if (!schema) throw new SchemaError('No document plot provided to GardState.fromJSON')
    const doc = schema.docFromJSON(json.doc)
    return GardState.fromConfig(config, doc, GardSelection.fromJSON({ config, doc }, json.selection))
  }

  /** @internal */
  static fromConfig(config: GardState.Configuration, doc: Plot.Doc, selection: GardSelection) {
    selection.check(config, doc)
    return new GardState(
      config,
      doc,
      selection,
      config.dynamicSlots.map(() => null),
      (state, slot) => slot.create(state),
      null
    )
  }

  /**
   * Returns true when the editor is {@link GardState.readOnly} to be
   * read-only.
   */
  get readOnly() {
    return this.facet(GardState.readOnly)
  }

  /**
   * Get the global text direction (true when left-to-right, false
   * when right-to-left) for the document. Note that the direction of
   * individual blocks can be overridden with {@link
   * GardState.textblockLTR}.
   */
  get textLTR() {
    return this.config.textLTR
  }

  /** Return the text direction in a given textblock (by tag). */
  textblockLTR(plot: Plot) {
    return this.config.textblockLTR(plot)
  }

  /**
   * Tells you whether a node type is an atom (a leaf or a plot with
   * an atomic shape).
   */
  isAtom(type: Node.Type) {
    return this.config.isAtom(type)
  }

  /**
   * Return the extent of the word around the given position, as a
   * text selection.
   */
  wordAt(pos: number, bias: -1 | 1 = 1) {
    return wordAt(this, pos, bias)
  }

  /**
   * This effect can be used to reconfigure the root extensions of
   * the editor. Doing this will discard any extensions {@link
   * GardState.appendConfig appended}, but does not reset the
   * content of {@link GardState.Compartment.reconfigure
   * reconfigured} compartments.
   */
  static reconfigure = Transaction.Effect.define<GardState.Extension>()

  /** Append extensions to the top-level configuration of the editor. */
  static appendConfig = Transaction.Effect.define<GardState.Extension>()
}

enum Prec {
  Lowest = 4,
  Low = 3,
  Default = 2,
  High = 1,
  Highest = 0
}

export namespace GardState {
  /**
   * Options passed when {@link GardState.create creating} an editor
   * state.
   */
  export interface Spec {
    /**
     * The initial document. When passing in a {@link Plot.Doc
     * document node} here, it is not necessary to include a schema
     * in your configuration (though it is allowed, and the document
     * content will be moved into that schema if it differs from the
     * one on the given document).
     *
     * All other forms require a schema from the configuration. A
     * string or DOM structure will be parsed as HTML. Passing a
     * string only works in the browser, where the library can use
     * the browser's HTML parser. In other environments, you'll need
     * to do the parsing yourself (for example with
     * [jsdom](https://jsdom.org/)). A JSON node deserialized, and a
     * function called to produce the document.
     */
    doc?: DocSource
    /**
     * The starting selection. Defaults to a cursor at the start of the
     * document.
     */
    selection?: GardSelection | GardSelection.Text.Spec | ((cx: GardSelection.Context) => GardSelection)
    /**
     * The configuration for this state, either as a resolved {@link
     * GardState.Configuration} or as a set of extensions.
     */
    config?: GardState.Extension | GardState.Configuration
  }

  /**
   * Fields can store additional information in an editor state, and
   * keep it in sync with the rest of the state. The type parameter
   * indicates the type of value stored in the field.
   */
  export class Field<Value> {
    /** @internal */
    public provides: GardState.Extension | undefined = undefined

    private constructor(
      /** @internal */
      readonly id: number,
      private createF: (state: GardState) => Value,
      private updateF: (value: Value, tr: Transaction) => Value,
      private compareF: (a: Value, b: Value) => boolean,
      /** @internal */
      readonly spec: GardState.Field.Spec<Value>
    ) {}

    /** Define a state field. */
    static define<Value>(config: GardState.Field.Spec<Value>): GardState.Field<Value> {
      const field = new GardState.Field<Value>(
        nextID++,
        config.create,
        config.update,
        config.compare || ((a, b) => a === b),
        config
      )
      if (config.provide) field.provides = config.provide(field)
      return field
    }

    private create(state: GardState) {
      const init = state.facet(initField).find(i => i.field == this)
      return (init?.create || this.createF)(state)
    }

    /** @internal */
    slot(addresses: { [id: number]: number }): DynamicSlot {
      const idx = addresses[this.id]! >> 1
      return {
        create: state => {
          state.values[idx] = this.create(state)
          return SlotStatus.Changed
        },
        update: (state, tr) => {
          const oldVal = state.values[idx]
          const value = this.updateF(oldVal, tr)
          if (this.compareF(oldVal, value)) return 0
          state.values[idx] = value
          return SlotStatus.Changed
        },
        reconfigure: (state, oldState) => {
          if (oldState.config.address[this.id] != null) {
            state.values[idx] = oldState.field(this)
            return 0
          }
          state.values[idx] = this.create(state)
          return SlotStatus.Changed
        }
      }
    }

    /**
     * State field instances can be used as {@link
     * GardState.Extension `Extension`} values to enable the field in
     * a given state.
     */
    get extension(): GardState.Extension {
      return this
    }

    /**
     * Returns an extension that enables this field and overrides the
     * way it is initialized. Can be useful when you need to provide a
     * non-default starting value for the field.
     */
    init(create: (state: GardState) => Value): GardState.Extension {
      return [this, initField.of({ field: this as any, create })]
    }
  }

  export namespace Field {
    /** The options passed when defining a state field. */
    export type Spec<Value> = {
      /** Creates the initial value for the field when a state is created. */
      create: (state: GardState) => Value

      /**
       * Compute a new value from the field's previous value and a
       * {@link Transaction transaction}. Should not mutate the old
       * value (since that will change the existing state), but
       * create a fresh one or return the old value unchanged.
       */
      update: (value: Value, transaction: Transaction) => Value

      /**
       * Compare two values of the field, returning `true` when they are
       * the same. This is used to avoid recomputing facets that depend
       * on the field when its value did not change. Defaults to using
       * `===`.
       */
      compare?: (a: Value, b: Value) => boolean

      /**
       * Provide extensions based on this field. The given function
       * will be called once with the initialized field. It is
       * typically used with a facet's {@link GardState.Facet.from}
       * method to create facet inputs from this field, but can also
       * return other extensions that should be enabled when the
       * field is present in a configuration.
       */
      provide?: (field: GardState.Field<Value>) => GardState.Extension

      /**
       * A function used to serialize this field's content to JSON. Only
       * necessary when this field is included in the argument to
       * {@link GardState.toJSON}.
       */
      toJSON?: (value: Value, state: GardState) => any

      /**
       * A function that deserializes the JSON representation of this
       * field's content.
       */
      fromJSON?: (json: any, state: GardState) => Value
    }

    /**
     * Define a field-like state slot that is computed from other
     * slots in the state. Automatically tracks dependencies and only
     * recomputes when one of the inputs accessed by the given
     * function changes. Use {@link GardState.field} to read the
     * value of such a field.
     */
    export class Derived<Value> {
      /** @internal */
      readonly id = nextID++
      /** @internal */
      dependencies: Slot[] = []

      private constructor(
        /** @internal */
        readonly value: (state: GardState) => Value,
        private compareF: (a: Value, b: Value) => boolean
      ) {}

      /**
       * Define a derived field. The optional `compare` function
       * prevents propagating a change when a recomputed result is the
       * same as the old value. It should return `true` when the inputs
       * can be considered the same. Defaults to `===`.
       */
      static define<Value>(
        compute: (state: GardState) => Value,
        spec: { compare?: (a: Value, b: Value) => boolean } = {}
      ) {
        return new Derived(compute, spec.compare || ((a, b) => a === b))
      }

      /**
       * Derived fields must be included in your state configuration
       * for them to be used.
       */
      get extension(): GardState.Extension {
        return this
      }

      /** @internal */
      slot(addresses: { [id: number]: number }): DynamicSlot {
        const idx = addresses[this.id]! >> 1
        const depSet = new DependencySet()

        return {
          create: state => {
            state.values[idx] = state.recordAccess(this.dependencies, this.value)
            return SlotStatus.Changed
          },
          update: (state, tr) => {
            depSet.update(this.dependencies, addresses)
            if (
              (depSet.doc && tr.docChanged) ||
              (depSet.sel && (tr.docChanged || tr.selection)) ||
              (depSet.schema && tr.startState.schema != state.schema) ||
              ensureAll(state, depSet.addrs)
            ) {
              const newVal = state.recordAccess<Value>(this.dependencies, this.value)
              if (!this.compareF(newVal, state.values[idx])) {
                state.values[idx] = newVal
                return SlotStatus.Changed
              }
            }
            return 0
          },
          reconfigure: (state, oldState) => {
            let newVal
            const oldAddr = oldState.config.address[this.id]
            if (oldAddr != null) {
              const oldVal = getAddr(oldState, oldAddr)
              const sameDependencies = this.dependencies.every(dep => {
                return dep instanceof GardState.Facet
                  ? oldState.facet(dep) === state.facet(dep)
                  : dep instanceof GardState.Field
                    ? oldState.field(dep, false) == state.field(dep, false)
                    : true
              })
              const value = sameDependencies ? oldVal : state.recordAccess(this.dependencies, this.value)
              if (sameDependencies || this.compareF(value, oldVal)) {
                state.values[idx] = oldVal
                return 0
              }
              newVal = value
            } else {
              newVal = state.recordAccess(this.dependencies, this.value)
            }
            state.values[idx] = newVal
            return SlotStatus.Changed
          }
        }
      }
    }
  }

  /**
   * A facet is a labeled value that is associated with an editor
   * state. It takes inputs from any number of extensions, and combines
   * those into a single output value.
   *
   * Examples of uses of facets are the {@link GardState.readOnly
   * read-only configuration}, {@link
   * editor.Wordgard.editorAttributes editor attributes}, and {@link
   * editor.Wordgard.updateListener update listeners}.
   *
   * Note that `Facet` instances can be used anywhere where {@link
   * GardState.Facet.Reader} is expected.
   *
   * Facets have an input type (the type of values provided for it),
   * and an output type (the type you get when you read the facet)
   * that defaults to an array of input values, but can be anything
   * if a {@link GardState.Facet.Spec.combine}
   * option is provided.
   */
  export class Facet<Input, Output = readonly Input[]> implements GardState.Facet.Reader<Output> {
    /** @internal */
    readonly id = nextID++
    /** The output of the facet when it has no inputs. */
    readonly default: Output
    /** @internal */
    readonly extensions: GardState.Extension | undefined

    private constructor(
      /** @internal */
      readonly combine: (values: readonly Input[]) => Output,
      /** @internal */
      readonly compareInput: (a: Input, b: Input) => boolean,
      /** @internal */
      readonly compare: (a: Output, b: Output) => boolean,
      /** True when this is a static facet. */
      readonly isStatic: boolean,
      enables: GardState.Extension | undefined | ((self: GardState.Facet<Input, Output>) => GardState.Extension)
    ) {
      this.default = combine(none)
      this.extensions = typeof enables == 'function' ? enables(this) : enables
    }

    /**
     * A facet reader for this facet, which can be used to {@link
     * GardState.facet read} it but not to define values for it.
     */
    get reader(): GardState.Facet.Reader<Output> {
      return this
    }

    /** Defines a facet with the given input an output types. */
    static define<Input, Output = readonly Input[]>(config: GardState.Facet.Spec<Input, Output> = {}) {
      return new GardState.Facet<Input, Output>(
        config.combine || (((a: any) => a) as any),
        config.compareInput || ((a, b) => a === b),
        config.compare || (!config.combine ? (sameArray as any) : (a, b) => a === b),
        !!config.static,
        config.enables
      )
    }

    /**
     * Returns an extension that provides the given value to this
     * facet.
     */
    of(value: Input): GardState.Extension {
      return new FacetProvider<Input>(this, nextID++, ProviderFlag.Static, value)
    }

    /**
     * Create an extension that derives a value for the facet from a
     * state. The given function should only depend on the state, not
     * any external non-constant inputs. Its return value will be kept
     * on state update, unless any of the fields or facets (including
     * document and selection) that it read are changed by the update,
     * in which case it is called again.
     *
     * In cases where your value depends only on a single field, you
     * can use the {@link GardState.Facet.from `from`} method
     * instead.
     */
    derive(get: (state: GardState) => Input): GardState.Extension {
      if (this.isStatic) throw new Error("Can't derive a static facet")
      const field = Field.Derived.define(get, { compare: this.compareInput })
      return [field, new FacetProvider<Input>(this, field.id, ProviderFlag.None, null)]
    }

    /**
     * Create an extension that derives zero or more values for this
     * facet from a state.
     */
    deriveN(get: (state: GardState) => readonly Input[]): GardState.Extension {
      if (this.isStatic) throw new Error("Can't derive a static facet")
      const field = Field.Derived.define(get, { compare: (a, b) => compareArray(a, b, this.compareInput) })
      return [field, new FacetProvider<Input>(this, field.id, ProviderFlag.Multi, null)]
    }

    /**
     * Shorthand method for registering a facet source with a state
     * field as input. If the field's type corresponds to this facet's
     * input type, the getter function can be omitted. If given, it
     * will be used to produce the input from the field value.
     */
    from<T extends Input>(field: GardState.Field<T> | GardState.Field.Derived<T>): GardState.Extension
    from<T>(field: GardState.Field<T> | GardState.Field.Derived<T>, get: (value: T) => Input): GardState.Extension
    from<T>(field: GardState.Field<T> | GardState.Field.Derived<T>, get?: (value: T) => Input): GardState.Extension {
      if (this.isStatic) throw new Error("Can't derive a static facet")
      if (!get) return new FacetProvider<Input>(this, field.id, ProviderFlag.None, null)
      return this.derive(s => get(s.field(field)))
    }

    tag!: Output
  }

  export namespace Facet {
    /**
     * Options passed when {@link GardState.Facet.define defining} a
     * facet.
     */
    export type Spec<Input, Output> = {
      /**
       * How to combine the input values into a single output value. When
       * not given, the array of input values becomes the output. This
       * function will immediately be called on creating the facet, with
       * an empty array, to compute the facet's default value when no
       * inputs are present.
       */
      combine?: (value: readonly Input[]) => Output
      /**
       * How to compare output values to determine whether the value
       * of the facet changed. When a new value for the facet is
       * computed that that compares as equal to the old value, the
       * old value is kept. So in most circumstances, facet values
       * can be cheaply compared by identity to check for changes.
       * Defaults to comparing by `===` or, if no `combine` function
       * was given, comparing each element of the array with `===`.
       */
      compare?: (a: Output, b: Output) => boolean
      /**
       * How to compare input values to avoid recomputing the output
       * value when no inputs changed. Defaults to comparing with `===`.
       */
      compareInput?: (a: Input, b: Input) => boolean
      /**
       * Forbids dynamic inputs to this facet. Allows the facet to be
       * {@link GardState.Configuration.staticFacet read} from a
       * configuration.
       */
      static?: boolean
      /**
       * If given, these extensions (or the result of calling the
       * given function with the facet) will be added to any state
       * where this facet is provided. (Note that, while a facet's
       * {@link GardState.Facet.default default} value can be read
       * from a state even if the facet wasn't present in the state
       * at all, the extensions won't be added in that situation.)
       */
      enables?: GardState.Extension | ((self: GardState.Facet<Input, Output>) => GardState.Extension)
    }

    /**
     * A facet reader can be used to fetch the value of a facet,
     * through {@link GardState.facet} or as a dependency in {@link
     * GardState.Facet.derive `Facet.derive`}, but not to define
     * new values for the facet.
     */
    export type Reader<Output> = {
      /** @internal */
      id: number
      /** @internal */
      default: Output
      /** @hidden */
      tag: Output
    }

    /**
     * Utility function for combining multiple configuration objects.
     * `defaults` should hold default values for all optional fields
     * in `Config`.
     *
     * The function will, by default, raise an error when a field
     * gets two values that aren't `===`-equal, but you can provide
     * combine functions per field to do something else.
     */
    export function combineConfig<Config extends object>(
      configs: readonly Partial<Config>[],
      // The defaults of the optional properties. The type does not limit it to those properties.
      defaults: Partial<Config>,
      combine: { [P in keyof Config]?: (first: Config[P], second: Config[P]) => Config[P] } = {}
    ): Config {
      const result: any = {}
      for (const config of configs) {
        for (const key of Object.keys(config) as (keyof Config)[]) {
          const value = config[key],
            current = result[key]
          if (current === undefined) result[key] = value
          // Equal values and missing values do not conflict.
          else if (current !== value && value !== undefined) {
            if (Object.hasOwnProperty.call(combine, key)) result[key] = combine[key]!(current as any, value as any)
            else throw new Error(`Config merge conflict for field ${key as string}`)
          }
        }
      }
      for (const key in defaults) if (result[key] === undefined) result[key] = defaults[key]
      return result
    }
  }

  /**
   * A state configuration stores a set of extensions, structured so
   * that state updates can be performed efficiently.
   */
  export class Configuration {
    /** @internal */
    readonly statusTemplate: SlotStatus[] = []

    private constructor(
      /** The set of extensions that this configuration is based on. */
      readonly base: GardState.Extension,
      /** @internal */
      readonly compartments: Map<GardState.Compartment, GardState.Extension>,
      /** @internal */
      readonly dynamicSlots: DynamicSlot[],
      /** @internal */
      readonly address: { [id: number]: number },
      /** @internal */
      readonly staticValues: readonly any[],
      /** @internal */
      readonly facets: { [id: number]: readonly FacetProvider<any>[] }
    ) {
      while (this.statusTemplate.length < dynamicSlots.length) this.statusTemplate.push(SlotStatus.Unresolved)
    }

    /** Read the value of a static facet. */
    staticFacet<Output>(facet: GardState.Facet<any, Output>): Output {
      if (!facet.isStatic) throw new Error('Only static facets can be accessed from a configuration')
      const addr = this.address[facet.id]
      return addr == null ? facet.default : this.staticValues[addr >> 1]
    }

    /** @internal */
    static resolve(
      base: GardState.Extension,
      compartments: Map<GardState.Compartment, GardState.Extension>,
      oldState?: GardState
    ) {
      const fields: (GardState.Field<any> | GardState.Field.Derived<any>)[] = []
      const facets: { [id: number]: FacetProvider<any>[] } = Object.create(null)
      const newCompartments = new Map<GardState.Compartment, GardState.Extension>()

      for (const ext of flatten(base, compartments, newCompartments)) {
        if (ext instanceof FacetProvider) (facets[ext.facet.id] || (facets[ext.facet.id] = [])).push(ext)
        else fields.push(ext)
      }

      const address: { [id: number]: number } = Object.create(null)
      const staticValues: any[] = []
      const dynamicSlots: ((address: { [id: number]: number }) => DynamicSlot)[] = []

      for (const field of fields) {
        address[field.id] = dynamicSlots.length << 1
        dynamicSlots.push(a => field.slot(a))
      }

      const oldFacets = oldState?.config.facets
      for (const id in facets) {
        const providers = facets[id]!,
          facet = providers[0]!.facet
        const oldProviders = (oldFacets && oldFacets[id]) || none
        if (providers.every(p => p.flags & ProviderFlag.Static)) {
          address[facet.id] = (staticValues.length << 1) | 1
          if (sameArray(oldProviders, providers)) {
            staticValues.push(oldState!.facet(facet))
          } else {
            const value = facet.combine(providers.map(p => p.value))
            staticValues.push(oldState && facet.compare(value, oldState.facet(facet)) ? oldState.facet(facet) : value)
          }
        } else {
          for (const p of providers) {
            if (p.flags & ProviderFlag.Static) {
              address[p.id] = (staticValues.length << 1) | 1
              staticValues.push(p.value)
            }
          }
          address[facet.id] = dynamicSlots.length << 1
          dynamicSlots.push(a => dynamicFacetSlot(a, facet, providers))
        }
      }

      const dynamic = dynamicSlots.map(f => f(address))
      return new GardState.Configuration(base, newCompartments, dynamic, address, staticValues, facets)
    }

    /** Create a configuration from the given set of extensions. */
    static create(extensions: GardState.Extension) {
      return GardState.Configuration.resolve(extensions, new Map())
    }

    /**
     * Get the schema defined by this configuration. Will be null if
     * the schema does not contain a document plot type.
     */
    get schema(): Schema | null {
      const elts = this.staticFacet(GardState.schemaElement)
      if (!elts.some(elt => elt instanceof Plot.Type && elt.isDoc)) return null
      return Schema.define(elts)
    }

    // Kludge to avoid cyclic dep with ./selection
    /** @internal */
    get textLTR() {
      return this.staticFacet(GardState.textLTR)
    }
    /** @internal */
    textblockLTR(plot: Plot) {
      for (const f of this.staticFacet(GardState.textblockLTR)) {
        const result = f(plot)
        if (result != null) return result
      }
      return this.textLTR
    }
    /** @internal */
    get visualCursorMotion() {
      return this.staticFacet(GardState.visualCursorMotion)
    }
    /** @internal */
    isAtom(type: Node.Type) {
      return type.isLeaf || (this.staticFacet(GardState.isAtom).get(type) ?? type.isAtom)
    }
  }

  function flatten(
    extension: GardState.Extension,
    compartments: Map<GardState.Compartment, GardState.Extension>,
    newCompartments: Map<GardState.Compartment, GardState.Extension>
  ) {
    const result: (FacetProvider<any> | GardState.Field<any> | GardState.Field.Derived<any>)[][] = [[], [], [], [], []]
    const seen = new Map<GardState.Extension, number>()
    function inner(ext: GardState.Extension, prec: number) {
      const known = seen.get(ext)
      if (known != null) {
        if (known <= prec) return
        const found = result[known]!.indexOf(ext as any)
        if (found > -1) result[known]!.splice(found, 1)
        if (ext instanceof CompartmentInstance) newCompartments.delete(ext.compartment)
      }
      seen.set(ext, prec)
      if (Array.isArray(ext)) {
        for (const e of ext) inner(e, prec)
      } else if (ext instanceof CompartmentInstance) {
        if (newCompartments.has(ext.compartment)) throw new RangeError(`Duplicate use of compartment in extensions`)
        const content = compartments.get(ext.compartment) || ext.inner
        newCompartments.set(ext.compartment, content)
        inner(content, prec)
      } else if (ext instanceof PrecExtension) {
        inner(ext.inner, ext.prec)
      } else if (ext instanceof GardState.Field) {
        result[prec]!.push(ext)
        if (ext.provides) inner(ext.provides, prec)
      } else if (ext instanceof GardState.Field.Derived) {
        result[prec]!.push(ext)
      } else if (ext instanceof FacetProvider) {
        result[prec]!.push(ext)
        if (ext.facet.extensions) inner(ext.facet.extensions, Prec.Default)
      } else {
        const content = (ext as any).extension
        if (!content) {
          throw new Error(
            `Unrecognized extension value in extension set (${ext}). This sometimes happens because multiple instances of wordgard/state are loaded, breaking instanceof checks.`
          )
        }
        inner(content, prec)
      }
    }
    inner(extension, Prec.Default)
    return result.reduce((a, b) => a.concat(b))
  }

  /**
   * Extension values can be {@link GardState.Spec.config provided}
   * when creating a state to attach various kinds of configuration
   * and behavior information. They can either be built-in
   * extension-providing objects, such as {@link GardState.Field
   * state fields} or {@link GardState.Facet.of facet providers}, or
   * objects with an extension in its `extension` property.
   * Extensions can be nested in arrays arbitrarily deep—they will be
   * flattened when resolved into a configuration.
   */
  export type Extension = { extension: GardState.Extension } | readonly GardState.Extension[]

  /**
   * By default extensions are registered in the order they are found
   * in the flattened form of the configuration's extension tree.
   * Individual extension values can be assigned a precedence to
   * override this. Extensions that do not have a precedence set get
   * the precedence of the nearest parent with a precedence, or
   * {@link GardState.prec.default `default`} if there is no such
   * parent. The final ordering of extensions is determined by first
   * sorting by precedence and then by order within each precedence.
   */
  export const prec = {
    /**
     * The highest precedence level, for extensions that should end up
     * near the start of the precedence ordering.
     */
    highest: mkPrec(Prec.Highest),
    /**
     * A higher-than-default precedence, for extensions that should
     * come before those with default precedence.
     */
    high: mkPrec(Prec.High),
    /**
     * The default precedence, which is also used for extensions
     * without an explicit precedence.
     */
    default: mkPrec(Prec.Default),
    /** A lower-than-default precedence. */
    low: mkPrec(Prec.Low),
    /**
     * The lowest precedence level. Meant for things that should end up
     * near the end of the extension order.
     */
    lowest: mkPrec(Prec.Lowest)
  }

  /**
   * Extension compartments can be used to make a configuration
   * dynamic. By {@link GardState.Compartment.of wrapping} part of your
   * configuration in a compartment, you can later {@link
   * GardState.Compartment.reconfigure replace} that part through a
   * transaction.
   */
  export class Compartment {
    private constructor() {}

    /** Define a new compartment. */
    static define() {
      return new Compartment()
    }

    /**
     * Create an instance of this compartment to add to your {@link
     * GardState.Spec.config state configuration}.
     */
    of(ext: GardState.Extension): GardState.Extension {
      return new CompartmentInstance(this, ext)
    }

    /**
     * Create an {@link Transaction.Spec.effects effect} that
     * reconfigures this compartment.
     */
    reconfigure(content: GardState.Extension): Transaction.Effect<unknown> {
      return GardState.Compartment.reconfigureCompartment.of({ compartment: this, extension: content })
    }

    /**
     * Get the current content of the compartment in the state, or
     * `undefined` if it isn't present.
     */
    get(state: GardState): GardState.Extension | undefined {
      return state.config.compartments.get(this)
    }

    /** @internal */
    static reconfigureCompartment = Transaction.Effect.define<{
      compartment: GardState.Compartment
      extension: GardState.Extension
    }>()
  }

  /**
   * Facet used to register {@link Schema schema} elements. *If*
   * a configuration contains a {@link Plot.defineDoc document}
   * type, the editor's document schema will be derived from the
   * content of this facet. (Otherwise, the state will try to use the
   * schema provided via the {@link GardState.Spec.doc} option, or
   * raise an error is none is provided.)
   */
  export const schemaElement = GardState.Facet.define<
    Schema.Element | readonly Schema.Element[],
    readonly Schema.Element[]
  >({
    combine: values => values.reduce((set: readonly Schema.Element[], elt) => set.concat(elt), none),
    static: true
  })

  /**
   * This facet controls the value of the {@link GardState.readOnly
   * `readOnly` getter}, which is consulted by commands and
   * extensions that implement editing functionality to determine
   * whether they should apply. It defaults to false, but when its
   * highest-precedence value is `true`, the state is considered
   * read-only, and such functions won't change the document.
   *
   * Not to be confused with {@link editor.Wordgard.editable}, which
   * controls whether the editor's DOM is set to be editable (and
   * thus focusable).
   */
  export const readOnly = GardState.Facet.define<boolean, boolean>({
    combine: values => (values.length ? values[0]! : false)
  })

  /**
   * Facet that indicates the document's default text direction. Note
   * that this will not affect the editor CSS, and when the state's
   * value disagrees with the direction set in the editor, the editor
   * component will automatically inject an instance of this with a
   * high precedence to align the state to the DOM. Still, if you
   * know the direction in advance, it can be useful to set this, so
   * that the direction is already accurate during initialization.
   * Defaults to true.
   */
  export const textLTR = GardState.Facet.define<boolean, boolean>({
    combine: values => (values.length ? values[0]! : true),
    static: true
  })

  /**
   * Configure the text direction per textblock. All values given for
   * this will be consulted in order of precedence, until one returns
   * a non-null value. If none set a direction, the editor's {@link
   * GardState.textLTR base direction} is used.
   *
   * Schema elements like {@link schema.direction} register an
   * instance of this to make the editor aware of the meaning of the
   * {@link types.Direction} mark.
   */
  export const textblockLTR = GardState.Facet.define<(plot: Plot) => boolean | null>({
    static: true
  })

  /**
   * Configure whether to use visual or logical cursor motion in
   * bidirectional text. The default is visual, where pressing
   * left/right arrow keys moves the cursor in the direction that
   * corresponds to the arrow on key. When disabled, the motion uses
   * the string index order instead.
   */
  export const visualCursorMotion = GardState.Facet.define<boolean, boolean>({
    combine(values) {
      return !values.length ? true : values[0]!
    },
    static: true
  })

  /** @internal */
  export const isAtom = GardState.Facet.define<[Plot.Type, boolean], Map<Plot.Type, boolean>>({
    static: true,
    combine(inputs) {
      const map = new Map<Plot.Type, boolean>()
      for (let i = inputs.length - 1; i >= 0; i--) map.set(inputs[i]![0], inputs[i]![1])
      return map
    }
  })
}

const initField = GardState.Facet.define<{ field: GardState.Field<unknown>; create: (state: GardState) => unknown }>({
  static: true
})

function addValue<T>(set: T[], value: T) {
  if (set.indexOf(value) < 0) set.push(value)
}

function mkPrec(value: number) {
  return (ext: GardState.Extension) => new PrecExtension(ext, value) as GardState.Extension
}

class PrecExtension {
  constructor(
    readonly inner: GardState.Extension,
    readonly prec: number
  ) {}
  extension!: GardState.Extension
}

function sameArray<T>(a: readonly T[], b: readonly T[]) {
  return a == b || (a.length == b.length && a.every((e, i) => e === b[i]))
}

type Slot =
  | GardState.Facet.Reader<any>
  | GardState.Field<any>
  | GardState.Field.Derived<any>
  | 'doc'
  | 'selection'
  | 'schema'

enum ProviderFlag {
  None = 0,
  Static = 1,
  Multi = 2, // Dynamic providers may produce an array of values
  Auto = 4 // Dependencies automatically tracked
}

enum SlotStatus {
  Unresolved = 0,
  Changed = 1,
  Computed = 2,
  Computing = 4
}

class DependencySet {
  doc: boolean = false
  sel: boolean = false
  schema: boolean = false
  addrs: number[] = []
  count: number = 0

  update(deps: readonly Slot[], addresses: { [id: number]: number }) {
    while (this.count < deps.length) {
      const dep = deps[this.count++]!
      if (dep === 'doc') this.doc = true
      else if (dep === 'selection') this.sel = true
      else if (dep === 'schema') this.schema = true
      else if (((addresses[dep.id] ?? 1) & 1) == 0) this.addrs.push(addresses[dep.id]!)
    }
  }
}

class FacetProvider<Input> {
  extension!: GardState.Extension // Kludge to convince the type system these count as extensions

  constructor(
    readonly facet: GardState.Facet<Input, any>,
    // Own ID for static facets, ID of source for those
    // reading a field.
    readonly id: number,
    readonly flags: ProviderFlag,
    // Value if this is a static facet
    readonly value: Input | null
  ) {}
}

function compareArray<T>(a: readonly T[], b: readonly T[], compare: (a: T, b: T) => boolean) {
  if (a.length != b.length) return false
  for (let i = 0; i < a.length; i++) if (!compare(a[i]!, b[i]!)) return false
  return true
}

function ensureAll(state: GardState, addrs: readonly number[]) {
  let changed = false
  for (const addr of addrs) if (ensureAddr(state, addr)! & SlotStatus.Changed) changed = true
  return changed
}

function dynamicFacetSlot<Input, Output>(
  addresses: { [id: number]: number },
  facet: GardState.Facet<Input, Output>,
  providers: readonly FacetProvider<Input>[]
): DynamicSlot {
  const providerAddrs = providers.map(p => addresses[p.id]!)
  const dynamic = providerAddrs.filter(p => !(p & 1))
  const idx = addresses[facet.id]! >> 1

  function get(state: GardState) {
    const values: Input[] = []
    for (let i = 0; i < providerAddrs.length; i++) {
      const value = getAddr(state, providerAddrs[i]!)
      if (providers[i]!.flags & ProviderFlag.Multi) for (const val of value) values.push(val)
      else values.push(value)
    }
    return facet.combine(values)
  }

  return {
    create(state) {
      for (const addr of providerAddrs) ensureAddr(state, addr)
      state.values[idx] = get(state)
      return SlotStatus.Changed
    },
    update(state) {
      if (!ensureAll(state, dynamic)) return 0
      const value = get(state)
      if (facet.compare(value, state.values[idx])) return 0
      state.values[idx] = value
      return SlotStatus.Changed
    },
    reconfigure(state, oldState) {
      const depChanged = ensureAll(state, providerAddrs)
      const oldProviders = oldState.config.facets[facet.id],
        oldValue = oldState.facet(facet)
      if (oldProviders && !depChanged && sameArray(providers, oldProviders)) {
        state.values[idx] = oldValue
        return 0
      }
      const value = get(state)
      if (facet.compare(value, oldValue)) {
        state.values[idx] = oldValue
        return 0
      }
      state.values[idx] = value
      return SlotStatus.Changed
    }
  }
}

function ensureAddr(state: GardState, addr: number) {
  if (addr & 1) return SlotStatus.Computed
  const idx = addr >> 1
  const status = state.status[idx]!
  if (status == SlotStatus.Computing) throw new Error('Cyclic dependency between fields and/or facets')
  if (status & SlotStatus.Computed) return status
  state.status[idx] = SlotStatus.Computing
  const changed = state.computeSlot!(state, state.config.dynamicSlots[idx]!)
  return (state.status[idx] = SlotStatus.Computed | changed)
}

function getAddr(state: GardState, addr: number) {
  return addr & 1 ? state.config.staticValues[addr >> 1] : state.values[addr >> 1]
}

class CompartmentInstance {
  constructor(
    readonly compartment: GardState.Compartment,
    readonly inner: GardState.Extension
  ) {}
  extension!: GardState.Extension
}

interface DynamicSlot {
  create(state: GardState): SlotStatus
  update(state: GardState, tr: Transaction): SlotStatus
  reconfigure(state: GardState, oldState: GardState): SlotStatus
}

// Kludge to avoid cyclic dependency with ./selection
GardSelection.selectionType = GardState.Facet.define<SelectionType>({
  combine(values) {
    const types = [GardSelection.Text.type, GardSelection.Node.type, ...values]
    for (let i = 0; i < types.length; i++) {
      for (let j = i + 1; j < types.length; j++) {
        if (types[i]!.tag == types[j]!.tag) throw new Error(`Duplicate selection JSON tag: ${types[i]!.tag}`)
      }
    }
    return types
  },
  static: true
})

Transaction.extender = GardState.Facet.define()

Transaction.appender = GardState.Facet.define()
