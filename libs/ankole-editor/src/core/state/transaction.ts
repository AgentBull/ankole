import { Plot, ChangeSet } from '../doc'
import type { GardState } from './state'
import { GardSelection } from './selection'

/**
 * Changes to the editor state are grouped into transactions.
 * Typically, a user action creates a single transaction, which may
 * contain any number of document changes, may change the selection,
 * or have other {@link Transaction.Effect effects}. Create a
 * transaction by calling {@link GardState.update}, or immediately
 * dispatch one by calling {@link editor.Wordgard.dispatch
 * `Wordgard.dispatch`}.
 */
export class Transaction {
  /** @internal */
  _state: GardState | null = null

  private constructor(
    /** The state from which this transaction starts. */
    readonly startState: GardState,
    /** The document changes made by this transaction. */
    readonly changes: ChangeSet,
    /**
     * The selection set by this transaction, or undefined if it
     * doesn't explicitly set a selection.
     */
    readonly selection: GardSelection | undefined,
    /** The effects contained in this transaction. */
    readonly effects: readonly Transaction.Effect<any>[],
    /** @internal */
    readonly annotations: readonly Transaction.Annotation<any>[],
    /**
     * Whether the selection should be scrolled into view after this
     * transaction is dispatched.
     */
    readonly scrollIntoView: boolean
  ) {
    if (!annotations.some((a: Transaction.Annotation<any>) => a.type == Transaction.time)) {
      this.annotations = annotations.concat(Transaction.time.of(Date.now()))
    }
    this.newDoc = this.changes.apply(this.startState.doc)
    this.newSelection =
      selection || startState.selection.map(changes, { doc: this.newDoc, config: this.startState.config })
    this.newSelection.check(startState.config, this.newDoc)
  }

  /**
   * The new selection produced by the transaction. If {@link
   * Transaction.selection `this.selection`} is undefined, this will
   * {@link GardSelection.map map} the start state's current
   * selection through the changes made by the transaction.
   */
  newSelection: GardSelection

  /**
   * The new document produced by the transaction. Contrary to
   * {@link Transaction.state `.state`}`.doc`, accessing this won't
   * force the entire new state to be computed right away, so it is
   * recommended that {@link Transaction.extender transaction
   * extenders} use this property when they need to look at the new
   * document.
   */
  newDoc: Plot.Doc

  /** @internal */
  static create(startState: GardState, spec: ResolvedSpec) {
    return new Transaction(
      startState,
      spec.changes,
      spec.selection,
      spec.effects,
      spec.annotations,
      spec.scrollIntoView
    )
  }

  /**
   * The new state created by the transaction. Lazily computed so
   * that the state is resolved the first time this property is
   * accessed.
   */
  get state() {
    if (!this._state) this.startState.applyTransaction(this)
    return this._state!
  }

  /**
   * Get the value of the given transaction {@link
   * Transaction.Annotation annotation} type, if any.
   */
  annotation<T>(type: Transaction.Annotation.Type<T>): T | undefined {
    for (const ann of this.annotations) if (ann.type == type) return ann.value
    return undefined
  }

  /** Indicates whether the transaction changed the document. */
  get docChanged(): boolean {
    return !this.changes.empty
  }

  /**
   * Indicates whether this transaction reconfigures the state
   * (through a {@link GardState.Compartment configuration
   * compartment}, {@link GardState.reconfigure reconfiguration}, or
   * {@link GardState.appendConfig appended configuration}).
   */
  get reconfigured(): boolean {
    return this.startState.config != this.state.config
  }

  /**
   * Returns true if the transaction has a {@link
   * Transaction.userEvent user event} annotation that is equal to or
   * more specific than `event`. For example, if the transaction has
   * `"select.pointer"` as user event, `"select"` and
   * `"select.pointer"` will match it.
   */
  isUserEvent(event: string): boolean {
    const e = this.annotation(Transaction.userEvent)
    return !!(e && (e == event || (e.length > event.length && e.startsWith(event) && e[event.length] == '.')))
  }

  /**
   * Facet used to register a hook that gets a chance to add to
   * transactions before they are applied. If such a function returns
   * a transaction spec, it will be combined with the original
   * transaction (in the same way as the arguments to
   * {@link GardState.update}).
   *
   * When possible, it is recommended to avoid accessing {@link
   * Transaction.state} in an extender, since it will force creation
   * of a state that will then be discarded again, if the transaction
   * is actually extended.
   *
   * This functionality should be used with care. Indiscriminately
   * modifying transaction is likely to break something or degrade
   * the user experience.
   *
   * Extenders that may add document changes should generally not do
   * anything for {@link Transaction.remote remote} transactions,
   * because doing so risks causing endlessly cascading changes or
   * other confusion. It is possible to define extenders that are
   * safe when activated on multiple peer (for example, duplicate
   * deletions of the same content tend to converge), but it requires
   * a lot of care.
   */
  static extender: GardState.Facet<(tr: Transaction) => Transaction.Spec | null>

  /**
   * A transaction appender can create more transactions in response
   * to a transaction. {@link Transaction.append}, which is
   * called by the {@link Wordgard editor} when dispatching a
   * transaction, will call appenders on sets of transactions,
   * allowing them to add another transaction. When another appender
   * adds a transaction, extenders that already ran will be called
   * again, but only with the transactions that were added after they
   * ran.
   */
  static appender: GardState.Facet<(trs: readonly Transaction[], state: GardState) => Transaction.Spec | null>
}

export namespace Transaction {
  /**
   * Describes a {@link Transaction transaction} when calling {@link
   * GardState.update `GardState.update`} or {@link Wordgard.dispatch
   * `Wordgard.dispatch`}.
   */
  export interface Spec {
    /** The changes to the document made by this transaction. */
    changes?: ChangeSet.Spec
    /**
     * When set, this transaction explicitly updates the selection.
     * Offsets in this selection should refer to the document as it
     * is _after_ the transaction. If a selection can only be
     * computed after the new document is available, you can pass a
     * function here.
     */
    selection?:
      | GardSelection
      | GardSelection.Text.Spec
      | ((cx: GardSelection.Context, changes: ChangeSet) => GardSelection | null)
    /**
     * Attach {@link Transaction.Effect effects} to this transaction.
     * Again, when they contain positions and this same spec makes
     * changes, those positions should refer to positions in the
     * updated document.
     */
    effects?: Transaction.Effect<any> | readonly Transaction.Effect<any>[]
    /**
     * Set {@link Transaction.Annotation annotations} for this
     * transaction.
     */
    annotations?: Transaction.Annotation<any> | readonly Transaction.Annotation<any>[]
    /** Shorthand for `annotations: `{@link Transaction.userEvent `Transaction.userEvent`}`.of(...)`. */
    userEvent?: string
    /**
     * When set to `true`, the transaction is marked as needing to
     * scroll the current selection into view.
     */
    scrollIntoView?: boolean
    /**
     * Only meaningful for specs that are combined with another
     * transaction spec (via {@link Transaction.merge or by being
     * returned from an {@link Transaction.extender extender}.
     * Normally, when specs are combined, the positions in `changes`
     * are taken to refer to the document positions in the initial
     * document. When a spec has `sequental` set to true, its
     * positions will be taken to refer to the document created by
     * the changes in the spec before it.
     */
    sequential?: boolean
  }

  /**
   * Merge two transaction specs into a single one, combining the
   * effect of both.
   */
  export function merge(state: GardState, a: Transaction.Spec, b: Transaction.Spec): Transaction.Spec {
    const rA = resolveTransactionInner(state, null, a)
    return mergeTransaction(state, rA, resolveTransactionInner(state, rA.changes, b))
  }

  /**
   * Apply {@link Transaction.appender transaction appenders}, return
   * an array of the original transaction plus any that were appended.
   */
  export function append(tr: Transaction): readonly Transaction[] {
    const result = [tr]
    let top = tr.state
    const appenders = tr.startState.facet(Transaction.appender)
    if (!appenders.length) return result
    for (const seen = appenders.map(() => 0); ;) {
      let done = true
      for (let i = 0; i < appenders.length; i++) {
        const from = seen[i]!
        if (from < result.length) {
          const add = appenders[i]!(from ? result.slice(from) : result, top)
          if (add) {
            const tr = top.update(Transaction.merge(top, add, { annotations: Transaction.appended.of(true) }))
            result.push(tr)
            top = tr.state
            done = false
          }
          seen[i] = result.length
        }
      }
      if (done) return result
    }
  }

  /**
   * Annotations are tagged values that are used to add metadata to
   * transactions in an extensible way. They should be used to model
   * things that effect the entire transaction (such as its {@link
   * Transaction.time time stamp} or information about its {@link
   * Transaction.userEvent origin}). For effects that happen
   * _alongside_ the other changes made by the transaction, {@link
   * Transaction.Effect effects} are more appropriate.
   */
  export class Annotation<T> {
    /** @internal */
    constructor(
      /** The annotation type. */
      readonly type: Transaction.Annotation.Type<T>,
      /** The value of this annotation. */
      readonly value: T
    ) {}

    /** Define a new type of annotation. */
    static define<T>() {
      return new Transaction.Annotation.Type<T>()
    }

    // This is just to get less sloppy typing (where StateEffect is a subtype of Annotation)
    declare private _isAnnotation: true
  }

  export namespace Annotation {
    /**
     * Marker that identifies a type of {@link Transaction.Annotation
     * annotation}.
     */
    export class Type<T> {
      /** Create an instance of this annotation. */
      of(value: T): Transaction.Annotation<T> {
        return new Transaction.Annotation(this, value)
      }
    }
  }

  /**
   * Annotation used to store transaction timestamps. Automatically
   * added to every transaction, holding `Date.now()`.
   */
  export const time = Transaction.Annotation.define<number>()

  /**
   * Annotation used to associate a transaction with a user interface
   * event. Holds a string identifying the event, using a
   * dot-separated format to support attaching more specific
   * information. The events used by the core libraries are:
   *
   *  - `"input"` when content is entered
   *    - `"input.type"` for typed input
   *      - `"input.type.compose"` for composition
   *    - `"input.paste"` for pasted input
   *    - `"input.drop"` when adding content with drag-and-drop
   *  - `"delete"` when the user deletes content
   *    - `"delete.selection"` when deleting the selection
   *    - `"delete.forward"` when deleting forward from the selection
   *    - `"delete.backward"` when deleting backward from the selection
   *    - `"delete.cut"` when cutting to the clipboard
   *  - `"move"` when content is moved
   *    - `"move.drop"` when content is moved within the editor
   *      through drag-and-drop
   *  - `"select"` when explicitly changing the selection
   *    - `"select.pointer"` when selecting with a mouse or other pointing
   *      device
   *    - `"select.all"` when selecting the entire document
   *  - `"undo"` and `"redo"` for history actions
   *  - `"insert"` for actions that insert nodes
   *  - `"mark"` for actions that manipulate marks
   *    - `"mark.add"` when a command adds a mark
   *    - `"mark.remove"` when a command removes one
   *  - `"split"`, `"wrap"`, `"settype"`, `"wrap"`, `"unwrap"` for
   *    block manipulation actions
   *
   * Use {@link Transaction.isUserEvent `isUserEvent`} to check
   * whether the annotation matches a given event.
   */
  export const userEvent = Annotation.define<string>()

  /**
   * Annotation indicating whether a transaction should be added to
   * the undo history or not.
   */
  export const addToHistory = Annotation.define<boolean>()

  /**
   * Annotation indicating (when present and true) that a transaction
   * represents a change made by some other actor, not the user. This
   * is used, for example, to tag other people's changes in
   * collaborative editing.
   */
  export const remote = Annotation.define<boolean>()

  /**
   * A flag set on transactions created by a {@link
   * Transaction.appender transaction appender}.
   */
  export const appended = Annotation.define<boolean>()

  /**
   * Transaction effects can be used to represent additional effects
   * associated with a {@link Transaction.effects transaction}. They
   * are often useful to model changes to custom {@link
   * GardState.Field state fields}, when those changes aren't
   * implicit in document or selection changes.
   */
  export class Effect<Value> {
    /** @internal */
    constructor(
      /** @internal */
      readonly type: Transaction.Effect.Type<Value>,
      /** The value of this effect. */
      readonly value: Value
    ) {}

    /**
     * Map this effect through a position mapping. Will return
     * `undefined` when the changes deleted the effect.
     */
    map(mapping: ChangeSet): Transaction.Effect<Value> | undefined {
      const mapped = this.type.map(this.value, mapping)
      return mapped === undefined ? undefined : mapped == this.value ? this : new Transaction.Effect(this.type, mapped)
    }

    /**
     * Tells you whether this effect object is of a given
     * {@link Transaction.Effect.Type type}.
     */
    is<T>(type: Transaction.Effect.Type<T>): this is Transaction.Effect<T> {
      return this.type == (type as any)
    }

    /**
     * Define a new effect type. The type parameter indicates the
     * type of values that his effect holds. It should be a type that
     * doesn't include `undefined`, since that is used in {@link
     * Transaction.Effect.map mapping} to indicate that an effect is
     * removed.
     */
    static define<Value = null>(spec: Transaction.Effect.Spec<Value> = {}): Transaction.Effect.Type<Value> {
      return new Transaction.Effect.Type(spec.map || (v => v))
    }
  }

  export namespace Effect {
    /** Map an array of effects through a change set. */
    export function mapEffects(effects: readonly Transaction.Effect<any>[], mapping: ChangeSet) {
      if (!effects.length) return effects
      const result = []
      for (const effect of effects) {
        const mapped = effect.map(mapping)
        if (mapped) result.push(mapped)
      }
      return result
    }

    /**
     * A type of state effect. Defined with {@link
     * Transaction.Effect.define}.
     */
    export class Type<Value> {
      /** @internal */
      constructor(
        // The `any` types in these function types are there to work
        // around TypeScript issue #37631, where the type guard on
        // `StateEffect.is` mysteriously stops working when these properly
        // have type `Value`.
        /** @internal */
        readonly map: (value: any, mapping: ChangeSet) => any | undefined
      ) {}

      /**
       * Create an {@link Transaction.Effect effect} instance of this
       * type.
       */
      of(value: Value): Transaction.Effect<Value> {
        return new Transaction.Effect(this, value)
      }
    }

    /** Options passed when defining an effect. */
    export interface Spec<Value> {
      /**
       * Provides a way to map an effect like this through a position
       * mapping. When not given, the effects will simply not be mapped.
       * When the function returns `undefined`, that means the mapping
       * deletes the effect.
       */
      map?: (value: Value, mapping: ChangeSet) => Value | undefined
    }
  }
}

type ResolvedSpec = {
  changes: ChangeSet
  selection: GardSelection | undefined
  effects: readonly Transaction.Effect<any>[]
  annotations: readonly Transaction.Annotation<any>[]
  scrollIntoView: boolean
}

function selCx(config: GardState.Configuration, doc: Plot.Doc, changes: ChangeSet) {
  let newDoc: Plot.Doc | undefined
  return {
    get doc() {
      return newDoc || (newDoc = changes.apply(doc))
    },
    config
  }
}

export function mergeTransaction(state: GardState, a: ResolvedSpec, b: ResolvedSpec): ResolvedSpec {
  const changes = a.changes.compose(b.changes)
  return {
    changes,
    selection: b.selection || (a.selection && a.selection.map(b.changes, selCx(state.config, state.doc, changes))),
    effects: Transaction.Effect.mapEffects(a.effects, b.changes).concat(b.effects),
    annotations: a.annotations.length ? a.annotations.concat(b.annotations) : b.annotations,
    scrollIntoView: a.scrollIntoView || b.scrollIntoView
  }
}

export function resolveTransactionInner(
  state: GardState,
  after: ChangeSet | null,
  spec: Transaction.Spec
): ResolvedSpec {
  const { sequential } = spec
  let { changes } = spec
  if (after && after.empty) after = null
  const doc = after && sequential ? after.apply(state.doc) : state.doc
  if (!(changes instanceof ChangeSet)) changes = ChangeSet.create(doc, changes || [])
  let effects = asArray(spec.effects),
    annotations = asArray(spec.annotations)
  if (spec.userEvent) annotations = annotations.concat(Transaction.userEvent.of(spec.userEvent))
  let selection = !spec.selection
    ? undefined
    : spec.selection instanceof GardSelection
      ? spec.selection
      : typeof spec.selection == 'function'
        ? (spec.selection({ doc: changes.apply(doc), config: state.config }, changes) ?? undefined)
        : GardSelection.Text.create(spec.selection)
  if (after && !sequential) {
    if (selection) {
      const { a, b } = ChangeSet.transform(state.doc, after, changes)
      selection = selection.map(a, selCx(state.config, doc, changes))
      changes = b
    } else {
      changes = changes.transform(state.doc, after)
    }
    effects = Transaction.Effect.mapEffects(effects, after)
  }
  return { changes, selection, effects, annotations, scrollIntoView: !!spec.scrollIntoView }
}

export function resolveTransaction(state: GardState, spec: Transaction.Spec): Transaction {
  let s = resolveTransactionInner(state, null, spec)
  const extenders = state.facet(Transaction.extender)
  let tr = Transaction.create(state, s)
  for (let i = extenders.length - 1; i >= 0; i--) {
    const extension = extenders[i]!(tr)
    if (extension) {
      s = mergeTransaction(state, s, resolveTransactionInner(state, tr.changes, extension))
      tr = Transaction.create(state, s)
    }
  }
  return tr
}

const none: readonly any[] = []

export function asArray<T>(value: undefined | T | readonly T[]): readonly T[] {
  return value == null ? none : Array.isArray(value) ? value : [value as T]
}
