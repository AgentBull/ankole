import { expect, test } from 'bun:test'
import { Leaf, type Node } from '../src/core/doc'
import { Transaction } from '../src/core/state'
import { history } from '../src/core/history'
import { Emphasis, Strong, Paragraph } from '../src/core/types'
import { Blockquote } from '../src/editor/schema'
import { PageSession } from '../src/editor/page-session'
import { limits } from '../src/document/tree'
import { parseXml, printXml } from '../src/document/xml'
import { pageDocument, readTree } from '../src/editor/convert'
import { headlessState } from '../src/editor/extension'
import { preparePageUpdate } from '../src/editor/page-update'
import { redo, undo } from '../src/editor/commands'
import { open } from './helpers'

test('an already canonical transaction keeps its identity', () => {
  const transaction = headlessState('plain').update({ changes: { from: 1, insert: [Leaf.text('x')] } })
  expect(preparePageUpdate(transaction)).toBe(transaction)
})

test('typing into an empty page keeps the caret, metadata, and one undo step', () => {
  const editor = open('')
  const marker = Transaction.Annotation.define<string>()
  const raw = editor.state.update({
    changes: { from: 1, insert: [Leaf.text('🙂')] },
    selection: { anchor: 3 },
    annotations: [marker.of('kept'), history.isolate.of(true)],
    userEvent: 'input.type',
    scrollIntoView: true
  })
  const prepared = preparePageUpdate(raw)
  expect(prepared.newDoc.eq(pageDocument(parseXml('<page><p>🙂</p></page>')))).toBe(true)
  expect(prepared.newSelection.anchor).toBe(3)
  expect(prepared.annotation(marker)).toBe('kept')
  expect(prepared.annotation(Transaction.userEvent)).toBe('input.type')
  expect(prepared.annotation(history.isolate)).toBe(true)
  expect(prepared.scrollIntoView).toBe(true)
  editor.dispatch(prepared)
  expect(undo(editor)).toBe(true)
  expect(printXml(readTree(editor.state.doc))).toBe('<page />')
  expect(undo(editor)).toBe(false)
  expect(redo(editor)).toBe(true)
  expect(editor.state.doc.eq(prepared.newDoc)).toBe(true)
})

test.each([
  ['strong', Strong],
  ['em', Emphasis]
] as const)('%s whitespace changes only marks and preserves every position and adjacent embed', (name, mark) => {
  const state = headlessState(parseXml('<page><p>a b</p><embed ref="r" table="t" view="v" /><p>c d</p></page>'))
  const third = state.doc.content[0]!.length + 1
  const prepared = preparePageUpdate(
    state.update({
      changes: [
        { from: 1, to: 3, add: mark },
        { from: third + 1, to: third + 3, add: mark }
      ],
      selection: { anchor: 3 }
    })
  )
  expect(printXml(readTree(prepared.newDoc))).toBe(
    `<page><p><${name}>a</${name}> b</p><embed ref="r" table="t" view="v" /><p><${name}>c</${name}> d</p></page>`
  )
  expect(prepared.newDoc.eq(pageDocument(readTree(prepared.newDoc)))).toBe(true)
  expect(prepared.newDoc.content[1]!.eq(state.doc.content[1]!)).toBe(true)
  expect(prepared.changes.sections.filter((_, index) => index % 2 === 1).every(section => section < 0)).toBe(true)
  for (let position = 0; position <= state.doc.length; position++) {
    expect(prepared.changes.mapPos(position)).toBe(position)
  }
  expect(prepared.newSelection.anchor).toBe(3)
})

test('structural normalization maps the selection and transaction effects together', () => {
  const state = headlessState('')
  const position = Transaction.Effect.define<number>({ map: (value, changes) => changes.mapPos(value, 1) })
  const raw = state.update({
    changes: { from: state.doc.length, insert: pageDocument(parseXml('<page><p>x</p></page>')).content },
    selection: { anchor: 4 },
    effects: position.of(4)
  })
  const prepared = preparePageUpdate(raw)
  expect(prepared.newDoc.eq(pageDocument(parseXml('<page><p>x</p></page>')))).toBe(true)
  expect(prepared.newSelection.anchor).toBe(2)
  expect(prepared.effects.find(effect => effect.is(position))?.value).toBe(2)
})

test('submission removes invalid input without splitting a valid surrogate pair', () => {
  const state = headlessState('a🙂b')
  const prepared = preparePageUpdate(state.update({ changes: { from: 4, insert: [Leaf.text('\ud83d')] } }))
  expect(prepared.newDoc.eq(state.doc)).toBe(true)
  expect(prepared.changes.empty).toBe(true)
})

test('a rejected oversized batch does not change the editor or its history', () => {
  const editor = open('before')
  const state = editor.state
  const raw = state.update({ changes: { from: 1, insert: [Leaf.text('a'.repeat(limits.source))] } })
  expect(() => preparePageUpdate(raw)).toThrow('源码超过')
  expect(editor.state).toBe(state)
  expect(undo(editor)).toBe(false)
})

for (const boundary of ['source', 'nodes', 'depth'] as const) {
  test(`dispatch rejects one over the ${boundary} boundary before document, revision or history changes`, () => {
    const editor = open('before')
    const session = new PageSession(editor)
    if (boundary === 'source') {
      editor.dispatch({
        changes: { from: 1, to: 7, insert: [Leaf.text('a'.repeat(limits.source - '<page><p></p></page>'.length))] }
      })
      expect(session.readXml().xml.length).toBe(limits.source)
    } else if (boundary === 'nodes') {
      editor.dispatch({
        changes: {
          from: 0,
          to: editor.state.doc.length,
          insert: Array.from({ length: limits.nodes - 1 }, () => Paragraph.create([]))
        }
      })
    } else {
      let node: Node = Paragraph.create([Leaf.text('a')])
      for (let index = 0; index < limits.depth - 2; index++) node = Blockquote.create([node])
      editor.dispatch({ changes: { from: 0, to: editor.state.doc.length, insert: [node] } })
    }
    const accepted = editor.state
    const revision = session.revision
    const xml = session.readXml().xml
    expect(() =>
      editor.dispatch({
        changes:
          boundary === 'source'
            ? { from: 1, insert: [Leaf.text('x')] }
            : boundary === 'nodes'
              ? { from: 0, insert: [Paragraph.create([])] }
              : { from: 0, to: editor.state.doc.length, insert: [Blockquote.create(editor.state.doc.content)] }
      })
    ).toThrow()
    expect(editor.state).toBe(accepted)
    expect(session.revision).toBe(revision)
    expect(session.readXml().xml).toBe(xml)
    expect(undo(editor)).toBe(true)
    expect(session.readXml().xml).toBe('<page><p>before</p></page>')
    expect(undo(editor)).toBe(false)
    editor.dispatch({ changes: { from: 1, insert: [Leaf.text('after ')] } })
    expect(session.readXml().xml).toBe('<page><p>after before</p></page>')
    session.dispose()
  })
}
