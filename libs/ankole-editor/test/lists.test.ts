import { expect, test } from 'bun:test'
import { Command, deleteCut } from '../src/core/command'
import type { Wordgard } from '../src/core/editor'
import { parseMarkdown } from '../src/document/markdown'
import { parseXml } from '../src/document/xml'
import { applyBlockType } from '../src/editor/block-actions'
import { isList } from '../src/editor/block-insert'
import { PageSession } from '../src/editor/page-session'
import { exportMarkdown, expectReopens, open, press, readTree, select, typeText } from './helpers'

/** Put the caret in the text node `text`, at `offset`. */
function caret(editor: Wordgard, text: string, offset: number | 'end' = 0) {
  let found: number | undefined
  editor.state.doc.iterate((node, pos) => {
    if (found === undefined && node.isText && node.param === text) {
      found = pos + (offset === 'end' ? text.length : offset)
    }
  })
  if (found === undefined) throw new Error(`The page has no text ${text}`)
  select(editor, found)
}

test.each([
  ['adjacent bullet lists', '- foo\n- bar\n+ baz\n', '- foo\n- bar\n- baz'],
  ['adjacent ordered lists', '1. foo\n2. bar\n3) baz\n', '1. foo\n2. bar\n3. baz'],
  ['an ordered list after a blank line', '1. first\n\n1) restart', '1. first\n2. restart'],
  [
    'mixed task items in a sublist',
    '- parent\n  - plain\n  - [ ] todo\n  - final',
    '- parent\n  - plain\n  - [ ] todo\n  - final'
  ],
  [
    'a paragraph after a sublist',
    '- parent\n  - plain\n  - [ ] todo\n\n  after',
    '- parent\n\n  - plain\n  - [ ] todo\n\n  after'
  ]
])('%s stay one editable list through page writes', (_, source, canonical) => {
  const expected = parseMarkdown(source)
  expect(expected).toEqual(parseMarkdown(canonical))
  const editor = open(source)
  const page = new PageSession(editor)
  try {
    for (let cycle = 0; cycle < 2; cycle++) {
      expect(readTree(editor)).toEqual(expected)
      expect(editor.state.doc.content.every(isList)).toBe(true)
      const snapshot = page.read()
      expect(snapshot.markdown).toBe(canonical)
      page.apply({ format: 'xml', source: snapshot.xml, revision: snapshot.revision })
    }
  } finally {
    page.dispose()
  }
})

test('converting the paragraph between two lists joins them', () => {
  const editor = open('- before\n\nbetween\n\n- after')
  caret(editor, 'between', 'end')
  applyBlockType(editor, 'bullet')
  expect(readTree(editor)).toEqual(parseMarkdown('- before\n- between\n- after'))
})

test('converting a block with attributes keeps the attributes on the item text', () => {
  for (const [source, text] of [
    ['<p source="x">hello</p>', 'hello'],
    ['<h2 source="x">Title</h2>', 'Title']
  ] as const) {
    const editor = open(source)
    caret(editor, text, 'end')
    applyBlockType(editor, 'bullet')
    expect(readTree(editor)).toEqual(parseMarkdown(`- <p source="x">${text}</p>`))
  }
})

test('list items keep empty and attributed paragraphs', () => {
  for (const source of [
    '- <p />',
    '- a\n\n  <p />\n\n  b',
    '- <p align="center">x</p>',
    '- a\n\n  ```\n  code\n  ```\n\n  <p />'
  ]) {
    const editor = open(source)
    expect(readTree(editor)).toEqual(parseMarkdown(source))
  }
})

test('Backspace at the start of an item that holds a paragraph keeps one paragraph level', () => {
  for (const [source, expected] of [
    ['- <p source="x">a</p>', '<p source="x">a</p>'],
    ['- first\n- <p source="x">a</p>', '- first\n\n<p source="x">a</p>']
  ] as const) {
    const editor = open(source)
    caret(editor, 'a')
    press(editor, 'Backspace')
    expect(readTree(editor)).toEqual(parseMarkdown(expected))
  }
})

// List keys of SPEC §7.5 Lists and of the Backspace and Delete tables. Keys are written as key
// bindings name them. The test script selects macOS for the line deletion keys.
for (const { name, markdown, at, keys, expected } of [
  {
    name: 'Backspace turns a middle item into a paragraph and splits the list',
    markdown: '- a\n- hello\n- next',
    at: ['hello', 0],
    keys: ['Backspace'],
    expected: '- a\n\nhello\n\n- next'
  },
  {
    name: 'Backspace turns a nested item with children into text of the item above',
    markdown: '- a\n  - hello\n    - child\n- next',
    at: ['hello', 0],
    keys: ['Backspace'],
    expected: '- a\n\n  hello\n\n  - child\n- next'
  },
  {
    name: 'Backspace keeps the paragraph after a nested list in the item',
    markdown: '* foo\n  * bar\n\n  baz',
    at: ['bar', 0],
    keys: ['Backspace'],
    expected: '- foo\n\n  bar\n\n  baz'
  },
  {
    name: 'Backspace moves text under an item out of the list',
    markdown: '- a\n\n  hello\n- next',
    at: ['hello', 0],
    keys: ['Backspace'],
    expected: '- a\n\nhello\n\n- next'
  },
  {
    name: 'Backspace drops the check of a done task; the rest of a numbered list starts at 1',
    markdown: '- [ ] a\n- [x] hello\n- [ ] next\n\n1. b\n2. one\n3. two',
    at: ['hello', 0],
    keys: ['Backspace'],
    expected: '- [ ] a\n\nhello\n\n- [ ] next\n\n1. b\n2. one\n3. two'
  },
  {
    name: 'Backspace in an empty item gives an empty paragraph',
    markdown: '- a\n- x\n- next',
    at: ['x', 'end'],
    keys: ['Backspace', 'Backspace'],
    expected: '- a\n\n<p />\n\n- next'
  },
  {
    name: 'line deletion joins a top-level item to the text before it and keeps its children at their level',
    markdown: '- a\n  - b\n- hello\n  - child\n- next',
    at: ['hello', 0],
    keys: ['Meta-Backspace'],
    expected: '- a\n  - bhello\n  - child\n- next'
  },
  {
    name: 'line deletion joins the first item to the paragraph before the list',
    markdown: 's\n\n- hello\n  - child\n- next',
    at: ['hello', 0],
    keys: ['Meta-Backspace'],
    expected: 'shello\n\n- child\n- next'
  },
  {
    name: 'line deletion lifts a nested item with its children',
    markdown: '- a\n  - hello\n    - child\n- next',
    at: ['hello', 0],
    keys: ['Meta-Backspace'],
    expected: '- a\n- hello\n  - child\n- next'
  },
  {
    name: 'line deletion removes an empty item',
    markdown: '- a\n- x\n- next',
    at: ['x', 'end'],
    keys: ['Backspace', 'Meta-Backspace'],
    expected: '- a\n- next'
  },
  {
    name: 'Delete takes in the first nested item; its children keep their level',
    markdown: '- hello\n  - child\n    - grandchild\n  - sibling',
    at: ['hello', 'end'],
    keys: ['Delete'],
    expected: '- hellochild\n  - grandchild\n  - sibling'
  },
  {
    name: 'Delete takes in the next item; the item before takes its children',
    markdown: '- hello\n- next\n  - child',
    at: ['hello', 'end'],
    keys: ['Delete'],
    expected: '- hellonext\n  - child'
  },
  {
    name: 'Enter in an empty middle item leaves the list',
    markdown: '- a\n- x\n- next',
    at: ['x', 'end'],
    keys: ['Backspace', 'Enter'],
    expected: '- a\n\n<p />\n\n- next'
  },
  {
    name: 'Enter in an empty nested item lifts it; it keeps a paragraph above its new children',
    markdown: '- a\n  - x\n  - y\n- next',
    at: ['x', 'end'],
    keys: ['Backspace', 'Enter'],
    expected: '- a\n- <p />\n  - y\n- next'
  },
  {
    name: 'Enter at the start of an item adds an empty item above',
    markdown: '- a\n- hello',
    at: ['hello', 0],
    keys: ['Enter'],
    expected: '- a\n-\n- hello'
  },
  {
    name: 'Enter at the end of a done task adds an open task; Enter again leaves the list',
    markdown: '- [x] hello',
    at: ['hello', 'end'],
    keys: ['Enter', 'Enter'],
    expected: '- [x] hello\n\n<p />'
  },
  {
    name: 'Enter in an item with children moves the text after the caret and the children to a new item',
    markdown: '- hello\n  - child',
    at: ['hello', 2],
    keys: ['Enter'],
    expected: '- he\n- llo\n  - child'
  },
  {
    name: 'Enter in a plain child paragraph after a nested list creates a sibling paragraph',
    markdown: '* foo\n  * bar\n\n  baz',
    at: ['baz', 2],
    keys: ['Enter'],
    expected: '- foo\n\n  - bar\n\n  ba\n\n  z'
  },
  {
    name: 'Tab nests an item under the item above, with its children',
    markdown: '- a\n- hello\n  - child\n- next',
    at: ['hello', 2],
    keys: ['Tab'],
    expected: '- a\n  - hello\n    - child\n- next'
  },
  {
    name: 'Tab nests an item into the list that ends the item above',
    markdown: '- a\n  - b\n- hello',
    at: ['hello', 0],
    keys: ['Tab'],
    expected: '- a\n  - b\n  - hello'
  },
  {
    name: 'Tab does not nest the first item of a list',
    markdown: '- hello\n  - child',
    at: ['child', 0],
    keys: ['Tab'],
    expected: '- hello\n  - child'
  },
  {
    name: 'Shift+Tab lifts an item; the items after it become its children',
    markdown: '- a\n  - hello\n  - b\n- next',
    at: ['hello', 0],
    keys: ['Shift-Tab'],
    expected: '- a\n- hello\n  - b\n- next'
  },
  {
    name: 'Shift+Tab keeps the blocks after a nested list in a new item',
    markdown: '* foo\n  * bar\n\n  baz',
    at: ['bar', 0],
    keys: ['Shift-Tab'],
    expected: '- foo\n- bar\n- baz'
  },
  {
    name: 'Shift+Tab does not lift a top-level item',
    markdown: '- a\n- hello',
    at: ['hello', 0],
    keys: ['Shift-Tab'],
    expected: '- a\n- hello'
  }
] as const) {
  test(name, () => {
    const editor = open(markdown)
    caret(editor, at[0], at[1])
    for (const key of keys) press(editor, key)
    expect(exportMarkdown(editor)).toBe(expected)
    expectReopens(editor)
  })
}

test('a new item next to a done task is an open task', () => {
  const editor = open('- [x] a\n- [x] hello')
  caret(editor, 'hello')
  press(editor, 'Enter')
  expect(readTree(editor)).toEqual(
    parseXml('<page><ul><li task="done"><p>a</p></li><li task="todo" /><li task="done"><p>hello</p></li></ul></page>')
  )
})

test('Shift+Tab lifts the selected items of a nested list together', () => {
  const editor = open('- hello\n  - one\n  - two\n  - three')
  let one = 0,
    two = 0
  editor.state.doc.iterate((node, pos) => {
    if (node.isText && node.param === 'one') one = pos + 1
    if (node.isText && node.param === 'two') two = pos + 2
  })
  select(editor, one, two)
  press(editor, 'Shift-Tab')
  expect(exportMarkdown(editor)).toBe('- hello\n- one\n- two\n  - three')
})

test('Tab nests the selected items under the first one, which stays', () => {
  const editor = open('- one\n- two\n- three')
  let one = 0,
    three = 0
  editor.state.doc.iterate((node, pos) => {
    if (node.isText && node.param === 'one') one = pos + 1
    if (node.isText && node.param === 'three') three = pos + 2
  })
  select(editor, one, three)
  press(editor, 'Tab')
  expect(exportMarkdown(editor)).toBe('- one\n  - two\n  - three')
})

test('Tab stops at the deepest list level', () => {
  let markdown = '- 0'
  for (let level = 1; level <= 49; level++) markdown += `\n${'  '.repeat(level)}- ${level}`
  const editor = open(`${markdown}\n${'  '.repeat(49)}- last`)
  caret(editor, 'last')
  press(editor, 'Tab')
  expect(exportMarkdown(editor)).toBe(`${markdown}\n${'  '.repeat(49)}- last`)
})

test('deleting the text of an item leaves an empty item', () => {
  for (const keys of [['Backspace', 'Backspace'], ['selection']]) {
    const editor = open('- ab\n- cd')
    if (keys[0] === 'selection') {
      caret(editor, 'ab')
      select(editor, editor.state.selection.head, editor.state.selection.head + 2)
      press(editor, 'Backspace')
    } else {
      caret(editor, 'ab', 'end')
      for (const key of keys) press(editor, key)
    }
    expect(exportMarkdown(editor), keys.join()).toBe('-\n- cd')
  }
})

test('an empty paragraph that an item has in the source stays', () => {
  const editor = open('- <p />\n- <p align="center" />')
  expect(exportMarkdown(editor)).toBe('- <p />\n- <p align="center" />')
  expectReopens(editor)
  const page = new PageSession(editor)
  try {
    page.apply({ format: 'markdown', source: '- <p />\n- a', revision: page.revision })
    expect(exportMarkdown(editor)).toBe('- <p />\n- a')
  } finally {
    page.dispose()
  }
})

test('an empty item that takes children keeps a paragraph above them', () => {
  const editor = open('-\n- y')
  caret(editor, 'y')
  press(editor, 'Tab')
  expect(exportMarkdown(editor)).toBe('- <p />\n  - y')
})

/** Select from `offset` in the text block `anchor` to `headOffset` in the text block `head`. */
function selectRange(editor: Wordgard, [anchor, offset, head, headOffset]: Range) {
  const start = (text: string) => {
    let found = -1
    editor.state.doc.iterate((node, pos) => {
      if (found < 0 && node.isPlot && node.isTextblock && node.textContent() === text) found = pos + 1
    })
    if (found < 0) throw new Error(`The page has no text block ${text}`)
    return found
  }
  select(editor, start(anchor) + offset, start(head) + headOffset)
}

type Range = readonly [string, number, string, number]

test.each<[string, string, Range, string]>([
  [
    'a nested item in a table cell',
    '<table>\n  <tr>\n    <td>\n      - x1\n        - x2\n    </td>\n    <td>\n      y\n    </td>\n  </tr>\n</table>',
    ['x1', 1, 'x2', 1],
    '<table>\n  <tr>\n    <td>\n      - x?2\n    </td>\n    <td>\n      y\n    </td>\n  </tr>\n</table>'
  ],
  [
    'a nested item in a callout with a following block',
    '<callout>\n  - x1\n    - x2\n\n  after\n</callout>',
    ['x1', 1, 'x2', 1],
    '<callout>\n  - x?2\n\n  after\n</callout>'
  ],
  [
    'a sublist item and a callout',
    '- one\n  - two\n\n<callout>\n  inside c\n\n  second c\n</callout>\n\ntail',
    ['two', 1, 'inside c', 3],
    '- one\n  - t?ide c\n\n<callout>\n  second c\n</callout>\n\ntail'
  ],
  ['an ordered item and its sublist', '1. a1\n   - n1\n   - n2\n2. z9', ['a1', 1, 'n2', 1], '1. a?2\n2. z9'],
  ['a paragraph and an item with two blocks', 'q1\n\n- l1\n\n  l1b', ['q1', 2, 'l1', 0], 'q1?l1\n\n- l1b']
])('Backspace, typing and cut over %s keep the unselected structure', (_, source, range, expected) => {
  const edits: [string, (editor: Wordgard) => unknown][] = [
    ['', editor => press(editor, 'Backspace')],
    ['Z', editor => typeText(editor, 'Z')],
    ['', editor => Command.dispatch(editor, deleteCut)]
  ]
  for (const [inserted, edit] of edits) {
    const editor = open(source)
    selectRange(editor, range)
    edit(editor)
    expect(readTree(editor)).toEqual(readTree(open(expected.replace('?', inserted))))
  }
})
