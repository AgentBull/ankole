import structuralDiffs from '../corpus/rust/structural-diffs.json'
import { describe, expect, test } from 'bun:test'
import { ChangeSet, Leaf, type Plot } from '../src/core/doc'
import { Wordgard } from '../src/core/editor'
import { Transaction } from '../src/core/state'
import { parseXml, printXml } from '../src/document/xml'
import { headlessState } from '../src/editor/extension'
import { pageDocument, readTree } from '../src/editor/convert'
import { Paragraph } from '../src/core/types'
import { insertImage, redo, toggleFormat, undo } from '../src/editor/commands'
import { Align } from '../src/editor/schema'
import { limits } from '../src/document/tree'
import { PageCollaboration, type PageChange, type PageChangeRequest } from '../src/editor/page-collaboration'
import { trackCommentSelection } from '../src/editor/comments'
import { blockChange, deleteBlock } from '../src/editor/block-actions'
import { changeTable, editableTable, type TableAction } from '../src/editor/tables'

/** This view adapter uses the production state, appenders, changes and transaction listeners. */
function editor(xml = '<page><p>base</p></page>', guarded = false): Wordgard {
  const view = {
    state: headlessState(parseXml(xml)),
    composing: false,
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
