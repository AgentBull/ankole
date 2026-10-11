import { GardState, Transaction, Correction } from '../state'
import { ChangeSet, Plot } from '../doc'

class LocalUpdate {
  constructor(
    readonly changes: ChangeSet,
    readonly effects: readonly Transaction.Effect<unknown>[]
  ) {}
}

function addUpdate(to: LocalUpdate | null, changes: ChangeSet, effects: readonly Transaction.Effect<unknown>[] = []) {
  if (changes.empty && !effects.length) return to
  if (!to) return new LocalUpdate(changes, effects)
  return new LocalUpdate(
    to.changes.compose(changes),
    Transaction.Effect.mapEffects(to.effects, changes).concat(effects)
  )
}

function mapOpenUpdate(update: LocalUpdate, doc: Plot.Doc, over: ChangeSet, accum: ChangeSet) {
  const { a, b } = ChangeSet.transform(doc, over, update.changes)
  return [new LocalUpdate(b, Transaction.Effect.mapEffects(update.effects, a)), accum.compose(a)] as const
}

class CollabState {
  constructor(
    // The version up to which changes have been confirmed.
    readonly version: number,
    // The document at version `this.version`.
    readonly syncedDoc: Plot.Doc,
    // A set of local unconfirmed changes that may have been sent to
    // the server. Because we cannot compose these with other changes
    // anymore once they may have been sent, reading these with
    // `sendableUpdate` will, via a side effect, lock them.
    public nextUpdate: LocalUpdate | null,
    // Local unconfirmed changes that have not been locked yet. New
    // transactions will be added to this.
    public openUpdate: LocalUpdate | null
  ) {}
}

const collabConfig = GardState.Facet.define<collab.Config & { generatedID: string }, Required<collab.Config>>({
  combine(configs) {
    const combined = GardState.Facet.combineConfig(
      configs,
      {
        startVersion: 0,
        clientID: null as any,
        sharedEffects: () => [],
        corrections: []
      },
      {
        generatedID: a => a
      }
    )
    if (combined.clientID == null) combined.clientID = (configs.length && configs[0]!.generatedID) || ''
    return combined
  }
})

const collabReceive = Transaction.Effect.define<CollabState>({
  map(state, changes) {
    // This is used to make sure changes added to collab receive
    // transactions by extenders still get stored as unconfirmed.
    return changes.empty
      ? state
      : new CollabState(state.version, state.syncedDoc, state.nextUpdate, addUpdate(state.openUpdate, changes))
  }
})

const collabField = GardState.Field.define({
  create(state) {
    return new CollabState(state.facet(collabConfig).startVersion, state.doc, null, null)
  },

  update(collab: CollabState, tr: Transaction) {
    for (const e of tr.effects) if (e.is(collabReceive)) return e.value
    const { sharedEffects } = tr.startState.facet(collabConfig)
    const effects = sharedEffects(tr)
    if (effects.length || !tr.changes.empty) {
      return new CollabState(
        collab.version,
        collab.syncedDoc,
        collab.nextUpdate,
        addUpdate(collab.openUpdate, tr.changes, effects)
      )
    }
    return collab
  }
})

/** Create an instance of the collaborative editing plugin. */
export function collab(config: collab.Config = {}): GardState.Extension {
  return [collabField, collabConfig.of({ generatedID: Math.floor(Math.random() * 1e15).toString(36), ...config })]
}

export namespace collab {
  /** Options to {@link collab}. */
  export type Config = {
    /** The starting document version. Defaults to 0. */
    startVersion?: number
    /**
     * This client's identifying {@link collab.getClientID ID}. Will be a
     * randomly generated string if not provided.
     */
    clientID?: string
    /**
     * A set of corrections to apply to transformed changes. Can be
     * used to enforce document shapes even in merged changes.
     * Requires the exact same set, in the same order, to be used on
     * the server.
     */
    corrections?: readonly Correction[]
    /**
     * It is possible to share information other than document changes
     * through this extension. If you provide this option, your
     * function will be called on each transaction, and the effects it
     * returns will be sent to the server, much like changes are. Such
     * effects are automatically remapped when conflicting remote
     * changes come in.
     */
    sharedEffects?: (tr: Transaction) => readonly Transaction.Effect<any>[]
  }

  /** An update is a set of changes and effects. */
  export interface Update {
    /** The document version that this update starts from. */
    version: number
    /**
     * The {@link collab.Config.clientID ID} of the client who
     * created this update.
     */
    clientID: string
    /** The changes made by this update. */
    changes: ChangeSet
    /**
     * The effects in this update. There'll only ever be effects here
     * when you configure your collab extension with a {@link
     * collab.Config.sharedEffects `sharedEffects`} option.
     */
    effects?: readonly Transaction.Effect<unknown>[]
  }

  /**
   * Create a transaction that represents a set of new updates received
   * from the authority. Applying this transaction moves the state
   * forward to, for remote changes, integrate them into our local
   * state, and for our own changes, drop them from the set of
   * unconfirmed local changes.
   */
  export function receive(state: GardState, updates: readonly collab.Update[]) {
    let { version, syncedDoc, nextUpdate, openUpdate } = state.field(collabField)
    const { clientID, corrections } = state.facet(collabConfig)

    let changes = ChangeSet.empty(state.doc.length)
    let effects: readonly Transaction.Effect<unknown>[] = []

    let haveRemote = false
    for (const update of updates) {
      if (update.version != version) throw new Error('Version mismatch in in received collab update')
      if (update.clientID == clientID) {
        if (!nextUpdate) throw new Error('Received unknown update with our client ID')
        syncedDoc = openUpdate || haveRemote ? nextUpdate.changes.apply(syncedDoc) : state.doc
        mismatch: if (!nextUpdate.changes.eq(update.changes)) {
          if (haveRemote && nextUpdate && corrections.length) {
            const correct = Correction.check(nextUpdate.changes, syncedDoc, corrections)
            if (correct && nextUpdate.changes.compose(correct).eq(update.changes)) {
              if (openUpdate) [openUpdate, changes] = mapOpenUpdate(openUpdate, syncedDoc, correct, changes)
              else changes = changes.compose(correct)
              syncedDoc = correct.apply(syncedDoc)
              break mismatch
            }
          }
          throw new Error("Received update with our client ID doesn't match our own local update")
        }
        nextUpdate = null
      } else {
        let newChanges = update.changes,
          newEffects = update.effects || []
        let baseDoc = syncedDoc
        if (nextUpdate) {
          const { a, b } = ChangeSet.transform(baseDoc, newChanges, nextUpdate.changes)
          if (openUpdate) baseDoc = nextUpdate.changes.apply(baseDoc)
          nextUpdate = new LocalUpdate(b, Transaction.Effect.mapEffects(nextUpdate.effects, a))
          newChanges = a
          newEffects = Transaction.Effect.mapEffects(newEffects, b)
        }
        if (openUpdate) {
          const { a, b } = ChangeSet.transform(baseDoc, newChanges, openUpdate.changes)
          openUpdate = new LocalUpdate(b, Transaction.Effect.mapEffects(openUpdate.effects, a))
          newChanges = a
          newEffects = Transaction.Effect.mapEffects(newEffects, b)
        }
        changes = changes.compose(newChanges)
        effects = Transaction.Effect.mapEffects(effects, newChanges).concat(newEffects)
        syncedDoc = update.changes.apply(syncedDoc)
        haveRemote = true
      }
      version++
    }

    if (haveRemote && corrections.length) {
      let base = syncedDoc
      if (nextUpdate) {
        base = nextUpdate.changes.apply(base)
        const correct = Correction.check(nextUpdate.changes, base, corrections)
        if (correct) {
          nextUpdate = addUpdate(nextUpdate, correct)
          if (openUpdate) {
            ;[openUpdate, changes] = mapOpenUpdate(openUpdate, base, correct, changes)
            base = correct.apply(base)
          } else {
            changes = changes.compose(correct)
          }
        }
      }
      if (openUpdate) {
        base = openUpdate.changes.apply(base)
        const correct = Correction.check(openUpdate.changes, base, corrections)
        if (correct) {
          openUpdate = addUpdate(openUpdate, correct)
          changes = changes.compose(correct)
        }
      }
    }

    return state.update({
      changes,
      effects: effects.concat(collabReceive.of(new CollabState(version, syncedDoc, nextUpdate, openUpdate))),
      annotations: [Transaction.addToHistory.of(false), Transaction.remote.of(true)]
    })
  }

  /**
   * If there are unconfirmed local changes that need to be sent to the
   * server,return them as an `Update` object.
   */
  export function sendableUpdate(state: GardState): collab.Update | null {
    const collab = state.field(collabField)
    if (!collab.nextUpdate) {
      if (!collab.openUpdate) return null
      collab.nextUpdate = collab.openUpdate
      collab.openUpdate = null
    }
    return {
      version: collab.version,
      clientID: getClientID(state),
      changes: collab.nextUpdate.changes,
      effects: collab.nextUpdate.effects
    }
  }

  /** Returns true if there are unconfirmed changes for this editor. */
  export function hasUnsentUpdate(state: GardState): boolean {
    const collab = state.field(collabField)
    return !!(collab.nextUpdate || collab.openUpdate)
  }

  /**
   * Get the version up to which the collab plugin has synced with the
   * central authority.
   */
  export function getSyncedVersion(state: GardState) {
    return state.field(collabField).version
  }

  /** Get this editor's collaborative editing client ID. */
  export function getClientID(state: GardState) {
    return state.facet(collabConfig).clientID
  }

  /**
   * Transform an update that arrives on the server with an outdated
   * start version. Being able to do this requires tracking a
   * document history server-side. It is not necessary to do this,
   * but it helps a lot with “starvation” problems, where slower
   * clients or clients with a high ping can, in a busy document,
   * keep losing the race to submit their changes to other, faster
   * clients.
   */
  export function transformUpdate(
    update: collab.Update,
    over: readonly { doc: Plot.Doc; changes: ChangeSet; clientID: string }[],
    corrections?: readonly Correction[]
  ): collab.Update | null {
    if (!over.length) return update
    const { clientID } = update
    let { version, changes, effects } = update
    for (const other of over) {
      if (other.clientID == clientID) return null
      if (effects && effects.length) {
        effects = Transaction.Effect.mapEffects(effects, other.changes.transform(other.doc, changes, true))
      }
      changes = changes.transform(other.doc, other.changes)
      version++
    }
    if (corrections && corrections.length) {
      const corrected = Correction.check(changes, changes.apply(over[over.length - 1]!.doc), corrections)
      if (corrected) {
        changes = changes.compose(corrected)
        if (effects) effects = Transaction.Effect.mapEffects(effects, corrected)
      }
    }
    return { clientID, version, changes, effects }
  }
}
