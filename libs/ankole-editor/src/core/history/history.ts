import { GardState, Transaction, GardSelection } from '../state'
import { Plot, ChangeSet } from '../doc'
import { Command, Menu, undo as undoCmd, redo as redoCmd } from '../command'
import { phrases } from '../phrases'

enum BranchName {
  Done,
  Undone
}

const fromHistory = Transaction.Effect.define<{ side: BranchName; startDoc: Plot.Doc; rest: Branch | null }>({
  map(value, change) {
    return {
      side: value.side,
      startDoc: change.apply(value.startDoc),
      rest: !value.rest ? null : value.rest.addMapping(change, value.startDoc)
    }
  }
})

interface HistoryConfig {
  /** The minimum depth (amount of events) to store. Defaults to 100. */
  minDepth?: number
  /**
   * The maximum time (in milliseconds) that adjacent events can be
   * apart and still be grouped together. Defaults to 500.
   */
  newGroupDelay?: number
  /**
   * By default, when close enough together in time, changes are
   * joined into an existing undo event if they touch any of the
   * changed ranges from that event. You can pass a custom predicate
   * here to influence that logic.
   */
  joinToEvent?: (tr: Transaction, isAdjacent: boolean) => boolean
}

const historyConfig = GardState.Facet.define<HistoryConfig, Required<HistoryConfig>>({
  combine(configs) {
    return GardState.Facet.combineConfig(
      configs,
      {
        minDepth: 100,
        newGroupDelay: 500,
        joinToEvent: (_t, isAdjacent) => isAdjacent
      },
      {
        minDepth: Math.max,
        newGroupDelay: Math.min,
        joinToEvent: (a, b) => (tr, adj) => a(tr, adj) || b(tr, adj)
      }
    )
  }
})

const historyField_ = GardState.Field.define({
  create() {
    return new HistoryState(null, null)
  },

  update(state: HistoryState, tr: Transaction): HistoryState {
    const config = tr.state.facet(historyConfig)

    const fromHist = tr.effects.find(e => e.is(fromHistory))
    if (fromHist) {
      const { side, rest } = fromHist.value,
        event = eventFromTransaction(tr)
      let other = side == BranchName.Done ? state.undone : state.done
      if (event) other = new Branch(event.changes, event.effects, null, tr.startState.selection, other)
      return new HistoryState(side == BranchName.Done ? rest : other, side == BranchName.Done ? other : rest)
    }

    const isolate = tr.annotation(history.isolate)
    if (isolate == true || isolate == 'before') state = state.isolate()

    if (tr.annotation(Transaction.addToHistory) === false) {
      return tr.changes.empty
        ? state
        : new HistoryState(
            state.done && state.done.addMapping(tr.changes, tr.startState.doc),
            state.undone && state.undone.addMapping(tr.changes, tr.startState.doc),
            state.prevTime,
            state.prevUserEvent
          )
    }

    const event = eventFromTransaction(tr)
    const time = tr.annotation(Transaction.time)!,
      userEvent = tr.annotation(Transaction.userEvent)
    if (event) state = state.addChanges(event, time, userEvent, config, tr)

    if (isolate == true || isolate == 'after') state = state.isolate()
    return state.clip(config.minDepth)
  },

  toJSON(value, state): history.JSON {
    const mkJSON = (value: Branch | null): history.EventJSON[] => {
      const events: { changes: ChangeSet.JSON; selection: unknown }[] = []
      for (let cur = value; cur; cur = cur.next) {
        events.push({ changes: cur.changes.toJSON(), selection: cur.startSelection.toJSON(state) })
      }
      return events
    }
    return {
      done: mkJSON((value.done = value.done && value.done.resolveFully(state.config))),
      undone: mkJSON((value.undone = value.undone && value.undone.resolveFully(state.config)))
    }
  },

  fromJSON(json: history.JSON, state: GardState) {
    if (!json || !Array.isArray(json.done) || !Array.isArray(json.undone)) throw new RangeError('Invalid history JSON')
    const buildBranch = (json: { changes: ChangeSet.JSON; selection: unknown }[]) => {
      let result: Branch | null = null
      for (let i = json.length - 1; i >= 0; i--) {
        result = new Branch(
          ChangeSet.fromJSON(state.schema, json[i]!.changes),
          none,
          null,
          GardSelection.fromJSON(state, json[i]!.selection),
          result
        )
      }

      return result
    }
    return new HistoryState(buildBranch(json.done), buildBranch(json.undone))
  }
})

/**
 * Create a history extension with the given configuration. Will
 * include the state field that tracks history, handlers for the
 * {@link undo} and {@link redo} commands that make use of it, and
 * the {@link undoButton undo}/{@link redoButton redo} menu buttons.
 */
export function history(config: HistoryConfig = {}): GardState.Extension {
  return [
    historyField_,
    historyConfig.of(config),
    Command.handler(undoCmd, undo),
    Command.handler(redoCmd, redo),
    undoButton,
    redoButton
  ]
}

export namespace history {
  /**
   * The state field used to store the history data. Should probably
   * only be used when you want to {@link GardState.toJSON serialize}
   * or {@link GardState.fromJSON deserialize} state objects in a
   * way that preserves history.
   */
  export const field = historyField_ as GardState.Field<unknown>

  /**
   * Transaction annotation that will prevent that transaction from
   * being combined with other transactions in the undo history. Given
   * `"before"`, it'll prevent merging with previous transactions. With
   * `"after"`, subsequent transactions won't be combined with this
   * one. With `true`, the transaction is isolated on both sides.
   */
  export const isolate = Transaction.Annotation.define<'before' | 'after' | true>()

  /**
   * This facet provides a way to register functions that, given a
   * transaction, provide a set of effects that the history should
   * store when inverting the transaction. This can be used to
   * integrate specific effects in the history, so that they can be
   * undone (and redone again).
   */
  export const invertedEffects = GardState.Facet.define<(tr: Transaction) => readonly Transaction.Effect<any>[]>()

  export type EventJSON = {
    changes: ChangeSet.JSON
    selection: unknown
  }

  export type JSON = {
    done: readonly EventJSON[]
    undone: readonly EventJSON[]
  }
}

/**
 * Undo a single group of history events. Returns false if no group
 * is available.
 */
export const undo: Command.Pure = ({ state }) => {
  const historyState = state.field(historyField_, false)
  if (state.readOnly || !historyState) return false
  return historyState.pop(BranchName.Done, state)
}

/**
 * Redo a single group of undone history events. Returns false if no
 * group is available.
 */
export const redo: Command.Pure = ({ state }) => {
  const historyState = state.field(historyField_, false)
  if (state.readOnly || !historyState) return false
  return historyState.pop(BranchName.Undone, state)
}

function depth(branch: Branch | null | undefined) {
  return branch ? branch.depth : 0
}

/** The amount of undoable change events available in a given state. */
export const undoDepth = (state: GardState) => depth(state.field(historyField_, false)?.done)

/** The amount of redoable change events available in a given state. */
export const redoDepth = (state: GardState) => depth(state.field(historyField_, false)?.undone)

// History branch events store groups of changes or effects that need
// to be undone/redone together. They form a linked list.
class Branch {
  depth: number

  constructor(
    // The changes in this event. It will hold at least one
    // change or effect.
    readonly changes: ChangeSet,
    // The effects associated with this event
    readonly effects: readonly Transaction.Effect<any>[],
    // Accumulated mapping (from addToHistory==false) that should be
    // applied to this event and those below. `doc` refers to the doc
    // that doesn't have this change yet, which is both the start doc
    // for the mapping change and `this.changes`, which is needed to
    // be able to perform further mapping on these.
    readonly mapped: { change: ChangeSet; doc: Plot.Doc } | null,
    // The selection before this event
    readonly startSelection: GardSelection,
    readonly next: Branch | null
  ) {
    this.depth = depth(next) + 1
  }

  // Assumes `this` is already resolved
  addChanges(changes: ChangeSet, effects: readonly Transaction.Effect<any>[]) {
    return new Branch(
      changes.compose(this.changes),
      conc(Transaction.Effect.mapEffects(effects, this.changes), this.effects),
      null,
      this.startSelection,
      this.next
    )
  }

  // Resolve this event's mapping, if any.
  resolve(config: GardState.Configuration): Branch | null {
    if (!this.mapped) return this
    const { change, doc } = this.mapped
    let { next } = this
    // Map the event's changes and mapped.change (which both start
    // from mapped.doc) over each other
    const { a: mappedMapping, b: mappedChanges } = ChangeSet.transform(doc, change, this.changes)
    // If there's more events below this, push the updated mapping down
    if (next) next = next.addMapping(mappedMapping, next.mapped ? null : this.changes.apply(doc))
    // If there's nothing left in this event, return the next one
    if (mappedChanges.empty && !this.effects.length) return next && next.resolve(config)
    // Map the effects over the original mapping, and the selection
    // (referring to the state before this event's changes) over the
    // updated mapping.
    let selDoc: Plot.Doc | undefined
    const selCx = {
      get doc() {
        return selDoc || (selDoc = mappedChanges.apply(change.apply(doc)))
      },
      config
    }
    return new Branch(
      mappedChanges,
      Transaction.Effect.mapEffects(this.effects, change),
      null,
      this.startSelection.map(mappedMapping, selCx),
      next
    )
  }

  // When serializing to JSON, we first fully resolve the whole history.
  resolveFully(config: GardState.Configuration): Branch | null {
    const stack: Branch[] = []
    for (let head = this.resolve(config); head; head = head.next ? head.next.resolve(config) : null) stack.push(head)
    let result: Branch | null = null
    for (let i = stack.length - 1; i >= 0; i--) {
      const next = stack[i]!
      if (next.next == result) result = next!
      else result = new Branch(next.changes, next.effects, null, next.startSelection, result)
    }
    return result
  }

  // Add a mapping to this change
  addMapping(change: ChangeSet, startDoc: Plot.Doc | null) {
    return new Branch(
      this.changes,
      this.effects,
      this.mapped ? { change: this.mapped.change.compose(change), doc: this.mapped.doc } : { change, doc: startDoc! },
      this.startSelection,
      this.next
    )
  }

  // Drop any events below the given depth
  clip(depth: number): Branch | null {
    if (depth <= 0) return null
    return new Branch(this.changes, this.effects, this.mapped, this.startSelection, this.next?.clip(depth - 1) ?? null)
  }
}

function eventFromTransaction(tr: Transaction): {
  changes: ChangeSet
  effects: readonly Transaction.Effect<any>[]
} | null {
  let effects: readonly Transaction.Effect<any>[] = none
  for (const invert of tr.startState.facet(history.invertedEffects)) {
    const result = invert(tr)
    if (result.length) effects = effects.concat(result)
  }
  if (!effects.length && tr.changes.empty) return null
  return { changes: tr.changes.invert(tr.startState.doc), effects }
}

// Check whether two change sets touch each other. The
// suspicious-looking use of before-positions in a and after-positions
// in b is because these will be inverted change sets.
function isAdjacent(a: ChangeSet, b: ChangeSet): boolean {
  const ranges: number[] = []
  let isAdjacent = false
  a.iterChangedRanges((f, t) => ranges.push(f, t))
  b.iterChangedRanges((_f, _t, f, t) => {
    for (let i = 0; i < ranges.length;) {
      const from = ranges[i++]!,
        to = ranges[i++]!
      if (t >= from && f <= to) isAdjacent = true
    }
  })
  return isAdjacent
}

function conc<T>(a: readonly T[], b: readonly T[]) {
  return !a.length ? b : !b.length ? a : a.concat(b)
}

const none: readonly any[] = []

const joinableUserEvent = /^(input\.type|delete)($|\.)/

class HistoryState {
  constructor(
    // These are only mutated when resolving in toJSON
    // The branch of undoable changes
    public done: Branch | null,
    // The branch of redoable changes
    public undone: Branch | null,
    // The time at which the last done event was created, or 0 if
    // nothing should be joined to it
    readonly prevTime: number = 0,
    // The user event that was last added to this.done
    readonly prevUserEvent: string | undefined = undefined
  ) {}

  isolate() {
    return this.prevTime ? new HistoryState(this.done, this.undone) : this
  }

  addChanges(
    event: { changes: ChangeSet; effects: readonly Transaction.Effect<any>[] },
    time: number,
    userEvent: string | undefined,
    config: Required<HistoryConfig>,
    tr: Transaction
  ): HistoryState {
    // Make sure the top of the done branch is resolved, so that we
    // can add changes without worrying about its mapping
    let done = this.done && this.done.resolve(tr.startState.config)
    // If possible, add the changes to the top event, otherwise start
    // a new event
    if (
      done &&
      !done.changes.empty &&
      (!userEvent || joinableUserEvent.test(userEvent) || tr.annotation(Transaction.appended)) &&
      ((time - this.prevTime < config.newGroupDelay &&
        config.joinToEvent(tr, isAdjacent(done.changes, event.changes))) ||
        // For compose (but not compose.start) events, always join with previous event
        userEvent == 'input.type.compose')
    ) {
      done = done.addChanges(event.changes, event.effects)
    } else {
      done = new Branch(event.changes, event.effects, null, tr.startState.selection, done)
    }
    return new HistoryState(done, null, time, userEvent)
  }

  pop(side: BranchName, state: GardState): Transaction.Spec | false {
    const branch = (side == BranchName.Done ? this.done : this.undone)?.resolve(state.config)
    if (!branch) return false
    return {
      changes: branch.changes,
      selection: branch.startSelection,
      effects: branch.effects.concat(
        fromHistory.of({ side, startDoc: branch.changes.apply(state.doc), rest: branch.next })
      ),
      userEvent: side == BranchName.Done ? 'undo' : 'redo',
      scrollIntoView: true
    }
  }

  clip(minDepth: number) {
    const max = minDepth * 1.3
    const done = depth(this.done) > max ? this.done!.clip(minDepth) : this.done
    const undone = depth(this.undone) > max ? this.undone!.clip(minDepth) : this.undone
    if (done != this.done || undone != this.undone) {
      return new HistoryState(done, undone, this.prevTime, this.prevUserEvent)
    }
    return this
  }
}

/** A menu button that undoes a change. */
export const undoButton = Menu.Button.define({
  run: undo,
  label: {
    icon: 'M69 90c9-16 10-41-24-40v20l-30-30 30-30v19c42-1 46 37 24 61z'
  },
  description: phrases.ref('undo'),
  enable: s => !s.readOnly && undoDepth(s) > 0,
  parent: Menu.Group.commands,
  rank: 10
})

/** A menu button that redoes an undone change. */
export const redoButton = Menu.Button.define({
  run: redo,
  label: {
    icon: 'M55 29v-19l30 30-30 30v-20c-35-1-33 24-24 40-22-24-17-62 24-61z'
  },
  description: phrases.ref('redo'),
  enable: s => !s.readOnly && redoDepth(s) > 0,
  parent: Menu.Group.commands,
  rank: 20
})
