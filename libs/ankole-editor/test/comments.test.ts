import { expect, test } from 'bun:test'
import { ChangeSet, Leaf } from '../src/core/doc'
import { GardSelection } from '../src/core/state'
import { parseXml, printXml } from '../src/document/xml'
import { printMarkdown } from '../src/document/markdown'
import { pageDocument, readTree } from '../src/editor/convert'
import { headlessState } from '../src/editor/extension'
import { Comment, schema } from '../src/editor/schema'
import markDiffs from '../corpus/rust/mark-diffs.json'
import { commentRanges, commentSelection, trackCommentSelection, withoutCommentSlice } from '../src/editor/comments'
import { duplication, movement, relocation, turnInto } from '../src/editor/block-actions'
import { BlockSelection } from '../src/editor/block-selection'
import { portablePageChanges, preparePageUpdate } from '../src/editor/page-update'

const a = '019a2b00-0000-7000-8000-000000000001'
const b = '019a2b00-0000-7000-8000-000000000002'
const xml = `<page><p><comment ids="${a}">First</comment></p><p>Second</p><p>Third</p></page>`
const source = (state: ReturnType<typeof headlessState>) => printXml(readTree(state.doc))

test('comment anchors round trip in canonical XML and disappear from portable Markdown', () => {
  const tree = parseXml(
    `<page><p><comment ids="${b} ${a} ${a}"><strong>one</strong><comment ids="${b}"> two</comment></comment></p></page>`
  )
  const canonical = `<page><p><comment ids="${a} ${b}"><strong>one</strong> two</comment></p></page>`
  expect(printXml(tree)).toBe(canonical)
  expect(printXml(readTree(pageDocument(tree)))).toBe(canonical)
  expect(printMarkdown(tree)).toBe('**one** two')
  expect(() => parseXml('<page><p><comment ids="fake">text</comment></p></page>')).toThrow()
})

test('overlapping concurrent annotations union IDs and removing one preserves the other', () => {
  const doc = headlessState('hello').doc
  const left = ChangeSet.create(doc, { from: 1, to: 6, add: Comment.of([a]) })
  const right = ChangeSet.create(doc, { from: 1, to: 6, add: Comment.of([b]) })
  const pair = ChangeSet.transform(doc, left, right)
  const result = pair.a.apply(right.apply(doc))
  expect(result.eq(pair.b.apply(left.apply(doc)))).toBe(true)
  expect(printXml(readTree(result))).toBe(`<page><p><comment ids="${a} ${b}">hello</comment></p></page>`)
  const removed = ChangeSet.create(result, { from: 1, to: 6, remove: Comment.of([a]) }).apply(result)
  expect(printXml(readTree(removed))).toBe(`<page><p><comment ids="${b}">hello</comment></p></page>`)
})

test('native mark diffs preserve selection and converge with concurrent local typing', () => {
  // Rust asserts that page_diff produces these exact shared protocol fixtures.
  for (const sample of markDiffs) {
    const doc = pageDocument(parseXml(sample.before))
    const remote = ChangeSet.fromJSON(schema, sample.changes as ChangeSet.JSON)
    const target = pageDocument(parseXml(sample.after))
    expect(remote.apply(doc).eq(target)).toBe(true)
    for (let pos = 0; pos <= doc.length; pos++) expect(remote.mapPos(pos)).toBe(pos)

    const insert = { from: 3, insert: [Leaf.text('!')] }
    const local = ChangeSet.create(doc, insert)
    const pair = ChangeSet.transform(doc, remote, local)
    const result = pair.a.apply(local.apply(doc))
    expect(result.eq(pair.b.apply(remote.apply(doc)))).toBe(true)
    // The inserted character stays at its intended position with its own marks.
    expect(result.eq(ChangeSet.create(target, insert).apply(target))).toBe(true)
  }
})

test('native comment set differences preserve a concurrently added thread', () => {
  const sample = markDiffs[1]!
  const doc = pageDocument(parseXml(sample.before))
  const remote = ChangeSet.fromJSON(schema, sample.changes as ChangeSet.JSON)
  const concurrentID = '019a2b00-0000-7000-8000-000000000004'
  const local = ChangeSet.create(doc, { from: 1, to: 6, add: Comment.of([concurrentID]) })
  const pair = ChangeSet.transform(doc, remote, local)
  const result = pair.a.apply(local.apply(doc))
  expect(result.eq(pair.b.apply(remote.apply(doc)))).toBe(true)
  expect(printXml(readTree(result))).toBe(
    `<page><p><comment ids="${b} 019a2b00-0000-7000-8000-000000000003 ${concurrentID}">hello</comment></p></page>`
  )
})

test('production block move and drag relocation carry anchors; duplication and clipboard do not', () => {
  let state = headlessState(parseXml(xml))
  state = state.update({ selection: BlockSelection.of(state.doc, [0])! }).state
  const moved = preparePageUpdate(state.update(movement(state, 1)!)).state
  expect(source(moved)).toBe(`<page><p>Second</p><p><comment ids="${a}">First</comment></p><p>Third</p></page>`)
  const dragged = preparePageUpdate(state.update(relocation(state, [0], state.doc.length)!)).state
  expect(source(dragged)).toBe(`<page><p>Second</p><p>Third</p><p><comment ids="${a}">First</comment></p></page>`)
  const duplicate = preparePageUpdate(state.update(duplication(state)!)).state
  expect(source(duplicate)).toBe(
    `<page><p><comment ids="${a}">First</comment></p><p>First</p><p>Second</p><p>Third</p></page>`
  )
  expect(JSON.stringify(withoutCommentSlice(state.selection.toSlice(state.doc)).toJSON())).not.toContain('Comment')
  const code = preparePageUpdate(state.update(turnInto(state, { kind: 'code' })!)).state
  expect(source(code)).toBe(`<page><pre><comment ids="${a}">First</comment></pre><p>Second</p><p>Third</p></page>`)
})

test('host selection and anchor ranges use editor token positions', () => {
  let state = headlessState(parseXml(xml))
  state = state.update({ selection: GardSelection.range(1, 6) }).state
  expect(commentSelection({ state })).toEqual({ from: 1, to: 6, quote: 'First' })
  expect(commentRanges({ state })).toEqual([{ id: a, from: 1, to: 6 }])
  let code = headlessState('```\nhello\n```')
  code = code.update({ selection: GardSelection.range(1, 6) }).state
  expect(commentSelection({ state: code })).toEqual({ from: 1, to: 6, quote: 'hello' })
})

test('a draft selection follows retained source and invalidates after replacement even with identical text', () => {
  const editor = {
    state: headlessState('Before\n\nSelected phrase\n\nAfter'),
    dispatch(spec: Parameters<ReturnType<typeof headlessState>['update']>[0]) {
      this.state = this.state.update(spec).state
    }
  }
  const read = trackCommentSelection(editor, { from: 9, to: 24, quote: 'Selected phrase' })
  editor.dispatch({ changes: { from: 1, insert: [Leaf.text('New ')] } })
  expect(read(editor.state)).toEqual({ from: 13, to: 28, quote: 'Selected phrase' })
  // Even a partial deletion makes the user's original quote uncertain.
  editor.dispatch({ changes: { from: 21, to: 28 } })
  expect(read(editor.state)).toBeNull()
  const replacement = trackCommentSelection(editor, { from: 13, to: 21, quote: 'Selected' })
  editor.dispatch({ changes: { from: 13, to: 21, insert: [Leaf.text('Selected')] } })
  expect(replacement(editor.state)).toBeNull()
})

test('capturing another draft selection invalidates the previous reader', () => {
  const editor = {
    state: headlessState('First\n\nSecond'),
    dispatch(spec: Parameters<ReturnType<typeof headlessState>['update']>[0]) {
      this.state = this.state.update(spec).state
    }
  }
  const first = trackCommentSelection(editor, { from: 1, to: 6, quote: 'First' })
  const second = trackCommentSelection(editor, { from: 8, to: 14, quote: 'Second' })
  expect(first(editor.state)).toBeNull()
  expect(second(editor.state)).toEqual({ from: 8, to: 14, quote: 'Second' })
})

test('a paragraph move and a concurrent edit converge with the same comment anchor', () => {
  let state = headlessState(parseXml(xml))
  state = state.update({ selection: BlockSelection.of(state.doc, [0])! }).state
  const moved = preparePageUpdate(state.update(relocation(state, [0], state.doc.length)!)).changes
  const edited = ChangeSet.create(state.doc, { from: 21, insert: [Leaf.text('!')] })
  const transformed = ChangeSet.transform(state.doc, moved, edited)
  const left = transformed.a.apply(edited.apply(state.doc))
  const right = transformed.b.apply(moved.apply(state.doc))
  expect(left.eq(right)).toBe(true)
  expect(printXml(readTree(left))).toBe(
    `<page><p>Second</p><p>Third!</p><p><comment ids="${a}">First</comment></p></page>`
  )
})

test('code comments preserve whitespace and line break marks without changing portable code', () => {
  const xml = `<page><pre lang="ts">a<comment ids="${a}">b\n  c</comment>d</pre></page>`
  const tree = parseXml(xml)
  const doc = pageDocument(tree)
  expect(printXml(readTree(doc))).toBe(xml)
  expect(printMarkdown(tree)).toBe('```ts\nab\n  cd\n```')
  expect(commentRanges({ state: headlessState(tree) })).toEqual([{ id: a, from: 2, to: 7 }])
  expect(() => parseXml('<page><pre><strong>invalid</strong></pre></page>')).toThrow()
})

test('Mermaid comments preserve their source anchors through XML and editor round trips', () => {
  const xml = `<page><mermaid view="code">flowchart TD\n<comment ids="${a}">A --&gt; B</comment></mermaid></page>`
  const tree = parseXml(xml)
  const state = headlessState(tree)
  expect(printXml(readTree(state.doc))).toBe(xml)
  expect(commentRanges({ state })).toEqual([{ id: a, from: 14, to: 21 }])
  expect(printMarkdown(tree)).not.toContain(a)
  const unmarked = headlessState(parseXml('<page><mermaid view="code">flowchart TD\nA --&gt; B</mermaid></page>'))
  const annotated = unmarked.update({ changes: { from: 14, to: 21, add: Comment.of([a]) } }).state
  expect(source(annotated)).toBe(xml)
  const edited = annotated.update({ changes: { from: 21, insert: [Leaf.text('\nB --> C')] } }).state
  expect(commentRanges({ state: edited })).toEqual([{ id: a, from: 14, to: 21 }])
})

test('portable source edits retain current anchors and discard source thread IDs', () => {
  const before = headlessState(parseXml(xml)).doc
  const after = headlessState(
    parseXml(`<page><p><comment ids="${b}">First</comment></p><p>Updated</p><p>Third</p></page>`)
  ).doc
  const result = portablePageChanges(before, after).apply(before)
  expect(printXml(readTree(result))).toBe(
    `<page><p><comment ids="${a}">First</comment></p><p>Updated</p><p>Third</p></page>`
  )
  const rewritten = headlessState('Unrelated replacement').doc
  expect(commentRanges({ state: { doc: portablePageChanges(before, rewritten).apply(before) } })).toEqual([])
})
