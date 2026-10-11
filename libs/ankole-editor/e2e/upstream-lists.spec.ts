import { caret, expect, expectMarkdown, openDocument, reopen, selectText, test } from './helpers'

const source = 'pm-schema-list:test/test-commands.ts:'

for (const fixture of [
  { line: 65, offset: 3, end: 3, expected: ['foo', 'bar'] },
  { line: 68, offset: 6, end: 6, expected: ['foobar', ''] },
  { line: 71, offset: 3, end: 5, expected: ['foo', 'r'] }
]) {
  test(`${source}${fixture.line} splitListItem through Enter`, async ({ page }) => {
    await openDocument(page, '- foobar')
    await selectText(page, 'foobar', fixture.offset, 'foobar', fixture.end)
    await page.keyboard.press('Enter')
    await expect(page.locator('.editor-content > ul > li')).toHaveText(fixture.expected)
    await reopen(page)
    await expect(page.locator('.editor-content > ul > li')).toHaveText(fixture.expected)
  })
}

test(`${source}91 lifts the first nested item and keeps its following sibling nested`, async ({ page }) => {
  await openDocument(page, '- hello\n  - one\n  - two')
  await caret(page.locator('.editor-content li').filter({ hasText: /^one$/ }), 0)
  await page.keyboard.press('Shift+Tab')
  await expectMarkdown(page, '- hello\n- one\n  - two')
  await expect(page.locator('.editor-content ul ul li')).toHaveText('two')
  await reopen(page)
})

test(`${source}95 lifts two selected items from a nested list`, async ({ page }) => {
  await openDocument(page, '- hello\n  - one\n  - two')
  await selectText(page, 'one', 1, 'two', 3)
  await page.keyboard.press('Shift+Tab')
  await expect(page.locator('.editor-content > ul > li')).toHaveText(['hello', 'one', 'two'])
  await reopen(page)
})

test('commonmark:325 preserves the paragraph after a nested list on Enter', async ({ page }) => {
  await openDocument(page, '* foo\n  * bar\n\n  baz')
  await expect(page.locator('.editor-content')).toHaveText('foobarbaz')
  await caret(page.locator('.editor-content p').filter({ hasText: /^baz$/ }), 2)
  await page.keyboard.press('Enter')
  await expect(page.locator('.editor-content')).toHaveText('foobarbaz')
  await expect(page.locator('.editor-content > ul > li').last()).toHaveText('z')
  await expect(page.locator('.editor-content ul ul li')).toHaveText('bar')
  await reopen(page)
  await expect(page.locator('.editor-content')).toHaveText('foobarbaz')
})

test('commonmark:325 retains trailing content when Shift+Tab lifts the nested item', async ({ page }) => {
  await openDocument(page, '* foo\n  * bar\n\n  baz')
  await caret(page.locator('.editor-content li').filter({ hasText: /^bar$/ }), 0)
  await page.keyboard.press('Shift+Tab')
  await expect(page.locator('.editor-content > ul > li')).toHaveText(['foo', 'bar', 'baz'])
  await reopen(page)
  await expect(page.locator('.editor-content')).toHaveText('foobarbaz')
})

test('commonmark:325 retains trailing content when Backspace turns the nested item into text', async ({ page }) => {
  await openDocument(page, '* foo\n  * bar\n\n  baz')
  await caret(page.locator('.editor-content li').filter({ hasText: /^bar$/ }), 0)
  await page.keyboard.press('Backspace')
  await expectMarkdown(page, '- foo\n\n  bar\n\n  baz')
  await reopen(page)
  await expect(page.locator('.editor-content')).toHaveText('foobarbaz')
})

test('commonmark:325 Tab keeps a first nested item; a selection replaces across the trailing paragraph', async ({
  page
}) => {
  await openDocument(page, '* foo\n  * bar\n\n  baz')
  await caret(page.locator('.editor-content li').filter({ hasText: /^bar$/ }), 0)
  await page.keyboard.press('Tab')
  await expect(page.locator('.editor-content ul ul li')).toHaveText('bar')
  await expect(page.locator('.editor-content ul ul ul')).toHaveCount(0)
  await expect(page.locator('.editor-content')).toHaveText('foobarbaz')
  await selectText(page, 'bar', 1, 'baz', 2)
  await page.keyboard.insertText('X')
  await expect(page.locator('.editor-content')).toHaveText('foobXz')
  await reopen(page)
  await expect(page.locator('.editor-content')).toHaveText('foobXz')
})

test('mixed task and plain list items keep their checkbox roles through editing', async ({ page }) => {
  await openDocument(page, '- plain\n- [ ] task\n- after')
  await expect(page.locator('.editor-content li[role=checkbox]')).toHaveText('task')
  await caret(page.locator('.editor-content li').filter({ hasText: /^task$/ }))
  await page.keyboard.press('Enter')
  await page.keyboard.type('new task')
  await expect(page.locator('.editor-content li[role=checkbox]')).toHaveText(['task', 'new task'])
  await reopen(page)
  await expect(page.locator('.editor-content li:not([role=checkbox])')).toHaveText(['plain', 'after'])
})

test('nested mixed lists remain editable through Enter, lifting and reopening', async ({ page }) => {
  await openDocument(page, '- parent\n  - plain\n  - [ ] task\n  - after')
  await expect(page.locator('.read-only-block')).toHaveCount(0)
  await caret(page.locator('.editor-content li[role=checkbox]'))
  await page.keyboard.press('Enter')
  await page.keyboard.type('new task')
  await expect(page.locator('.editor-content li[role=checkbox]')).toHaveText(['task', 'new task'])
  await reopen(page)
  await caret(page.locator('.editor-content li[role=checkbox]').last(), 0)
  await page.keyboard.press('Shift+Tab')
  const lifted = '- parent\n  - plain\n  - [ ] task\n- [ ] new task\n  - after'
  await expectMarkdown(page, lifted)
  await expect(page.locator('.editor-content')).toContainText('after')
  await reopen(page)
  await expectMarkdown(page, lifted)
  await expect(page.locator('.read-only-block')).toHaveCount(0)
})

test('Backspace at an inline format boundary does not lift a following list paragraph', async ({ page }) => {
  await openDocument(page, '* foo\n  * ba**r**\n\n  baz')
  await caret(page.locator('.editor-content strong'), 0)
  await page.keyboard.press('Backspace')
  await expect(page.locator('.editor-content ul ul li')).toHaveText('br')
  await expectMarkdown(page, '- foo\n\n  - b**r**\n\n  baz')
  await reopen(page)
})
