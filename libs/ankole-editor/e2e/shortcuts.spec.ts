import type { Page } from '@playwright/test'
import { caret, expectMarkdown, openDocument, selectText, test } from './helpers'

// Shortcuts as in Notion. Command on macOS is Ctrl elsewhere; turn into is Command+Option or Ctrl+Shift.
const mac = process.platform === 'darwin'
const turnInto = (digit: string) => (mac ? `Meta+Alt+${digit}` : `Control+Shift+${digit}`)

// Type into an empty paragraph between "s" and "e".
async function typeIntoEmptyParagraph(page: Page, text: string) {
  await openDocument(page, 's\n\nX\n\ne')
  await caret(page.locator('.editor-content').getByText('X', { exact: true }))
  await page.keyboard.press('Backspace')
  await page.keyboard.type(text)
}

for (const [typed, expected] of [
  ['[] ', 's\n\n<ul>\n  <li task="todo" />\n</ul>\n\ne'],
  ['---', 's\n\n---\n\n<p />\n\ne'],
  ['---abc', 's\n\n---\n\nabc\n\ne'],
  ['" q', 's\n\n> q\n\ne'],
  ['| q', 's\n\n> q\n\ne']
]) {
  test(`typing ${JSON.stringify(typed)} at the start of an empty paragraph converts it`, async ({ page }) => {
    await typeIntoEmptyParagraph(page, typed!)
    await expectMarkdown(page, expected!)
  })
}

test('undo right after a typed shortcut gives back the typed characters', async ({ page }) => {
  await typeIntoEmptyParagraph(page, '[] ')
  await page.keyboard.press('ControlOrMeta+Z')
  await expectMarkdown(page, 's\n\n\\[]&#x20;\n\ne')
})

for (const [key, expected] of [
  ['ControlOrMeta+E', '`hello` world'],
  ['ControlOrMeta+Shift+S', '~~hello~~ world'],
  ['ControlOrMeta+Shift+X', '~~hello~~ world'],
  ['ControlOrMeta+Shift+H', '<mark>hello</mark> world']
]) {
  test(`${key} formats the selected text`, async ({ page }) => {
    await openDocument(page, 'hello world')
    await selectText(page, 'hello world', 0, 'hello world', 5)
    await page.keyboard.press(key!)
    await expectMarkdown(page, expected!)
  })
}

for (const { name, markdown, at, key, expected } of [
  {
    name: 'moves a paragraph down',
    markdown: 's\n\nhello\n\nb\n\ne',
    at: 'hello',
    key: 'ControlOrMeta+Shift+ArrowDown',
    expected: 's\n\nb\n\nhello\n\ne'
  },
  {
    name: 'moves a paragraph up',
    markdown: 's\n\nb\n\nhello\n\ne',
    at: 'hello',
    key: 'ControlOrMeta+Shift+ArrowUp',
    expected: 's\n\nhello\n\nb\n\ne'
  },
  {
    name: 'moves a list item with its nested items down',
    markdown: '- a\n  - child\n- b',
    at: 'a',
    key: 'ControlOrMeta+Shift+ArrowDown',
    expected: '- b\n- a\n  - child'
  },
  {
    name: 'moves a list item past an item with nested items',
    markdown: '- a\n- b\n  - child',
    at: 'b',
    key: 'ControlOrMeta+Shift+ArrowUp',
    expected: '- b\n  - child\n- a'
  },
  {
    name: 'turns a paragraph into a heading',
    markdown: 'hello',
    at: 'hello',
    key: turnInto('2'),
    expected: '## hello'
  },
  {
    name: 'turns a heading into a paragraph',
    markdown: '## hello',
    at: 'hello',
    key: turnInto('0'),
    expected: 'hello'
  },
  {
    name: 'turns a paragraph into a to-do',
    markdown: 'hello',
    at: 'hello',
    key: turnInto('4'),
    expected: '- [ ] hello'
  },
  { name: 'turns a paragraph into a bullet', markdown: 'hello', at: 'hello', key: turnInto('5'), expected: '- hello' },
  {
    name: 'turns a paragraph into a numbered item',
    markdown: 'hello',
    at: 'hello',
    key: turnInto('6'),
    expected: '1. hello'
  },
  {
    name: 'turns a paragraph into a code block',
    markdown: 'hello',
    at: 'hello',
    key: turnInto('8'),
    expected: '```\nhello\n```'
  },
  {
    name: 'duplicates a paragraph',
    markdown: 's\n\nhello\n\ne',
    at: 'hello',
    key: 'ControlOrMeta+D',
    expected: 's\n\nhello\n\nhello\n\ne'
  },
  {
    name: 'duplicates a list item with its nested items',
    markdown: '- a\n  - child\n- b',
    at: 'a',
    key: 'ControlOrMeta+D',
    expected: '- a\n  - child\n- a\n  - child\n- b'
  },
  {
    name: 'duplicates a line of a callout',
    markdown: '<callout tone="info">\n  one\n\n  two\n</callout>',
    at: 'one',
    key: 'ControlOrMeta+D',
    expected: '<callout tone="info">\n  one\n\n  one\n\n  two\n</callout>'
  }
]) {
  test(`${key} ${name}`, async ({ page }) => {
    await openDocument(page, markdown)
    await caret(page.locator('.editor-content').getByText(at, { exact: true }), 1)
    await page.keyboard.press(key)
    await expectMarkdown(page, expected)
  })
}

test('moving a block is one undo step', async ({ page }) => {
  await openDocument(page, 's\n\nhello\n\nb\n\ne')
  await caret(page.locator('.editor-content').getByText('hello', { exact: true }), 1)
  await page.keyboard.press('ControlOrMeta+Shift+ArrowDown')
  await page.keyboard.press('ControlOrMeta+Z')
  await expectMarkdown(page, 's\n\nhello\n\nb\n\ne')
})

for (const { name, markdown, from, to, key, expected } of [
  {
    name: 'duplicates every selected list item',
    markdown: '- a\n- b\n- c',
    from: 'a',
    to: 'b',
    key: 'ControlOrMeta+D',
    expected: '- a\n- b\n- a\n- b\n- c'
  },
  {
    name: 'moves every selected paragraph',
    markdown: 's\n\nhello\n\nworld\n\nb\n\ne',
    from: 'hello',
    to: 'world',
    key: 'ControlOrMeta+Shift+ArrowDown',
    expected: 's\n\nb\n\nhello\n\nworld\n\ne'
  }
]) {
  test(`${key} ${name}`, async ({ page }) => {
    await openDocument(page, markdown)
    await selectText(page, from, 0, to, 1)
    await page.keyboard.press(key)
    await expectMarkdown(page, expected)
  })
}
