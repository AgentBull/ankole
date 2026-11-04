import structuralDiffs from '../corpus/rust/structural-diffs.json'
import draftRebase from '../corpus/rust/draft-rebase.json'
import { describe, expect, test } from 'bun:test'
import { ChangeSet, Leaf, type Plot } from '../src/core/doc'
import { Wordgard } from '../src/core/editor'
import { Transaction } from '../src/core/state'
import { parseXml, printXml } from '../src/document/xml'
import { headlessState } from '../src/editor/extension'
import { pageDocument, readTree } from '../src/editor/convert'
import { Paragraph, Strong } from '../src/core/types'
import { insertImage, redo, toggleFormat, undo } from '../src/editor/commands'
import { Align, ListItem } from '../src/editor/schema'
import { limits } from '../src/document/tree'
import { PageCollaboration, type PageChange, type PageChangeRequest } from '../src/editor/page-collaboration'
import { trackCommentSelection } from '../src/editor/comments'
import { blockChange, deleteBlock } from '../src/editor/block-actions'
import { changeTable, editableTable, type TableAction } from '../src/editor/tables'
import { Command, enter, insertText } from '../src/core/command'
import { BlockSelection } from '../src/editor/block-selection'
import { eventHandler } from '../src/core/editor/input'
import { endComposition, exportMarkdown } from './helpers'
import { undoDepth } from '../src/core/history'

/** This view adapter uses the production state, appenders, changes and transaction listeners. */
function editor(xml = '<page><p>base</p></page>', guarded = false): Wordgard {
  const view = {
    state: headlessState(parseXml(xml)),
    composing: false,
    connected: true,
    focus() {},
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
const composingColumns =
  '<page><p>Before</p><columns><column><p>A</p><p>Keep</p></column><column><p>B</p></column></columns><p>After</p></page>'
function textAt(document: Plot.Doc, text: string): number {
  let found = -1
  document.iterate((node, pos) => {
    if (node.isText && node.param === text) found = pos
  })
  if (found < 0) throw new Error(`Missing text: ${text}`)
  return found
}
function beginColumnComposition(view: Wordgard) {
  Object.assign(view, { composing: true })
  view.dispatch({
    selection: BlockSelection.of(view.state.doc, [textAt(view.state.doc, 'A') - 1, textAt(view.state.doc, 'B') - 1])!
  })
  expect(
    Command.dispatch(view, insertText, {
      ...view.state.selection.replacementRange,
      insert: 'zh',
      userEvent: 'input.type.compose.start'
    })
  ).toBe(true)
  expect(view.state.sel.head.parent.parent!.node.name).toBe('Column')
}
function finishColumnComposition(view: Wordgard, cancel = false, endEvent = true) {
  const host = view.state.sel.head.parent
  Command.dispatch(view, insertText, {
    from: host.start,
    to: host.end,
    insert: cancel ? '' : '中',
    userEvent: 'input.type.compose'
  })
  endComposition(view)
  if (endEvent) for (const handler of view.state.facet(eventHandler).compositionend ?? []) handler({} as Event, view)
}

/** Unit transport: two production clients, server ordering and canonical wire validation. */
function peers(xml: string) {
  const views = [editor(xml, true), editor(xml, true)] as const
  let document = views[0].state.doc
  const log: PageChange[] = []
  const failures: unknown[] = []
  const recoveries: { index: number; draft: string | null }[] = []
  const pending = [false, false]
  const clients = views.map(
    (view, index) =>
      new PageCollaboration(view, 0, {
        clientID: `peer-${index}`,
        changed(state) {
          pending[index] = state.pending
          if (state.error) failures.push(state.error)
        },
        reset(draft) {
          recoveries.push({ index, draft })
          failures.push(new Error('Unexpected document reset'))
        },
        sync() {},
        async send(request) {
          // Both clients can have a batch in flight before the first commit returns.
          await Bun.sleep(10)
          if (
            !log.some(change => change.client_id === request.client_id && change.client_seq === request.client_seq) &&
            request.base_revision === log.length
          ) {
            const changed = ChangeSet.fromJSON(document.schema, request.changes).apply(document)
            expect(changed.eq(pageDocument(parseXml(printXml(readTree(changed)))))).toBe(true)
            document = changed
            log.push({
              revision: log.length + 1,
              kind: 'change',
              client_id: request.client_id,
              client_seq: request.client_seq,
              changes: request.changes
            })
          }
          const response = { revision: log.length, changes: log.slice(request.base_revision) }
          for (const client of clients) client.receive({ revision: log.length, changes: [...log] })
          return response
        }
      })
  )
  return {
    views,
    clients,
    recoveries,
    committedXML: () => printXml(readTree(document)),
    async settle() {
      await waitFor(
        () => pending.every(value => !value) && clients.every(client => client.currentRevision() === log.length)
      )
      expect(failures).toEqual([])
      for (const view of views) expect(view.state.doc.eq(document)).toBe(true)
      return printXml(readTree(document))
    },
    dispose() {
      for (const client of clients) client.dispose()
    }
  }
}

describe('production OT client', () => {
  for (const remoteTarget of [null, 'first', 'After']) {
    test(`empty list composition still finishes after remote ${remoteTarget ?? 'no edit'}`, async () => {
      const original = '<page><ul><li><p>first</p></li><li /></ul><p>After</p></page>'
      const network = peers(original)
      const [view, peer] = network.views
      try {
        let itemStart = -1
        view.state.doc.iterate((node, pos) => {
          if (node.type === ListItem.type && node.isPlot && !node.content.length) itemStart = pos + 1
        })
        expect(itemStart).toBeGreaterThan(0)
        view.dispatch({ selection: { anchor: itemStart } })
        Object.assign(view, { composing: true })
        const start = enter(view, null)
        expect(start).not.toBeNull()
        view.dispatch({ ...start!, userEvent: 'input.type.compose.start' })
        Command.dispatch(view, insertText, {
          from: view.state.selection.from,
          to: view.state.selection.to,
          insert: 'zh',
          userEvent: 'input.type.compose'
        })
        const paragraph = view.state.sel.head.parent
        Command.dispatch(view, insertText, {
          from: paragraph.start,
          to: paragraph.end,
          insert: '',
          userEvent: 'input.type.compose'
        })
        if (remoteTarget !== null) {
          peer.dispatch({
            changes: { from: textAt(peer.state.doc, remoteTarget), insert: [Leaf.text('Remote ')] },
            userEvent: 'input.type'
          })
          await waitFor(() => xmlOf(view).includes(`Remote ${remoteTarget}`))
        }
        expect(xmlOf(view)).toContain('<li><p /></li>')
        endComposition(view)
        const expected = remoteTarget === null ? original : original.replace(remoteTarget, `Remote ${remoteTarget}`)
        expect(await network.settle()).toBe(expected)
        expect(exportMarkdown(view)).not.toContain('<p />')
        expect(undoDepth(view.state)).toBe(1)
        expect(undo(view)).toBe(true)
        expect(await network.settle()).toBe(expected)
      } finally {
        network.dispose()
      }
    })
  }

  for (const remoteTarget of ['Before', 'After']) {
    for (const cancel of [false, true]) {
      test(`remote ${remoteTarget} text remains visible during column composition and ${cancel ? 'cancellation' : 'commit'}`, async () => {
        const network = peers(composingColumns)
        const [view, peer] = network.views
        try {
          beginColumnComposition(view)
          const head = view.state.selection.head
          peer.dispatch({
            changes: { from: textAt(peer.state.doc, remoteTarget), insert: [Leaf.text('Remote ')] },
            userEvent: 'input.type'
          })
          await waitFor(() => network.clients[0]!.currentRevision() === 1)
          expect(xmlOf(view)).toContain(`Remote ${remoteTarget}`)
          expect(view.state.selection.head).toBe(head + (remoteTarget === 'Before' ? 7 : 0))
          expect(view.state.sel.head.parent.node.textContent()).toBe('zh')
          expect(view.state.sel.head.parent.parent!.node.name).toBe('Column')
          expect(network.recoveries).toEqual([])
          expect(network.committedXML()).not.toContain('zh')
          finishColumnComposition(view, cancel)
          const stored = await network.settle()
          expect(stored).toContain(cancel ? '<p />' : '<p>中</p>')
          expect(stored).toContain(`Remote ${remoteTarget}`)
          expect(stored).not.toContain('<columns')
          expect(undo(view)).toBe(true)
          const restored = await network.settle()
          expect(restored).toContain('<p>A</p>')
          expect(restored).toContain('<p>B</p>')
          expect(restored).toContain(`Remote ${remoteTarget}`)
          expect(redo(view)).toBe(true)
          expect(await network.settle()).toBe(stored)
        } finally {
          network.dispose()
        }
      })
    }
  }

  for (const outcome of ['stale', 'lost acknowledgement']) {
    for (const cancel of [false, true]) {
      test(`an in-flight ${outcome} request preserves composition through ${cancel ? 'core cancellation' : 'core commit'}`, async () => {
        const view = editor(composingColumns, true)
        let document = view.state.doc
        const log: PageChange[] = []
        const requests: PageChangeRequest[] = []
        const release = Promise.withResolvers<void>()
        const acknowledge = Promise.withResolvers<void>()
        const recoveries: (string | null)[] = []
        const failures: unknown[] = []
        let pending = false
        const commit = (request: Pick<PageChangeRequest, 'client_id' | 'client_seq' | 'changes'>) => {
          const changed = ChangeSet.fromJSON(document.schema, request.changes).apply(document)
          expect(changed.eq(pageDocument(parseXml(printXml(readTree(changed)))))).toBe(true)
          document = changed
          log.push({ revision: log.length + 1, kind: 'change', ...request })
        }
        const client = new PageCollaboration(view, 0, {
          clientID: 'composing-sender',
          changed(state) {
            pending = state.pending
            if (state.error) failures.push(state.error)
          },
          reset(draft) {
            recoveries.push(draft)
          },
          sync() {
            throw new Error('Unexpected revision gap')
          },
          async send(request) {
            requests.push(structuredClone(request))
            if (requests.length === 1) {
              if (outcome === 'lost acknowledgement') commit(request)
              await release.promise
              if (outcome === 'lost acknowledgement') throw new Error('acknowledgement lost')
            } else if (outcome === 'lost acknowledgement' && requests.length === 2) {
              expect(request).toEqual(requests[0]!)
              await acknowledge.promise
            } else {
              expect(request.base_revision).toBe(log.length)
              commit(request)
            }
            return { revision: log.length, changes: log.slice(request.base_revision) }
          }
        })
        try {
          view.dispatch({
            changes: { from: textAt(view.state.doc, 'Before'), insert: [Leaf.text('Local ')] },
            userEvent: 'input.type'
          })
          await waitFor(() => requests.length === 1)
          const original = structuredClone(requests[0]!)
          beginColumnComposition(view)
          if (outcome === 'lost acknowledgement') {
            release.resolve()
            await waitFor(() => requests.length === 2)
          }
          commit({
            client_id: 'peer',
            client_seq: 1,
            changes: ChangeSet.create(document, {
              from: textAt(document, 'After'),
              insert: [Leaf.text('Remote ')]
            }).toJSON()
          })
          client.receive({ revision: log.length, changes: [...log] })
          expect(client.currentRevision()).toBe(outcome === 'stale' ? 1 : 2)
          expect(xmlOf(view)).toContain('Local Before')
          expect(xmlOf(view)).toContain('Remote After')
          expect(view.state.sel.head.parent.node.textContent()).toBe('zh')
          expect(view.state.sel.head.parent.parent!.node.name).toBe('Column')
          release.resolve()
          acknowledge.resolve()
          await Bun.sleep(80)
          expect(requests).toEqual(outcome === 'stale' ? [original] : [original, original])
          expect(printXml(readTree(document))).not.toContain('zh')
          expect(pending).toBe(true)

          // Core composition cleanup need not dispatch the DOM compositionend hook.
          // The next send must still normalize both memory and the prepared payload.
          finishColumnComposition(view, cancel, false)
          await waitFor(() => !pending && client.currentRevision() === log.length)
          const stored = printXml(readTree(document))
          expect(xmlOf(view)).toBe(stored)
          expect(view.state.doc.eq(pageDocument(parseXml(stored)))).toBe(true)
          expect(stored).not.toContain('<columns')
          expect(stored).toContain(cancel ? '<p />' : '<p>中</p>')
          expect(stored).toContain('Local Before')
          expect(stored).toContain('Remote After')
          expect(requests).toHaveLength(outcome === 'stale' ? 2 : 3)
          expect(requests.at(-1)!.client_seq).toBe(2)
          expect(requests.at(-1)!.base_revision).toBe(outcome === 'stale' ? 1 : 2)
          expect(requests[0]).toEqual(original)
          expect(recoveries).toEqual([])
          expect(failures.map(error => (error as Error).message)).toEqual(
            outcome === 'stale' ? [] : ['acknowledgement lost']
          )
          expect(undo(view)).toBe(true)
          await waitFor(() => !pending && client.currentRevision() === log.length)
          const restored = xmlOf(view)
          expect(restored).toBe(
            composingColumns
              .replace('<p>Before</p>', '<p>Local Before</p>')
              .replace('<p>After</p>', '<p>Remote After</p>')
          )
          expect(restored).toBe(printXml(readTree(document)))
          expect(view.state.doc.eq(pageDocument(parseXml(restored)))).toBe(true)
          expect(redo(view)).toBe(true)
          await waitFor(() => !pending && client.currentRevision() === log.length)
          expect(xmlOf(view)).toBe(stored)
          expect(xmlOf(view)).toBe(printXml(readTree(document)))
          expect(view.state.doc.eq(pageDocument(parseXml(stored)))).toBe(true)
        } finally {
          release.resolve()
          acknowledge.resolve()
          client.dispose()
        }
      })
    }
  }

  for (const { cancel, followup } of [
    { cancel: false, followup: false },
    { cancel: true, followup: false },
    { cancel: false, followup: true }
  ]) {
    test(`core ${cancel ? 'cancellation' : 'commit'} normalizes before a slow acknowledged request releases its slot${followup ? ' and separates later ordinary input' : ''}`, async () => {
      const view = editor(composingColumns, true)
      let document = view.state.doc
      const log: PageChange[] = []
      const requests: PageChangeRequest[] = []
      const release = Promise.withResolvers<void>()
      const failures: unknown[] = []
      let pending = false
      const client = new PageCollaboration(view, 0, {
        clientID: 'slow-composition',
        changed(state) {
          pending = state.pending
          if (state.error) failures.push(state.error)
        },
        reset() {
          throw new Error('Unexpected reset')
        },
        sync() {
          throw new Error('Unexpected revision gap')
        },
        async send(request) {
          requests.push(structuredClone(request))
          document = ChangeSet.fromJSON(document.schema, request.changes).apply(document)
          log.push({
            revision: log.length + 1,
            kind: 'change',
            client_id: request.client_id,
            client_seq: request.client_seq,
            changes: request.changes
          })
          if (requests.length === 1) await release.promise
          return { revision: log.length, changes: log.slice(request.base_revision) }
        }
      })
      try {
        view.dispatch({
          changes: { from: textAt(view.state.doc, 'Before'), insert: [Leaf.text('Local ')] },
          userEvent: 'input.type'
        })
        await waitFor(() => requests.length === 1)
        const original = structuredClone(requests[0]!)
        beginColumnComposition(view)
        const remote = ChangeSet.create(document, {
          from: textAt(document, 'After'),
          insert: [Leaf.text('Remote ')]
        })
        document = remote.apply(document)
        log.push({ revision: 2, kind: 'change', client_id: 'peer', client_seq: 1, changes: remote.toJSON() })
        client.receive({ revision: 2, changes: [...log] })
        expect(client.currentRevision()).toBe(2)
        expect(view.state.sel.head.parent.parent!.node.name).toBe('Column')

        finishColumnComposition(view, cancel, false)
        const completed = composingColumns
          .replace('<p>Before</p>', '<p>Local Before</p>')
          .replace('<p>After</p>', '<p>Remote After</p>')
        const expected = completed.replace(
          '<columns><column><p>A</p><p>Keep</p></column><column><p>B</p></column></columns>',
          `${cancel ? '<p />' : '<p>中</p>'}<p>Keep</p>`
        )
        // Local completion cannot wait for the transport or its 500 ms history grouping window.
        expect(view.state.doc.eq(pageDocument(parseXml(expected)))).toBe(true)
        await Bun.sleep(600)
        if (followup) {
          const { from, to } = view.state.selection.replacementRange
          Command.dispatch(view, insertText, {
            from,
            to,
            insert: 'x',
            userEvent: 'input.type'
          })
          expect(xmlOf(view)).toBe(expected.replace('<p>中</p>', '<p>中x</p>'))
          expect(undo(view)).toBe(true)
          expect(xmlOf(view)).toBe(expected)
        }
        expect(requests).toEqual([original])
        release.resolve()
        await waitFor(() => !pending)
        expect(xmlOf(view)).toBe(expected)
        expect(printXml(readTree(document))).toBe(expected)
        expect(undo(view)).toBe(true)
        expect(xmlOf(view)).toBe(completed)
        await waitFor(() => !pending)
        expect(printXml(readTree(document))).toBe(completed)
        expect(redo(view)).toBe(true)
        expect(xmlOf(view)).toBe(expected)
        await waitFor(() => !pending)
        expect(printXml(readTree(document))).toBe(expected)
        expect(failures).toEqual([])
      } finally {
        release.resolve()
        client.dispose()
      }
    })
  }

  test('core completion applies full normalization to composing marks without column cleanup', async () => {
    const original = '<page><p>base</p></page>'
    const view = editor(original, true)
    Object.assign(view, { composing: true })
    view.dispatch({
      changes: { from: 1, to: 5, insert: [Leaf.text('中 ', [Strong])] },
      selection: { anchor: 3 },
      userEvent: 'input.type.compose.start'
    })
    const expected = '<page><p><strong>中</strong> </p></page>'
    expect(view.state.doc.eq(pageDocument(parseXml(expected)))).toBe(false)
    await Bun.sleep(600)
    endComposition(view)
    expect(view.state.doc.eq(pageDocument(parseXml(expected)))).toBe(true)
    expect(view.state.selection.head).toBe(3)
    expect(undo(view)).toBe(true)
    expect(xmlOf(view)).toBe(original)
    expect(redo(view)).toBe(true)
    expect(xmlOf(view)).toBe(expected)
  })

  for (const replacement of [false, true]) {
    test(`a remote ${replacement ? 'replacement' : 'deletion'} of the composing host preserves the draft through recovery`, () => {
      const view = editor(composingColumns, true)
      const confirmed = view.state.doc
      const columns = confirmed.resolve(textAt(confirmed, 'A')).matchingParent(node => node.name === 'Columns')!
      let draft: string | null | undefined
      let sends = 0
      const client = new PageCollaboration(view, 0, {
        clientID: 'composing-draft',
        changed() {},
        sync() {},
        reset(value) {
          draft = value
        },
        async send() {
          sends++
          throw new Error('Unexpected request')
        }
      })
      try {
        beginColumnComposition(view)
        const before = view.state
        const remote = ChangeSet.create(confirmed, {
          from: columns.before,
          to: columns.after,
          insert: replacement ? [Paragraph.create([Leaf.text('replacement')])] : []
        })
        client.receive({
          revision: 1,
          changes: [{ revision: 1, kind: 'change', client_id: 'peer', client_seq: 1, changes: remote.toJSON() }]
        })
        expect(view.state).toBe(before)
        expect(client.currentRevision()).toBe(0)
        expect(draft).toContain('<p>zh</p>')
        expect(draft).toContain('<p>Keep</p>')
        expect(draft).not.toContain('<p>B</p>')
        expect(draft).not.toContain('replacement')
        expect(sends).toBe(0)
      } finally {
        client.dispose()
      }
    })
  }

  const tableXML = (labels: string[]) =>
    `<page><table>${labels.map(label => `<tr><td><p>${label}</p></td></tr>`).join('')}</table></page>`
  const typeInCell = (view: Wordgard, label: string) => {
    let at = -1
    view.state.doc.iterate((node, pos) => {
      if (node.isText && node.param === label) at = pos
    })
    expect(at).toBeGreaterThanOrEqual(0)
    view.dispatch({ changes: { from: at + label.length, insert: [Leaf.text(' from peer')] } })
  }

  test('sorting an already ordered table submits no rewrite and retains concurrent cell input', async () => {
    const network = peers(tableXML(['A', 'B']))
    const [a, b] = network.views
    try {
      a.dispatch({ selection: { anchor: 4 } })
      expect(changeTable(a, 'sort_ascending')).toBe(false)
      typeInCell(b, 'A')
      expect(await network.settle()).toBe(tableXML(['A from peer', 'B']))
      expect(network.clients[0]!.currentRevision()).toBe(1)
    } finally {
      network.dispose()
    }
  })

  test('sorting retains unchanged edge rows and their concurrent edits', async () => {
    const network = peers(tableXML(['A', 'C', 'B', 'D']))
    const [a, b] = network.views
    try {
      a.dispatch({ selection: { anchor: 4 } })
      expect(changeTable(a, 'sort_ascending')).toBe(true)
      typeInCell(b, 'A')
      typeInCell(b, 'D')
      expect(await network.settle()).toBe(tableXML(['A from peer', 'B', 'C', 'D from peer']))
      expect(undo(a)).toBe(true)
      expect(await network.settle()).toBe(tableXML(['A from peer', 'C', 'B', 'D from peer']))
    } finally {
      network.dispose()
    }
  })

  for (const first of ['sort', 'typing']) {
    test(`a row reorder overlapping cell input preserves the uncommitted draft when ${first} commits first`, async () => {
      const network = peers(tableXML(['B', 'A']))
      const [a, b] = network.views
      const sort = (view: Wordgard) => {
        view.dispatch({ selection: { anchor: 4 } })
        expect(changeTable(view, 'sort_ascending')).toBe(true)
      }
      try {
        if (first === 'sort') {
          sort(a)
          typeInCell(b, 'A')
        } else {
          typeInCell(a, 'A')
          sort(b)
        }
        const kept = xmlOf(b)
        await waitFor(() => network.recoveries.length === 1)
        expect(network.recoveries).toEqual([{ index: 1, draft: kept }])
        expect(xmlOf(b)).toBe(kept)
        expect(network.committedXML()).toBe(first === 'sort' ? tableXML(['A', 'B']) : tableXML(['B', 'A from peer']))
        expect(network.clients[0]!.currentRevision()).toBe(1)
      } finally {
        network.dispose()
      }
    })
  }

  for (const action of ['delete_row', 'delete_column'] as const) {
    for (const first of ['deletion', 'typing']) {
      test(`${action} overlapping input preserves the draft when ${first} commits first`, async () => {
        const network = peers(
          '<page><table><tr><td><p>A</p></td><td><p>B</p></td></tr><tr><td><p>C</p></td><td><p>D</p></td></tr></table></page>'
        )
        const [a, b] = network.views
        const remove = (view: Wordgard) => {
          view.dispatch({ selection: { anchor: 4 } })
          expect(changeTable(view, action)).toBe(true)
        }
        try {
          if (first === 'deletion') {
            remove(a)
            typeInCell(b, 'A')
          } else {
            typeInCell(a, 'A')
            remove(b)
          }
          const committed = xmlOf(a)
          const draft = xmlOf(b)
          await waitFor(() => network.recoveries.length === 1)
          expect(network.recoveries).toEqual([{ index: 1, draft }])
          expect(xmlOf(b)).toBe(draft)
          expect(network.committedXML()).toBe(committed)
          expect(network.clients[0]!.currentRevision()).toBe(1)
        } finally {
          network.dispose()
        }
      })
    }
  }

  test('concurrent list conversions preserve later typing and undo only the local conversion', async () => {
    const network = peers('<page><p>A</p><p>B</p></page>')
    const [a, b] = network.views
    try {
      a.dispatch({ selection: { anchor: 1 } })
      b.dispatch({ selection: { anchor: 4 } })
      a.dispatch(blockChange(a.state, 'bullet')!)
      b.dispatch(blockChange(b.state, 'bullet')!)
      expect(await network.settle()).toBe('<page><ul><li><p>A</p></li><li><p>B</p></li></ul></page>')
      expect(undo(b)).toBe(true)
      expect(await network.settle()).toBe('<page><ul><li><p>A</p></li></ul><p>B</p></page>')
      b.dispatch({ changes: { from: b.state.doc.length - 1, insert: [Leaf.text(' kept')] } })
      expect(await network.settle()).toBe('<page><ul><li><p>A</p></li></ul><p>B kept</p></page>')
    } finally {
      network.dispose()
    }
  })

  test('undo restores an original empty list paragraph on both clients without replaying local input cleanup', async () => {
    const network = peers('<page><ul><li><p /></li></ul></page>')
    const [a, b] = network.views
    try {
      a.dispatch({ changes: { from: 3, insert: [Leaf.text('typed')] }, userEvent: 'input.type' })
      expect(await network.settle()).toBe('<page><ul><li><p>typed</p></li></ul></page>')
      expect(undo(a)).toBe(true)
      expect(await network.settle()).toBe('<page><ul><li><p /></li></ul></page>')
      b.dispatch({ changes: { from: 3, insert: [Leaf.text('continued')] }, userEvent: 'input.type' })
      expect(await network.settle()).toBe('<page><ul><li><p>continued</p></li></ul></page>')
    } finally {
      network.dispose()
    }
  })

  test('deleting between two lists merges them while preserving concurrent typing through both users undo', async () => {
    const network = peers('<page><ul><li><p>A</p></li></ul><p>remove</p><ul><li><p>B</p></li></ul></page>')
    const [a, b] = network.views
    try {
      expect(deleteBlock(a, a.state.doc.content[0]!.length)).toBe(true)
      let at = 0
      b.state.doc.iterate((node, pos) => {
        if (node.isText && node.param === 'B') at = pos
      })
      b.dispatch({ changes: { from: at + 1, insert: [Leaf.text(' from peer')] } })
      expect(await network.settle()).toBe('<page><ul><li><p>A</p></li><li><p>B from peer</p></li></ul></page>')
      expect(undo(a)).toBe(true)
      expect(await network.settle()).toBe(
        '<page><ul><li><p>A</p></li></ul><p>remove</p><ul><li><p>B from peer</p></li></ul></page>'
      )
      expect(undo(b)).toBe(true)
      expect(await network.settle()).toBe(
        '<page><ul><li><p>A</p></li></ul><p>remove</p><ul><li><p>B</p></li></ul></page>'
      )
    } finally {
      network.dispose()
    }
  })

  for (const action of [
    'row_before',
    'row_after',
    'column_before',
    'column_after',
    'header',
    'align_center',
    'delete_row',
    'delete_column'
  ] as TableAction[]) {
    test(`concurrent table ${action} retains typing in an unaffected cell`, async () => {
      const network = peers(
        '<page><table><tr><td><p>A</p></td><td><p>B</p></td></tr><tr><td><p>C</p></td><td><p>D</p></td></tr></table></page>'
      )
      const [a, b] = network.views
      try {
        a.dispatch({ selection: { anchor: 4 } })
        expect(changeTable(a, action)).toBe(true)
        const typedCell = action === 'header' || action === 'align_center' ? 'A' : 'D'
        let at = 0
        b.state.doc.iterate((node, pos) => {
          if (node.isText && node.param === typedCell) at = pos
        })
        b.dispatch({ changes: { from: at + 1, insert: [Leaf.text(' from peer')] } })
        const xml = await network.settle()
        expect(xml).toContain(`<p>${typedCell} from peer</p>`)
        expect(xml.match(/from peer/g)).toHaveLength(1)
        expect(undo(a)).toBe(true)
        expect(await network.settle()).toBe(
          `<page><table><tr><td><p>A${typedCell === 'A' ? ' from peer' : ''}</p></td><td><p>B</p></td></tr><tr><td><p>C</p></td><td><p>D${typedCell === 'D' ? ' from peer' : ''}</p></td></tr></table></page>`
        )
        expect(redo(a)).toBe(true)
        expect(await network.settle()).toBe(xml)
      } finally {
        network.dispose()
      }
    })
  }

  test('presence selections map through pending edits and reject a different confirmed revision', () => {
    const view = editor('<page><p>before 😀 after</p></page>')
    const client = new PageCollaboration(view, 3, {
      clientID: 'presence',
      async send() {
        throw new Error('not sent')
      },
      changed() {},
      reset() {},
      sync() {}
    })
    try {
      view.dispatch({ changes: { from: 1, insert: [Leaf.text('local ')] } })
      expect(client.selectionToConfirmed({ anchor: 15, head: 14 })).toEqual({ revision: 3, anchor: 9, head: 8 })
      expect(client.selectionFromConfirmed({ revision: 3, anchor: 9, head: 8 })).toEqual({ anchor: 15, head: 14 })
      expect(client.selectionFromConfirmed({ revision: 2, anchor: 9, head: 8 })).toBeNull()
      expect(client.selectionFromConfirmed({ revision: 3, anchor: -1, head: 8 })).toBeNull()
    } finally {
      client.dispose()
    }
  })

  test('an Agent heading conversion keeps pending human text inside the heading and retains its comment anchor', async () => {
    const id = '019a2b00-0000-7000-8000-000000000001'
    const source = `<page><p><comment ids="${id}">Hello</comment> world</p></page>`
    const view = editor(source, true)
    // The native Rust and NIF tests assert this exact compatible-block diff.
    const changes: ChangeSet.JSON = [[1, [{ type: 'Heading', param: 2 }]], 12]
    let document = ChangeSet.fromJSON(view.state.schema, changes).apply(view.state.doc)
    let pending = false
    const failures: unknown[] = []
    const client = new PageCollaboration(view, 0, {
      clientID: 'human',
      changed(state) {
        pending = state.pending
        if (state.error) failures.push(state.error)
      },
      reset() {
        failures.push(new Error('Unexpected reset'))
      },
      sync() {},
      async send(request) {
        expect(request.base_revision).toBe(1)
        document = ChangeSet.fromJSON(document.schema, request.changes).apply(document)
        return {
          revision: 2,
          changes: [
            {
              revision: 2,
              kind: 'change',
              client_id: 'human',
              client_seq: request.client_seq,
              changes: request.changes
            }
          ]
        }
      }
    })
    try {
      view.dispatch({ changes: { from: 6, insert: [Leaf.text(' HUMAN')] }, userEvent: 'input.type' })
      client.receive({
        revision: 1,
        changes: [{ revision: 1, kind: 'change', client_id: 'server:agent', client_seq: 1, changes }]
      })
      await waitFor(() => client.currentRevision() === 2 && !pending)
      expect(failures).toEqual([])
      expect(view.state.doc.eq(document)).toBe(true)
      expect(xmlOf(view)).toBe(`<page><h2><comment ids="${id}">Hello</comment> HUMAN world</h2></page>`)
    } finally {
      client.dispose()
    }
  })

  test('the native Agent sorting delta retains the local draft instead of splitting the table', () => {
    for (const sample of structuralDiffs) {
      const view = editor(sample.before, true)
      let recovery: string | null | undefined
      const client = new PageCollaboration(view, 0, {
        clientID: 'human',
        changed() {},
        reset(draft) {
          recovery = draft
        },
        sync() {},
        async send() {
          throw new Error('Conflicting draft must not be sent')
        }
      })
      try {
        typeInCell(view, 'B')
        const draft = xmlOf(view)
        const changes = sample.changes as ChangeSet.JSON
        expect(
          printXml(
            readTree(ChangeSet.fromJSON(view.state.schema, changes).apply(pageDocument(parseXml(sample.before))))
          )
        ).toBe(sample.after)
        client.receive({
          revision: 1,
          changes: [{ revision: 1, kind: 'change', client_id: 'server:agent', client_seq: 1, changes }]
        })
        expect(recovery).toBe(draft)
        expect(xmlOf(view)).toBe(draft)
        expect(draft).toContain('<p>B from peer</p>')
      } finally {
        client.dispose()
      }
    }
  })

  test('concurrent row and column insertions keep the table editable and the next structure command fills missing cells', async () => {
    const network = peers(
      '<page><table><tr><td><p>A</p></td><td><p>B</p></td></tr><tr><td><p>C</p></td><td><p>D</p></td></tr></table></page>'
    )
    const [a, b] = network.views
    try {
      for (const view of network.views) view.dispatch({ selection: { anchor: 4 } })
      expect(changeTable(a, 'row_after')).toBe(true)
      expect(changeTable(b, 'column_after')).toBe(true)
      await network.settle()
      for (const view of network.views) {
        view.dispatch({ selection: { anchor: 4 } })
        expect(editableTable(view.state)).toBeTruthy()
      }
      expect(changeTable(b, 'column_before')).toBe(true)
      const xml = await network.settle()
      const context = editableTable(b.state)!
      expect(context.rows).toHaveLength(3)
      expect(context.rows.map(row => row.content.length)).toEqual([4, 4, 4])
      for (const text of ['A', 'B', 'C', 'D']) expect(xml.match(new RegExp(`<p>${text}</p>`, 'g'))).toHaveLength(1)
    } finally {
      network.dispose()
    }
  })

  test('formatting a ragged imported table with an empty first row preserves every row and cell', async () => {
    const network = peers('<page><table><tr /><tr><td><p>Kept</p></td></tr></table></page>')
    const [a] = network.views
    try {
      a.dispatch({ selection: { anchor: 6 } })
      expect(changeTable(a, 'align_right')).toBe(true)
      expect(await network.settle()).toBe(
        '<page><table><tr /><tr><td align="right"><p>Kept</p></td></tr></table></page>'
      )
      expect(changeTable(a, 'header')).toBe(true)
      expect(await network.settle()).toBe(
        '<page><table><tr /><tr><th align="right"><p>Kept</p></th></tr></table></page>'
      )
    } finally {
      network.dispose()
    }
  })

  test('a timed-out structural batch keeps its request identity while rebasing and correcting the live draft', async () => {
    const view = editor('<page><p>A</p><p>B</p></page>', true)
    const peer = editor('<page><p>A</p><p>B</p></page>', true)
    peer.dispatch({ selection: { anchor: 1 } })
    const remote = peer.state.update(blockChange(peer.state, 'bullet')!).changes
    let document = remote.apply(peer.state.doc)
    let original: PageChangeRequest | undefined
    let calls = 0
    const client = new PageCollaboration(view, 0, {
      clientID: 'retry-structure',
      changed() {},
      sync() {},
      reset() {
        throw new Error('Unexpected reset')
      },
      async send(request) {
        calls++
        if (calls === 1) {
          original = structuredClone(request)
          throw new Error('Connection lost before response')
        }
        if (calls === 2) {
          expect(request).toEqual(original!)
          return {
            revision: 1,
            changes: [{ revision: 1, kind: 'change', client_id: 'peer', client_seq: 1, changes: remote.toJSON() }]
          }
        }
        expect(request.client_seq).toBe(2)
        expect(request.base_revision).toBe(1)
        document = ChangeSet.fromJSON(document.schema, request.changes).apply(document)
        expect(document.eq(pageDocument(parseXml(printXml(readTree(document)))))).toBe(true)
        return {
          revision: 2,
          changes: [
            {
              revision: 2,
              kind: 'change',
              client_id: request.client_id,
              client_seq: request.client_seq,
              changes: request.changes
            }
          ]
        }
      }
    })
    try {
      view.dispatch({ selection: { anchor: 4 } })
      view.dispatch(blockChange(view.state, 'bullet')!)
      await waitFor(() => calls === 1)
      client.receive({
        revision: 1,
        changes: [{ revision: 1, kind: 'change', client_id: 'peer', client_seq: 1, changes: remote.toJSON() }]
      })
      expect(undo(view)).toBe(true)
      expect(xmlOf(view)).toBe('<page><ul><li><p>A</p></li></ul><p>B</p></page>')
      expect(redo(view)).toBe(true)
      expect(xmlOf(view)).toBe('<page><ul><li><p>A</p></li><li><p>B</p></li></ul></page>')
      view.dispatch({ changes: { from: view.state.doc.length - 3, insert: [Leaf.text(' continued')] } })
      await waitFor(() => client.currentRevision() === 2)
      expect(calls).toBe(3)
      expect(view.state.doc.eq(document)).toBe(true)
      expect(xmlOf(view)).toBe('<page><ul><li><p>A</p></li><li><p>B continued</p></li></ul></page>')
    } finally {
      client.dispose()
    }
  })

  test('draft comment selection follows remote insertion rebased over a pending local edit', () => {
    const view = editor('<page><p>Before</p><p>Selected phrase</p><p>After</p></page>')
    const confirmed = view.state.doc
    const client = new PageCollaboration(view, 0, {
      clientID: 'comment-draft',
      changed() {},
      reset() {
        throw new Error('Unexpected reset')
      },
      sync() {
        throw new Error('Unexpected sync')
      },
      async send() {
        throw new Error('No transport tick in this synchronous test')
      }
    })
    const read = trackCommentSelection(view, { from: 9, to: 24, quote: 'Selected phrase' })
    view.dispatch({ changes: { from: 1, insert: [Leaf.text('Local ')] } })
    const remote = ChangeSet.create(confirmed, { from: 1, insert: [Leaf.text('Remote ')] })
    client.receive({
      revision: 1,
      changes: [{ kind: 'change', revision: 1, client_id: 'peer', client_seq: 1, changes: remote.toJSON() }]
    })
    expect(read(view.state)).toEqual({ from: 22, to: 37, quote: 'Selected phrase' })
    expect(xmlOf(view)).toContain('<p>Selected phrase</p>')
    client.dispose()
  })

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

  test.each([false, true])(
    'two individually valid edits that exceed the combined limit preserve the local draft while composing=%s',
    composing => {
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
      Object.assign(view, { composing })
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
      expect(client.currentRevision()).toBe(0)
      client.dispose()
    }
  )

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

  test('native whole-document writes retain an in-flight draft once through its original request and reopen', async () => {
    const view = editor(draftRebase[0]!.before, true)
    let document = view.state.doc
    const log: PageChange[] = []
    const requests: PageChangeRequest[] = []
    const release = Promise.withResolvers<void>()
    let pending = false
    const recoveries: (string | null)[] = []
    const client = new PageCollaboration(view, 0, {
      clientID: 'retained-draft',
      changed(state) {
        pending = state.pending
        expect(state.error).toBeUndefined()
      },
      reset(draft) {
        recoveries.push(draft)
      },
      sync() {},
      async send(request) {
        requests.push(structuredClone(request))
        if (requests.length === 1) await release.promise
        if (request.base_revision === log.length) {
          document = ChangeSet.fromJSON(document.schema, request.changes).apply(document)
          log.push({
            revision: log.length + 1,
            kind: 'change',
            client_id: request.client_id,
            client_seq: request.client_seq,
            changes: request.changes
          })
        }
        return { revision: log.length, changes: log.slice(request.base_revision) }
      }
    })
    try {
      const draft = ' Local draft A'
      view.dispatch({ changes: { from: view.state.doc.length - 1, insert: [Leaf.text(draft)] } })
      await waitFor(() => requests.length === 1)
      const original = structuredClone(requests[0])
      expect(original!.base_revision).toBe(0)

      for (const sample of draftRebase) {
        const changes = sample.changes as ChangeSet.JSON
        document = ChangeSet.fromJSON(document.schema, changes).apply(document)
        expect(printXml(readTree(document))).toBe(sample.after)
        const change: PageChange = {
          revision: log.length + 1,
          kind: 'change',
          client_id: 'server:agent',
          client_seq: log.length + 1,
          changes
        }
        log.push(change)
        client.receive({ revision: log.length, changes: [change] })
        expect(xmlOf(view).split(draft)).toHaveLength(2)
        expect(requests).toEqual([original!])
      }

      release.resolve()
      await waitFor(() => !pending && client.currentRevision() === log.length)
      expect(requests).toHaveLength(2)
      expect(requests[0]).toEqual(original!)
      expect(recoveries).toEqual([])
      const stored = printXml(readTree(document))
      expect(xmlOf(view)).toBe(stored)
      expect(stored.split(draft)).toHaveLength(2)
      for (const text of ['Corrected name', 'Appended block', 'Second block']) expect(stored).toContain(text)
      expect(stored).not.toContain('Initial')
      expect(stored).not.toContain('Remote name')
      expect(xmlOf(editor(stored, true))).toBe(stored)
    } finally {
      release.resolve()
      client.dispose()
    }
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
    // Delete the code text, retaining its container so concurrent input can rebase safely.
    const removal = ChangeSet.fromJSON(view.state.schema, [7, [1, []], 1])
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

  test('pure mark modifications and identical concurrent block deletions rebase without resetting peer typing', async () => {
    // 1. Pure mark modification (Align + Strong) concurrent with peer typing in the same paragraph.
    const markNetwork = peers('<page><p>Hello world</p></page>')
    const [m1, m2] = markNetwork.views
    try {
      m1.dispatch({ selection: { anchor: 1, head: 6 } })
      expect(toggleFormat(m1, 'strong')).toBe(true)
      m1.dispatch({ selection: { anchor: 1 } })
      m1.dispatch({ changes: { from: 0, add: Align.of('center') } })
      m2.dispatch({ changes: { from: 12, insert: [Leaf.text('!')] }, userEvent: 'input.type' })
      expect(await markNetwork.settle()).toBe('<page><p align="center"><strong>Hello</strong> world!</p></page>')
    } finally {
      markNetwork.dispose()
    }

    // 2. Identical concurrent whole-block deletion while both peers also type in another block.
    const deleteView = editor('<page><p>obsolete</p><p>shared</p></page>', true)
    const peerDoc = pageDocument(parseXml('<page><p>obsolete</p><p>shared</p></page>'))
    // Remote peer deletes <p>obsolete</p> (span 10) and appends '!' to <p>shared</p>.
    const remoteChanges = ChangeSet.create(peerDoc, [
      { from: 0, to: 10 },
      { from: 17, insert: [Leaf.text('!')] }
    ])
    let serverDoc = remoteChanges.apply(peerDoc)
    let resets = 0
    const client = new PageCollaboration(deleteView, 0, {
      clientID: 'local-peer',
      changed() {},
      reset() {
        resets++
      },
      sync() {},
      async send(request) {
        serverDoc = ChangeSet.fromJSON(serverDoc.schema, request.changes).apply(serverDoc)
        return {
          revision: 2,
          changes: [
            {
              revision: 2,
              kind: 'change',
              client_id: request.client_id,
              client_seq: request.client_seq,
              changes: request.changes
            }
          ]
        }
      }
    })
    try {
      expect(deleteBlock(deleteView, 0)).toBe(true)
      deleteView.dispatch({ changes: { from: 1, insert: [Leaf.text('local ')] }, userEvent: 'input.type' })
      client.receive({
        revision: 1,
        changes: [
          { revision: 1, kind: 'change', client_id: 'remote-peer', client_seq: 1, changes: remoteChanges.toJSON() }
        ]
      })
      await waitFor(() => client.currentRevision() === 2)
      expect(resets).toBe(0)
      expect(xmlOf(deleteView)).toBe('<page><p>local shared!</p></page>')
      expect(printXml(readTree(serverDoc))).toBe('<page><p>local shared!</p></page>')
    } finally {
      client.dispose()
    }
  })

  test('malformed remote changes publish the error and recover via reset instead of throwing', () => {
    for (const malformed of [
      [[9999, []]] as unknown as ChangeSet.JSON,
      [[0, [{ type: 'UnknownNodeType', param: null }]]] as unknown as ChangeSet.JSON
    ]) {
      const view = editor('<page><p>safe</p></page>', true)
      let failure: unknown
      let resetDraft: string | null | undefined
      const client = new PageCollaboration(view, 4, {
        clientID: 'reader',
        changed(state) {
          if (state.error) failure = state.error
        },
        reset(draft) {
          resetDraft = draft
        },
        sync() {},
        async send() {
          throw new Error('not sent')
        }
      })
      view.dispatch({ changes: { from: 5, insert: [Leaf.text(' draft')] }, userEvent: 'input.type' })
      expect(() =>
        client.receive({
          revision: 5,
          changes: [{ revision: 5, kind: 'change', client_id: 'corrupt', client_seq: 1, changes: malformed }]
        })
      ).not.toThrow()
      expect(failure).toBeInstanceOf(Error)
      expect(resetDraft).toBe('<page><p>safe draft</p></page>')
      expect(client.currentRevision()).toBe(4)
    }
  })
})
