import type { Page } from '@playwright/test'
import { caret, expect, expectMarkdown, openDocument, test } from './helpers'

async function clickBelow(page: Page, side: 'left' | 'center' | 'right' = 'center') {
  const box = (await page.locator('.editor-content').boundingBox())!
  const last = (await page.locator('.editor-content > :last-child').boundingBox())!
  const x = side === 'left' ? box.x - 60 : side === 'right' ? box.x + box.width + 60 : box.x + 40
  await page.mouse.click(x, last.y + last.height + 35)
}

// SPEC §7.5 Page-end click: every nonempty or non-paragraph ending gets a root paragraph.
for (const [name, markdown, expected] of [
  ['a table', '| a | b |\n| - | - |\n| c | d |', '| a | b |\n| - | - |\n| c | d |\n\nx'],
  ['a quote', '> quote', '> quote\n\nx'],
  ['a callout', '<callout tone="info">c</callout>', '<callout tone="info">\n  c\n</callout>\n\nx'],
  ['an embed', 'a\n\n<embed ref="t" />', 'a\n\n<embed ref="t" />\n\nx'],
  ['a divider', 'a\n\n---', 'a\n\n---\n\nx'],
  ['a paragraph', 'a\n\nlast', 'a\n\nlast\n\nx'],
  ['a heading', '## Heading', '## Heading\n\nx'],
  ['an empty heading', '<h2></h2>', '##\n\nx'],
  ['a code block', '```\ncode\n```', '```\ncode\n```\n\nx'],
  ['a list', '- one\n- two', '- one\n- two\n\nx'],
  ['an empty list item', '- one\n- ', '- one\n-\n\nx'],
  ['a task list', '- [ ] Task', '- [ ] Task\n\nx'],
  ['nested blocks', '<block>\nParent\n\nChild\n</block>', '<block>\n  Parent\n\n  Child\n</block>\n\nx']
] as const) {
  test(`a click below ${name} appends and focuses a root paragraph`, async ({ page }) => {
    await openDocument(page, markdown)
    await clickBelow(page)
    await expect(page.locator('.editor-content')).toBeFocused()
    await page.keyboard.type('x')
    await expectMarkdown(page, expected)
  })
}

test('repeated clicks reuse the empty last paragraph and expose its typing hint', async ({ page }) => {
  await openDocument(page, 'First')
  const paragraphs = page.locator('.editor-content > p')
  await clickBelow(page)
  await expect(paragraphs).toHaveCount(2)
  await expect(paragraphs.last()).toHaveAttribute('data-placeholder', /\//)
  for (const side of ['left', 'center', 'right'] as const) {
    await caret(paragraphs.first(), 0)
    await clickBelow(page, side)
    await expect(paragraphs).toHaveCount(2)
    await expect(page.locator('.editor-content')).toBeFocused()
  }
  await page.screenshot({ path: test.info().outputPath('page-end.png') })
  await page.keyboard.type('Second')
  await expect(paragraphs).toHaveText(['First', 'Second'])
  await expect(paragraphs.last()).not.toHaveAttribute('data-placeholder')
  await page.keyboard.press('ControlOrMeta+z')
  await expect(paragraphs).toHaveText(['First', ''])
  await page.keyboard.press('ControlOrMeta+z')
  await expect(paragraphs).toHaveText(['First'])
  await page.keyboard.press('ControlOrMeta+Shift+z')
  await expect(paragraphs).toHaveText(['First', ''])
})

for (const side of ['left', 'right'] as const) {
  test(`page whitespace on the ${side} creates a paragraph only below the last block`, async ({ page }) => {
    await openDocument(page, 'First\n\nLast')
    const paragraphs = page.locator('.editor-content > p')
    const last = (await paragraphs.last().boundingBox())!
    await page.mouse.click(side === 'left' ? last.x - 60 : last.x + last.width + 60, last.y + last.height / 2)
    await expect(paragraphs).toHaveCount(2)
    await clickBelow(page, side)
    await expect(paragraphs).toHaveCount(3)
    await page.keyboard.type('New')
    await expect(paragraphs).toHaveText(['First', 'Last', 'New'])
  })
}

test('dragging up from below the page selects blocks without appending a paragraph', async ({ page }) => {
  await openDocument(page, 'First\n\nLast')
  const paragraphs = page.locator('.editor-content > p')
  const last = (await paragraphs.last().boundingBox())!
  await page.mouse.move(last.x + 100, last.y + last.height + 50)
  await page.mouse.down()
  await page.mouse.move(last.x - 60, last.y + 2, { steps: 10 })
  await page.mouse.up()
  await expect(paragraphs).toHaveCount(2)
  await expect(page.locator('.editor-selected-block')).toHaveText('Last')
})

test('an empty page reuses its paragraph', async ({ page }) => {
  await openDocument(page, '')
  await clickBelow(page)
  await clickBelow(page, 'right')
  await expect(page.locator('.editor-content > p')).toHaveCount(1)
  await page.keyboard.type('First')
  await expect(page.locator('.editor-content > p')).toHaveText('First')
})

test('an empty paragraph inside the last column stays there while the page gets a root paragraph', async ({ page }) => {
  await openDocument(page, '<columns>\n<column>\nLeft\n</column>\n<column>\n<p></p>\n</column>\n</columns>')
  await clickBelow(page)
  await page.keyboard.type('After columns')
  await expect(page.locator('.editor-content > p')).toHaveText('After columns')
  await expect(page.locator('.editor-content .editor-column').last().locator('p')).toHaveText('')
})

test('a long document accepts clicks in the page padding below the editor', async ({ page }) => {
  await openDocument(page, Array.from({ length: 30 }, (_, index) => `Line ${index + 1}`).join('\n\n'))
  const paragraphs = page.locator('.editor-content > p')
  await paragraphs.last().scrollIntoViewIfNeeded()
  await clickBelow(page, 'right')
  await expect(paragraphs).toHaveCount(31)
  await page.keyboard.type('After the long page')
  await expect(paragraphs.last()).toHaveText('After the long page')
})

test('read-only whitespace does not append a paragraph', async ({ page }) => {
  await page.goto('/playground/embedded.html')
  await page.getByRole('button', { name: 'Toggle read only', exact: true }).click()
  const editor = page.getByTestId('first-editor').locator('.editor-content')
  await expect(editor).toHaveAttribute('contenteditable', 'false')
  const before = await editor.innerHTML()
  const box = (await editor.boundingBox())!
  await page.mouse.click(box.x + 40, box.y + box.height - 20)
  expect(await editor.innerHTML()).toBe(before)
})
