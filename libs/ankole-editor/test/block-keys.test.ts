import { expect, test } from 'bun:test'
import type { Wordgard } from '../src/core/editor'
import { Command } from '../src/core/command/command'
import { deleteCut, deleteRange } from '../src/core/command/commands'
import { GardState } from '../src/core/state'
import { CellSelection } from '../src/core/table'
import { mathEditorField } from '../src/blocks/math'
import { BlockSelection } from '../src/editor/block-selection'
import { PageSession } from '../src/editor/page-session'
import { redo, undo } from '../src/editor/commands'
import { foldedHeadings } from '../src/editor/headings'
import { attachHost } from '../src/editor/host-context'
import { exportMarkdown, open, press, select, typeText } from './helpers'

// Block boundary keys beside e2e/block-keys.spec.ts: cases that need several blocks in a selection,
// or keys whose effect the e2e specs do not read back. The test script selects macOS bindings.

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

test('Tab in a code block indents its line and Shift+Tab removes that indentation', () => {
  const editor = open('```\nhello\n```')
  select(editor, at(editor, 'hello', 2))
  press(editor, 'Tab')
  expect(exportMarkdown(editor)).toBe('```\n\thello\n```')
  expect(editor.state.selection.head).toBe(at(editor, '\thello', 3))
  press(editor, 'Shift-Tab')
  expect(exportMarkdown(editor)).toBe('```\nhello\n```')
  expect(editor.state.selection.head).toBe(at(editor, 'hello', 2))
  expect(undo(editor)).toBe(true)
  expect(exportMarkdown(editor)).toBe('```\n\thello\n```')
})

test('code indentation preserves a backward multiline selection and includes its ending line', () => {
  const editor = open('```\nfirst\nsecond\nthird\n```')
  const start = at(editor, 'first', 2)
  const end = at(editor, 'second')
  select(editor, end, start)
  press(editor, 'Tab')
  expect(exportMarkdown(editor)).toBe('```\n\tfirst\n\tsecond\nthird\n```')
  expect(editor.state.selection.anchor).toBe(end + 2)
  expect(editor.state.selection.head).toBe(start + 1)
  press(editor, 'Shift-Tab')
  expect(exportMarkdown(editor)).toBe('```\nfirst\nsecond\nthird\n```')
  expect(editor.state.selection.anchor).toBe(end)
  expect(editor.state.selection.head).toBe(start)
})

test('code outdent removes one tab or up to two spaces without changing unindented lines', () => {
  const editor = open('```\n    first\n  second\n third\n\tfourth\nfifth\n```')
  select(editor, at(editor, '    first'), at(editor, 'fifth', 'end'))
  press(editor, 'Shift-Tab')
  expect(exportMarkdown(editor)).toBe('```\n  first\nsecond\nthird\nfourth\nfifth\n```')
})

test('code Tab at the start of an empty line keeps a writing caret after its tab', () => {
  const editor = open('```\nfirst\n\nlast\n```')
  const empty = at(editor, 'first', 'end') + 1
  select(editor, empty)
  press(editor, 'Tab')
  expect(exportMarkdown(editor)).toBe('```\nfirst\n\t\nlast\n```')
  expect(editor.state.selection.head).toBe(empty + 1)
})

test('Tab stops at indent 49; Shift+Tab removes the last level and consumes keys at limits', () => {
  const editor = open('<p indent="48">hello</p>')
  select(editor, at(editor, 'hello'))
  expect(press(editor, 'Tab')).toBe(true)
  expect(press(editor, 'Tab')).toBe(true)
  expect(exportMarkdown(editor)).toBe('<p indent="49">hello</p>')
  const plain = open('<p indent="1">hello</p>')
  select(plain, at(plain, 'hello'))
  expect(press(plain, 'Shift-Tab')).toBe(true)
  expect(press(plain, 'Shift-Tab')).toBe(true)
  expect(exportMarkdown(plain)).toBe('hello')
  const list = open('- first\n- second')
  select(list, at(list, 'first'))
  expect(press(list, 'Tab')).toBe(true)
  expect(press(list, 'Shift-Tab')).toBe(true)
  expect(exportMarkdown(list)).toBe('- first\n- second')
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

test('Escape in a code block selects it, and ArrowDown selects the next block or appends one at page end', () => {
  const withNext = open('```js\nconst a = 1\n```\n\nnext')
  select(withNext, at(withNext, 'const a = 1', 3))
  expect(press(withNext, 'Escape')).toBe(true)
  expect(withNext.state.selection).toBeInstanceOf(BlockSelection)
  expect(press(withNext, 'ArrowDown')).toBe(true)
  expect(withNext.state.selection).toBeInstanceOf(BlockSelection)
  const nextNode = (withNext.state.selection as BlockSelection).last.node
  expect(nextNode.isPlot && nextNode.textContent()).toBe('next')

  const atEnd = open('```js\nconst a = 1\n```')
  select(atEnd, at(atEnd, 'const a = 1', 5))
  expect(press(atEnd, 'Escape')).toBe(true)
  expect(atEnd.state.selection).toBeInstanceOf(BlockSelection)
  expect(press(atEnd, 'ArrowDown')).toBe(true)
  expect(exportMarkdown(atEnd)).toBe('```js\nconst a = 1\n```\n\n<p />')
  expect(atEnd.state.selection).toBeInstanceOf(BlockSelection)
  // Pressing ArrowDown again on the trailing empty root paragraph does not append duplicates.
  expect(press(atEnd, 'ArrowDown')).toBe(true)
  expect(exportMarkdown(atEnd)).toBe('```js\nconst a = 1\n```\n\n<p />')
  typeText(atEnd, 'after')
  expect(exportMarkdown(atEnd)).toBe('```js\nconst a = 1\n```\n\nafter')
  expect(undo(atEnd)).toBe(true)
  expect(exportMarkdown(atEnd)).toBe('```js\nconst a = 1\n```\n\n<p />')
  expect(undo(atEnd)).toBe(true)
  expect(exportMarkdown(atEnd)).toBe('```js\nconst a = 1\n```')
})

test('Escape toggles whole-block selection on and off for text and leaf blocks', () => {
  const textEditor = open('first\n\nsecond')
  select(textEditor, at(textEditor, 'first', 2))
  expect(press(textEditor, 'Escape')).toBe(true)
  expect(textEditor.state.selection).toBeInstanceOf(BlockSelection)
  expect(press(textEditor, 'Escape')).toBe(true)
  expect(textEditor.state.selection.isCursor).toBe(true)
  expect(textEditor.state.selection.head).toBe(at(textEditor, 'first', 'end'))
  expect(press(textEditor, 'Escape')).toBe(true)
  expect(textEditor.state.selection).toBeInstanceOf(BlockSelection)
  const firstNode = (textEditor.state.selection as BlockSelection).last.node
  expect(firstNode.isPlot && firstNode.textContent()).toBe('first')

  const leafEditor = open('---\n\nafter')
  leafEditor.dispatch({ selection: BlockSelection.between(leafEditor.state.doc, 0, 0)! })
  expect(press(leafEditor, 'Escape')).toBe(true)
  expect(leafEditor.state.selection.isCursor).toBe(true)
  expect(press(leafEditor, 'Escape')).toBe(true)
  expect(leafEditor.state.selection).toBeInstanceOf(BlockSelection)
  expect((leafEditor.state.selection as BlockSelection).last.before).toBe(0)
})

test('Shift+Enter exits code and Mermaid blocks into a new paragraph below without splitting source', () => {
  const code = open('```ts\nconst a = 1\nconst b = 2\n```')
  select(code, at(code, 'const a = 1', 5))
  expect(press(code, 'Shift-Enter')).toBe(true)
  typeText(code, 'below')
  expect(exportMarkdown(code)).toBe('```ts\nconst a = 1\nconst b = 2\n```\n\nbelow')

  const mermaid = open('```mermaid\nflowchart TD\n  A --> B\n```')
  select(mermaid, at(mermaid, 'flowchart TD', 4))
  expect(press(mermaid, 'Shift-Enter')).toBe(true)
  typeText(mermaid, 'caption')
  expect(exportMarkdown(mermaid)).toBe('```mermaid\nflowchart TD\n  A --> B\n```\n\ncaption')
})

test('Backspace at the start of a code or Mermaid block is a no-op', () => {
  for (const source of [
    'before\n\n```\nconst a = 1\n```',
    '```\n```\n\nafter',
    'before\n\n```mermaid\nflowchart LR\n```'
  ]) {
    const editor = open(source)
    const expected = exportMarkdown(editor)
    let start = 0
    editor.state.doc.iterate((node, pos) => {
      if (!start && (node.name === 'CodeBlock' || node.name === 'Mermaid')) start = pos + 1
    })
    select(editor, start)
    for (const key of ['Backspace', 'Meta-Backspace']) {
      press(editor, key)
      expect(exportMarkdown(editor)).toBe(expected)
    }
  }
})

test('Mermaid boundary merges strip inline marks in source views and skip diagram-only views', () => {
  const sourceView = open('```mermaid\nflowchart LR\n```\n\n**bold** [link](https://example.com)')
  select(sourceView, at(sourceView, 'bold', 0))
  press(sourceView, 'Backspace')
  expect(exportMarkdown(sourceView)).toBe('```mermaid\nflowchart LRbold link\n```')

  const diagramOnly = open('before\n\n<mermaid view="diagram">\n```mermaid\nflowchart LR\n```\n</mermaid>\n\nafter')
  select(diagramOnly, at(diagramOnly, 'after', 0))
  press(diagramOnly, 'Backspace')
  expect(exportMarkdown(diagramOnly)).toBe(
    'beforeafter\n\n<mermaid view="diagram">\n  ```mermaid\n  flowchart LR\n  ```\n</mermaid>'
  )
})

test('leaf and formula blocks handle Enter, Space, ArrowLeft, ArrowRight, and Mod+Enter in block selection', () => {
  const divider = open('before\n\n---\n\nafter')
  let rulePos = -1
  divider.state.doc.iterate((node, pos) => {
    if (node.name === 'HorizontalRule') rulePos = pos
  })
  divider.dispatch({ selection: BlockSelection.between(divider.state.doc, rulePos, rulePos)! })
  expect(press(divider, 'ArrowLeft')).toBe(true)
  expect(divider.state.selection.head).toBe(at(divider, 'before', 'end'))
  divider.dispatch({ selection: BlockSelection.between(divider.state.doc, rulePos, rulePos)! })
  expect(press(divider, 'ArrowRight')).toBe(true)
  expect(divider.state.selection.head).toBe(at(divider, 'after', 0))
  divider.dispatch({ selection: BlockSelection.between(divider.state.doc, rulePos, rulePos)! })
  expect(press(divider, 'Enter')).toBe(true)
  typeText(divider, 'inserted')
  expect(exportMarkdown(divider)).toBe('before\n\n---\n\ninserted\n\nafter')

  for (const key of ['Enter', ' ', 'Meta-Enter']) {
    const math = open('$$\nE = mc^2\n$$')
    math.dispatch({ selection: BlockSelection.between(math.state.doc, 0, 0)! })
    expect(press(math, key), key).toBe(true)
    expect(math.state.field(mathEditorField), key).toBe(0)
  }

  const opened: string[] = []
  const embed = open('<embed ref="target-page" />')
  const detach = attachHost(embed, { openPage: id => opened.push(id) })
  try {
    embed.dispatch({ selection: BlockSelection.between(embed.state.doc, 0, 0)! })
    expect(press(embed, 'Meta-Enter')).toBe(true)
    expect(opened).toEqual(['target-page'])
  } finally {
    detach()
  }

  const heading = open('## Section\n\nBody')
  select(heading, at(heading, 'Section', 2))
  expect(press(heading, 'Meta-Enter')).toBe(true)
  expect(heading.state.field(foldedHeadings).has(0)).toBe(true)
  expect(press(heading, 'Meta-Enter')).toBe(true)
  expect(heading.state.field(foldedHeadings).has(0)).toBe(false)
})

test('tables escalate Escape from cell to table selection, navigate cells with arrows, and step Mod+A', () => {
  const editor = open('| a | b |\n| - | - |\n| c | d |')
  select(editor, at(editor, 'a', 0))
  expect(press(editor, 'Escape')).toBe(true)
  expect(editor.state.selection).toBeInstanceOf(CellSelection)
  expect(press(editor, 'ArrowRight')).toBe(true)
  expect(press(editor, 'ArrowDown')).toBe(true)
  // Clamps at bottom-right edge without collapsing CellSelection.
  expect(press(editor, 'ArrowDown')).toBe(true)
  expect(editor.state.selection).toBeInstanceOf(CellSelection)
  expect(press(editor, 'Enter')).toBe(true)
  typeText(editor, '!')
  expect(exportMarkdown(editor)).toBe('| a | b  |\n| - | -- |\n| c | d! |')

  // Escape twice from inside a cell selects the whole table, and ArrowDown at page end appends a paragraph.
  expect(press(editor, 'Escape')).toBe(true)
  expect(editor.state.selection).toBeInstanceOf(CellSelection)
  expect(press(editor, 'Escape')).toBe(true)
  expect(editor.state.selection).toBeInstanceOf(BlockSelection)
  expect(press(editor, 'ArrowDown')).toBe(true)
  typeText(editor, 'after table')
  expect(exportMarkdown(editor)).toBe('| a | b  |\n| - | -- |\n| c | d! |\n\nafter table')

  // Mod+A inside a cell selects cell text, then all cells, then the whole page.
  select(editor, at(editor, 'a', 0))
  expect(press(editor, 'Meta-a')).toBe(true)
  expect(editor.state.selection).not.toBeInstanceOf(CellSelection)
  expect(press(editor, 'Meta-a')).toBe(true)
  expect(editor.state.selection).toBeInstanceOf(CellSelection)
  expect((editor.state.selection as CellSelection).ranges.length).toBe(4)
  expect(press(editor, 'Meta-a')).toBe(true)
  expect(editor.state.selection.from).toBe(0)
  expect(editor.state.selection.to).toBe(editor.state.doc.length)
})

test('turn-into shortcuts toggle back to a paragraph when pressed again', () => {
  for (const [digit, converted] of [
    ['1', '# hello'],
    ['2', '## hello'],
    ['3', '### hello'],
    ['4', '- [ ] hello'],
    ['5', '- hello'],
    ['6', '1. hello'],
    ['8', '```\nhello\n```']
  ] as const) {
    const editor = open('hello')
    select(editor, at(editor, 'hello', 2))
    expect(press(editor, `Meta-Alt-${digit}`), digit).toBe(true)
    expect(exportMarkdown(editor), digit).toBe(converted)
    expect(press(editor, `Meta-Alt-${digit}`), digit).toBe(true)
    expect(exportMarkdown(editor), digit).toBe('hello')
  }
})

test('Enter in the only empty paragraph of a callout stays inside, and the next Enter leaves it', () => {
  const editor = open('pre\n\n<callout tone="warning" icon="🔥">\n  <p />\n</callout>\n\npost')
  let empty = -1
  editor.state.doc.iterate((node, pos) => {
    if (node.isPlot && node.isTextblock && !node.content.length) empty = pos + 1
  })
  select(editor, empty)
  press(editor, 'Enter')
  expect(exportMarkdown(editor)).toBe(
    'pre\n\n<callout icon="🔥" tone="warning">\n  <p />\n\n  <p />\n</callout>\n\npost'
  )
  press(editor, 'Enter')
  expect(exportMarkdown(editor)).toBe('pre\n\n<callout icon="🔥" tone="warning">\n  <p />\n</callout>\n\n<p />\n\npost')
})

test.each([
  ['<callout tone="info">\n  - a1\n  - a2\n</callout>', '<callout tone="info">\n  - a2\n</callout>'],
  ['> - a1\n> - a2', '> - a2']
])('Meta+Backspace at the first item of a list in %p joins the text before the container', (inside, left) => {
  const editor = open(`top\n\n${inside}`)
  select(editor, at(editor, 'a1'))
  press(editor, 'Meta-Backspace')
  expect(exportMarkdown(editor)).toBe(`topa1\n\n${left}`)
  expect(editor.state.selection.head).toBe(at(editor, 'topa1', 3))
})

test.each(['> ---\n>\n> x', '<callout tone="info">\n  ---\n\n  x\n</callout>'])(
  'Backspace after a divider at the start of %p keeps the text in its container',
  inside => {
    const editor = open(`top\n\n${inside}`)
    const before = editor.state.doc
    select(editor, at(editor, 'x'))
    press(editor, 'Backspace')
    expect(editor.state.doc.eq(before)).toBe(true)
  }
)
