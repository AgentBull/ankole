import {
  caret,
  clipboard,
  expect,
  expectMarkdown,
  openDocument,
  replaceDocument,
  reopen,
  selectText,
  test
} from './helpers'

// Backspace, Delete, Enter and Tab at block boundaries behave as in Notion (checked by hand on
// 2026-10-08). The caret is in the text given by `at`. Playwright runs the browsers on this
// machine, so the page and the browser use its platform keys.
const mac = process.platform === 'darwin'
const backspace = mac ? [['Backspace'], ['Alt+Backspace'], ['Control+H']] : [['Backspace'], ['Control+Backspace']]
const lineStart = mac ? [['Meta+Backspace']] : []
const forward = mac
  ? [['Delete'], ['Alt+Delete'], ['Meta+Delete'], ['Control+D'], ['Control+K']]
  : [['Delete'], ['Control+Delete']]

type Scenario = {
  name: string
  markdown: string
  at: [text: string, offset: number | 'end']
  keys: string[][]
  expected: string
}

const scenarios: Scenario[] = [
  {
    name: 'Backspace and line deletion merge a paragraph into the paragraph before it',
    markdown: 's\n\na\n\nhello\n\ne',
    at: ['hello', 0],
    keys: [...backspace, ...lineStart],
    expected: 's\n\nahello\n\ne'
  },
  {
    name: 'a heading merges into the paragraph before it, which keeps its type',
    markdown: 's\n\na\n\n## hello\n\ne',
    at: ['hello', 0],
    keys: [...backspace, ...lineStart],
    expected: 's\n\nahello\n\ne'
  },
  {
    name: 'Backspace turns the first list item into a paragraph',
    markdown: 's\n\na\n\n- hello\n- next\n\ne',
    at: ['hello', 0],
    keys: backspace,
    expected: 's\n\na\n\nhello\n\n- next\n\ne'
  },
  {
    name: 'line deletion merges the first list item into the paragraph before the list',
    markdown: 's\n\na\n\n- hello\n- next\n\ne',
    at: ['hello', 0],
    keys: lineStart,
    expected: 's\n\nahello\n\n- next\n\ne'
  },
  {
    name: 'Backspace turns a middle list item into a paragraph and splits the list',
    markdown: 's\n\n- a\n- hello\n- next\n\ne',
    at: ['hello', 0],
    keys: backspace,
    expected: 's\n\n- a\n\nhello\n\n- next\n\ne'
  },
  {
    name: 'line deletion merges a middle list item into the item before it',
    markdown: 's\n\n- a\n- hello\n- next\n\ne',
    at: ['hello', 0],
    keys: lineStart,
    expected: 's\n\n- ahello\n- next\n\ne'
  },
  {
    name: 'Backspace turns a nested list item into text of the item above',
    markdown: 's\n\n- a\n  - hello\n- next\n\ne',
    at: ['hello', 0],
    keys: backspace,
    expected: 's\n\n- a\n\n  hello\n- next\n\ne'
  },
  {
    name: 'line deletion lifts a nested list item one level',
    markdown: 's\n\n- a\n  - hello\n- next\n\ne',
    at: ['hello', 0],
    keys: lineStart,
    expected: 's\n\n- a\n- hello\n- next\n\ne'
  },
  {
    name: 'Backspace in a nested item with children keeps the children under the item above',
    markdown: 's\n\n- a\n  - hello\n    - child\n- next\n\ne',
    at: ['hello', 0],
    keys: backspace,
    expected: 's\n\n- a\n\n  hello\n\n  - child\n- next\n\ne'
  },
  {
    name: 'line deletion lifts a nested item together with its children',
    markdown: 's\n\n- a\n  - hello\n    - child\n- next\n\ne',
    at: ['hello', 0],
    keys: lineStart,
    expected: 's\n\n- a\n- hello\n  - child\n- next\n\ne'
  },
  {
    name: 'text under a list item moves out of the list',
    markdown: 's\n\n- a\n\n  hello\n- next\n\ne',
    at: ['hello', 0],
    keys: [...backspace, ...lineStart],
    expected: 's\n\n- a\n\nhello\n\n- next\n\ne'
  },
  {
    name: 'an indented paragraph outdents',
    markdown: 's\n\na\n\n<p indent="1">hello</p>\n\ne',
    at: ['hello', 0],
    keys: [...backspace, ...lineStart],
    expected: 's\n\na\n\nhello\n\ne'
  },
  {
    name: 'Backspace turns a quote into a paragraph',
    markdown: 's\n\n> hello\n\nnext\n\ne',
    at: ['hello', 0],
    keys: backspace,
    expected: 's\n\nhello\n\nnext\n\ne'
  },
  {
    name: 'Backspace turns all paragraphs of a quote into paragraphs',
    markdown: 's\n\n> hello\n>\n> more\n\ne',
    at: ['hello', 0],
    keys: [['Backspace']],
    expected: 's\n\nhello\n\nmore\n\ne'
  },
  {
    name: 'line deletion merges a quote into the paragraph before it',
    markdown: 's\n\n> hello\n\nnext\n\ne',
    at: ['hello', 0],
    keys: lineStart,
    expected: 'shello\n\nnext\n\ne'
  },
  {
    name: 'Backspace turns a numbered item into a paragraph; the rest of the list numbers from 1',
    markdown: 's\n\n1. a\n2. hello\n3. next\n\ne',
    at: ['hello', 0],
    keys: [['Backspace']],
    expected: 's\n\n1. a\n\nhello\n\n1. next\n\ne'
  },
  {
    name: 'Backspace turns a checked to-do into a paragraph without the check',
    markdown: 's\n\n- [ ] a\n- [x] hello\n- [ ] next\n\ne',
    at: ['hello', 0],
    keys: [['Backspace']],
    expected: 's\n\n- [ ] a\n\nhello\n\n- [ ] next\n\ne'
  },
  {
    name: 'text after a divider merges past it; the divider stays',
    markdown: 's\n\n---\n\nhello\n\ne',
    at: ['hello', 0],
    keys: [...backspace, ...lineStart],
    expected: 'shello\n\n---\n\ne'
  },
  {
    name: 'text after an embed merges past it; the reference stays',
    markdown: 's\n\n<embed ref="r" />\n\nhello\n\ne',
    at: ['hello', 0],
    keys: [...backspace, ...lineStart],
    expected: 'shello\n\n<embed ref="r" />\n\ne'
  },
  {
    name: 'nothing happens after an embed at the page start',
    markdown: '<embed ref="r" />\n\nhello\n\ne',
    at: ['hello', 0],
    keys: [...backspace, ...lineStart],
    expected: '<embed ref="r" />\n\nhello\n\ne'
  },
  {
    name: 'the text of a one-line callout merges into the paragraph before it; the empty callout goes',
    markdown: 's\n\n<callout tone="info">hello</callout>\n\ne',
    at: ['hello', 0],
    keys: [...backspace, ...lineStart],
    expected: 'shello\n\ne'
  },
  {
    name: 'the first line of a callout merges out; the callout keeps its other lines',
    markdown: 's\n\n<callout tone="info">\n  hello\n\n  world\n</callout>\n\ne',
    at: ['hello', 0],
    keys: [['Backspace']],
    expected: 'shello\n\n<callout tone="info">\n  world\n</callout>\n\ne'
  },
  {
    name: 'an empty list item becomes an empty paragraph with Backspace and goes with line deletion',
    markdown: 's\n\n- a\n- x\n- next\n\ne',
    at: ['x', 'end'],
    keys: [['Backspace', 'Backspace']],
    expected: 's\n\n- a\n\n<p />\n\n- next\n\ne'
  },
  {
    name: 'line deletion removes an empty list item',
    markdown: 's\n\n- a\n- x\n- next\n\ne',
    at: ['x', 'end'],
    keys: lineStart.map(keys => ['Backspace', ...keys]),
    expected: 's\n\n- a\n- next\n\ne'
  },
  {
    name: 'Backspace removes an empty heading',
    markdown: 's\n\n## x\n\ne',
    at: ['x', 'end'],
    keys: [['Backspace', 'Backspace']],
    expected: 's\n\ne'
  },
  {
    name: 'Backspace turns an empty quote into an empty paragraph',
    markdown: 's\n\n> x\n\ne',
    at: ['x', 'end'],
    keys: [['Backspace', 'Backspace']],
    expected: 's\n\n<p />\n\ne'
  },
  {
    name: 'text after a callout merges into its last line',
    markdown: 's\n\n<callout tone="info">c</callout>\n\nhello\n\ne',
    at: ['hello', 0],
    keys: [['Backspace']],
    expected: 's\n\n<callout tone="info">\n  chello\n</callout>\n\ne'
  },
  {
    name: 'text after a quote merges into the quote',
    markdown: 's\n\n> quote\n\nhello\n\ne',
    at: ['hello', 0],
    keys: [['Backspace']],
    expected: 's\n\n> quotehello\n\ne'
  },
  {
    name: 'text after a table merges into its last cell',
    markdown: 's\n\n| a | b |\n| - | - |\n| x | y |\n\nhello\n\ne',
    at: ['hello', 0],
    keys: [['Backspace']],
    expected: 's\n\n| a | b      |\n| - | ------ |\n| x | yhello |\n\ne'
  },
  {
    name: 'nothing happens at the start of a table cell',
    markdown: '| a | b |\n| - | - |\n| x | hello |',
    at: ['hello', 0],
    keys: [['Backspace'], ...lineStart],
    expected: '| a | b     |\n| - | ----- |\n| x | hello |'
  },
  {
    name: 'every forward deletion key merges the next paragraph',
    markdown: 's\n\nhello\n\nb\n\ne',
    at: ['hello', 'end'],
    keys: forward,
    expected: 's\n\nhellob\n\ne'
  },
  {
    name: 'Delete at the end of a heading takes in the next paragraph',
    markdown: 's\n\n## hello\n\nb\n\ne',
    at: ['hello', 'end'],
    keys: [['Delete']],
    expected: 's\n\n## hellob\n\ne'
  },
  {
    name: 'Delete at the end of a list item takes in the next item',
    markdown: 's\n\n- hello\n- next\n\ne',
    at: ['hello', 'end'],
    keys: [['Delete']],
    expected: 's\n\n- hellonext\n\ne'
  },
  {
    name: 'Delete at the end of a quote takes in the next paragraph',
    markdown: 's\n\n> hello\n\nb\n\ne',
    at: ['hello', 'end'],
    keys: forward,
    expected: 's\n\n> hellob\n\ne'
  },
  {
    name: 'Delete before a divider takes in the text after it; the divider stays',
    markdown: 's\n\nhello\n\n---\n\nb\n\ne',
    at: ['hello', 'end'],
    keys: forward,
    expected: 's\n\nhellob\n\n---\n\ne'
  },
  {
    name: 'Delete before a list takes in its first item',
    markdown: 's\n\nhello\n\n- b\n- c\n\ne',
    at: ['hello', 'end'],
    keys: [['Delete']],
    expected: 's\n\nhellob\n\n- c\n\ne'
  },
  {
    name: 'Delete at the end of a list item takes in its first nested item',
    markdown: 's\n\n- hello\n  - child\n- next\n\ne',
    at: ['hello', 'end'],
    keys: [['Delete']],
    expected: 's\n\n- hellochild\n- next\n\ne'
  },
  {
    name: 'Delete before an embed takes in the text after it; the reference stays',
    markdown: 's\n\nhello\n\n<embed ref="r" />\n\ne',
    at: ['hello', 'end'],
    keys: forward,
    expected: 's\n\nhelloe\n\n<embed ref="r" />'
  },
  {
    name: 'nothing happens before an embed at the page end',
    markdown: 's\n\nhello\n\n<embed ref="r" />',
    at: ['hello', 'end'],
    keys: forward,
    expected: 's\n\nhello\n\n<embed ref="r" />'
  },
  {
    name: 'Delete at the end of a callout takes in the next paragraph',
    markdown: 's\n\n<callout tone="info">hello</callout>\n\nb\n\ne',
    at: ['hello', 'end'],
    keys: [['Delete']],
    expected: 's\n\n<callout tone="info">\n  hellob\n</callout>\n\ne'
  },
  {
    name: 'Delete before a callout takes in its first line; the empty callout goes',
    markdown: 's\n\nhello\n\n<callout tone="info">c</callout>\n\ne',
    at: ['hello', 'end'],
    keys: [['Delete']],
    expected: 's\n\nhelloc\n\ne'
  },
  {
    name: 'Delete before a quote takes in its text; the empty quote goes',
    markdown: 's\n\nhello\n\n> quote\n\ne',
    at: ['hello', 'end'],
    keys: [['Delete']],
    expected: 's\n\nhelloquote\n\ne'
  },
  {
    name: 'nothing happens before a table',
    markdown: 's\n\nhello\n\n| a | b |\n| - | - |\n| x | y |\n\ne',
    at: ['hello', 'end'],
    keys: [['Delete']],
    expected: 's\n\nhello\n\n| a | b |\n| - | - |\n| x | y |\n\ne'
  },
  {
    name: 'Enter in an empty middle list item leaves the list',
    markdown: 's\n\n- a\n- x\n- next\n\ne',
    at: ['x', 'end'],
    keys: [['Backspace', 'Enter']],
    expected: 's\n\n- a\n\n<p />\n\n- next\n\ne'
  },
  {
    name: 'Enter in an empty nested list item lifts it',
    markdown: 's\n\n- a\n  - x\n- next\n\ne',
    at: ['x', 'end'],
    keys: [['Backspace', 'Enter']],
    expected: 's\n\n- a\n-\n- next\n\ne'
  },
  {
    name: 'Enter at the start of a list item adds an empty item above',
    markdown: 's\n\n- a\n- hello\n\ne',
    at: ['hello', 0],
    keys: [['Enter']],
    expected: 's\n\n- a\n-\n- hello\n\ne'
  },
  {
    name: 'Enter in the middle of a heading leaves the rest as a paragraph',
    markdown: 's\n\n## hello\n\ne',
    at: ['hello', 3],
    keys: [['Enter']],
    expected: 's\n\n## hel\n\nlo\n\ne'
  },
  {
    name: 'Enter at the end of a heading adds a paragraph',
    markdown: 's\n\n## hello\n\ne',
    at: ['hello', 'end'],
    keys: [['Enter']],
    expected: 's\n\n## hello\n\n<p />\n\ne'
  },
  {
    name: 'Enter at the start of a heading adds a paragraph above',
    markdown: 's\n\n## hello\n\ne',
    at: ['hello', 0],
    keys: [['Enter']],
    expected: 's\n\n<p />\n\n## hello\n\ne'
  },
  {
    name: 'Enter at the end of a quote leaves the quote',
    markdown: 's\n\n> hello\n\ne',
    at: ['hello', 'end'],
    keys: [['Enter']],
    expected: 's\n\n> hello\n\n<p />\n\ne'
  },
  {
    name: 'Enter in the middle of a quote leaves the rest as a paragraph',
    markdown: 's\n\n> hello\n\ne',
    at: ['hello', 2],
    keys: [['Enter']],
    expected: 's\n\n> he\n\nllo\n\ne'
  },
  {
    name: 'Enter in the middle of a quote keeps its later paragraphs in a quote',
    markdown: 's\n\n> hello\n>\n> more\n\ne',
    at: ['hello', 2],
    keys: [['Enter']],
    expected: 's\n\n> he\n\nllo\n\n> more\n\ne'
  },
  {
    name: 'Enter at the start of a quote adds a paragraph above it',
    markdown: 's\n\n> hello\n\ne',
    at: ['hello', 0],
    keys: [['Enter']],
    expected: 's\n\n<p />\n\n> hello\n\ne'
  },
  {
    name: 'Enter at the end of a checked to-do adds an unchecked one; Enter again leaves the list',
    markdown: 's\n\n- [x] hello\n\ne',
    at: ['hello', 'end'],
    keys: [['Enter', 'Enter']],
    expected: 's\n\n- [x] hello\n\n<p />\n\ne'
  },
  {
    name: 'Enter in a callout adds a line inside it',
    markdown: 's\n\n<callout tone="info">hello</callout>\n\ne',
    at: ['hello', 'end'],
    keys: [['Enter']],
    expected: 's\n\n<callout tone="info">\n  hello\n\n  <p />\n</callout>\n\ne'
  },
  {
    name: 'Enter on an empty last line of a callout moves the line after the callout',
    markdown: 's\n\n<callout tone="info">hello</callout>\n\ne',
    at: ['hello', 'end'],
    keys: [['Enter', 'Enter']],
    expected: 's\n\n<callout tone="info">\n  hello\n</callout>\n\n<p />\n\ne'
  },
  {
    name: 'Shift+Enter adds a line break inside a list item',
    markdown: 's\n\n- hello\n\ne',
    at: ['hello', 2],
    keys: [['Shift+Enter']],
    expected: 's\n\n- he<br />llo\n\ne'
  },
  {
    name: 'Tab anywhere in a list item nests it under the item above',
    markdown: 's\n\n- a\n- hello\n- next\n\ne',
    at: ['hello', 2],
    keys: [['Tab']],
    expected: 's\n\n- a\n  - hello\n- next\n\ne'
  },
  {
    name: 'Tab anywhere in a paragraph indents it; Shift+Tab outdents it',
    markdown: 's\n\na\n\nhello\n\ne',
    at: ['hello', 2],
    keys: [['Tab'], ['Tab', 'Shift+Tab', 'Tab']],
    expected: 's\n\n<block>\n  a\n\n  hello\n</block>\n\ne'
  },
  {
    name: 'Shift+Tab lifts a nested item; the items after it become its children',
    markdown: 's\n\n- a\n  - hello\n  - b\n  - c\n- next\n\ne',
    at: ['hello', 0],
    keys: [['Shift+Tab']],
    expected: 's\n\n- a\n- hello\n  - b\n  - c\n- next\n\ne'
  },
  {
    name: 'Shift+Tab lifts a nested item with its children',
    markdown: 's\n\n- a\n  - hello\n    - child\n- next\n\ne',
    at: ['hello', 0],
    keys: [['Shift+Tab']],
    expected: 's\n\n- a\n- hello\n  - child\n- next\n\ne'
  },
  {
    name: 'Tab nests the first list item under the preceding ordinary block',
    markdown: 's\n\n- hello\n\ne',
    at: ['hello', 0],
    keys: [['Tab']],
    expected: '<block>\n  s\n\n  - hello\n</block>\n\ne'
  },
  {
    name: 'Tab keeps the first list item when no preceding block can own it',
    markdown: '- hello\n\ne',
    at: ['hello', 0],
    keys: [['Tab']],
    expected: '- hello\n\ne'
  },
  {
    name: 'Tab in a code block indents the current line',
    markdown: 's\n\n```\nhello\n```\n\ne',
    at: ['hello', 2],
    keys: [['Tab']],
    expected: 's\n\n```\n\thello\n```\n\ne'
  }
]

for (const { name, markdown, at, keys, expected } of scenarios) {
  test(name, async ({ page }) => {
    test.skip(!keys.length, 'The keys are macOS text editing keys.')
    await page.goto('/')
    for (const sequence of keys) {
      await test.step(sequence.join(', '), async () => {
        await replaceDocument(page, markdown)
        await caret(page.locator('.editor-content').getByText(at[0], { exact: true }), at[1])
        for (const key of sequence) await page.keyboard.press(key)
        await expectMarkdown(page, expected)
      })
    }
  })
}

test('code Tab and Shift+Tab indent selected lines without replacing their text', async ({ page }) => {
  await openDocument(page, 'Before\n\n```\nfirst\nsecond\nthird\n```\n\nAfter')
  const code = page.locator('.editor-content pre')
  await code.click()
  await page.keyboard.press('ControlOrMeta+a')
  await page.keyboard.press('Tab')
  await expect.poll(() => code.innerText()).toBe('\tfirst\n\tsecond\n\tthird')
  await page.keyboard.press('Shift+Tab')
  await expect.poll(() => code.innerText()).toBe('first\nsecond\nthird')
  await page.keyboard.press('ControlOrMeta+z')
  await expect.poll(() => code.innerText()).toBe('\tfirst\n\tsecond\n\tthird')
  await page.keyboard.press('ControlOrMeta+Shift+z')
  await expect.poll(() => code.innerText()).toBe('first\nsecond\nthird')
  await selectText(page, 'second', 0, 'first', 2)
  await page.keyboard.press('Tab')
  await expect.poll(() => code.innerText()).toBe('\tfirst\n\tsecond\nthird')
  await expect(page.locator('.editor-content > p')).toHaveText(['Before', 'After'])
  await reopen(page)
  await expect.poll(() => code.innerText()).toBe('\tfirst\n\tsecond\nthird')
})

test('Shift+Tab lifts a selected child while preserving selected root siblings', async ({ page }) => {
  await openDocument(page, '<block>\n  Parent\n\n  Child\n</block>\n\nRoot')
  await caret(page.locator('.editor-content').getByText('Child', { exact: true }), 0)
  await page.keyboard.press('Escape')
  await page.keyboard.press('Shift+ArrowDown')
  await expect(page.locator('.editor-selected-block')).toHaveText(['Child', 'Root'])
  await page.keyboard.press('Shift+Tab')
  await expect(page.locator('.editor-content > p')).toHaveText(['Parent', 'Child', 'Root'])
  await expect(page.locator('.editor-selected-block')).toHaveText(['Child', 'Root'])
  await page.keyboard.press('ControlOrMeta+z')
  await expect(page.locator('.block-group > p')).toHaveText(['Parent', 'Child'])
  await expect(page.locator('.editor-selected-block')).toHaveText(['Child', 'Root'])
})

test('pasting over two selected list items keeps the next item at its level', async ({ page }) => {
  await openDocument(page, '- i1\n- i2\n- i3')
  await caret(page.locator('.editor-content').getByText('i1', { exact: true }), 1)
  await page.keyboard.press('Escape')
  await page.keyboard.press('Shift+ArrowDown')
  await expect(page.locator('.editor-selected-block')).toHaveText(['i1', 'i2'])
  await clipboard(page.locator('.editor-content'), 'paste', { 'text/plain': 'Z' })
  await expectMarkdown(page, '- Z\n- i3')
})

test('typing and cutting over a range keep the structure that Backspace keeps', async ({ page }) => {
  const source = '- one\n  - two\n\n<callout>\n  inside c\n\n  second c\n</callout>\n\ntail'
  const kept = (text: string) => `- one\n  - ${text}\n\n<callout>\n  second c\n</callout>\n\ntail`
  await openDocument(page, source)
  await selectText(page, 'two', 1, 'inside c', 3)
  await page.keyboard.type('Z')
  await expectMarkdown(page, kept('tZide c'))
  await replaceDocument(page, source)
  await selectText(page, 'two', 1, 'inside c', 3)
  await clipboard(page.locator('.editor-content'), 'cut')
  await expectMarkdown(page, kept('tide c'))
  await replaceDocument(page, '1. a1\n   - n1\n   - n2\n2. z9')
  await selectText(page, 'a1', 1, 'n2', 1)
  await clipboard(page.locator('.editor-content'), 'cut')
  await expectMarkdown(page, '1. a2\n2. z9')
})
