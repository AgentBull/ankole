import { expect, test } from 'bun:test'
import { GardState } from '../src/core/state'
import { parseXml, printXml } from '../src/document/xml'
import { dispatchStep } from '../src/editor/block-insert'
import { BlockSelection } from '../src/editor/block-selection'
import { undo } from '../src/editor/commands'
import { blockDrop } from '../src/react/block-geometry'
import { open, readTree, expectReopens } from './helpers'

const page = (body: string) => open(parseXml(`<page>${body}</page>`))
const rect = (left = 100, top = 100, width = 300, height = 40) => ({
  left,
  top,
  width,
  height,
  right: left + width,
  bottom: top + height
})
const expectBody = (editor: ReturnType<typeof page>, body: string) =>
  expect(printXml(readTree(editor))).toBe(printXml(parseXml(`<page>${body}</page>`)))
function at(editor: ReturnType<typeof page>, text: string) {
  let result = -1
  editor.state.doc.iterate((node, pos) => {
    if (node.isPlot && node.inlineContent && node.textContent() === text) result = pos
  })
  if (result < 0) throw new Error(`Missing block: ${text}`)
  return result
}
const row = '<columns><column><p>A</p></column><column><p>B</p></column></columns>'

test.each([true, false])('a drop %s before the target moves the selected group in one undo step', before => {
  const original = '<p>A</p><p>B</p><p>C</p><p>D</p>'
  const editor = page(original)
  const result = blockDrop(
    editor.state,
    [at(editor, 'C'), at(editor, 'D')],
    { pos: at(editor, 'A'), rect: rect() },
    { x: 110, y: before ? 101 : 139, viewportWidth: 1000 },
    () => null
  )
  expect(result?.marker).toEqual({ left: 100, top: before ? 96 : 144, width: 300, height: 2 })
  dispatchStep(editor, result!.edit)
  expectBody(editor, before ? '<p>C</p><p>D</p><p>A</p><p>B</p>' : '<p>A</p><p>C</p><p>D</p><p>B</p>')
  expect(editor.state.selection).toBeInstanceOf(BlockSelection)
  expectReopens(editor)
  expect(undo(editor)).toBe(true)
  expectBody(editor, original)
})

test.each([-1, 1] as const)('the side %s marker creates a column and keeps its selected block', side => {
  const editor = page('<p>A</p><p>B</p>')
  const result = blockDrop(
    editor.state,
    [at(editor, 'B')],
    { pos: at(editor, 'A'), rect: rect() },
    { x: side < 0 ? 100 : 400, y: 120, viewportWidth: 1000 },
    () => null
  )
  expect(result?.marker).toEqual({ left: side < 0 ? 92 : 406, top: 100, width: 2, height: 40 })
  dispatchStep(editor, result!.edit)
  expectBody(editor, side < 0 ? '<columns><column><p>B</p></column><column><p>A</p></column></columns>' : row)
  expect(editor.state.selection).toBeInstanceOf(BlockSelection)
  expectReopens(editor)
  expect(undo(editor)).toBe(true)
  expectBody(editor, '<p>A</p><p>B</p>')
})

test('a narrow viewport keeps a side gesture in document order', () => {
  const editor = page('<p>A</p><p>B</p><p>C</p>')
  const result = blockDrop(
    editor.state,
    [at(editor, 'C')],
    { pos: at(editor, 'A'), rect: rect() },
    { x: 100, y: 120, viewportWidth: 600 },
    () => null
  )
  expect(result?.marker).toEqual({ left: 100, top: 144, width: 300, height: 2 })
  dispatchStep(editor, result!.edit)
  expectBody(editor, '<p>A</p><p>C</p><p>B</p>')
})

test('the indented marker inserts a child before existing children and undo restores their owner', () => {
  const original = '<block><p>Parent</p><p>Existing</p></block><p>Moved</p>'
  const editor = page(original)
  const result = blockDrop(
    editor.state,
    [at(editor, 'Moved')],
    { pos: 0, rect: rect() },
    { x: 150, y: 139, viewportWidth: 1000 },
    () => null
  )
  expect(result?.marker).toEqual({ left: 130, top: 144, width: 270, height: 2 })
  dispatchStep(editor, result!.edit)
  expectBody(editor, '<block><p>Parent</p><p>Moved</p><p>Existing</p></block>')
  expectReopens(editor)
  expect(undo(editor)).toBe(true)
  expectBody(editor, original)
})

test('moving left lifts the marker through nested list owners and drops outside the list', () => {
  const list = '<ul><li><p>Parent</p><ul><li><p>Child</p></li></ul></li></ul>'
  const editor = page(`<p>Moved</p>${list}<p>After</p>`)
  const listPos = editor.state.doc.firstChild!.length
  const result = blockDrop(
    editor.state,
    [0],
    { pos: at(editor, 'Child') - 1, rect: rect(160) },
    { x: 90, y: 139, viewportWidth: 1000 },
    pos => rect(pos === listPos ? 100 : 130)
  )
  expect(result?.marker).toEqual({ left: 100, top: 144, width: 300, height: 2 })
  dispatchStep(editor, result!.edit)
  expectBody(editor, `${list}<p>Moved</p><p>After</p>`)
  expectReopens(editor)
  expect(undo(editor)).toBe(true)
  expectBody(editor, `<p>Moved</p>${list}<p>After</p>`)
})

test.each([true, false])('dropping %s above a row returns its last column block to the page', above => {
  const editor = page(`${row}<p>After</p>`)
  const result = blockDrop(
    editor.state,
    [at(editor, 'B')],
    { pos: at(editor, 'A'), rect: rect(100, 100, 140) },
    { x: 110, y: above ? 90 : 150, viewportWidth: 1000 },
    () => rect()
  )
  expect(result?.marker).toEqual({ left: 100, top: above ? 96 : 144, width: 300, height: 2 })
  dispatchStep(editor, result!.edit)
  expectBody(editor, above ? '<p>B</p><p>A</p><p>After</p>' : '<p>A</p><p>B</p><p>After</p>')
  expectReopens(editor)
  expect(undo(editor)).toBe(true)
  expectBody(editor, `${row}<p>After</p>`)
})

test('self-drops and read-only documents have neither a marker nor an edit', () => {
  const editor = page('<p>A</p><p>B</p>')
  const hit = { pos: 0, rect: rect() }
  for (const x of [100, 110, 150, 400]) {
    expect(blockDrop(editor.state, [0], hit, { x, y: 120, viewportWidth: 1000 }, () => null)).toBeNull()
  }
  editor.dispatch({ effects: GardState.appendConfig.of(GardState.readOnly.of(true)) })
  for (const x of [100, 110, 150, 400]) {
    expect(blockDrop(editor.state, [at(editor, 'B')], hit, { x, y: 120, viewportWidth: 1000 }, () => null)).toBeNull()
  }
  expectBody(editor, '<p>A</p><p>B</p>')
})
