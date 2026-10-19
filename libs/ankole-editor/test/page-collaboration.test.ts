import { describe, expect, test } from 'bun:test'
import { ChangeSet, Leaf, type Plot } from '../src/core/doc'
import { Wordgard } from '../src/core/editor'
import { Transaction } from '../src/core/state'
import { parseXml, printXml } from '../src/document/xml'
import { headlessState } from '../src/editor/extension'
import { pageDocument, readTree } from '../src/editor/convert'
import { Paragraph } from '../src/core/types'
import { insertImage, undo } from '../src/editor/commands'
import { limits } from '../src/document/tree'
import { PageCollaboration, type PageChange, type PageChangeRequest } from '../src/editor/page-collaboration'

/** This view adapter uses the production state, appenders, changes and transaction listeners. */
function editor(xml = '<page><p>base</p></page>', guarded = false): Wordgard {
  const view = {
    state: headlessState(parseXml(xml)),
    composing: false,
    dispatch(spec: Transaction | Transaction.Spec) {
      const transactions = Transaction.append(spec instanceof Transaction ? spec : view.state.update(spec))
      if (guarded) {
        try {
          for (const guard of view.state.facet(Wordgard.transactionGuard)) {
            guard(transactions, view as unknown as Wordgard)
          }
        } catch {
          return
        }
      }
      view.state = transactions.at(-1)!.state
      for (const listener of view.state.facet(Wordgard.transactionListener)) {
        listener(transactions, view as unknown as Wordgard)
      }
    }
  }
  return view as unknown as Wordgard
}
const waitFor = async (test: () => boolean) => {
  const deadline = Date.now() + 2500
  while (!test()) {
    if (Date.now() > deadline) throw new Error('Collaboration did not settle')
    await Bun.sleep(10)
  }
}
const xmlOf = (view: Wordgard) => printXml(readTree(view.state.doc))

describe('production OT client', () => {
  test('image insertion keeps the current surrounding text and its metadata', () => {
    const view = editor()
    view.dispatch({ selection: { anchor: 3 } })
    expect(insertImage(view, { src: 'ankole:asset/digest/image.png', alt: '说明', title: '标题' })).toBe(true)
    expect(xmlOf(view)).toBe(
      '<page><p>ba<img alt="说明" src="ankole:asset/digest/image.png" title="标题" />se</p></page>'
    )
    expect(undo(view)).toBe(true)
    expect(xmlOf(view)).toBe('<page><p>base</p></page>')
  })

  test('a limit failure is visible and a repaired live draft can save', async () => {
    const view = editor()
    let failure: unknown,
      calls = 0
    const client = new PageCollaboration(view, 0, {
      clientID: 'limits',
      changed(state) {
        failure = state.error
      },
      reset() {},
      sync() {},
      async send(request) {
        calls++
        return {
          revision: 1,
          changes: [
            {
              revision: 1,
              kind: 'change',
              client_id: 'limits',
              client_seq: request.client_seq,
              changes: request.changes
            }
          ]
        }
      }
    })
    view.dispatch({ changes: { from: 1, insert: [Leaf.text('x'.repeat(limits.source))] } })
    await waitFor(() => Boolean(failure))
    expect(calls).toBe(0)
    view.dispatch({ selection: { anchor: 2 } })
    expect(failure).toBeInstanceOf(Error)
    expect(view.state.doc.length).toBeGreaterThan(limits.source)
    view.dispatch({ changes: { from: 1, to: limits.source + 1, insert: [Leaf.text('fixed ')] } })
    await waitFor(() => client.currentRevision() === 1)
    expect(failure).toBeUndefined()
    expect(xmlOf(view)).toBe('<page><p>fixed base</p></page>')
    client.dispose()
  })

  test('a reset with an invalid draft preserves the editable document and reports the error', () => {
    const view = editor()
    let failure: unknown,
      resets = 0
    const client = new PageCollaboration(view, 0, {
      clientID: 'limits',
      changed(state) {
        failure = state.error
      },
      reset() {
        resets++
      },
      sync() {},
      async send() {
        throw new Error('not sent')
      }
    })
    view.dispatch({
      changes: {
        from: 0,
        to: view.state.doc.length,
        insert: Array.from({ length: limits.nodes }, () => Paragraph.create([]))
      }
    })
    client.receive({ revision: 1, changes: [{ revision: 1, kind: 'reset' }] })
    expect(resets).toBe(0)
    expect(failure).toBeInstanceOf(Error)
    expect(view.state.doc.content.length).toBe(limits.nodes)
    client.dispose()
  })

  test('two individually valid edits that exceed the combined limit preserve the local draft', () => {
    const xml = `<page><p>${'x'.repeat(limits.source - '<page><p></p></page>'.length - 2)}</p></page>`
    const view = editor(xml, true)
    const initial = view.state
    const remote = initial.update({ changes: { from: 1, insert: [Leaf.text('BB')] } }).changes
    let draft: string | null | undefined
    let sent = 0
    const client = new PageCollaboration(view, 0, {
      clientID: 'local',
      changed() {},
      reset(value) {
        draft = value
      },
      sync() {},
      async send() {
        sent++
        throw new Error('not sent')
      }
    })
    view.dispatch({ changes: { from: 1, insert: [Leaf.text('A')] } })
    const accepted = view.state
    client.receive({
      revision: 1,
      changes: [{ revision: 1, kind: 'change', client_id: 'other', client_seq: 1, changes: remote.toJSON() }]
    })
    expect(view.state).toBe(accepted)
    expect(draft?.length).toBe(limits.source - 1)
    expect(draft?.startsWith('<page><p>A')).toBe(true)
    expect(draft?.includes('BB')).toBe(false)
    expect(sent).toBe(0)
    client.dispose()
  })

  test('two concurrent clients rebase an old base and converge with server storage', async () => {
    const a = editor(),
      b = editor()
    let document: Plot.Doc = a.state.doc
    const log: PageChange[] = []
    const clients: PageCollaboration[] = []
    const send = async (request: PageChangeRequest) => {
      if (
        !log.some(change => change.client_id === request.client_id && change.client_seq === request.client_seq) &&
        request.base_revision === log.length
      ) {
        const changes = ChangeSet.fromJSON(document.schema, request.changes)
        document = changes.apply(document)
        log.push({
          revision: log.length + 1,
          kind: 'change',
          client_id: request.client_id,
          client_seq: request.client_seq,
          changes: request.changes
        })
      }
      const response = { revision: log.length, changes: log.filter(change => change.revision > request.base_revision) }
      queueMicrotask(() => {
        for (const client of clients) client.receive({ revision: log.length, changes: log })
      })
      return response
    }
    let reset = false
    for (const [view, id] of [
      [a, 'a'],
      [b, 'b']
    ] as const) {
      clients.push(
        new PageCollaboration(view, 0, {
          clientID: id,
          send,
          changed() {},
          reset() {
            reset = true
          },
          sync() {}
        })
      )
    }
    a.dispatch({ changes: { from: 1, insert: [Leaf.text('A')] } })
    b.dispatch({ changes: { from: 1, insert: [Leaf.text('B')] } })
    await waitFor(() => clients.every(client => client.currentRevision() === 2))
    expect(reset).toBe(false)
    expect(xmlOf(a)).toBe(xmlOf(b))
    expect(xmlOf(a)).toBe(printXml(readTree(document)))
    for (const client of clients) client.dispose()
  })

  test('lost acknowledgement retries the same prepared payload and commits once', async () => {
    const view = editor()
    let first: PageChangeRequest | undefined,
      calls = 0
    const client = new PageCollaboration(view, 0, {
      clientID: 'a',
      changed() {},
      reset() {},
      sync() {},
      async send(request) {
        calls++
        if (!first) {
          first = structuredClone(request)
          throw new Error('acknowledgement lost')
        }
        expect(request).toEqual(first)
        return {
          revision: 1,
          changes: [
            { revision: 1, kind: 'change', client_id: 'a', client_seq: request.client_seq, changes: first.changes }
          ]
        }
      }
    })
    view.dispatch({ changes: { from: 1, insert: [Leaf.text('once')] } })
    await waitFor(() => client.currentRevision() === 1)
    expect(calls).toBe(2)
    expect(xmlOf(view)).toBe('<page><p>oncebase</p></page>')
    client.dispose()
  })

  test('an Agent reset preserves unconfirmed local work without transforming across it', () => {
    const view = editor()
    let draft: string | null | undefined
    const client = new PageCollaboration(view, 0, {
      clientID: 'a',
      async send() {
        throw new Error('not sent')
      },
      changed() {},
      reset(value) {
        draft = value
      },
      sync() {}
    })
    view.dispatch({ changes: { from: 1, insert: [Leaf.text('draft ')] } })
    client.receive({ revision: 1, changes: [{ revision: 1, kind: 'reset' }] })
    expect(draft).toBe('<page><p>draft base</p></page>')
    expect(client.currentRevision()).toBe(0)
  })

  test('edits after a commit broadcast are sent when its original request times out', async () => {
    const view = editor()
    let document = view.state.doc
    const log: PageChange[] = []
    let rejectAcknowledgement!: (error: Error) => void
    let calls = 0
    const client = new PageCollaboration(view, 0, {
      clientID: 'broadcast-before-timeout',
      changed() {},
      reset() {},
      sync() {},
      async send(request) {
        calls++
        expect(request.base_revision).toBe(log.length)
        document = ChangeSet.fromJSON(document.schema, request.changes).apply(document)
        log.push({
          revision: log.length + 1,
          kind: 'change',
          client_id: request.client_id,
          client_seq: request.client_seq,
          changes: request.changes
        })
        if (calls === 1) {
          return new Promise((_resolve, reject) => {
            rejectAcknowledgement = reject
          })
        }
        return { revision: log.length, changes: log.slice(request.base_revision) }
      }
    })
    try {
      view.dispatch({ changes: { from: 1, insert: [Leaf.text('A')] } })
      await waitFor(() => calls === 1)
      client.receive({ revision: 1, changes: [...log] })
      view.dispatch({ changes: { from: 2, insert: [Leaf.text('B')] } })
      // Let the edit timer run while the original request still occupies the transport.
      await Bun.sleep(80)
      rejectAcknowledgement(new Error('acknowledgement timed out'))
      await waitFor(() => client.currentRevision() === 2)
      expect(calls).toBe(2)
      expect(printXml(readTree(document))).toBe('<page><p>ABbase</p></page>')
      expect(xmlOf(view)).toBe(printXml(readTree(document)))
    } finally {
      client.dispose()
    }
  })

  test('an explicitly rejected old base is prepared again after a noncanonical transform', async () => {
    const view = editor('<page><p>stay</p><pre>a</pre></page>')
    const removal = ChangeSet.fromJSON(view.state.schema, [6, [3, []]])
    let document = removal.apply(view.state.doc)
    let calls = 0
    const client = new PageCollaboration(view, 0, {
      clientID: 'b',
      changed() {},
      reset() {},
      sync() {},
      async send(request) {
        calls++
        if (calls === 1) {
          return {
            revision: 1,
            changes: [{ revision: 1, kind: 'change', client_id: 'a', client_seq: 1, changes: removal.toJSON() }]
          }
        }
        const changed = ChangeSet.fromJSON(document.schema, request.changes).apply(document)
        const canonical = pageDocument(parseXml(printXml(readTree(changed))))
        expect(changed.eq(canonical)).toBe(true)
        document = changed
        return {
          revision: 2,
          changes: [
            { revision: 2, kind: 'change', client_id: 'b', client_seq: request.client_seq, changes: request.changes }
          ]
        }
      }
    })
    view.dispatch({ changes: ChangeSet.fromJSON(view.state.schema, [7, [0, [{ type: 'Text', param: '\r' }]], 2]) })
    await waitFor(() => client.currentRevision() === 2)
    expect(xmlOf(view)).toBe(printXml(readTree(document)))
    expect(view.state.doc.eq(pageDocument(parseXml(xmlOf(view))))).toBe(true)
    expect(calls).toBe(2)
    client.dispose()
  })
})
