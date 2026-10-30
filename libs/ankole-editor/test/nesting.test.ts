import { expect, test } from 'bun:test'
import type { Wordgard } from '../src/core/editor'
import { parseXml, printXml } from '../src/document/xml'
import { BlockSelection } from '../src/editor/block-selection'
import { relocation, turnBlockInto } from '../src/editor/block-actions'
import { undo } from '../src/editor/commands'
import { open, select, press, readTree, expectReopens, exportMarkdown } from './helpers'

const xml = (editor: Wordgard) => printXml(readTree(editor))
const page = (body: string) => open(parseXml(`<page>${body}</page>`))
const expectBody = (editor: Wordgard, body: string) =>
  expect(xml(editor)).toBe(printXml(parseXml(`<page>${body}</page>`)))
function caret(editor: Wordgard, value: string, end = false) {
  let at = -1
  editor.state.doc.iterate((node, pos) => {
    if (node.isText && node.param === value) at = pos + (end ? value.length : 0)
  })
  if (at < 0) throw new Error(`Missing text: ${value}`)
  select(editor, at)
}

test('Tab creates structural children; parent duplication, deletion, and undo include them', () => {
  const editor = page('<p>Parent</p><p>Child</p><p>After</p>')
  caret(editor, 'Child')
  press(editor, 'Tab')
  const subtree = '<block><p>Parent</p><p>Child</p></block>'
  expectBody(editor, `${subtree}<p>After</p>`)
  caret(editor, 'Parent')
  press(editor, 'Escape')
  expect(editor.state.selection).toBeInstanceOf(BlockSelection)
  press(editor, 'Meta-d')
  expectBody(editor, `${subtree}${subtree}<p>After</p>`)
  press(editor, 'Backspace')
  expectBody(editor, `${subtree}<p>After</p>`)
  expect(undo(editor)).toBe(true)
  expectBody(editor, `${subtree}${subtree}<p>After</p>`)
  expectReopens(editor)
})

test('cross-column block selection nests together and undo restores both columns and selection', () => {
  const editor = page(
    '<columns><column width="1200"><p>Left</p><p>Left second</p></column><column width="800"><p>Right</p><p>Right second</p></column></columns>'
  )
  caret(editor, 'Left second')
  press(editor, 'Escape')
  press(editor, 'Shift-ArrowDown')
  expect(
    (editor.state.selection as BlockSelection).blocks.map(unit => (unit.node.isPlot ? unit.node.textContent() : null))
  ).toEqual(['Left second', 'Right'])
  const before = xml(editor)
  const selected = editor.state.selection
  press(editor, 'Tab')
  expectBody(
    editor,
    '<columns><column width="1200"><block><p>Left</p><p>Left second</p><p>Right</p></block></column><column width="800"><p>Right second</p></column></columns>'
  )
  expect(
    (editor.state.selection as BlockSelection).blocks.map(unit => (unit.node.isPlot ? unit.node.textContent() : null))
  ).toEqual(['Left second', 'Right'])
  expectReopens(editor)
  expect(undo(editor)).toBe(true)
  expect(xml(editor)).toBe(before)
  expect(editor.state.selection.eq(selected)).toBe(true)
  press(editor, 'Shift-Tab')
  expect(xml(editor)).toBe(before)
})

test('disconnected indentation preserves unselected siblings and appends below existing children', () => {
  const editor = page('<block><p>Parent</p><p>Existing</p></block><p>A</p><p>Keep</p><p>B</p>')
  const positions: number[] = []
  editor.state.doc.iterate((node, pos) => {
    if (node.isPlot && node.name === 'Paragraph' && ['A', 'B'].includes(node.textContent())) positions.push(pos)
  })
  editor.dispatch({ selection: BlockSelection.of(editor.state.doc, positions)! })
  press(editor, 'Tab')
  expectBody(editor, '<block><p>Parent</p><p>Existing</p><p>A</p><p>B</p></block><p>Keep</p>')
  expectReopens(editor)
})

test('selected children from different parents lift independently while root blocks stay', () => {
  const editor = page('<block><p>One</p><p>A</p></block><block><p>Two</p><p>B</p><p>Following</p></block><p>Root</p>')
  const positions: number[] = []
  editor.state.doc.iterate((node, pos) => {
    if (node.isPlot && node.name === 'Paragraph' && ['A', 'B', 'Root'].includes(node.textContent())) positions.push(pos)
  })
  editor.dispatch({ selection: BlockSelection.of(editor.state.doc, positions)! })
  const before = xml(editor)
  press(editor, 'Shift-Tab')
  expectBody(
    editor,
    '<block><p>One</p></block><p>A</p><block><p>Two</p></block><block><p>B</p><p>Following</p></block><p>Root</p>'
  )
  expect(
    (editor.state.selection as BlockSelection).blocks.map(unit => (unit.node.isPlot ? unit.node.textContent() : null))
  ).toEqual(['A', 'B\nFollowing', 'Root'])
  expectReopens(editor)
  expect(undo(editor)).toBe(true)
  expect(xml(editor)).toBe(before)
})

test('Tab on the first child stays; later children can nest under their previous sibling', () => {
  const editor = page('<block><p>Parent</p><p>First</p><p>Second</p></block>')
  caret(editor, 'First')
  const before = xml(editor)
  press(editor, 'Tab')
  expect(xml(editor)).toBe(before)
  caret(editor, 'Second')
  press(editor, 'Tab')
  expectBody(editor, '<block><p>Parent</p><block><p>First</p><p>Second</p></block></block>')
  expectReopens(editor)
})

test.each(['Shift-Tab', 'Backspace'])('%s lifts the child and puts its following siblings under it', key => {
  const editor = page('<block><p>Parent</p><p>First</p><p>Second</p></block><p>After</p>')
  caret(editor, 'First')
  press(editor, key)
  expectBody(editor, '<block><p>Parent</p></block><block><p>First</p><p>Second</p></block><p>After</p>')
  expectReopens(editor)
})

test('Enter at the end of a parent transfers children to the new sibling', () => {
  const editor = page('<block><p>Parent</p><p>Child</p></block><p>After</p>')
  caret(editor, 'Parent', true)
  press(editor, 'Enter')
  expectBody(editor, '<block><p>Parent</p></block><block><p/><p>Child</p></block><p>After</p>')
  expect(editor.state.sel.head.parent.node.isTextblock).toBe(true)
  expect(editor.state.sel.head.parent.node.content.length).toBe(0)
  expectReopens(editor)
})

test('Enter at a parent start inserts before it and keeps its children', () => {
  const editor = page('<block><h2>Parent</h2><p>Child</p></block>')
  caret(editor, 'Parent')
  press(editor, 'Enter')
  expectBody(editor, '<p/><block><h2>Parent</h2><p>Child</p></block>')
})

test('Enter inside code keeps its literal newline even when that block owns children', () => {
  const editor = page('<block><pre>code</pre><p>Child</p></block>')
  caret(editor, 'code', true)
  press(editor, 'Enter')
  expectBody(editor, '<block><pre>code\n</pre><p>Child</p></block>')
})

test('Tab can attach a paragraph after a list to its last item', () => {
  const editor = page('<ul><li><p>Item</p></li></ul><p>Child</p>')
  caret(editor, 'Child')
  press(editor, 'Tab')
  expectBody(editor, '<ul><li><p>Item</p><p>Child</p></li></ul>')
  expectReopens(editor)
})

test.each(['ul', 'ol'])('Tab nests the leading %s item under a paragraph without moving later items', tag => {
  const editor = page(`<p>Parent</p><${tag}><li><p>Child</p></li><li><p>After</p></li></${tag}>`)
  caret(editor, 'Child', true)
  press(editor, 'Tab')
  expectBody(
    editor,
    `<block><p>Parent</p><${tag}><li><p>Child</p></li></${tag}></block><${tag}><li><p>After</p></li></${tag}>`
  )
  expect(editor.state.sel.head.textblockParent!.node.textContent()).toBe('Child')
  expectReopens(editor)
  press(editor, 'Shift-Tab')
  expectBody(editor, `<p>Parent</p><${tag}><li><p>Child</p></li><li><p>After</p></li></${tag}>`)
})

test('a selected list prefix nests below a paragraph together and preserves task state and children', () => {
  const editor = page(
    '<p>Parent</p><ul><li task="done"><p>A</p><p>Child</p></li><li><p>B</p></li><li><p>C</p></li></ul>'
  )
  caret(editor, 'A')
  press(editor, 'Escape')
  press(editor, 'Shift-ArrowDown')
  press(editor, 'Tab')
  expectBody(
    editor,
    '<block><p>Parent</p><ul><li task="done"><p>A</p><p>Child</p></li><li><p>B</p></li></ul></block><ul><li><p>C</p></li></ul>'
  )
  expectReopens(editor)
})

test.each([0, 1])('lifting item %s from an ordinary parent brings its following children with it', index => {
  const editor = page(
    '<block><p>Parent</p><ul><li><p>A</p></li><li><p>B</p></li></ul><p>Following child</p></block><p>After</p>'
  )
  caret(editor, index ? 'B' : 'A')
  press(editor, 'Shift-Tab')
  expectBody(
    editor,
    index
      ? '<block><p>Parent</p><ul><li><p>A</p></li></ul></block><ul><li><p>B</p><p>Following child</p></li></ul><p>After</p>'
      : '<p>Parent</p><ul><li><p>A</p><ul><li><p>B</p></li></ul><p>Following child</p></li></ul><p>After</p>'
  )
  expectReopens(editor)
})

test('Enter in an empty list child of an ordinary parent lifts it while retaining its marker', () => {
  const editor = page('<block><p>Parent</p><ul><li><p>A</p></li><li/></ul></block>')
  select(editor, editor.state.doc.length - 3)
  press(editor, 'Enter')
  expectBody(editor, '<block><p>Parent</p><ul><li><p>A</p></li></ul></block><ul><li/></ul>')
  expectReopens(editor)
})

test('block selection expands from a child to the parent, then shrinks', () => {
  const editor = page('<block><p>Parent</p><p>Child</p></block>')
  caret(editor, 'Child')
  press(editor, 'Escape')
  const child = editor.state.selection
  press(editor, 'Shift-ArrowUp')
  expect((editor.state.selection as BlockSelection).blocks[0]!.node.name).toBe('BlockGroup')
  press(editor, 'Shift-ArrowDown')
  expect(editor.state.selection.eq(child)).toBe(true)
})

test('plain children of a list item have their own selection and lift with their following siblings', () => {
  const editor = page('<ul><li><p>Item</p><p>Child</p><p>Following child</p></li><li><p>Next item</p></li></ul>')
  caret(editor, 'Child')
  press(editor, 'Escape')
  expect(
    (editor.state.selection as BlockSelection).blocks.map(block =>
      block.node.isPlot ? block.node.textContent() : null
    )
  ).toEqual(['Child'])
  press(editor, 'Enter')
  press(editor, 'Shift-Tab')
  expectBody(
    editor,
    '<ul><li><p>Item</p></li></ul><block><p>Child</p><p>Following child</p></block><ul><li><p>Next item</p></li></ul>'
  )
  expectReopens(editor)
})

test('Enter in a plain child of a list item creates another plain child; an empty child exits', () => {
  const editor = page('<ul><li><p>Item</p><p>Child</p></li></ul>')
  caret(editor, 'Child', true)
  const before = xml(editor)
  press(editor, 'Tab')
  expect(xml(editor)).toBe(before)
  press(editor, 'Enter')
  expectBody(editor, '<ul><li><p>Item</p><p>Child</p><p/></li></ul>')
  press(editor, 'Enter')
  expectBody(editor, '<ul><li><p>Item</p><p>Child</p></li></ul><p/>')
})

test('nesting stops at 49 child levels, including the subtree being moved', () => {
  const body = '<p>Previous</p><block><p>Parent</p><p>Child</p></block>'
  const editor = page('<block><p>Ancestor</p>'.repeat(48) + body + '</block>'.repeat(48))
  caret(editor, 'Parent')
  const before = xml(editor)
  press(editor, 'Tab')
  expect(xml(editor)).toBe(before)
  expectReopens(editor)
})

test('turning a parent into a heading changes its own text and preserves children', () => {
  const editor = page('<block><p>Parent</p><p>Child</p></block>')
  expect(turnBlockInto(editor, 0, 'h2')).toBe(true)
  expectBody(editor, '<block><h2>Parent</h2><p>Child</p></block>')
})

test('turning a parent into a list item moves its children into that item', () => {
  const editor = page('<block><p>Parent</p><p>Child</p></block>')
  expect(turnBlockInto(editor, 0, 'bullet')).toBe(true)
  expectBody(editor, '<ul><li><p>Parent</p><p>Child</p></li></ul>')
  expect(turnBlockInto(editor, 1, 'paragraph')).toBe(true)
  expectBody(editor, '<block><p>Parent</p><p>Child</p></block>')
  expectReopens(editor)
})

test('a parent can change to a callout and back without converting its children', () => {
  const editor = page('<block><p>Parent</p><p>Child</p></block>')
  expect(turnBlockInto(editor, 0, 'callout')).toBe(true)
  expectBody(editor, '<block><callout><p>Parent</p></callout><p>Child</p></block>')
  expect(turnBlockInto(editor, 0, 'paragraph')).toBe(true)
  expectBody(editor, '<block><p>Parent</p><p>Child</p></block>')
  expectReopens(editor)
})

test('Backspace at a parent start joins its text to the preceding block and lifts its children', () => {
  const editor = page('<p>Before</p><block><p>Parent</p><p>Child</p><p>Second</p></block>')
  caret(editor, 'Parent')
  press(editor, 'Backspace')
  expectBody(editor, '<p>BeforeParent</p><p>Child</p><p>Second</p>')
  expectReopens(editor)
})

test('dragging below a paragraph can make a child, and undo restores the original document', () => {
  const editor = page('<p>Parent</p><p>Child</p><p>After</p>')
  const first = editor.state.doc.firstChild!
  const change = relocation(editor.state, [first.length], first.length, 0)
  expect(change).not.toBeNull()
  editor.dispatch(change!)
  expectBody(editor, '<block><p>Parent</p><p>Child</p></block><p>After</p>')
  expect(undo(editor)).toBe(true)
  expectBody(editor, '<p>Parent</p><p>Child</p><p>After</p>')
})

test('dropping directly below a parent inserts before its existing children, at the shown boundary', () => {
  const editor = page('<block><p>Parent</p><p>Existing child</p></block><p>Moved</p>')
  const afterParent = editor.state.doc.firstChild!.length
  const change = relocation(editor.state, [afterParent], afterParent, 0)
  editor.dispatch(change!)
  expectBody(editor, '<block><p>Parent</p><p>Moved</p><p>Existing child</p></block>')
})

test('without a position, turning blocks into a type converts every block the text selection touches', () => {
  const editor = open('First\n\nSecond\n\nThird')
  const [first] = editor.state.doc.content
  select(editor, 2, first!.length + 3)
  expect(turnBlockInto(editor, undefined, 'h2')).toBe(true)
  expect(exportMarkdown(editor)).toBe('## First\n\n## Second\n\nThird')
  undo(editor)
  expect(exportMarkdown(editor)).toBe('First\n\nSecond\n\nThird')
})
