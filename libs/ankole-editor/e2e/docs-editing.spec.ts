import { caret, expect, openDocument, reopen, selectText, test } from './helpers'

const callout =
  'docs:src/frontend/apps/impress/src/features/docs/doc-editor/components/custom-blocks/__tests__/CalloutBlockShortcuts.test.ts:'
test(`${callout}97 character deletion keeps the callout attributes`, async ({ page }) => {
  await openDocument(page, '<callout tone="info">Text</callout>')
  await caret(page.locator('.editor-content aside p'))
  await page.keyboard.press('Backspace')
  await expect(page.locator('.editor-content aside')).toHaveText('Tex')
  await expect(page.locator('.editor-content aside')).toHaveAttribute('data-tone', 'info')
  await reopen(page)
  await expect(page.locator('.editor-content aside')).toHaveText('Tex')
})

test(`${callout}108 selected text deletion keeps the custom container`, async ({ page }) => {
  await openDocument(page, '<callout tone="info">Text</callout>')
  await selectText(page, 'Text', 0, 'Text', 4)
  await page.keyboard.press('Backspace')
  await expect(page.locator('.editor-content aside')).toHaveText('')
  await expect(page.locator('.editor-content aside')).toHaveAttribute('data-tone', 'info')
  await page.getByRole('button', { name: '撤销', exact: true }).click()
  await expect(page.locator('.editor-content aside')).toHaveText('Text')
  await reopen(page)
})

const source = 'docs:src/frontend/apps/e2e/__tests__/app-impress/doc-editor.spec.ts:'
test(`${source}638 resizing between mobile and desktop preserves editable text`, async ({ page }) => {
  await openDocument(page, 'Hello World - Desktop Text')
  await page.setViewportSize({ width: 500, height: 1200 })
  await expect(page.locator('.editor-content')).toContainText('Hello World - Desktop Text')
  await caret(page.locator('.editor-content > p'))
  await page.keyboard.press('Enter')
  await page.keyboard.type('Mobile Text')
  await page.setViewportSize({ width: 1280, height: 720 })
  await expect(page.locator('.editor-content > p')).toHaveText(['Hello World - Desktop Text', 'Mobile Text'])
  await reopen(page)
})

test(`${source}216 reloading restores saved edits`, async ({ page }) => {
  await openDocument(page, 'Hello World Doc persisted 2')
  await caret(page.locator('.editor-content > p'))
  await page.keyboard.type(' edited')
  await expect(page.locator('.save-state')).toContainText('已保存')
  await page.reload()
  await expect(page.locator('.editor-content')).toHaveText('Hello World Doc persisted 2 edited')
})

test(`${source}129 applying Markdown creates the original link destination`, async ({ page }) => {
  await openDocument(page, '[test markdown](http://test-markdown.html)')
  await expect(page.locator('.editor-content a')).toHaveText('test markdown')
  await expect(page.locator('.editor-content a')).toHaveAttribute('href', 'http://test-markdown.html')
  await reopen(page)
  await expect(page.locator('.editor-content a')).toHaveAttribute('href', 'http://test-markdown.html')
})
