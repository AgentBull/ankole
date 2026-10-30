import { ChangeSet, type Plot } from '../core/doc'
import { Wordgard } from '../core/editor'
import { Correction, GardState, Transaction } from '../core/state'
import { pageCorrections } from './corrections'
import { preparePageUpdate, validatedPageSource } from './page-update'

export type PageChange = {
  revision: number
  kind: 'change' | 'reset'
  client_id?: string
  client_seq?: number
  changes?: ChangeSet.JSON
}
export type PageChanges = {
  revision: number
  acknowledged_revision?: number
  changes: PageChange[]
  reset_required?: boolean
}
export type PageChangeRequest = {
  base_revision: number
  client_id: string
  client_seq: number
  changes: ChangeSet.JSON
}
export type CollaborationState = { revision: number; xml: string; pending: boolean; error?: unknown }
type Sent = { sequence: number; changes: ChangeSet; request: PageChangeRequest }

/** One in-flight batch, followed by local edits. The server alone orders committed batches. */
export class PageCollaboration {
  private confirmed: Plot.Doc
  private pending: ChangeSet
  private sent?: Sent
  private sequence = 0
  private applying = false
  private disposed = false
  private pushing = false
  private timer?: ReturnType<typeof setTimeout>
  private revision: number

  constructor(
    private editor: Wordgard,
    revision: number,
    private options: {
      clientID: string
      send(request: PageChangeRequest): Promise<PageChanges>
      changed(state: CollaborationState): void
      reset(draft: string | null): void
      sync(): void
    }
  ) {
    this.revision = revision
    this.confirmed = editor.state.doc
    this.pending = ChangeSet.empty(this.confirmed.length)
    editor.dispatch({
      effects: GardState.appendConfig.of(
        Wordgard.transactionListener.of(transactions => {
          if (this.disposed || this.applying || !transactions.some(transaction => transaction.docChanged)) return
          for (const transaction of transactions) {
            if (transaction.docChanged) this.pending = this.pending.compose(transaction.changes)
          }
          this.publish()
          this.schedule()
        })
      )
    })
    this.publish()
  }

  private publish(error?: unknown) {
    this.options.changed({
      revision: this.revision,
      xml: validatedPageSource(this.confirmed).xml,
      pending: !!this.sent || !this.pending.empty,
      error
    })
  }

  private schedule(delay = 30) {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      void this.flush()
    }, delay)
  }

  private async flush() {
    if (this.disposed || this.pushing) return
    if (!this.sent) {
      if (this.pending.empty) return
      if (this.editor.composing) {
        this.schedule()
        return
      }
      try {
        // Input appenders have finished. Apply N to memory and include its correction in this batch.
        const correction = preparePageUpdate(this.editor.state.update({}))
        if (correction.docChanged) this.editor.dispatch(correction)
        const changes = this.pending
        const sequence = ++this.sequence
        this.sent = {
          sequence,
          changes,
          request: {
            base_revision: this.revision,
            client_id: this.options.clientID,
            client_seq: sequence,
            changes: changes.toJSON()
          }
        }
        this.pending = ChangeSet.empty(this.editor.state.doc.length)
      } catch (error) {
        // Invalid local content must be repaired before it can become a request.
        this.publish(error)
        return
      }
    }
    const sent = this.sent
    let delay: number | undefined = 30
    this.pushing = true
    try {
      const response = await this.options.send(sent.request)
      if (this.disposed) return
      if (this.receive(response) === false) {
        delay = undefined
        return
      }
      if (this.disposed) return
      if (this.sent === sent) {
        // The response proves that this batch was not committed. Transform can leave N's normal
        // form, so prepare the rebased local work again before a new sequence is submitted.
        this.pending = sent.changes.compose(this.pending)
        this.sent = undefined
      }
      this.publish()
    } catch (error) {
      delay = 1000
      if (!this.disposed) this.publish(error)
    } finally {
      this.pushing = false
      // A broadcast may acknowledge this request while later edits wait for its transport slot.
      if (!this.disposed && delay !== undefined && (this.sent || !this.pending.empty)) this.schedule(delay)
    }
  }

  receive(response: PageChanges) {
    if (this.disposed) return
    if (response.reset_required) {
      return this.reset()
    }
    for (const change of [...response.changes].sort((a, b) => a.revision - b.revision)) {
      if (change.revision <= this.revision) continue
      if (change.revision !== this.revision + 1) {
        this.options.sync()
        return
      }
      if (change.kind === 'reset') {
        return this.reset()
      }
      try {
        const remote = ChangeSet.fromJSON(this.confirmed.schema, change.changes!)
        if (this.sent && change.client_id === this.options.clientID && change.client_seq === this.sent.sequence) {
          this.confirmed = remote.apply(this.confirmed)
          this.sent = undefined
        } else {
          const nextConfirmed = remote.apply(this.confirmed)
          const local = this.localChanges()
          // Positional OT cannot follow an edit into a container that another writer
          // deleted or replaced. Keep the draft through the host's existing recovery flow.
          if (
            replacesEditedContainer(this.confirmed, remote, local) ||
            replacesEditedContainer(this.confirmed, local, remote)
          ) {
            return this.reset()
          }
          let afterSent = this.confirmed
          let visible = remote
          let nextSentChanges = this.sent?.changes
          if (this.sent) {
            afterSent = this.sent.changes.apply(this.confirmed)
            const transformed = ChangeSet.transform(this.confirmed, remote, this.sent.changes)
            visible = transformed.a
            nextSentChanges = transformed.b
          }
          const transformed = ChangeSet.transform(afterSent, visible, this.pending)
          this.applying = true
          try {
            const before = this.editor.state
            const incoming = before.update({
              changes: transformed.a,
              annotations: [Transaction.remote.of(true), Transaction.addToHistory.of(false)],
              userEvent: 'remote'
            })
            // A rebase can make two individually valid edits violate the page's rules.
            // Own the repair as local pending work, while mapping the visible selection
            // and undo history through the complete incoming transaction only once.
            const correction = preparePageUpdate(
              incoming.state.update({
                changes: Correction.check(incoming.changes, incoming.newDoc, pageCorrections) ?? []
              })
            )
            const nextPending = transformed.b.compose(correction.changes)
            this.editor.dispatch(
              before.update(Transaction.merge(before, incoming, { changes: correction.changes, sequential: true }))
            )
            // Two valid peer edits can exceed a document limit when combined.
            // Preserve this client's accepted draft instead of advancing an unapplied view.
            if (this.editor.state === before) return this.reset()
            if (this.sent && nextSentChanges) this.sent.changes = nextSentChanges
            this.pending = nextPending
            this.confirmed = nextConfirmed
          } finally {
            this.applying = false
          }
        }
      } catch (error) {
        this.publish(error)
        return this.reset()
      }
      this.revision = change.revision
    }
    if (response.revision > this.revision) this.options.sync()
    this.publish()
    this.schedule()
  }

  private reset() {
    try {
      const draft = this.sent || !this.pending.empty ? validatedPageSource(this.editor.state.doc).xml : null
      this.dispose()
      this.options.reset(draft)
      return true
    } catch (error) {
      // Keep the live draft editable when it cannot yet be exported, for example after a limit violation.
      this.publish(error)
      return false
    }
  }

  currentRevision() {
    return this.revision
  }

  /** Express this view's selection in the confirmed document's coordinate system. */
  selectionToConfirmed(selection: { anchor: number; head: number }) {
    const changes = this.localChanges().invert(this.confirmed)
    return { revision: this.revision, ...mapSelection(selection, changes) }
  }

  /** A peer selection is meaningful only at the exact revision it names. */
  selectionFromConfirmed(selection: { revision: number; anchor: number; head: number }) {
    if (
      selection.revision !== this.revision ||
      ![selection.anchor, selection.head].every(
        position => Number.isSafeInteger(position) && position >= 0 && position <= this.confirmed.length
      )
    ) {
      return null
    }
    return mapSelection(selection, this.localChanges())
  }

  private localChanges() {
    return this.sent ? this.sent.changes.compose(this.pending) : this.pending
  }
  dispose() {
    this.disposed = true
    clearTimeout(this.timer)
  }
}

function replacesEditedContainer(document: Plot.Doc, replacement: ChangeSet, edits: ChangeSet): boolean {
  if (replacement.empty || edits.empty) return false
  let conflict = false
  replacement.iterChanges((from, to, fromB, toB) => {
    if (conflict || from === to) return
    const pureDelete = fromB === toB
    document.iterate(from, to, (node, pos) => {
      if (conflict) return false
      if (!node.isPlot || pos < from || pos + node.length > to) return
      const end = pos + node.length
      edits.iterChanges((editFrom, editTo, editFromB, editToB) => {
        if (editFrom >= end || editTo <= pos) return
        if (pureDelete && editFromB === editToB && editFrom <= pos && editTo >= end) return
        conflict = true
      })
      return false
    })
  })
  return conflict
}

function mapSelection(selection: { anchor: number; head: number }, changes: ChangeSet) {
  const forward = selection.anchor <= selection.head
  return {
    anchor: changes.mapPos(selection.anchor, forward ? 1 : -1),
    head: changes.mapPos(selection.head, selection.anchor === selection.head || !forward ? 1 : -1)
  }
}
