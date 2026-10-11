import { caret, expect, openDocument, reopen, selectText, showSource, test } from './helpers'

test('mouse selection opens formatting and toggles only the selected word', async ({ page }) => {
  await openDocument(page, 'Before selected after')
  await page.getByText('Before selected after', { exact: true }).dblclick({ position: { x: 70, y: 12 } })
  const toolbar = page.getByRole('toolbar', { name: '选区格式' })
  await expect(toolbar).toBeVisible()
  const selected = await page.evaluate(() => window.getSelection()!.toString())
  expect(selected.trim()).toBeTruthy()
  await toolbar.getByRole('button', { name: '粗体', exact: true }).click()
  await expect(page.locator('.editor-content strong')).toHaveText(selected)
  await expect(toolbar.getByRole('button', { name: '粗体', exact: true })).toHaveAttribute('aria-pressed', 'true')
  await toolbar.getByRole('button', { name: '粗体', exact: true }).click()
  await expect(page.locator('.editor-content strong')).toHaveCount(0)
  await expect(page.locator('.editor-content > p')).toHaveText('Before selected after')
})

test('backward selection retains its range through repeated formatting and Markdown', async ({ page }) => {
  await openDocument(page, 'Before selected after')
  await selectText(page, 'Before selected after', 15, 'Before selected after', 7)
  const toolbar = page.getByRole('toolbar', { name: '选区格式' })
  await toolbar.getByRole('button', { name: '粗体', exact: true }).click()
  await toolbar.getByRole('button', { name: '下划线', exact: true }).click()
  await toolbar.getByRole('button', { name: '高亮', exact: true }).click()
  for (const format of ['strong', 'u', 'mark']) {
    await expect(page.locator(`.editor-content ${format}`)).toHaveText('selected')
  }
  await expect(page.locator('.editor-content mark')).toHaveCSS('background-color', 'rgb(255, 241, 184)')
  expect(await page.evaluate(() => window.getSelection()!.toString())).toBe('selected')
  await reopen(page)
  for (const format of ['strong', 'u', 'mark']) {
    await expect(page.locator(`.editor-content ${format}`)).toHaveText('selected')
  }
  await expect(page.locator('.editor-content mark')).toHaveCSS('background-color', 'rgb(255, 241, 184)')
})

test('cross-paragraph formatting keeps unselected prefixes and suffixes', async ({ page }) => {
  await openDocument(page, 'First line\n\nSecond line')
  await selectText(page, 'First line', 6, 'Second line', 6)
  await page.getByRole('toolbar', { name: '选区格式' }).getByRole('button', { name: '斜体', exact: true }).click()
  await expect(page.locator('.editor-content em')).toHaveText(['line', 'Second'])
  await reopen(page)
  await expect(page.locator('.editor-content > p')).toHaveText(['First line', 'Second line'])
  await expect(page.locator('.editor-content em')).toHaveText(['line', 'Second'])
})

test('keyboard selection and Alt+F10 expose an operable toolbar without losing text', async ({ page }) => {
  await openDocument(page, 'Keyboard')
  await caret(page.locator('.editor-content p'), 0)
  for (let index = 0; index < 8; index++) await page.keyboard.press('Shift+ArrowRight')
  const toolbar = page.getByRole('toolbar', { name: '选区格式' })
  await expect(toolbar).toBeVisible()
  await page.keyboard.press('Alt+F10')
  await expect(toolbar.getByRole('button', { name: '粗体', exact: true })).toBeFocused()
  await page.keyboard.press('ArrowRight')
  await page.keyboard.press('Enter')
  await expect(page.locator('.editor-content em')).toHaveText('Keyboard')
  await page.keyboard.press('Escape')
  await expect(toolbar).toBeHidden()
})

test('link form preserves the range while focus is in its input; editing and removal persist', async ({ page }) => {
  await openDocument(page, 'Visit example today')
  await selectText(page, 'Visit example today', 6, 'Visit example today', 13)
  await page.keyboard.press('ControlOrMeta+k')
  await page.getByRole('textbox', { name: '链接地址', exact: true }).fill('https://example.com/path?q=1')
  await page.getByRole('button', { name: '应用链接', exact: true }).click()
  const link = page.locator('.editor-content a')
  await expect(link).toHaveText('example')
  await expect(link).toHaveAttribute('href', 'https://example.com/path?q=1')
  await caret(link, 2)
  await page.keyboard.press('ControlOrMeta+k')
  await expect(page.getByRole('textbox', { name: '链接地址', exact: true })).toHaveValue('https://example.com/path?q=1')
  await page.getByRole('textbox', { name: '链接地址', exact: true }).fill('example.org')
  await page.keyboard.press('Enter')
  await expect(link).toHaveAttribute('href', 'https://example.org')
  await reopen(page)
  await selectText(page, 'example', 0, 'example', 7)
  await page.getByRole('toolbar', { name: '选区格式' }).getByRole('button', { name: '链接', exact: true }).click()
  await page.getByRole('button', { name: '移除链接', exact: true }).click()
  await expect(link).toHaveCount(0)
  await expect(page.locator('.editor-content > p')).toHaveText('Visit example today')
  await page.getByRole('button', { name: '撤销', exact: true }).click()
  await expect(link).toHaveAttribute('href', 'https://example.org')
})

test('invalid links stay in the form; Escape cancels without changing content', async ({ page }) => {
  await openDocument(page, 'Safe text')
  await selectText(page, 'Safe text', 0, 'Safe text', 4)
  await page.keyboard.press('ControlOrMeta+k')
  await page.getByRole('textbox', { name: '链接地址', exact: true }).fill('javascript:alert(1)')
  await page.keyboard.press('Enter')
  await expect(page.getByRole('alert')).toContainText('请输入网址')
  await page.keyboard.press('Escape')
  await expect(page.getByRole('dialog', { name: '编辑链接' })).toBeHidden()
  await expect(page.locator('.editor-content a')).toHaveCount(0)
  expect(await page.evaluate(() => window.getSelection()!.toString())).toBe('Safe')
})

test('a source draft hides the selection toolbar and the block menu', async ({ page }) => {
  await openDocument(page, 'Before')
  await selectText(page, 'Before', 0, 'Before', 6)
  const toolbar = page.getByRole('toolbar', { name: '选区格式' })
  await expect(toolbar).toBeVisible()
  const source = await showSource(page)
  await source.fill('Draft')
  await expect(toolbar).toHaveCount(0)
  await expect(page.locator('.block-menu')).toHaveCount(0)
})

test('code block selection does not offer text formatting', async ({ page }) => {
  await openDocument(page, '```\nconst value = 1\n```')
  await selectText(page, 'const value = 1', 0, 'const value = 1', 5)
  await expect(page.getByRole('toolbar', { name: '选区格式' })).toHaveCount(0)
})

test('plus inserts after the hovered block rather than the old caret', async ({ page }) => {
  await openDocument(page, 'First\n\nSecond\n\nThird')
  await caret(page.locator('.editor-content > p').last())
  await page.locator('.editor-content > p').first().hover()
  await page.getByRole('button', { name: '在下方添加 Block', exact: true }).click()
  const item = page.getByRole('menuitem', { name: /二级标题/ })
  await item.hover()
  await page.evaluate(
    () => new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve())))
  )
  await expect(page.getByRole('button', { name: '在下方添加 Block', exact: true })).toBeVisible()
  const anchor = (await page.getByRole('button', { name: '在下方添加 Block', exact: true }).boundingBox())!
  const menu = (await item.boundingBox())!
  expect(menu.x).toBeGreaterThanOrEqual(anchor.x)
  expect(menu.x).toBeLessThanOrEqual(anchor.x + anchor.width)
  await item.click()
  await page.keyboard.type('Inserted')
  await expect(page.locator('.editor-content > *')).toHaveText(['First', 'Inserted', 'Second', 'Third'])
  await expect(page.locator('.editor-content h2')).toHaveText('Inserted')
})

test('Block menu duplicates, moves and deletes the hovered block with undo', async ({ page }) => {
  await openDocument(page, 'First\n\nSecond\n\nThird')
  const paragraphs = page.locator('.editor-content > p')
  await caret(paragraphs.last())
  await paragraphs.first().hover()
  await page.getByRole('button', { name: 'Block 菜单', exact: true }).click()
  await page.getByRole('menuitem', { name: /创建副本/ }).click()
  await expect(paragraphs).toHaveText(['First', 'First', 'Second', 'Third'])
  // A menu closes after its action. Wait for the closing animation before opening the next menu.
  await expect(page.getByRole('menu')).toHaveCount(0)
  await page.getByRole('button', { name: '当前 Block 菜单', exact: true }).click()
  await page.getByRole('menuitem', { name: '下移', exact: true }).click()
  await expect(paragraphs).toHaveText(['First', 'Second', 'First', 'Third'])
  await expect(page.getByRole('menu')).toHaveCount(0)
  await page.keyboard.press('ControlOrMeta+/')
  await page.getByRole('menuitem', { name: '删除 Block', exact: true }).click()
  await expect(paragraphs).toHaveText(['First', 'Second', 'Third'])
  await page.getByRole('button', { name: '撤销', exact: true }).click()
  await expect(paragraphs).toHaveText(['First', 'Second', 'First', 'Third'])
})

test('turn into preserves marked text; converting to a callout keeps the cursor inside it', async ({ page }) => {
  await openDocument(page, 'Before **marked** after')
  await caret(page.locator('.editor-content p'))
  await page.keyboard.press('ControlOrMeta+/')
  await page.getByRole('menuitem', { name: '转换为', exact: true }).hover()
  await page.getByRole('menuitem', { name: /二级标题/ }).click()
  await expect(page.locator('.editor-content h2 strong')).toHaveText('marked')
  await page.keyboard.press('ControlOrMeta+/')
  await page.getByRole('menuitem', { name: '转换为', exact: true }).hover()
  await page.getByRole('menuitem', { name: /提示块/ }).click()
  await page.keyboard.insertText('!')
  await expect(page.locator('.callout p')).toHaveText('Before marked after!')
  await reopen(page)
  await expect(page.locator('.callout strong')).toHaveText('marked')
})

test('a Block menu copy keeps nested callout blocks and unknown elements', async ({ page }) => {
  await openDocument(
    page,
    '<callout tone="warning">\n  Before\n\n  - one\n    - nested\n\n  <widget key="value">\n    Payload\n  </widget>\n</callout>'
  )
  const widgets = page.locator('.editor-content .unknown-element[data-name="widget"]')
  await caret(page.locator('.callout > p'))
  await page.keyboard.press('ControlOrMeta+/')
  await page.getByRole('menuitem', { name: /创建副本/ }).click()
  await expect(page.locator('.callout')).toHaveCount(2)
  await expect(widgets).toHaveText(['Payload', 'Payload'])
  await reopen(page)
  await expect(page.locator('.callout ul ul li')).toHaveText(['nested', 'nested'])
  await expect(widgets).toHaveText(['Payload', 'Payload'])
})

test('a database reference can be duplicated and deleted with undo, but not turned into text', async ({ page }) => {
  await openDocument(page, 'Before\n\n<database ref="tasks" />\n\nAfter')
  const cards = page.locator('.editor-content .database-reference')
  await cards.hover()
  await page.getByRole('button', { name: 'Block 菜单', exact: true }).click()
  await expect(page.getByRole('menuitem', { name: '转换为', exact: true })).toHaveAttribute('aria-disabled', 'true')
  await page.getByRole('menuitem', { name: /创建副本/ }).click()
  await expect(cards.locator('code')).toHaveText(['tasks', 'tasks'])
  await reopen(page)
  await expect(cards).toHaveCount(2)
  await cards.last().hover()
  await page.getByRole('button', { name: 'Block 菜单', exact: true }).click()
  await page.getByRole('menuitem', { name: '删除 Block', exact: true }).click()
  await expect(cards).toHaveCount(1)
  await page.getByRole('button', { name: '撤销', exact: true }).click()
  await expect(cards).toHaveCount(2)
  await expect(page.locator('.editor-content > p')).toHaveText(['Before', 'After'])
})

test('deleting the only block leaves a writable paragraph', async ({ page }) => {
  await openDocument(page, 'Only')
  await caret(page.locator('.editor-content p'))
  await page.keyboard.press('ControlOrMeta+/')
  await page.getByRole('menuitem', { name: '删除 Block', exact: true }).click()
  await page.keyboard.type('Fresh')
  await expect(page.locator('.editor-content > p')).toHaveText('Fresh')
})

test('slash menu filters heading levels and supports keyboard select and Escape', async ({ page }) => {
  await openDocument(page, 'Start')
  await caret(page.locator('.editor-content p'))
  await page.keyboard.press('Enter')
  await page.keyboard.type('/h3')
  await expect(page.getByRole('option')).toHaveCount(1)
  await page.keyboard.press('Enter')
  await page.keyboard.type('Title')
  await expect(page.locator('.editor-content h3')).toHaveText('Title')
  await page.keyboard.press('Enter')
  await page.keyboard.type('/number')
  await page.keyboard.press('Enter')
  await page.keyboard.type('Step')
  await expect(page.locator('.editor-content ol li')).toHaveText('Step')
  await page.keyboard.press('Enter')
  await page.keyboard.press('Enter')
  await page.keyboard.type('/no-match')
  await expect(page.getByRole('listbox', { name: '插入 Block' })).toHaveCount(0)
  await page.keyboard.press('Escape')
  await expect(page.locator('.editor-content > p').last()).toHaveText('/no-match')
})

test('slash in a code block is text and opens no menu', async ({ page }) => {
  await openDocument(page, '```\nconst a = 1\n```')
  await caret(page.locator('.editor-content pre'), 'end')
  await page.keyboard.type(' /h3')
  await expect(page.getByRole('listbox', { name: '插入 Block' })).toHaveCount(0)
  await page.keyboard.press('Enter')
  await expect(page.locator('.editor-content h3')).toHaveCount(0)
  await expect(page.locator('.editor-content pre')).toContainText('const a = 1 /h3')
})

test('insert menu supports keyboard cancellation without changing text or the caret', async ({ page }) => {
  await openDocument(page, 'Alpha')
  await caret(page.locator('.editor-content p'), 2)
  await page.getByRole('button', { name: '插入', exact: true }).click()
  await page.keyboard.press('ArrowDown')
  await page.keyboard.press('Escape')
  await page.keyboard.type('X')
  await expect(page.locator('.editor-content p')).toHaveText('AlXpha')
})

test('floating toolbar stays inside a narrow viewport and disappears when selection collapses', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 700 })
  await openDocument(page, '短句用于移动端工具栏')
  await selectText(page, '短句用于移动端工具栏', 0, '短句用于移动端工具栏', 2)
  const toolbar = page.getByRole('toolbar', { name: '选区格式' })
  await expect(toolbar).toBeVisible()
  const box = await toolbar.boundingBox()
  expect(box!.x).toBeGreaterThanOrEqual(0)
  expect(box!.x + box!.width).toBeLessThanOrEqual(390)
  await page.keyboard.press('ArrowRight')
  await expect(toolbar).toBeHidden()
})

test('code conversion keeps literal text and line breaks and can be reversed through undo', async ({ page }) => {
  await openDocument(page, '**Marked** [link](https://example.com)  \nNext line')
  await caret(page.locator('.editor-content p'))
  await page.keyboard.press('ControlOrMeta+/')
  await page.getByRole('menuitem', { name: '转换为', exact: true }).hover()
  await page.getByRole('menuitem', { name: /代码块/ }).click()
  await expect(page.locator('.editor-content pre')).toHaveText('Marked link\nNext line', { useInnerText: true })
  await expect(page.locator('.editor-content pre :is(strong, a)')).toHaveCount(0)
  await page.getByRole('button', { name: '撤销', exact: true }).click()
  await expect(page.locator('.editor-content strong')).toHaveText('Marked')
  await expect(page.locator('.editor-content a')).toHaveAttribute('href', 'https://example.com')
  await page.getByRole('button', { name: '重做', exact: true }).click()
  await reopen(page)
  await expect(page.locator('.editor-content pre')).toHaveText('Marked link\nNext line', { useInnerText: true })
})

test('toolbar follows scroll and hides when the selection leaves the editing viewport', async ({ page }) => {
  await openDocument(
    page,
    ['Select me', ...Array.from({ length: 50 }, (_, index) => `Paragraph ${index}`)].join('\n\n')
  )
  await selectText(page, 'Select me', 0, 'Select me', 6)
  const toolbar = page.getByRole('toolbar', { name: '选区格式' })
  await expect(toolbar).toBeVisible()
  await page.locator('.editor-pane').evaluate(element => {
    element.scrollTop = 800
  })
  await expect(toolbar).toBeHidden()
  await page.locator('.editor-pane').evaluate(element => {
    element.scrollTop = 0
  })
  await expect(toolbar).toBeVisible()
})

test('IME confirmation keys do not submit or close the link form', async ({ page }) => {
  await openDocument(page, 'Link text')
  await selectText(page, 'Link text', 0, 'Link text', 4)
  await page.keyboard.press('ControlOrMeta+k')
  const input = page.getByRole('textbox', { name: '链接地址', exact: true })
  await input.fill('https://example.com')
  for (const key of ['Enter', 'Escape']) {
    await input.dispatchEvent('keydown', { key, isComposing: true, bubbles: true, cancelable: true })
    await input.dispatchEvent('keydown', { key, keyCode: 229, bubbles: true, cancelable: true })
    await expect(input).toBeFocused()
    await expect(page.locator('.editor-content a')).toHaveCount(0)
  }
  await input.press('Enter')
  await expect(page.locator('.editor-content a')).toHaveText('Link')
})

test('rapid slash confirmation removes the complete query on every insertion', async ({ page }) => {
  await openDocument(page, 'Start')
  await caret(page.locator('.editor-content p'))
  for (let index = 0; index < 8; index++) {
    await page.keyboard.press('Enter')
    await page.keyboard.type('/h2')
    await page.keyboard.press('Enter')
    await page.keyboard.type(`Heading ${index}`)
    await expect(page.locator('.editor-content h2').last()).toHaveText(`Heading ${index}`)
  }
  await reopen(page)
  await expect(page.locator('.editor-content h2')).toHaveText(
    Array.from({ length: 8 }, (_, index) => `Heading ${index}`)
  )
})
