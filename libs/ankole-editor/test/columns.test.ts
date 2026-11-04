import { expect, test } from 'bun:test'
import { parseXml, printXml } from '../src/document/xml'
import { ChangeSet, Leaf } from '../src/core/doc'
import { Correction } from '../src/core/state'
import { pageDocument, readTree as readDocument } from '../src/editor/convert'
import { pageCorrections } from '../src/editor/corrections'
import { columnDrop, columnInsertion, columnResize } from '../src/editor/columns'
import { deleteBlock, relocation, duplicateBlocks } from '../src/editor/block-actions'
import { Command, deleteCut, insertText } from '../src/core/command'
import { BlockSelection } from '../src/editor/block-selection'
import { Columns } from '../src/editor/schema'
import { insertImage, redo, undo } from '../src/editor/commands'
import { redoDepth, undoDepth } from '../src/core/history'
import { open, select, press, readTree, expectReopens, setComposing, endComposition, typeText } from './helpers'

const page = (body: string) => open(parseXml(`<page>${body}</page>`))
const column = (body: string) => `<column>${body}</column>`
const row = (...columns: string[]) => `<columns>${columns.map(column).join('')}</columns>`
const xml = (editor: ReturnType<typeof page>) => printXml(readTree(editor))
const expectBody = (editor: ReturnType<typeof page>, body: string) =>
  expect(xml(editor)).toBe(printXml(parseXml(`<page>${body}</page>`)))
function at(editor: ReturnType<typeof page>, text: string) {
  let result = -1
  editor.state.doc.iterate((node, pos) => {
    if (node.isPlot && node.inlineContent && node.textContent() === text) result = pos
  })
  if (result < 0) throw new Error(`Missing block: ${text}`)
  return result
}

test('column widths and content round trip; empty or single columns unwrap', () => {
  const editor = page('<columns><column width="1200"><p>A</p></column><column width="800"><p>B</p></column></columns>')
  expectReopens(editor)
  expectBody(page('<columns><column/><column width="1000"><p>A</p><p>B</p></column></columns>'), '<p>A</p><p>B</p>')
  expect(() => page('<column><p>A</p></column>')).toThrow()
  expect(() => page('<columns><column width="0"><p>A</p></column></columns>')).toThrow()
})

test.each([-1, 1] as const)('dropping a block on side %s makes editable columns and undo restores it', side => {
  const editor = page('<p>A</p><p>B</p><p>C</p>')
  const edit = columnDrop(editor.state, [at(editor, 'C')], at(editor, 'A'), side)
  expect(edit).not.toBeNull()
  editor.dispatch(edit!)
  expectBody(editor, `${side < 0 ? row('<p>C</p>', '<p>A</p>') : row('<p>A</p>', '<p>C</p>')}<p>B</p>`)
  expect(editor.state.selection).toBeInstanceOf(BlockSelection)
  expectReopens(editor)
  expect(undo(editor)).toBe(true)
  expectBody(editor, '<p>A</p><p>B</p><p>C</p>')
})

test('moving a column last block back to the page removes the column layout', () => {
  const editor = page(`${row('<p>A</p>', '<p>B</p>')}<p>C</p>`)
  editor.dispatch(relocation(editor.state, [at(editor, 'B')], editor.state.doc.length)!)
  expectBody(editor, '<p>A</p><p>C</p><p>B</p>')
  expectReopens(editor)
})

test.each(['Backspace', 'Delete'])('%s joins adjacent column text and undo restores the layout', key => {
  const initial = row('<p>A</p><p>A2</p>', '<p>B</p><p>B2</p>')
  const editor = page(initial)
  select(editor, key === 'Backspace' ? at(editor, 'B') + 1 : at(editor, 'A2') + 3)
  press(editor, key)
  expectBody(editor, row('<p>A</p><p>A2B</p>', '<p>B2</p>'))
  expect(editor.state.selection.head).toBe(at(editor, 'A2B') + 3)
  expectReopens(editor)
  expect(undo(editor)).toBe(true)
  expectBody(editor, initial)
})

test('joining the only block of a column unwraps the remaining column', () => {
  const editor = page(row('<p>A</p>', '<p>B</p>'))
  select(editor, at(editor, 'B') + 1)
  press(editor, 'Backspace')
  expectBody(editor, '<p>AB</p>')
  expect(editor.state.selection.head).toBe(2)
  expectReopens(editor)
  expect(undo(editor)).toBe(true)
  expectBody(editor, row('<p>A</p>', '<p>B</p>'))
})

test('a column first block can join the preceding page block', () => {
  const editor = page(`<p>Before</p>${row('<p>A</p><p>A2</p>', '<p>B</p>')}`)
  select(editor, at(editor, 'A') + 1)
  press(editor, 'Backspace')
  expectBody(editor, `<p>BeforeA</p>${row('<p>A2</p>', '<p>B</p>')}`)
  expectReopens(editor)
})

test('a drop beside an existing column creates a sibling column', () => {
  const editor = page(`${row('<p>A</p><p>A2</p>', '<p>B</p>')}<p>C</p>`)
  editor.dispatch(columnDrop(editor.state, [at(editor, 'C')], at(editor, 'A2'), 1)!)
  expectBody(editor, row('<p>A</p><p>A2</p>', '<p>C</p>', '<p>B</p>'))
  expectReopens(editor)
})

test('dropping one list item beside another block preserves its marker and leaves its siblings', () => {
  const editor = page('<p>A</p><ul><li><p>B</p></li><li><p>C</p></li></ul>')
  editor.dispatch(columnDrop(editor.state, [at(editor, 'B') - 1], at(editor, 'A'), 1)!)
  expectBody(editor, `${row('<p>A</p>', '<ul><li><p>B</p></li></ul>')}<ul><li><p>C</p></li></ul>`)
  expectReopens(editor)
})

test('inserting columns retains the current block and enters the first column', () => {
  const editor = page('<p>A</p>')
  select(editor, 1)
  editor.dispatch(columnInsertion(editor.state, 3)!)
  expectBody(editor, row('<p>A</p>', '<p/>', '<p/>'))
  expect(editor.state.selection.empty).toBe(true)
  press(editor, 'Enter')
  expectBody(editor, row('<p/><p>A</p>', '<p/>', '<p/>'))
  expectReopens(editor)
})

test('a one-item list can become a column without leaving an extra paragraph', () => {
  const editor = page('<ul><li><p>A</p></li></ul>')
  select(editor, 3)
  editor.dispatch(columnInsertion(editor.state, 2)!)
  expectBody(editor, row('<ul><li><p>A</p></li></ul>', '<p/>'))
  expectReopens(editor)
})

test('resizing a pair preserves its total width, clamps extremes, and round trips', () => {
  const editor = page(row('<p>A</p>', '<p>B</p>'))
  const left = at(editor, 'A') - 1
  const right = at(editor, 'B') - 1
  editor.dispatch(columnResize(editor.state, left, right, 1400)!)
  expectBody(editor, '<columns><column width="1400"><p>A</p></column><column width="600"><p>B</p></column></columns>')
  expectReopens(editor)
  editor.dispatch(columnResize(editor.state, left, right, 1000)!)
  expectBody(editor, row('<p>A</p>', '<p>B</p>'))
  expectReopens(editor)
})

test('deleting the only block of a column unwraps the remaining column without deleting its blocks', () => {
  const editor = page(row('<p>A</p><p>A2</p>', '<p>B</p>'))
  select(editor, at(editor, 'B') + 1)
  press(editor, 'Escape')
  press(editor, 'Backspace')
  expectBody(editor, '<p>A</p><p>A2</p>')
  expectReopens(editor)
})

test('disconnected selections delete, replace and move only the selected blocks', () => {
  const source = `${row('<p>A</p><p>A2</p>', '<p>B</p><p>B2</p>')}<p>After</p>`
  const editor = page(source)
  const choose = () =>
    editor.dispatch({ selection: BlockSelection.of(editor.state.doc, [at(editor, 'A'), at(editor, 'B')])! })
  choose()
  press(editor, 'Backspace')
  expectBody(editor, `${row('<p>A2</p>', '<p>B2</p>')}<p>After</p>`)
  undo(editor)
  choose()
  const range = editor.state.selection.replacementRange
  Command.dispatch(editor, insertText, { ...range, insert: 'Replacement', userEvent: 'input.type' })
  expectBody(editor, `${row('<p>Replacement</p><p>A2</p>', '<p>B2</p>')}<p>After</p>`)
  undo(editor)
  choose()
  expect(insertImage(editor, { src: '/image.png', alt: 'Replacement' })).toBe(true)
  expectBody(editor, `${row('<p><img src="/image.png" alt="Replacement"/></p><p>A2</p>', '<p>B2</p>')}<p>After</p>`)
  undo(editor)
  choose()
  duplicateBlocks(editor)
  expectBody(editor, `${row('<p>A</p><p>A2</p>', '<p>B</p><p>A</p><p>B</p><p>B2</p>')}<p>After</p>`)
  undo(editor)
  choose()
  editor.dispatch(relocation(editor.state, [at(editor, 'A'), at(editor, 'B')], editor.state.doc.length)!)
  expectBody(editor, `${row('<p>A2</p>', '<p>B2</p>')}<p>After</p><p>A</p><p>B</p>`)
  expectReopens(editor)
})

test('starting composition only defers cleanup of the row that hosts its paragraph', () => {
  const editor = page(`${row('<p>A</p><p>A2</p>', '<p>A3</p>')}${row('<p>C</p>', '<p>B</p>')}`)
  editor.dispatch({ selection: BlockSelection.of(editor.state.doc, [at(editor, 'A'), at(editor, 'B')])! })
  expect(
    Command.dispatch(editor, insertText, {
      ...editor.state.selection.replacementRange,
      insert: 'Z',
      userEvent: 'input.type.compose.start'
    })
  ).toBe(true)
  let rows = 0
  editor.state.doc.iterate(node => {
    if (node.type === Columns.type) rows++
  })
  expect(rows).toBe(1)
  expectBody(editor, `${row('<p>Z</p><p>A2</p>', '<p>A3</p>')}<p>C</p>`)
})

test.each([
  { layers: 2, marked: false, cancel: false },
  { layers: 2, marked: true, cancel: true },
  { layers: 3, marked: false, cancel: true },
  { layers: 3, marked: true, cancel: false }
])('composition end cleans its outer column hosts ($layers layers, marked=$marked, cancel=$cancel)', scenario => {
  const inner = (text: string) =>
    row(`<p>${text}</p>`, '<p>Keep</p>').replace(
      '<columns>',
      scenario.marked ? '<columns data-key="kept">' : '<columns>'
    )
  let initial = inner('A')
  for (let index = 1; index < scenario.layers; index++) initial = row(initial, `<p>Remove ${index}</p>`)
  const editor = page(`${initial}<p>After</p>`)
  const original = editor.state.doc
  editor.dispatch({
    selection: BlockSelection.of(editor.state.doc, [
      at(editor, 'A'),
      ...Array.from({ length: scenario.layers - 1 }, (_, index) => at(editor, `Remove ${index + 1}`))
    ])!
  })
  setComposing(editor, true)
  Command.dispatch(editor, insertText, {
    ...editor.state.selection.replacementRange,
    insert: 'zh',
    userEvent: 'input.type.compose.start'
  })
  const from = at(editor, 'zh') + 1
  Command.dispatch(editor, insertText, {
    from,
    to: from + 2,
    insert: scenario.cancel ? '' : '中',
    userEvent: 'input.type.compose'
  })
  endComposition(editor)

  // Compare raw documents: XML export alone would normalize away the leftover outer rows.
  const expected = page(`${inner(scenario.cancel ? '' : '中')}<p>After</p>`).state.doc
  expect(editor.state.doc.eq(expected)).toBe(true)
  expect(undoDepth(editor.state)).toBe(1)
  expectReopens(editor)
  expect(undo(editor)).toBe(true)
  expect(editor.state.doc.eq(original)).toBe(true)
  expect(undoDepth(editor.state)).toBe(0)
  expect(redoDepth(editor.state)).toBe(1)
  expect(redo(editor)).toBe(true)
  expect(editor.state.doc.eq(expected)).toBe(true)
  expectReopens(editor)
})

test.each(
  [
    { tag: 'pre', attributes: ' lang="ts"', nested: false },
    { tag: 'h2', attributes: ' data-key="kept"', nested: false },
    { tag: 'pre', attributes: ' lang="ts"', nested: true },
    { tag: 'h2', attributes: ' data-key="kept"', nested: true }
  ].flatMap(scenario => [false, true].map(cancel => ({ ...scenario, cancel })))
)(
  'cross-column composition preserves its $tag host (nested=$nested, cancel=$cancel)',
  ({ tag, attributes, nested, cancel }) => {
    const block = (text: string) => `<${tag}${attributes}>${text}</${tag}>`
    const inner = row(block('Left'), '<p>Right</p>')
    const editor = page(nested ? row(inner, '<p>Outer</p>') : inner)
    const original = editor.state.doc
    select(editor, at(editor, 'Left') + 2, at(editor, 'Right') + 3)
    setComposing(editor, true)
    const { from, to } = editor.state.selection
    Command.dispatch(editor, insertText, {
      from,
      to,
      insert: 'zh',
      userEvent: 'input.type.compose.start'
    })
    const host = editor.state.sel.head.parent
    Command.dispatch(editor, insertText, {
      from: host.start + 1,
      to: host.start + 3,
      insert: cancel ? '' : '中',
      userEvent: 'input.type.compose'
    })
    endComposition(editor)

    const text = cancel ? 'Lght' : 'L中ght'
    const caret = cancel ? 2 : 3
    const expected = page(nested ? row(block(text), '<p>Outer</p>') : block(text)).state.doc
    expect(editor.state.doc.eq(expected)).toBe(true)
    expect(editor.state.selection.head).toBe(at(editor, text) + caret)
    expect(undoDepth(editor.state)).toBe(1)
    expectReopens(editor)
    expect(undo(editor)).toBe(true)
    expect(editor.state.doc.eq(original)).toBe(true)
    expect(redo(editor)).toBe(true)
    expect(editor.state.doc.eq(expected)).toBe(true)
    expect(editor.state.selection.head).toBe(at(editor, text) + caret)
    typeText(editor, '继续')
    const continued = cancel ? 'L继续ght' : 'L中继续ght'
    expectBody(editor, nested ? row(block(continued), '<p>Outer</p>') : block(continued))
    expectReopens(editor)
  }
)

test.each([false, true])('composition cleanup follows its list paragraph through columns (caret moved=%s)', moved => {
  const editor = page(`<ul><li>${row('<p>A</p>', '<p>B</p>')}</li></ul><p>Keep</p>`)
  const original = editor.state.doc
  editor.dispatch({ selection: BlockSelection.of(editor.state.doc, [at(editor, 'A'), at(editor, 'B')])! })
  setComposing(editor, true)
  Command.dispatch(editor, insertText, {
    ...editor.state.selection.replacementRange,
    insert: 'zh',
    userEvent: 'input.type.compose.start'
  })
  const paragraph = editor.state.sel.head.parent
  expect(paragraph.parent!.node.name).toBe('Column')
  Command.dispatch(editor, insertText, {
    from: paragraph.start,
    to: paragraph.end,
    insert: '',
    userEvent: 'input.type.compose'
  })
  if (moved) select(editor, at(editor, 'Keep') + 3)
  endComposition(editor)

  const expected = page('<ul><li /></ul><p>Keep</p>').state.doc
  expect(editor.state.doc.eq(expected)).toBe(true)
  if (moved) expect(editor.state.selection.head).toBe(at(editor, 'Keep') + 3)
  expect(undoDepth(editor.state)).toBe(1)
  expectReopens(editor)
  expect(undo(editor)).toBe(true)
  expect(editor.state.doc.eq(original)).toBe(true)
  expect(redo(editor)).toBe(true)
  expect(editor.state.doc.eq(expected)).toBe(true)
  if (moved) expect(editor.state.selection.head).toBe(at(editor, 'Keep') + 3)
  expectReopens(editor)
})

test('deleting a disconnected selection that touches both document edges preserves the middle block', () => {
  const editor = page('<p>A</p><p>Keep</p><p>B</p>')
  editor.dispatch({ selection: BlockSelection.of(editor.state.doc, [at(editor, 'A'), at(editor, 'B')])! })
  expect(deleteBlock(editor, at(editor, 'A'))).toBe(true)
  expectBody(editor, '<p>Keep</p>')
  expectReopens(editor)
})

// Each edit over a text range that crosses into the next column, as Backspace, typing, Enter and cut apply it.
const rangeEdits: [string, (editor: ReturnType<typeof page>) => unknown][] = [
  ['Backspace', editor => press(editor, 'Backspace')],
  ['typing', editor => typeText(editor, 'Z')],
  ['Enter', editor => press(editor, 'Enter')],
  ['cut', editor => Command.dispatch(editor, deleteCut)]
]

test.each(rangeEdits)('%s over a range into the next column joins the text and keeps both columns', (name, edit) => {
  const initial = row('<p>Left</p><p>Left second</p>', '<p>Right</p><p>Right second</p>')
  const editor = page(initial)
  select(editor, at(editor, 'Left second') + 5, at(editor, 'Right') + 3)
  edit(editor)
  const left = {
    Backspace: '<p>Leftght</p>',
    typing: '<p>LeftZght</p>',
    Enter: '<p>Left</p><p>ght</p>',
    cut: '<p>Leftght</p>'
  }[name]
  expectBody(editor, row(`<p>Left</p>${left}`, '<p>Right second</p>'))
  expectReopens(editor)
  expect(undo(editor)).toBe(true)
  expectBody(editor, initial)
})

test('a range inside one column keeps the column layout', () => {
  const editor = open(
    '<columns>\n  <column>\n    - x1\n      - x2\n  </column>\n\n  <column>\n    y\n  </column>\n</columns>'
  )
  select(editor, at(editor, 'x1') + 2, at(editor, 'x2') + 2)
  press(editor, 'Backspace')
  expectBody(editor, row('<ul><li><p>x2</p></li></ul>', '<p>y</p>'))
})

test.each([
  ['Right', row('<p>Left</p><p>Leftght</p>', '<p>Right second</p>')],
  ['Right second', '<p>Left</p><p>Leftght second</p>']
])('Backspace into %s, Enter and two undo steps restore the columns', (target, deleted) => {
  const initial = row('<p>Left</p><p>Left second</p>', '<p>Right</p><p>Right second</p>')
  const editor = page(initial)
  select(editor, at(editor, 'Left second') + 5, at(editor, target) + 3)
  press(editor, 'Backspace')
  expectBody(editor, deleted)
  press(editor, 'Enter')
  expect(undo(editor)).toBe(true)
  expectBody(editor, deleted)
  expect(undo(editor)).toBe(true)
  expectBody(editor, initial)
})

test('a remote deletion that leaves one column flattens the row when checked with the start document', () => {
  const doc = pageDocument(parseXml(`<page>${row('<p>Left</p>', '<p>Right</p>')}</page>`))
  const at: Record<string, number> = {}
  doc.iterate((node, pos) => {
    if (node.isText) at[node.param as string] = pos
  })
  // The raw change of a peer, as it arrives through collaboration, without local fitting.
  const changes = ChangeSet.create(doc, { from: at.Left! + 2, to: at.Right! + 2 })
  const next = changes.apply(doc)
  expect(Correction.check(changes, next, pageCorrections)).toBeNull()
  const correction = Correction.check(changes, next, pageCorrections, doc)!
  expect(printXml(readDocument(correction.apply(next)))).toBe('<page><p>Leght</p></page>')
})

test('an earlier change in the same paragraph does not hide a deletion that left one column', () => {
  const doc = pageDocument(parseXml(`<page>${row('<p>Left</p>', '<p>Right</p>')}</page>`))
  const at: Record<string, number> = {}
  doc.iterate((node, pos) => {
    if (node.isText) at[node.param as string] = pos
  })
  const changes = ChangeSet.create(doc, [
    { from: at.Left! + 1, insert: [Leaf.text('x')] },
    { from: at.Left! + 2, to: at.Right! + 2 }
  ])
  const next = changes.apply(doc)
  const correction = Correction.check(changes, next, pageCorrections, doc)!
  expect(printXml(readDocument(correction.apply(next)))).toBe('<page><p>Lxeght</p></page>')
})
