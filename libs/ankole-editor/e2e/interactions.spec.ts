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
  await expect(page.locator('.editor-content mark')).toHaveCSS('background-color', 'rgb(255, 252, 164)')
  expect(await page.evaluate(() => window.getSelection()!.toString())).toBe('selected')
  await reopen(page)
  for (const format of ['strong', 'u', 'mark']) {
    await expect(page.locator(`.editor-content ${format}`)).toHaveText('selected')
  }
  await expect(page.locator('.editor-content mark')).toHaveCSS('background-color', 'rgb(255, 252, 164)')
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
  await expect(toolbar.getByRole('button', { name: '转换 Block 类型', exact: true })).toBeFocused()
  await page.keyboard.press('ArrowRight')
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

test('the block menu inserts after the hovered block rather than the old caret', async ({ page }) => {
  await openDocument(page, 'First\n\nSecond\n\nThird')
  await caret(page.locator('.editor-content > p').last())
  await page.locator('.editor-content > p').first().hover()
  await page.locator('.drag-handle').getByRole('button', { name: '当前 Block 菜单', exact: true }).click()
  await page.getByRole('menuitem', { name: '在下方添加 Block', exact: true }).click()
  const item = page.getByRole('menuitem', { name: /二级标题/ })
  await item.hover()
  await page.evaluate(
    () => new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve())))
  )
  const typeTrigger = page.locator('.drag-handle').getByRole('button', { name: '当前 Block 菜单', exact: true })
  await expect(typeTrigger).toBeVisible()
  const anchor = (await typeTrigger.boundingBox())!
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
  await page
    .getByRole('toolbar', { name: '编辑器工具栏', exact: true })
    .getByRole('button', { name: '当前 Block 菜单', exact: true })
    .click()
  await page.getByRole('menuitem', { name: '下移', exact: true }).click()
  await expect(paragraphs).toHaveText(['First', 'Second', 'First', 'Third'])
  await expect(page.getByRole('menu')).toHaveCount(0)
  await page.keyboard.press('ControlOrMeta+/')
  await page.getByRole('menuitem', { name: '删除 Block', exact: true }).click()
  await expect(paragraphs).toHaveText(['First', 'Second', 'Third'])
  await page.getByRole('button', { name: '撤销', exact: true }).click()
  await expect(paragraphs).toHaveText(['First', 'Second', 'First', 'Third'])
})

test.describe('touch block handles', () => {
  test.use({ hasTouch: true, isMobile: true, viewport: { width: 820, height: 1180 } })
  test.skip(({ browserName }) => browserName === 'firefox', 'Playwright Firefox does not support touch emulation')

  test('a touch tap exposes the tapped Block menu without moving its native caret', async ({ page }) => {
    await openDocument(page, 'First\n\nSecond\n\nThird')
    const paragraphs = page.locator('.editor-content > p')
    await caret(paragraphs.last())
    const expectedCaret = await paragraphs.first().evaluate(element => {
      const box = element.getBoundingClientRect()
      const range = document.caretRangeFromPoint(box.x + 12, box.y + 10)!
      return {
        anchor: range.startContainer.textContent,
        anchorOffset: range.startOffset,
        focus: range.startContainer.textContent,
        focusOffset: range.startOffset
      }
    })
    await paragraphs.first().tap({ position: { x: 12, y: 10 } })
    const selection = () =>
      page.evaluate(() => {
        const selection = window.getSelection()!
        return {
          anchor: selection.anchorNode?.textContent,
          anchorOffset: selection.anchorOffset,
          focus: selection.focusNode?.textContent,
          focusOffset: selection.focusOffset
        }
      })
    expect(expectedCaret.anchor).toBe('First')
    const handle = page.getByRole('button', { name: 'Block 菜单', exact: true })
    await expect(handle).toBeVisible()
    // WebKit finishes native touch placement after the tap's focus event.
    await expect.poll(selection).toEqual(expectedCaret)
    await handle.tap()
    await page.getByRole('menuitem', { name: /创建副本/ }).tap()
    await expect(paragraphs).toHaveText(['First', 'First', 'Second', 'Third'])
    await page.keyboard.press('ControlOrMeta+z')
    await expect(paragraphs).toHaveText(['First', 'Second', 'Third'])
  })
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
  await page.getByRole('menuitem', { name: /高亮块/ }).click()
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
  await caret(page.locator('.callout-content > p'))
  await page.keyboard.press('ControlOrMeta+/')
  await page.getByRole('menuitem', { name: /创建副本/ }).click()
  await expect(page.locator('.callout')).toHaveCount(2)
  await expect(widgets).toHaveText(['Payload', 'Payload'])
  await reopen(page)
  await expect(page.locator('.callout ul ul li')).toHaveText(['nested', 'nested'])
  await expect(widgets).toHaveText(['Payload', 'Payload'])
})

test('an embed can be duplicated and deleted with undo, but not turned into text', async ({ page }) => {
  await openDocument(page, 'Before\n\n<embed ref="tasks" />\n\nAfter')
  const cards = page.locator('.editor-content .embed')
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
  await page.keyboard.type('/nomatch')
  const slash = page.getByRole('listbox', { name: '插入 Block' })
  await expect(slash.getByRole('status')).toHaveText('没有匹配的 Block')
  await expect(slash.getByRole('option')).toHaveCount(0)
  await page.keyboard.press('Escape')
  await expect(slash).toHaveCount(0)
  await expect(page.locator('.editor-content > p').last()).toHaveText('/nomatch')
  await page.keyboard.type('x')
  await expect(slash.getByRole('status')).toBeVisible()
  await page.keyboard.type(' ')
  await expect(slash).toHaveCount(0)
  await expect(page.locator('.editor-content > p').last()).toHaveText('/nomatchx')
})

test('slash and plus share block choices and menu width while only slash uses rich rows with raised tiles', async ({
  page
}) => {
  await openDocument(page, '')
  const paragraph = page.locator('.editor-content > p')
  await paragraph.hover()
  await page.getByRole('button', { name: '添加 Block', exact: true }).click()
  const insert = page.getByRole('menu', { name: '添加 Block', exact: true })
  const choices = insert.getByRole('menuitem')
  await expect(choices.first()).toBeVisible()
  const titles = await choices.allTextContents()
  await expect(insert).toHaveCSS('width', '264px')
  await expect(choices.first()).toHaveCSS('height', '40px')
  const plainIcon = choices.first().locator('.block-type-icon')
  await expect(plainIcon).toHaveCSS('width', '16px')
  await expect(plainIcon).toHaveCSS('background-image', 'none')
  await expect(plainIcon).toHaveCSS('box-shadow', 'none')
  await page.keyboard.press('Escape')
  await page.keyboard.type('/')
  const slash = page.getByRole('listbox', { name: '插入 Block', exact: true })
  const options = slash.getByRole('option')
  await expect(options).toHaveText(titles.map(title => title.trim()))
  await expect(slash).toHaveCSS('width', '264px')
  await expect(slash).toHaveCSS('border-top-left-radius', '4px')
  await expect(slash).toHaveCSS('padding-top', '8px')
  await expect(slash.getByRole('presentation').first()).toHaveCSS('height', '32px')
  await expect(options.first()).toHaveCSS('height', '60px')
  // The highlighted option takes the hover wash; the others stay clear while the pointer is away.
  await page.mouse.move(0, 0)
  await expect(options.first()).not.toHaveCSS('background-color', 'rgba(0, 0, 0, 0)')
  await expect(options.nth(1)).toHaveCSS('background-color', 'rgba(0, 0, 0, 0)')
  const tile = options.first().locator('.block-type-icon')
  await expect(tile).toHaveCSS('width', '44px')
  await expect(tile).not.toHaveCSS('background-image', 'none')
  await expect(tile).not.toHaveCSS('box-shadow', 'none')
  await page.keyboard.type('h2')
  await page.keyboard.press('Tab')
  await page.keyboard.type('Heading')
  await expect(page.locator('.editor-content > h2')).toHaveText('Heading')
  await expect(page.locator('.editor-content > *')).toHaveCount(1)
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

test('a saved slash query remounts without opening a menu until the editor receives focus', async ({ page }) => {
  await openDocument(page, '/h3')
  await reopen(page)
  const editor = page.getByRole('textbox', { name: '文档编辑器', exact: true })
  const menu = page.getByRole('listbox', { name: '插入 Block', exact: true })
  await expect(editor).toHaveText('/h3')
  await expect(menu).toBeHidden()
  await caret(editor.locator('p'))
  await expect(menu).toBeVisible()
  await expect(page.getByRole('option')).toHaveCount(1)
  await showSource(page)
  await expect(menu).toBeHidden()
  await expect(editor).toHaveText('/h3')
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

test('the selection toolbar turns the selected blocks into another type in one step', async ({ page }) => {
  await openDocument(page, 'First\n\nSecond')
  await selectText(page, 'First', 1, 'Second', 3)
  const toolbar = page.getByRole('toolbar', { name: '选区格式' })
  const type = toolbar.getByRole('button', { name: '转换 Block 类型', exact: true })
  await expect(type).toHaveText('正文')
  await type.click()
  await page.getByRole('menuitem', { name: /二级标题/ }).click()
  await expect(page.locator('.editor-content h2')).toHaveText(['First', 'Second'])
  await expect(toolbar).toBeVisible()
  await expect(type).toHaveText('二级标题')
  expect(await page.evaluate(() => window.getSelection()!.toString())).toContain('Sec')
  await page.getByRole('button', { name: '撤销', exact: true }).click()
  await expect(page.locator('.editor-content h2')).toHaveCount(0)
})

test('clicking elsewhere collapses the previous DOM selection after an empty compositionstart or unfocused click', async ({
  page
}) => {
  const paragraph =
    '多人在群里交替发言，导致上下文缓存不断失效； Agent 为了对齐信息反复重读，更危险的是权限泄露。如果群机器人绑定了店铺的高权限接口，随便哪位成员问一句采购金额时就可能把保密的供应商底价带出来。'
  await openDocument(page, paragraph)
  const content = page.locator('.editor-content')

  const points = await content.evaluate(element => {
    const textNode = element.querySelector('p')!.firstChild as Text
    const text = textNode.data
    const start = text.indexOf('发言，导致上下文缓')
    const end = start + '发言，导致上下文缓'.length
    const target = text.indexOf('店铺') + 2
    const rectAt = (from: number, to: number) => {
      const range = document.createRange()
      range.setStart(textNode, from)
      range.setEnd(textNode, to)
      return range.getBoundingClientRect()
    }
    const rStart = rectAt(start, start + 1)
    const rEnd = rectAt(end - 1, end)
    const rTarget = rectAt(target, target + 1)
    return {
      dragStart: { x: rStart.left + 1, y: (rStart.top + rStart.bottom) / 2 },
      dragEnd: { x: rEnd.right - 1, y: (rEnd.top + rEnd.bottom) / 2 },
      clickTarget: { x: rTarget.left + 1, y: (rTarget.top + rTarget.bottom) / 2 }
    }
  })

  // 1. Orphaned empty compositionstart before refocusing elsewhere by pointer click
  await page.mouse.move(points.dragStart.x, points.dragStart.y)
  await page.mouse.down()
  await page.mouse.move(points.dragEnd.x, points.dragEnd.y, { steps: 5 })
  await page.mouse.up()
  await expect.poll(() => page.evaluate(() => window.getSelection()!.toString())).toBe('发言，导致上下文缓')

  await content.evaluate(el => {
    el.dispatchEvent(new CompositionEvent('compositionstart', { data: '', bubbles: true }))
  })
  await page.mouse.click(points.clickTarget.x, points.clickTarget.y)
  await expect.poll(() => page.evaluate(() => window.getSelection()!.isCollapsed)).toBe(true)
  await expect(page.locator('wg-cursor')).toBeVisible()

  // 2. Clicking into the editor while document focus arrives asynchronously after mousedown's frame
  await page.mouse.move(points.dragStart.x, points.dragStart.y)
  await page.mouse.down()
  await page.mouse.move(points.dragEnd.x, points.dragEnd.y, { steps: 5 })
  await page.mouse.up()
  await expect.poll(() => page.evaluate(() => window.getSelection()!.toString())).toBe('发言，导致上下文缓')

  await page.evaluate(() => {
    Object.defineProperty(document, 'hasFocus', { configurable: true, value: () => false })
    window.dispatchEvent(new Event('blur'))
  })
  await page.waitForTimeout(30)
  await page.mouse.move(points.clickTarget.x, points.clickTarget.y)
  await page.mouse.down()
  await page.waitForTimeout(30)
  await page.evaluate(() => {
    delete (document as { hasFocus?: () => boolean }).hasFocus
    window.dispatchEvent(new Event('focus'))
  })
  await page.mouse.up()
  await expect.poll(() => page.evaluate(() => window.getSelection()!.isCollapsed)).toBe(true)
  await expect(page.locator('wg-cursor')).toBeVisible()
})

test('narrow editor surfaces the bottom-right / trigger and morphs the slash menu without leaving stray / text', async ({
  page
}) => {
  await openDocument(page, 'Compact note')
  const trigger = page.locator('[data-slash-corner-trigger]')
  await expect(trigger).toHaveCount(0)

  await page.setViewportSize({ width: 520, height: 640 })
  await expect(trigger).toBeVisible()
  await expect(trigger).toHaveCSS('width', '36px')
  await expect(trigger).toHaveCSS('height', '36px')

  await caret(page.locator('.editor-content > p'), 'end')
  await page.keyboard.press('Enter')
  await trigger.click()

  const slash = page.getByRole('listbox', { name: '插入 Block', exact: true })
  await expect(slash).toBeVisible()
  await expect(slash).toHaveAttribute('data-compact', '')
  await expect.poll(() => slash.getAttribute('data-morph')).toBe('open')
  await expect(page.locator('.editor-content > p').nth(1)).toHaveText('')

  // Dismissing with Escape morphs closed without leaving a literal `/` in the paragraph.
  await page.keyboard.press('Escape')
  await expect(slash).toHaveCount(0)
  await expect(page.locator('.editor-content > p').nth(1)).toHaveText('')

  // Re-opening from the corner button filters as the user types and applies the chosen block cleanly.
  await trigger.click()
  await expect(slash).toBeVisible()
  await page.keyboard.type('h2')
  await expect(slash.getByRole('option')).toHaveCount(1)
  await page.keyboard.press('Enter')
  await page.keyboard.type('Compact Section')
  await expect(page.locator('.editor-content > h2')).toHaveText('Compact Section')
  await expect(slash).toHaveCount(0)
})
