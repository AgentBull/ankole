import type { Page } from '@playwright/test'
import { caret, expect, expectMarkdown, openDocument, replaceDocument, selectText, test } from './helpers'

// Playwright runs the browsers on this machine, so the page and the browser use its platform keys.
const mac = process.platform === 'darwin'
const macKey = 'The key is a macOS text editing key.'

for (const { name, key, at, markdown, apple } of [
  { name: 'deletes the character before the caret', key: 'Control+H', at: 'end', markdown: 'hello worl', apple: true },
  {
    name: 'deletes the character after the caret and does not duplicate the block',
    key: 'Control+D',
    at: 0,
    markdown: 'ello world',
    apple: true
  },
  {
    name: 'deletes the word before the caret',
    key: mac ? 'Alt+Backspace' : 'Control+Backspace',
    at: 'end',
    markdown: 'hello&#x20;',
    apple: false
  },
  {
    name: 'deletes the word after the caret',
    key: mac ? 'Alt+Delete' : 'Control+Delete',
    at: 0,
    markdown: '&#x20;world',
    apple: false
  },
  { name: 'deletes to the line start', key: 'Meta+Backspace', at: 'end', markdown: '<p />', apple: true },
  { name: 'deletes to the line end', key: 'Meta+Delete', at: 0, markdown: '<p />', apple: true },
  { name: 'deletes to the line end', key: 'Control+K', at: 6, markdown: 'hello&#x20;', apple: true },
  { name: 'transposes the characters around the caret', key: 'Control+T', at: 2, markdown: 'hlelo world', apple: true }
] as const) {
  test(`${key} ${name}`, async ({ page, browserName }) => {
    test.skip(apple && !mac, macKey)
    test.skip(key === 'Control+T' && browserName === 'firefox', 'Firefox does not transpose characters.')
    await openDocument(page, 'hello world')
    await caret(page.locator('.editor-content > p'), at)
    await page.keyboard.press(key)
    await expectMarkdown(page, markdown)
  })
}

test('text that Ctrl+K deletes does not come back with Ctrl+Y on macOS', async ({ page }) => {
  test.skip(!mac, macKey)
  await openDocument(page, 'hello world')
  await caret(page.locator('.editor-content > p'), 6)
  await page.keyboard.press('Control+K')
  await page.keyboard.press('Control+Y')
  await expectMarkdown(page, 'hello&#x20;')
})

test('Ctrl+K deletes a selection on macOS and does not open the link form', async ({ page }) => {
  test.skip(!mac, macKey)
  await openDocument(page, 'hello world')
  await selectText(page, 'hello world', 0, 'hello world', 5)
  await page.keyboard.press('Control+K')
  await expect(page.getByRole('dialog', { name: '编辑链接' })).toHaveCount(0)
  await expectMarkdown(page, '&#x20;world')
})

// Deleting keys of the platform. Block boundaries are tested in block-keys.spec.ts.
const backward = mac
  ? ['Backspace', 'Control+H', 'Alt+Backspace', 'Meta+Backspace']
  : ['Backspace', 'Control+Backspace']
const forward = mac ? ['Delete', 'Control+D', 'Alt+Delete', 'Meta+Delete', 'Control+K'] : ['Delete', 'Control+Delete']

test('every deleting key removes only the text of a fully selected callout', async ({ page }) => {
  await page.goto('/')
  for (const key of [...backward, ...forward]) {
    await test.step(key, async () => {
      await replaceDocument(page, '<callout tone="info">hello world</callout>')
      await selectText(page, 'hello world', 0, 'hello world', 11)
      await page.keyboard.press(key)
      await expectMarkdown(page, '<callout tone="info">\n  <p />\n</callout>')
    })
  }
})

// The block that holds the DOM caret, described by its element name and text.
function caretBlock(page: Page) {
  return page.evaluate(() => {
    const blocks = 'li, td, th, .editor-content > *'
    const anchor = window.getSelection()?.anchorNode
    const element = anchor instanceof Element ? anchor : anchor?.parentElement
    const block = element?.closest(blocks)
    return block ? `${block.localName}:${block.textContent}` : null
  })
}

test('w3c/editing#513 Up and Down arrows stop in every editable block and skip a database reference', async ({
  page
}) => {
  const markdown = 'first\n\n<p />\n\n## heading\n\n<database ref="r" />\n\n- item\n\nlast'
  await openDocument(page, markdown)
  await caret(page.locator('.editor-content > p').first(), 0)
  await expect.poll(() => caretBlock(page)).toBe('p:first')
  for (const stop of ['p:', 'h2:heading', 'li:item', 'p:last', 'p:last']) {
    await page.keyboard.press('ArrowDown')
    await expect.poll(() => caretBlock(page), `ArrowDown to ${stop}`).toBe(stop)
  }
  for (const stop of ['li:item', 'h2:heading', 'p:', 'p:first', 'p:first']) {
    await page.keyboard.press('ArrowUp')
    await expect.poll(() => caretBlock(page), `ArrowUp to ${stop}`).toBe(stop)
  }
  await expectMarkdown(page, markdown)
})

// After "a", an empty block of each type, then "b". The table row has an empty cell before "c".
for (const { name, markdown, target, expected } of [
  {
    name: 'paragraph',
    markdown: 'a\n\n<p />\n\nb',
    target: '.editor-content > p >> nth=1',
    expected: 'a\n\nx\n\nb'
  },
  { name: 'heading', markdown: 'a\n\n<h2 />\n\nb', target: '.editor-content > h2', expected: 'a\n\n## x\n\nb' },
  { name: 'list item', markdown: 'a\n\n-\n\nb', target: '.editor-content li', expected: 'a\n\n- x\n\nb' },
  {
    name: 'callout paragraph',
    markdown: 'a\n\n<callout tone="info">\n  <p />\n</callout>\n\nb',
    target: '.editor-content aside p',
    expected: 'a\n\n<callout tone="info">\n  x\n</callout>\n\nb'
  },
  {
    name: 'table cell',
    markdown: '| a | b |\n| - | - |\n|  | c |',
    target: '.editor-content td >> nth=0',
    expected: '| a | b |\n| - | - |\n| x | c |'
  }
]) {
  for (const way of ['click', 'ArrowDown'] as const) {
    test(`w3c/editing#516 ${way} places the caret in an empty ${name}`, async ({ page }) => {
      await openDocument(page, markdown)
      if (way === 'click') {
        const box = (await page.locator(target).boundingBox())!
        await page.mouse.click(box.x + 8, box.y + box.height / 2)
      } else {
        await caret(page.locator('.editor-content').getByText('a', { exact: true }))
        await page.keyboard.press('ArrowDown')
      }
      await page.keyboard.type('x')
      await expectMarkdown(page, expected)
    })
  }
}
