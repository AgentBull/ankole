import { caret, expect, openDocument, reopen, selectText, test } from './helpers'

const native = 'affine:tests/blocksuite/e2e/selection/native.spec.ts:'
for (const { line, reverse, key } of [
  { line: 67, reverse: false, key: 'Backspace' },
  { line: 160, reverse: false, key: 'Delete' },
  { line: 206, reverse: true, key: 'Backspace' },
  { line: 233, reverse: true, key: 'Delete' }
]) {
  test(`${native}${line} range deletion, undo and redo`, async ({ page }) => {
    await openDocument(page, '123\n\n456\n\n789')
    await selectText(page, reverse ? '789' : '123', reverse ? 3 : 0, reverse ? '123' : '789', reverse ? 0 : 3)
    await page.keyboard.press(key)
    await expect(page.locator('.editor-content > p')).toHaveText([''])
    await page.getByRole('button', { name: '撤销', exact: true }).click()
    await expect(page.locator('.editor-content > p')).toHaveText(['123', '456', '789'])
    await page.getByRole('button', { name: '重做', exact: true }).click()
    await expect(page.locator('.editor-content > p')).toHaveText([''])
    await reopen(page)
  })
}

test(`${native}186 replaces a range across three paragraphs`, async ({ page }) => {
  await openDocument(page, '123\n\n456\n\n789')
  await selectText(page, '123', 0, '789', 3)
  await page.keyboard.press('Delete')
  await page.keyboard.type('a')
  await expect(page.locator('.editor-content > p')).toHaveText(['a'])
  await reopen(page)
})

const inline = 'affine:tests/blocksuite/e2e/cross-platform/inline/inline-editor.spec.ts:'
test(`${inline}407 rapid input keeps the caret at the text end`, async ({ page }) => {
  await openDocument(page, '')
  await page.locator('.editor-content').click()
  await Promise.all('aaaaaaaaaaaaaaaaaaaa'.split('').map(text => page.keyboard.type(text)))
  await expect(page.locator('.editor-content')).toHaveText('aaaaaaaaaaaaaaaaaaaa')
  const before = await page.evaluate(() => window.getSelection()!.focusOffset)
  await page.keyboard.press('ArrowRight')
  await page.keyboard.press('ArrowRight')
  await page.keyboard.press('ArrowRight')
  expect(await page.evaluate(() => window.getSelection()!.focusOffset)).toBe(before)
  await reopen(page)
})

test(`${inline}897 spaces beside a paragraph split survive reopen`, async ({ page }) => {
  await openDocument(page, '')
  await page.locator('.editor-content').click()
  await page.keyboard.type('abc   def', { delay: 20 })
  // The upstream keyboard helper uses 20 ms key presses so native selectionchange can run.
  for (let index = 0; index < 4; index++) await page.keyboard.press('ArrowLeft', { delay: 20 })
  await page.keyboard.press('Enter', { delay: 20 })
  expect(await page.locator('.editor-content > p').allTextContents()).toEqual(['abc  ', ' def'])
  await reopen(page)
  expect(await page.locator('.editor-content > p').allTextContents()).toEqual(['abc  ', ' def'])
})

test(`${inline}931 Shift+Arrow selects across lines and keeps both unselected ends`, async ({ page }) => {
  await openDocument(page, 'abc\n\ndef\n\nghi')
  await caret(page.locator('.editor-content > p').last(), 0)
  await page.keyboard.press('Shift+ArrowUp', { delay: 20 })
  await page.keyboard.press('Shift+ArrowUp', { delay: 20 })
  await page.keyboard.press('Shift+ArrowRight', { delay: 20 })
  await page.keyboard.press('Backspace')
  await expect(page.locator('.editor-content > p')).toHaveText(['aghi'])
  await reopen(page)
})

const firefox = 'affine:tests/blocksuite/e2e/cross-platform/inline/firefox-beforeinput.spec.ts:'
test(`${firefox}62 double-click word replacement leaves its neighbor`, async ({ page }) => {
  await openDocument(page, 'hello world')
  const point = await page.locator('.editor-content > p').evaluate(element => {
    const text = document.createTreeWalker(element, NodeFilter.SHOW_TEXT).nextNode()!
    const range = document.createRange()
    range.setStart(text, 1)
    range.setEnd(text, 2)
    const rect = range.getBoundingClientRect()
    return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 }
  })
  await page.mouse.dblclick(point.x, point.y)
  await page.keyboard.type('x')
  const text = await page.locator('.editor-content').textContent()
  expect(text!.startsWith('x')).toBe(true)
  expect(text).toContain('world')
  await reopen(page)
})

test(`${firefox}17 selection dragged beyond the editor does not break subsequent input`, async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 1000 })
  await openDocument(page, '123\n\n456\n\n789')
  const body = page.locator('.editor-content')
  const point = await body
    .locator(':scope > p')
    .last()
    .evaluate(element => {
      const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT)
      let last: Text | undefined
      while (walker.nextNode()) last = walker.currentNode as Text
      const range = document.createRange()
      range.setStart(last!, last!.length)
      range.collapse(true)
      const rect = range.getBoundingClientRect()
      return { x: rect.x, y: rect.y + rect.height / 2 }
    })
  expect(
    await body.evaluate((element, point) => element.contains(document.elementFromPoint(point.x, point.y)), point)
  ).toBe(true)
  const bounds = (await body.boundingBox())!
  await page.mouse.move(point.x, point.y)
  await page.mouse.down()
  await page.mouse.move(bounds.x + bounds.width / 2, bounds.y + bounds.height + 30, { steps: 20 })
  await page.mouse.up()
  await page.keyboard.press('Delete')
  await page.keyboard.type('a')
  await expect(body.locator(':scope > p').last()).toContainText('a')
  await reopen(page)
})
