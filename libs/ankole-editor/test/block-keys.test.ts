import { expect, test } from 'bun:test'
import type { Wordgard } from '../src/core/editor'
import { Command } from '../src/core/command/command'
import { deleteCut, deleteRange } from '../src/core/command/commands'
import { GardState } from '../src/core/state'
import { PageSession } from '../src/editor/page-session'
import { redo, undo } from '../src/editor/commands'
import { exportMarkdown, open, press, select } from './helpers'

// Block boundary keys beside e2e/block-keys.spec.ts: cases that need several blocks in a selection,
// or keys whose effect the e2e specs do not read back. Bun reports macOS, so the keys are macOS keys.

/** The position in the text node `text` at `offset`. */
function at(editor: Wordgard, text: string, offset: number | 'end' = 0) {
  let found: number | undefined
  editor.state.doc.iterate((node, pos) => {
    if (found === undefined && node.isText && node.param === text) {
      found = pos + (offset === 'end' ? text.length : offset)
    }
  })
  if (found === undefined) throw new Error(`The page has no text ${text}`)
  return found
}

test('Backspace in the only block of the page changes nothing', () => {
  for (const markdown of ['', '<p />', '## title']) {
    const editor = open(markdown)
    const before = editor.state.doc
    select(editor, 1)
    press(editor, 'Backspace')
    expect(editor.state.doc.eq(before), markdown).toBe(true)
  }
})

test('every deleting key keeps a callout whose blocks are all selected', () => {
  const markdown = '<callout tone="info">\n  hello\n\n  - world\n</callout>'
  for (const key of ['Backspace', 'Delete', 'Alt-Backspace', 'Meta-Backspace', 'Ctrl-h', 'Ctrl-d', 'Ctrl-k']) {
    const editor = open(markdown)
    select(editor, at(editor, 'hello'), at(editor, 'world', 'end'))
    press(editor, key)
    expect(exportMarkdown(editor), key).toBe('<callout tone="info">\n  <p />\n</callout>')
  }
})

test('a cut of all blocks of a callout keeps the callout', () => {
  const editor = open('<callout tone="info">\n  hello\n\n  - world\n</callout>')
  select(editor, at(editor, 'hello'), at(editor, 'world', 'end'))
  Command.dispatch(editor, deleteCut)
  expect(exportMarkdown(editor)).toBe('<callout tone="info">\n  <p />\n</callout>')
})

test.each(['delete.cut', 'delete.drag', 'delete'])(
  '%s of an explicit range keeps the callout and the disjoint caret in one dispatch',
  userEvent => {
    const markdown = 'before\n\n<callout data-key="keep" tone="info">\n  hello\n\n  - world\n</callout>\n\ntail'
    const deleted = 'before\n\n<callout data-key="keep" tone="info">\n  <p />\n</callout>\n\ntail'
    const editor = open(markdown)
    const session = new PageSession(editor)
    select(editor, at(editor, 'tail', 2))
    const from = at(editor, 'hello'),
      to = at(editor, 'world', 'end')
    expect(Command.dispatch(editor, deleteRange, { from, to, userEvent })).toBe(true)
    expect(exportMarkdown(editor)).toBe(deleted)
    expect(editor.state.selection.head).toBe(at(editor, 'tail', 2))
    expect(session.revision).toBe(1)
    expect(undo(editor)).toBe(true)
    expect(exportMarkdown(editor)).toBe(markdown)
    expect(session.revision).toBe(2)
    expect(redo(editor)).toBe(true)
    expect(exportMarkdown(editor)).toBe(deleted)
    expect(session.revision).toBe(3)
  }
)

test('an explicit range across a callout edge uses the normal deletion', () => {
  const editor = open('before\n\n<callout tone="info">\n  hello\n</callout>')
  expect(
    Command.dispatch(editor, deleteRange, {
      from: at(editor, 'before', 3),
      to: at(editor, 'hello', 2),
      userEvent: 'delete'
    })
  ).toBe(true)
  expect(exportMarkdown(editor)).toBe('befllo')
})

test('empty ranges and read-only callouts do not dispatch a deletion', () => {
  const markdown = '<callout tone="info">\n  hello\n</callout>'
  const editor = open(markdown)
  const session = new PageSession(editor)
  const from = at(editor, 'hello'),
    to = at(editor, 'hello', 'end')
  expect(Command.dispatch(editor, deleteRange, { from, to: from, userEvent: 'delete' })).toBe(false)
  editor.dispatch({ effects: GardState.appendConfig.of(GardState.readOnly.of(true)) })
  select(editor, from, to)
  expect(Command.dispatch(editor, deleteRange, { from, to, userEvent: 'delete' })).toBe(false)
  expect(Command.dispatch(editor, deleteCut)).toBe(false)
  expect(exportMarkdown(editor)).toBe(markdown)
  expect(session.revision).toBe(0)
})

test('deleting keys leave read-only block boundaries unchanged', () => {
  for (const [backward, keys] of [
    [true, ['Backspace', 'Alt-Backspace', 'Meta-Backspace', 'Ctrl-h']],
    [false, ['Delete', 'Alt-Delete', 'Meta-Delete', 'Ctrl-d', 'Ctrl-k']]
  ] as const) {
    for (const key of keys) {
      const editor = open('hello\n\nworld')
      const session = new PageSession(editor)
      select(editor, at(editor, backward ? 'world' : 'hello', backward ? 0 : 'end'))
      editor.dispatch({ effects: GardState.appendConfig.of(GardState.readOnly.of(true)) })
      press(editor, key)
      expect(exportMarkdown(editor), key).toBe('hello\n\nworld')
      expect(session.revision, key).toBe(0)
    }
  }
})

test.each(['## hello', '> hello', '- hello'])('Enter leaves read-only %s unchanged', markdown => {
  const editor = open(markdown)
  const session = new PageSession(editor)
  select(editor, at(editor, 'hello', 2))
  editor.dispatch({ effects: GardState.appendConfig.of(GardState.readOnly.of(true)) })
  press(editor, 'Enter')
  expect(exportMarkdown(editor)).toBe(markdown)
  expect(session.revision).toBe(0)
})

test('a selection across the edge of a callout deletes as elsewhere', () => {
  const editor = open('before\n\n<callout tone="info">\n  hello\n</callout>')
  select(editor, at(editor, 'before', 3), at(editor, 'hello', 2))
  press(editor, 'Backspace')
  expect(exportMarkdown(editor)).toBe('befllo')
})

test('Ctrl+K at the end of a block joins the next one; Ctrl+Y does not insert it again', () => {
  const editor = open('hello\n\nworld')
  select(editor, at(editor, 'hello', 'end'))
  press(editor, 'Ctrl-k')
  expect(exportMarkdown(editor)).toBe('helloworld')
  press(editor, 'Ctrl-y')
  expect(exportMarkdown(editor)).toBe('helloworld')
})

test('Enter replaces a selection in a heading and leaves the rest as a paragraph', () => {
  const editor = open('## hello world')
  select(editor, at(editor, 'hello world', 2), at(editor, 'hello world', 6))
  press(editor, 'Enter')
  expect(exportMarkdown(editor)).toBe('## he\n\nworld')
})

test('Backspace in an empty callout removes it and joins the text before it', () => {
  const editor = open('before\n\n<callout tone="info" />\n\nafter')
  let inside = 0
  editor.state.doc.iterate((node, pos) => {
    if (node.name == 'Callout') inside = pos + 1
  })
  select(editor, inside)
  press(editor, 'Backspace')
  expect(exportMarkdown(editor)).toBe('before\n\nafter')
  expect(editor.state.selection.head).toBe(at(editor, 'before', 'end'))
})

test('Tab in a code block inserts a tab; Shift+Tab leaves it', () => {
  const editor = open('```\nhello\n```')
  select(editor, at(editor, 'hello', 2))
  press(editor, 'Tab')
  press(editor, 'Shift-Tab')
  expect(exportMarkdown(editor)).toBe('```\nhe\tllo\n```')
})

test('Tab stops at indent 49; Shift+Tab removes the last level', () => {
  const editor = open('<p indent="48">hello</p>')
  select(editor, at(editor, 'hello'))
  press(editor, 'Tab')
  press(editor, 'Tab')
  expect(exportMarkdown(editor)).toBe('<p indent="49">hello</p>')
  const plain = open('<p indent="1">hello</p>')
  select(plain, at(plain, 'hello'))
  press(plain, 'Shift-Tab')
  press(plain, 'Shift-Tab')
  expect(exportMarkdown(plain)).toBe('hello')
})

test('each block key change is one undo step', () => {
  const editor = open('- a\n- hello\n- next')
  select(editor, at(editor, 'hello'))
  for (const key of ['Tab', 'Shift-Tab', 'Backspace', 'Enter']) press(editor, key)
  expect(exportMarkdown(editor)).toBe('- a\n\n<p />\n\nhello\n\n- next')
  for (const markdown of [
    '- a\n\nhello\n\n- next',
    '- a\n- hello\n- next',
    '- a\n  - hello\n- next',
    '- a\n- hello\n- next'
  ]) {
    expect(undo(editor)).toBe(true)
    expect(exportMarkdown(editor)).toBe(markdown)
  }
  expect(redo(editor)).toBe(true)
  expect(exportMarkdown(editor)).toBe('- a\n  - hello\n- next')
})
