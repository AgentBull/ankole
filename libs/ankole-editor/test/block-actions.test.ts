import { expect, test } from 'bun:test'
import { Leaf } from '../src/core/doc'
import type { Wordgard } from '../src/core/editor'
import { undo, undoDepth } from '../src/core/history'
import { GardSelection, Transaction, type GardState } from '../src/core/state'
import { printMarkdown } from '../src/document/markdown'
import { Callout } from '../src/blocks/callout'
import {
  applyBlockType,
  blockChange,
  canTurnInto,
  duplicateBlocks,
  duplication,
  insertAfterBlock,
  movement,
  removal,
  turnBlock,
  turnBlockInto,
  type CoreBlockType
} from '../src/editor/block-actions'
import { blockInsertion, compose } from '../src/editor/block-insert'
import { readTree } from '../src/editor/convert'
import { headlessState } from '../src/editor/extension'

const markdown = (state: GardState) => printMarkdown(readTree(state.doc))

/** The position `offset` characters into the first text leaf that equals `text`. */
function position(state: GardState, text: string, offset: number | 'end' = 0) {
  let found = -1
  state.doc.iterate((node, pos) => {
    if (found < 0 && node.isText && (node as Leaf<string>).param === text) {
      found = pos + (offset === 'end' ? text.length : offset)
    }
  })
  if (found < 0) throw new Error(`No text ${text}`)
  return found
}

/** A state for `source` with the selection from `text` at `offset` to `to`, or a caret. */
function open(source: string, text: string, offset: number | 'end' = 0, to?: [string, number]) {
  const state = headlessState(source)
  const anchor = position(state, text, offset)
  const head = to ? position(state, to[0], to[1]) : anchor
  return state.update({ selection: GardSelection.range(anchor, head) }).state
}

/** A state for `source` with a caret at `pos`. */
const openAt = (source: string, pos: number) => {
  const state = headlessState(source)
  return state.update({ selection: GardSelection.cursor(pos) }).state
}

function apply(state: GardState, spec: Transaction.Spec | null) {
  if (!spec) throw new Error('No change')
  return state.update(spec).state
}

const change = (state: GardState, type: CoreBlockType) => apply(state, blockChange(state, type))
const parentName = (state: GardState) => state.doc.resolve(state.selection.head).parent.node.name

test.each([
  ['hello', 'hello', 'h2', '## hello'],
  ['## hello', 'hello', 'paragraph', 'hello'],
  ['hello', 'hello', 'check', '- [ ] hello'],
  ['hello', 'hello', 'bullet', '- hello'],
  ['hello', 'hello', 'number', '1. hello'],
  ['hello', 'hello', 'code', '```\nhello\n```'],
  ['```js meta\nx = 1\n```', 'x = 1', 'paragraph', 'x = 1'],
  [
    '<p align="center" style="color: red" x="1">hi</p>',
    'hi',
    'h1',
    '<h1 align="center" style="color: red" x="1">hi</h1>'
  ],
  ['<p indent="2" x="1">hi</p>', 'hi', 'code', '<pre x="1">\n  ```\n  hi\n  ```\n</pre>']
] as const)('%p becomes %p', (source, text, type, expected) => {
  expect(markdown(change(open(source, text), type))).toBe(expected)
})

test('code keeps only text and line breaks', () => {
  const state = open('**Marked** [link](https://example.com)  \nNext line', 'Marked')
  expect(markdown(change(state, 'code'))).toBe('```\nMarked link\nNext line\n```')
})

test.each([
  'Before <chip id="x">chip <part>nested</part></chip> <strong data-x="1">marked</strong> after',
  '- Before <chip id="x">chip <part>nested</part></chip> <strong data-x="1">marked</strong> after'
])('code conversion keeps the text of read-only inline elements: %p', source => {
  expect(markdown(change(open(source, 'Before '), 'code'))).toBe('```\nBefore chip nested marked after\n```')
})

test('a block with attributes becomes a paragraph with them in a list item', () => {
  const state = open('<p align="center" x="1">hi</p>', 'hi')
  expect(markdown(change(state, 'bullet'))).toBe('- <p align="center" x="1">hi</p>')
})

test('indent becomes nesting, except for the first item of a list', () => {
  const state = open('<p indent="1">a</p>\n\n<p indent="1">b</p>\n\n<p indent="3">c</p>\n\nd', 'a', 0, ['d', 1])
  expect(markdown(change(state, 'bullet'))).toBe('- a\n  - b\n    - c\n- d')
})

test('a block after a list of the same kind joins it at its indent', () => {
  expect(markdown(change(open('- x\n  - y\n\n<p indent="2">b</p>', 'b'), 'bullet'))).toBe('- x\n  - y\n    - b')
  expect(markdown(change(open('- x\n\n<p indent="1">b</p>', 'b'), 'bullet'))).toBe('- x\n  - b')
  expect(markdown(change(open('- x\n\nb', 'b'), 'bullet'))).toBe('- x\n- b')
  expect(markdown(change(open('- x\n\nb', 'b'), 'number'))).toBe('- x\n\n1. b')
})

test('an empty paragraph becomes an empty item and keeps the caret', () => {
  const result = change(openAt('s\n\n<p />\n\ne', 4), 'check')
  expect(markdown(result)).toBe('s\n\n<ul>\n  <li task="todo" />\n</ul>\n\ne')
  expect(parentName(result)).toBe('ListItem')
})

test('a list item turned into another block leaves the list; its other blocks follow it', () => {
  expect(markdown(change(open('- a\n  - child\n- b', 'a'), 'paragraph'))).toBe('a\n\n- child\n- b')
  expect(markdown(change(open('- a\n- b\n- c', 'b'), 'h1'))).toBe('- a\n\n# b\n\n- c')
  expect(markdown(change(open('1. a\n2. b\n3. c', 'b'), 'code'))).toBe('1. a\n\n```\nb\n```\n\n1. c')
  expect(markdown(change(open('- a\n  - b\n  - c', 'b'), 'paragraph'))).toBe('- a\n\n  b\n\n  - c')
  expect(markdown(change(open('- a\n- b\n- c\n- d', 'b', 0, ['c', 1]), 'paragraph'))).toBe('- a\n\nb\n\nc\n\n- d')
})

test('an empty item becomes an empty block', () => {
  const state = openAt('- a\n-\n- c', 7)
  expect(parentName(state)).toBe('ListItem')
  const result = change(state, 'h2')
  expect(markdown(result)).toBe('- a\n\n##\n\n- c')
  expect(parentName(result)).toBe('Heading')
})

test('a list type applies to the list, or to the run of to-do or plain items', () => {
  expect(markdown(change(open('- a\n- b', 'a'), 'check'))).toBe('- [ ] a\n- [ ] b')
  expect(markdown(change(open('- [x] a\n- [ ] b\n- c', 'a'), 'bullet'))).toBe('- a\n- b\n- c')
  expect(markdown(change(open('- [ ] a\n- b', 'b'), 'number'))).toBe('- [ ] a\n\n1. b')
  expect(markdown(change(open('- a\n- [ ] b\n- c', 'b'), 'number'))).toBe('- a\n\n1. b\n\n- c')
  expect(markdown(change(open('- [ ] a\n- b', 'a', 0, ['b', 1]), 'number'))).toBe('1. a\n2. b')
  expect(markdown(change(open('1. a\n2. b', 'b'), 'check'))).toBe('- [ ] a\n- [ ] b')
  expect(markdown(change(open('3. a\n4. b', 'a'), 'bullet'))).toBe('- a\n- b')
})

test('quote and callout take the text of the block at the caret; the caret moves to its end', () => {
  const state = open('<h2 align="right">Title **x**</h2>', 'Title ', 2)
  const quoted = change(state, 'quote')
  expect(markdown(quoted)).toBe('> <p align="right">Title **x**</p>')
  expect(quoted.selection.head).toBe(quoted.doc.resolve(quoted.selection.head).parent.end)
  const callout = apply(state, blockInsertion(state, Callout.create([])))
  expect(markdown(callout)).toBe('<callout>\n  <p align="right">Title **x**</p>\n</callout>')
})

test('quote in a list item splits the list there', () => {
  expect(markdown(change(open('- abc\n- def', 'abc', 1), 'quote'))).toBe('- a\n\n> <p />\n\n- bc\n- def')
  expect(markdown(change(open('- abc\n- def', 'abc', 'end'), 'quote'))).toBe('- abc\n\n> <p />\n\n- def')
  const last = change(open('- a', 'a', 'end'), 'quote')
  expect(markdown(last)).toBe('- a\n\n> <p />\n\n-')
  expect(parentName(last)).toBe('Paragraph')
})

test.each([
  ['s\n\n<p />\n\ne', 4, 's\n\n---\n\n<p />\n\ne'],
  ['abcdef', 4, 'abc\n\n---\n\ndef'],
  ['abc', 4, 'abc\n\n---\n\n<p />'],
  ['abc\n\ndef', 4, 'abc\n\n---\n\ndef'],
  ['abc\n\ndef', 6, 'abc\n\n---\n\ndef'],
  ['<p x="1" />', 1, '---\n\n<p x="1" />'],
  ['- a\n- b', 4, '- a\n\n---\n\n- b']
] as const)('a divider in %p at %p', (source, pos, expected) => {
  const result = change(openAt(source, pos), 'divider')
  expect(markdown(result)).toBe(expected)
  expect(parentName(result)).not.toBe('Doc')
})

test('duplicates copy blocks with their attributes and move the caret into the copy', () => {
  const paragraph = open('s\n\nhello\n\ne', 'hello', 1)
  const copied = apply(paragraph, duplication(paragraph))
  expect(markdown(copied)).toBe('s\n\nhello\n\nhello\n\ne')
  expect(copied.selection.head).toBe(11)
  const item = open('- [x] a\n  - child\n- b', 'a')
  expect(markdown(apply(item, duplication(item)))).toBe('- [x] a\n  - child\n- [x] a\n  - child\n- b')
  const callout = open('<callout tone="info">\n  one\n\n  two\n</callout>', 'one', 1)
  expect(markdown(apply(callout, duplication(callout)))).toBe(
    '<callout tone="info">\n  one\n\n  one\n\n  two\n</callout>'
  )
  const two = open('- a\n- b\n- c', 'a', 0, ['b', 1])
  expect(markdown(apply(two, duplication(two)))).toBe('- a\n- b\n- a\n- b\n- c')
  const reference = openAt('a\n\n<embed ref="tasks" />', 0)
  const copy = apply(reference, duplication(reference, 3))
  expect(markdown(copy)).toBe('a\n\n<embed ref="tasks" />\n\n<embed ref="tasks" />')
  expect(copy.selection).toBeInstanceOf(GardSelection.Node)
  expect(copy.selection.from).toBe(4)
})

test('moves swap with a sibling and keep the selection', () => {
  const down = open('s\n\nhello\n\nb\n\ne', 'hello', 1)
  const moved = apply(down, movement(down, 1))
  expect(markdown(moved)).toBe('s\n\nb\n\nhello\n\ne')
  expect(moved.doc.resolve(moved.selection.head).parent.node.textContent()).toBe('hello')
  const item = open('- a\n- b\n  - child', 'b')
  expect(markdown(apply(item, movement(item, -1)))).toBe('- b\n  - child\n- a')
  const two = open('s\n\nhello\n\nworld\n\nb\n\ne', 'hello', 0, ['world', 1])
  expect(markdown(apply(two, movement(two, 1)))).toBe('s\n\nb\n\nhello\n\nworld\n\ne')
  expect(movement(open('a\n\nb', 'a'), -1)).toBeNull()
  const top = open('First\n\nSecond', 'Second')
  const up = apply(top, movement(top, 1, 0))
  expect(markdown(up)).toBe('Second\n\nFirst')
  expect(up.doc.resolve(up.selection.head).parent.node.textContent()).toBe('First')
})

test('deleting a block moves the caret to the next block, or the previous one', () => {
  const only = apply(open('Only', 'Only'), removal(open('Only', 'Only'), 0))
  expect(markdown(only)).toBe('<p />')
  expect(only.selection.head).toBe(1)
  const last = apply(open('a\n\nb', 'b'), removal(open('a\n\nb', 'b'), 3))
  expect(markdown(last)).toBe('a')
  expect(last.selection.head).toBe(1)
  const first = apply(open('a\n\nbc', 'a'), removal(open('a\n\nbc', 'a'), 0))
  expect(markdown(first)).toBe('bc')
  expect(first.selection.head).toBe(1)
})

test('a deleted range and a block type change compose', () => {
  const state = open('x/h2', 'x/h2', 4)
  const result = apply(
    state,
    compose(state, { changes: { from: 2, to: 5 } }, next => blockChange(next, 'h2'))
  )
  expect(markdown(result)).toBe('## x')
})

// A stand-in for the editor: block actions only read the state, dispatch and focus.
function editorFor(state: GardState) {
  const editor = {
    state,
    dispatch(spec: Transaction.Spec) {
      editor.state = Transaction.append(editor.state.update(spec)).at(-1)!.state
    },
    focus() {}
  }
  return editor as typeof editor & Wordgard
}

const undoOnce = (state: GardState) => state.update(undo({ state }, null) as Transaction.Spec).state

test.each(['h2', 'quote', 'divider', 'callout', 'embed'] as const)(
  'a slash query deletion and %p are one undo step',
  type => {
    const editor = editorFor(open('Start\n\nx/q', 'x/q', 3))
    expect(applyBlockType(editor, type, { from: 9, to: 11 })).toBe(true)
    expect(markdown(editor.state)).not.toBe('Start\n\nx/q')
    expect(undoDepth(editor.state)).toBe(1)
    expect(markdown(undoOnce(editor.state))).toBe('Start\n\nx/q')
  }
)

test.each(['h2', 'bullet', 'quote', 'divider', 'callout', 'embed'] as const)(
  'inserting %p after a block is one undo step',
  type => {
    const editor = editorFor(open('First\n\nSecond', 'Second', 'end'))
    expect(insertAfterBlock(editor, 0, type)).toBe(true)
    expect(editor.state.doc.content.length).toBeGreaterThan(2)
    expect(undoDepth(editor.state)).toBe(1)
    expect(markdown(undoOnce(editor.state))).toBe('First\n\nSecond')
  }
)

test('block actions are separate undo steps after typing', () => {
  const editor = editorFor(open('a', 'a', 'end'))
  editor.dispatch({ changes: { from: 2, insert: [Leaf.text('b')] }, userEvent: 'input.type' })
  applyBlockType(editor, 'h1')
  duplicateBlocks(editor)
  expect(markdown(editor.state)).toBe('# ab\n\n# ab')
  expect(markdown(undoOnce(editor.state))).toBe('# ab')
  expect(markdown(undoOnce(undoOnce(editor.state)))).toBe('ab')
})

test('canTurnInto allows lists, quotes and callouts while keeping dividers, embeds and tables disabled', () => {
  const state = headlessState(
    [
      'Paragraph',
      '## Heading',
      '- bullet',
      '1. ordered',
      '> quote',
      '<callout>\n  note\n</callout>',
      '---',
      '<embed ref="tasks" />',
      '| a |\n| - |\n| 1 |'
    ].join('\n\n')
  )
  const flags: boolean[] = []
  let pos = 0
  for (const node of state.doc.content) {
    flags.push(canTurnInto(state, pos))
    pos += node.length
  }
  expect(flags).toEqual([true, true, true, true, true, true, false, false, false])
  expect(turnBlock(headlessState('> one'), 0, 'quote')).toBeNull()
  expect(turnBlock(headlessState('<callout>\n  one\n</callout>'), 0, 'callout')).toBeNull()
  expect(turnBlock(headlessState('---'), 0, 'paragraph')).toBeNull()
})

test.each([
  ['- one\n- two', 0, 'paragraph', 'one\n\ntwo'],
  ['- one\n- two', 0, 'h2', '## one\n\n## two'],
  ['- one\n- two', 0, 'number', '1. one\n2. two'],
  ['- one\n- two', 0, 'quote', '> one\n>\n> two'],
  ['- one\n- two', 0, 'callout', '<callout>\n  one\n\n  two\n</callout>'],
  ['1. one\n2. two', 0, 'check', '- [ ] one\n- [ ] two'],
  ['1. one\n2. two', 0, 'quote', '> one\n>\n> two'],
  ['> one\n>\n> two', 0, 'paragraph', 'one\n\ntwo'],
  ['> ## Title\n>\n> Body', 0, 'paragraph', 'Title\n\nBody'],
  ['> one\n>\n> two', 0, 'bullet', '- one\n- two'],
  ['> one\n>\n> two', 0, 'h3', '### one\n\n### two'],
  ['> one\n>\n> two', 0, 'callout', '<callout>\n  one\n\n  two\n</callout>'],
  ['<callout tone="warning">\n  one\n\n  two\n</callout>', 0, 'quote', '> one\n>\n> two'],
  ['<callout tone="info">\n  one\n\n  two\n</callout>', 0, 'number', '1. one\n2. two'],
  ['<callout>\n  one\n</callout>', 0, 'code', '```\none\n```']
] as const)('turnBlock on %p into %p', (source, pos, type, expected) => {
  const editor = editorFor(openAt(source, 0))
  expect(turnBlockInto(editor, pos, type)).toBe(true)
  expect(markdown(editor.state)).toBe(expected)
  expect(undoDepth(editor.state)).toBe(1)
  expect(markdown(undoOnce(editor.state))).toBe(source)
})
