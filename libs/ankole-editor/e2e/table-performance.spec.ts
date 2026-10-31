import { test, expect, openDocument, caret } from './helpers'

test('a keystroke in a 500-row table takes far less than a second', async ({ page }) => {
  const rows = Array.from({ length: 500 }, (_, i) => `| r${i} | x | y | z | w |`)
  await openDocument(page, ['| a | b | c | d | e |', '| --- | --- | --- | --- | --- |', ...rows].join('\n'))
  const editor = page.locator('.editor-content')
  await caret(editor.getByText('r3', { exact: true }))
  await expect(page.getByRole('button', { name: '行 1', exact: true })).toBeVisible()
  // Quadratic table menu checks took about 26 s for each key. The bound allows for a slow machine.
  const start = Date.now()
  await page.keyboard.type('q')
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  expect(Date.now() - start).toBeLessThan(1000)
  await expect(editor.getByText('r3q', { exact: true })).toBeVisible()
})

test('cutting a whole document that starts with a table keeps the editor', async ({ page }) => {
  await openDocument(page, '| a | b |\n| --- | --- |\n| 1 | 2 |\n\nAfter')
  const editor = page.locator('.editor-content')
  await caret(editor.getByText('After', { exact: true }))
  // The cut comes before the editor draws the second ⌘A, as with fast real keys.
  await editor.evaluate(element => {
    const mac = /Mac/.test(navigator.platform)
    for (let i = 0; i < 2; i++) {
      element.dispatchEvent(
        new KeyboardEvent('keydown', {
          key: 'a',
          code: 'KeyA',
          metaKey: mac,
          ctrlKey: !mac,
          bubbles: true,
          cancelable: true
        })
      )
    }
    element.dispatchEvent(
      new ClipboardEvent('cut', { clipboardData: new DataTransfer(), bubbles: true, cancelable: true })
    )
  })
  await expect(editor.locator('table')).toHaveCount(0)
  await expect(editor).not.toContainText('After')
  await page.keyboard.type('Again')
  await expect(editor).toContainText('Again')
})
