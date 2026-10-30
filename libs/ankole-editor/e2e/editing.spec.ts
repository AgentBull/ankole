import { caret, expect, openDocument, reopen, selectDocument, showSource, test } from './helpers'

for (const afterDraw of [false, true]) {
  test(`typing after moving and formatting the caret keeps its position and marks (${afterDraw ? 'drawn' : 'pending'})`, async ({
    page
  }) => {
    await openDocument(page, 'Editable text')
    const editor = page.locator('.editor-content')
    await editor.click()
    await page.keyboard.press('ControlOrMeta+End')
    await page.keyboard.press('ControlOrMeta+b')
    if (afterDraw) {
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
    }
    await page.keyboard.insertText('Bold review')
    await expect(editor).toHaveText('Editable textBold review')
    await expect(editor.locator('strong')).toHaveText('Bold review')
    await reopen(page)
    await expect(editor.locator('strong')).toHaveText('Bold review')
  })
}

test('keyboard formatting survives Markdown and a full editor remount', async ({ page }) => {
  await openDocument(page, 'Keep this')
  await selectDocument(page)
  await page.keyboard.press('ControlOrMeta+b')
  await page.keyboard.press('ControlOrMeta+u')
  // Text that is both bold and underlined, in either nesting order.
  const formatted = page.locator('.editor-content :is(strong u, u strong)')
  await expect(formatted).toHaveText('Keep this')
  await reopen(page)
  await expect(formatted).toHaveText('Keep this')
})

test('Enter at a heading end creates a paragraph; Backspace merges it', async ({ page }) => {
  await openDocument(page, '## Title')
  await caret(page.locator('.editor-content h2'))
  await page.keyboard.press('Enter')
  await page.keyboard.type('Body')
  await expect(page.locator('.editor-content > p')).toHaveText('Body')
  await caret(page.locator('.editor-content > p'), 0)
  await page.keyboard.press('Backspace')
  await expect(page.locator('.editor-content h2')).toHaveText('TitleBody')
  await reopen(page)
  await expect(page.locator('.editor-content h2')).toHaveText('TitleBody')
})

test('Tab and Shift+Tab nest and lift a list item without changing its text', async ({ page }) => {
  await openDocument(page, '- first\n- second\n- third')
  await caret(page.locator('.editor-content li').filter({ hasText: /^second$/ }), 0)
  await page.keyboard.press('Tab')
  await expect(page.locator('.editor-content ul ul li')).toHaveText('second')
  await page.keyboard.press('Shift+Tab')
  await expect(page.locator('.editor-content > ul > li')).toHaveText(['first', 'second', 'third'])
  await page.keyboard.press('Shift+Tab')
  await expect(page.locator('.editor-content')).toBeFocused()
  await caret(page.locator('.editor-content li').filter({ hasText: /^first$/ }), 0)
  await page.keyboard.press('Tab')
  await expect(page.locator('.editor-content')).toBeFocused()
  await reopen(page)
  await expect(page.locator('.editor-content > ul > li')).toHaveText(['first', 'second', 'third'])
})

test('Shift+Enter and Unicode survive editing and reopening', async ({ page }) => {
  await openDocument(page, '中文 👩‍💻')
  await caret(page.locator('.editor-content > p'))
  await page.keyboard.press('Shift+Enter')
  await page.keyboard.insertText('العربية é')
  await expect(page.locator('.editor-content > p')).toHaveText('中文 👩‍💻العربية é')
  await reopen(page)
  await expect(page.locator('.editor-content > p')).toHaveText('中文 👩‍💻العربية é')
  await expect(page.locator('.editor-content > p br')).toHaveCount(1)
})

test('slash inserts an editable callout that reopens with its body', async ({ page }) => {
  await openDocument(page, 'Start')
  await caret(page.locator('.editor-content > p'))
  await page.keyboard.press('Enter')
  await page.keyboard.type('/callout')
  await page.getByRole('option', { name: /提示块/ }).click()
  const body = page.locator('.callout p')
  await expect(body).toBeEmpty()
  await page.keyboard.insertText(' 保留内容')
  await expect(body).toContainText('保留内容')
  await reopen(page)
  await expect(page.locator('.callout p')).toContainText('保留内容')
})

const withReference = 'Before\n\n<embed ref="tasks" />\n\nAfter'

test('select all, delete, undo and redo include an embed', async ({ page }) => {
  await openDocument(page, withReference)
  const card = page.locator('.editor-content .embed')
  await selectDocument(page)
  await page.keyboard.press('Backspace')
  await expect(card).toHaveCount(0)
  await page.getByRole('button', { name: '撤销', exact: true }).click()
  await expect(card.locator('code')).toHaveText('tasks')
  await expect(page.locator('.editor-content > p')).toHaveText(['Before', 'After'])
  await page.getByRole('button', { name: '重做', exact: true }).click()
  await expect(card).toHaveCount(0)
  await page.getByRole('button', { name: '撤销', exact: true }).click()
  await reopen(page)
  await expect(card.locator('code')).toHaveText('tasks')
})

test('Backspace and Delete beside an embed join the text around it and keep it', async ({ page }) => {
  const card = page.locator('.editor-content .embed')
  for (const [key, at] of [
    ['Backspace', 'last'],
    ['Delete', 'first']
  ] as const) {
    await openDocument(page, withReference)
    const paragraph = page.locator('.editor-content > p')[at]()
    await caret(paragraph, key === 'Backspace' ? 0 : 'end')
    await page.keyboard.press(key)
    await expect(page.locator('.editor-content > p')).toHaveText(['BeforeAfter'])
    await expect(card.locator('code')).toHaveText('tasks')
    await reopen(page)
    await expect(card.locator('code')).toHaveText('tasks')
  }
})

test('source drafts lock editing, can be discarded, and applied source can be undone', async ({ page }) => {
  await openDocument(page, '**Original**')
  const source = await showSource(page)
  await source.fill('## Replacement')
  const editor = page.locator('.editor-content')
  await expect(editor).toHaveAttribute('contenteditable', 'false')
  expect(await editor.ariaSnapshot()).toContain('Original')
  await editor.locator('strong').dblclick()
  expect(await page.evaluate(() => window.getSelection()!.toString())).toBe('Original')
  await page.keyboard.press('Delete')
  await expect(editor.locator('strong')).toHaveText('Original')
  await expect(source).toHaveValue('## Replacement')
  await expect(page.getByRole('button', { name: '关闭 Markdown', exact: true })).toBeDisabled()
  await page.getByRole('button', { name: '放弃修改', exact: true }).click()
  await expect(source).toHaveValue(/Original/)
  await source.fill('## Replacement')
  await page.getByRole('button', { name: '应用修改', exact: true }).click()
  await expect(page.locator('.editor-content h2')).toHaveText('Replacement')
  await page.getByRole('button', { name: '撤销', exact: true }).click()
  await expect(page.locator('.editor-content strong')).toHaveText('Original')
})

test('a checklist toggle and Enter on an empty list item survive reopening', async ({ page }) => {
  await openDocument(page, '- [ ] first\n- [x] second')
  const first = page.locator('.editor-content li').first()
  await first.click({ position: { x: 2, y: 10 } })
  await expect(first).toHaveAttribute('aria-checked', 'true')
  await caret(page.locator('.editor-content li').last())
  await page.keyboard.press('Enter')
  await page.keyboard.press('Enter')
  await page.keyboard.type('Outside')
  await expect(page.locator('.editor-content > p')).toHaveText('Outside')
  await reopen(page)
  await expect(page.locator('.editor-content li').first()).toHaveAttribute('aria-checked', 'true')
  await expect(page.locator('.editor-content > p')).toHaveText('Outside')
})

test('table Tab moves to the next cell and edits retain column alignment', async ({ page }) => {
  await openDocument(page, '| Name | Value |\n| :--- | ---: |\n| Alpha | 42 |')
  await caret(page.locator('.editor-content td').first())
  await page.keyboard.press('Tab')
  await page.keyboard.insertText('7')
  await expect(page.locator('.editor-content td').last()).toHaveText('427')
  await reopen(page)
  await expect(page.locator('.editor-content td').last()).toHaveText('427')
  const source = await showSource(page)
  expect(await source.inputValue()).toMatch(/\|\s*:-+\s*\|\s*-+:\s*\|/)
})

test('dragging a block changes document order and can be undone', async ({ page }) => {
  await openDocument(page, 'First\n\nSecond\n\nThird')
  const paragraphs = page.locator('.editor-content > p')
  await paragraphs.first().hover()
  const handle = page.getByRole('button', { name: 'Block 菜单', exact: true })
  await expect(handle).toHaveAttribute('draggable', 'true')
  await handle.dragTo(paragraphs.last(), { targetPosition: { x: 20, y: 24 } })
  await expect(paragraphs).toHaveText(['Second', 'Third', 'First'])
  await page.getByRole('button', { name: '撤销', exact: true }).click()
  await expect(paragraphs).toHaveText(['First', 'Second', 'Third'])
})
