import { ChangeSet, type Plot } from '../core/doc'
import { Wordgard } from '../core/editor'
import { GardState, Transaction } from '../core/state'
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
      const remote = ChangeSet.fromJSON(this.confirmed.schema, change.changes!)
      if (this.sent && change.client_id === this.options.clientID && change.client_seq === this.sent.sequence) {
        this.confirmed = remote.apply(this.confirmed)
        this.sent = undefined
      } else {
        let afterSent = this.confirmed
        let visible = remote
        if (this.sent) {
          afterSent = this.sent.changes.apply(this.confirmed)
          const transformed = ChangeSet.transform(this.confirmed, remote, this.sent.changes)
          visible = transformed.a
          this.sent.changes = transformed.b
        }
        const transformed = ChangeSet.transform(afterSent, visible, this.pending)
        this.pending = transformed.b
        this.confirmed = remote.apply(this.confirmed)
        this.applying = true
        try {
          const before = this.editor.state
          this.editor.dispatch({
            changes: transformed.a,
            annotations: Transaction.addToHistory.of(false),
            userEvent: 'remote'
          })
          // Two valid peer edits can exceed a document limit when combined.
          // Preserve this client's accepted draft instead of advancing an unapplied view.
          if (this.editor.state === before) return this.reset()
        } finally {
          this.applying = false
        }
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
  dispose() {
    this.disposed = true
    clearTimeout(this.timer)
  }
}
