import { test, expect, openDocument, caret, reopen, clipboard } from './helpers'

const source =
  '| 项目 | 负责人 | 状态 |\n| --- | :---: | --- |\n| 需求评审 | 林 | 完成 |\n| 交互设计 | 陈 | 进行中 |\n| 用户测试 | 周 | 待开始 |\n\n表格之后的正文'

test('selected rows delete together and inserting a row restores typing focus', async ({ page }) => {
  await openDocument(page, source)
  const editor = page.locator('.editor-content')
  await caret(editor.getByText('林', { exact: true }))
  await page.keyboard.press('Escape')
  await page.keyboard.press('Shift+ArrowDown')
  await expect(editor.locator('.wg-selected-cell')).toHaveCount(2)
  await page.getByRole('button', { name: '行', exact: true }).click()
  await page.getByRole('menuitem', { name: '删除行', exact: true }).click()
  await expect(editor.locator('tr')).toHaveCount(2)
  await expect(editor).not.toContainText('需求评审')
  await expect(editor).not.toContainText('交互设计')
  await page.getByRole('button', { name: '行', exact: true }).click()
  await page.getByRole('menuitem', { name: '在下方插入行', exact: true }).click()
  await expect(editor).toBeFocused()
  await page.keyboard.type('New row')
  await expect(editor.locator('tr').last()).toContainText('New row')
  await reopen(page)
  await expect(editor.locator('tr').last()).toContainText('New row')
})

test('merged table remains editable and selected cells merge and split', async ({ page }) => {
  await openDocument(page, source)
  const editor = page.locator('.editor-content')
  await caret(editor.getByText('林', { exact: true }))
  await page.keyboard.press('Escape')
  await page.keyboard.press('Shift+ArrowRight')
  await page.getByRole('button', { name: '单元格', exact: true }).click()
  await page.getByRole('menuitem', { name: '合并单元格', exact: true }).click()
  await expect(editor.locator('td[colspan="2"]')).toContainText('林')
  await expect(editor.locator('td[colspan="2"]')).toContainText('完成')
  await page.getByRole('button', { name: '单元格', exact: true }).click()
  await page.getByRole('menuitem', { name: '拆分单元格', exact: true }).click()
  await expect(editor.locator('[colspan]')).toHaveCount(0)
  await expect(editor.locator('tr').nth(1).locator('td')).toHaveCount(3)
  await reopen(page)
})

test('single cell clipboard pastes its content into the paragraph', async ({ page }) => {
  await openDocument(page, source)
  const editor = page.locator('.editor-content')
  await caret(editor.getByText('周', { exact: true }))
  await page.keyboard.press('Escape')
  const copied = await clipboard(editor, 'copy')
  await caret(editor.getByText('表格之后的正文', { exact: true }))
  await page.keyboard.press('Enter')
  await clipboard(editor, 'paste', copied)
  await expect(editor.locator('table')).toHaveCount(1)
  await expect(editor.locator(':scope > p').last()).toHaveText('周')
})

test('column handle shows alignment and applies a persistent background color', async ({ page }) => {
  await openDocument(page, source)
  const editor = page.locator('.editor-content')
  await caret(editor.getByText('陈', { exact: true }))
  await page.getByRole('button', { name: '列 2', exact: true }).click()
  await expect(page.getByRole('menuitemcheckbox', { name: '居中对齐', exact: true })).toHaveAttribute(
    'aria-checked',
    'true'
  )
  await page.getByRole('menuitem', { name: '背景色', exact: true }).hover()
  await page.getByRole('menuitemcheckbox', { name: '蓝色背景', exact: true }).click()
  await expect(editor.locator('[data-cell-background="#deedfc"]')).toHaveCount(4)
  await reopen(page)
  await expect(editor.locator('[data-cell-background="#deedfc"]')).toHaveCount(4)
  await caret(editor.getByText('陈', { exact: true }))
  await page.getByRole('button', { name: '列 2', exact: true }).click()
  await page.screenshot({ path: test.info().outputPath('table-menu.png') })
})

test('column resizing commits once, persists, and can be undone', async ({ page }) => {
  await openDocument(page, source)
  const editor = page.locator('.editor-content')
  await caret(editor.getByText('陈', { exact: true }))
  const handle = page.getByRole('separator', { name: '调整列宽 1', exact: true })
  await handle.hover()
  const box = (await handle.boundingBox())!
  await page.mouse.move(box.x + 4, box.y + 30)
  await page.mouse.down()
  await page.mouse.move(box.x + 64, box.y + 30, { steps: 5 })
  await page.mouse.up()
  const widths = await editor.locator('.table-block').getAttribute('data-table-widths')
  expect(widths).toBeTruthy()
  await page.keyboard.press('ControlOrMeta+z')
  await expect(editor.locator('.table-block')).not.toHaveAttribute('data-table-widths')
  await page.keyboard.press('ControlOrMeta+Shift+z')
  await expect(editor.locator('.table-block')).toHaveAttribute('data-table-widths', widths!)
  await reopen(page)
  await expect(editor.locator('.table-block')).toHaveAttribute('data-table-widths', widths!)
})

test('unequal column widths survive a merged first row and resize independently', async ({ page }) => {
  await openDocument(
    page,
    '<table widths="100,300"><tr><th colspan="2">Merged</th></tr><tr><td>First</td><td>Second</td></tr></table>'
  )
  const editor = page.locator('.editor-content')
  const first = editor.locator('td').first()
  const second = editor.locator('td').last()
  expect((await first.boundingBox())!.width).toBeCloseTo(100, 0)
  expect((await second.boundingBox())!.width).toBeCloseTo(300, 0)
  await caret(first)
  const resizer = page.getByRole('separator', { name: '调整列宽 1', exact: true })
  await expect(resizer).toHaveAttribute('aria-valuenow', '100')
  await resizer.hover()
  const handle = (await resizer.boundingBox())!
  await page.mouse.move(handle.x + 4, handle.y + 30)
  await page.mouse.down()
  await page.mouse.move(handle.x + 44, handle.y + 30, { steps: 4 })
  await page.mouse.up()
  await expect.poll(async () => (await first.boundingBox())!.width).toBeCloseTo(140, 0)
  await expect.poll(async () => (await second.boundingBox())!.width).toBeCloseTo(300, 0)
  await reopen(page)
  await expect.poll(async () => (await first.boundingBox())!.width).toBeCloseTo(140, 0)
  await expect(editor.locator('th')).toHaveAttribute('colspan', '2')
})

test('successive column formatting keeps the selected range and distributing retains the displayed width', async ({
  page
}) => {
  await openDocument(page, source)
  const editor = page.locator('.editor-content')
  const table = editor.locator('table')
  const before = (await table.boundingBox())!.width
  await caret(editor.getByText('陈', { exact: true }))
  await page.getByRole('button', { name: '列 1', exact: true }).click()
  await page.keyboard.press('Escape')
  await page.getByRole('button', { name: '列 2', exact: true }).click({ modifiers: ['Shift'] })
  await page.getByRole('menuitemcheckbox', { name: '右对齐', exact: true }).click()
  await expect(editor.locator('.wg-selected-cell')).toHaveCount(8)
  await page.getByRole('button', { name: '列', exact: true }).click()
  await page.getByRole('menuitem', { name: '背景色', exact: true }).hover()
  await page.getByRole('menuitemcheckbox', { name: '蓝色背景', exact: true }).click()
  await expect(editor.locator('[data-cell-background="#deedfc"]')).toHaveCount(8)
  await page.getByRole('button', { name: '表格操作', exact: true }).click()
  await page.getByRole('menuitem', { name: '均分列宽', exact: true }).click()
  expect(Math.abs((await table.boundingBox())!.width - before)).toBeLessThanOrEqual(2)
  await reopen(page)
  expect(Math.abs((await table.boundingBox())!.width - before)).toBeLessThanOrEqual(2)
})

test('wide tables scroll independently and keep header cells visible', async ({ page }) => {
  await page.setViewportSize({ width: 640, height: 720 })
  await openDocument(
    page,
    '| A | B | C | D | E | F | G | H |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n| 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |\n\nBody'
  )
  const editor = page.locator('.editor-content')
  const scroll = editor.locator('.table-scroll')
  await expect(scroll).toHaveAttribute('data-scroll-right', '')
  const before = await editor.getByText('Body', { exact: true }).boundingBox()
  await caret(editor.getByText('8', { exact: true }))
  await scroll.evaluate(node => {
    node.scrollLeft = node.scrollWidth
  })
  await expect(scroll).toHaveAttribute('data-scroll-left', '')
  expect((await editor.getByText('Body', { exact: true }).boundingBox())!.x).toBe(before!.x)
  await expect(scroll).toHaveAttribute('tabindex', '0')
  const last = (await editor.locator('td').last().boundingBox())!
  const resizer = page.getByRole('separator', { name: '调整列宽 8', exact: true })
  await expect.poll(async () => Math.abs((await resizer.boundingBox())!.x + 4 - last.x - last.width)).toBeLessThan(2)
  expect((await editor.locator('th').first().boundingBox())!.x).toBeCloseTo(
    (await editor.locator('td').first().boundingBox())!.x,
    0
  )
  await caret(editor.getByText('1', { exact: true }))
  await page.getByRole('button', { name: '列', exact: true }).click()
  await page.getByRole('menuitemcheckbox', { name: '切换表头列', exact: true }).click()
  await expect(editor.locator('.table-block')).toHaveAttribute('data-table-header-column', '')
  await scroll.evaluate(node => {
    node.scrollLeft = node.scrollWidth
  })
  const left = (await scroll.boundingBox())!.x
  for (const header of await editor.locator('tr > th:first-child').all()) {
    expect((await header.boundingBox())!.x).toBeCloseTo(left + 1, 0)
  }
  await page.screenshot({ path: test.info().outputPath('wide-table.png') })
})

test('boundary controls add a row or column and Mod-Enter continues in a new row', async ({ page }) => {
  await openDocument(page, source)
  const editor = page.locator('.editor-content')
  await caret(editor.getByText('陈', { exact: true }))
  await page.getByRole('button', { name: '添加列', exact: true }).click()
  await expect(editor.locator('tr').first().locator('th')).toHaveCount(4)
  await page.getByRole('button', { name: '添加行', exact: true }).click()
  await page.keyboard.type('Bottom')
  await expect(editor.locator('tr').last()).toContainText('Bottom')
  await page.keyboard.press('ControlOrMeta+Enter')
  await page.keyboard.type('Next')
  await expect(editor.locator('tr').last()).toContainText('Next')
  await expect(editor.locator('tr')).toHaveCount(6)
  await reopen(page)
})

test('sorting keeps the header, whole table width expands, and CSV is downloaded', async ({ page }) => {
  await openDocument(page, '| Item | Count |\n| --- | --- |\n| Ten | 10 |\n| Two | 2 |\n| Three | 3 |')
  const editor = page.locator('.editor-content')
  await caret(editor.getByText('Count', { exact: true }))
  await page.getByRole('button', { name: '列', exact: true }).click()
  await page.getByRole('menuitem', { name: '排序', exact: true }).hover()
  await page.getByRole('menuitem', { name: '升序排列', exact: true }).click()
  await expect(editor.locator('tr').nth(1)).toContainText('Two')
  await expect(editor.locator('tr').last()).toContainText('Ten')
  const original = (await editor.locator('.table-block').boundingBox())!.width
  await page.getByRole('button', { name: '表格操作', exact: true }).click()
  await page.getByRole('menuitemcheckbox', { name: '全宽表格', exact: true }).click()
  await expect.poll(async () => (await editor.locator('.table-block').boundingBox())!.width).toBeGreaterThan(original)
  await page.getByRole('button', { name: '表格操作', exact: true }).click()
  const download = page.waitForEvent('download')
  await page.getByRole('menuitem', { name: '导出 CSV', exact: true }).click()
  const file = await download
  expect(file.suggestedFilename()).toMatch(/\.csv$/)
  const { readFile } = await import('node:fs/promises')
  expect(await readFile((await file.path())!, 'utf8')).toContain('"Two","2"')
  await reopen(page)
  await expect(editor.locator('.table-block')).toHaveAttribute('data-table-layout', 'full')
})

test('row and column handles drag to new positions', async ({ page }) => {
  await openDocument(page, source)
  const editor = page.locator('.editor-content')
  await caret(editor.getByText('林', { exact: true }))
  await page
    .getByRole('button', { name: '行 2', exact: true })
    .dragTo(page.getByRole('button', { name: '行 4', exact: true }))
  await expect(editor.locator('tr').nth(2)).toContainText('需求评审')
  await page
    .getByRole('button', { name: '列 1', exact: true })
    .dragTo(page.getByRole('button', { name: '添加列', exact: true }))
  await expect(editor.locator('tr').first().locator('th').last()).toHaveText('项目')
  await reopen(page)
})

test('long table keeps column headers visible while its contents scroll', async ({ page }) => {
  await openDocument(
    page,
    `| Name | Value |\n| --- | --- |\n${Array.from({ length: 40 }, (_, i) => `| Row ${i} | ${i} |`).join('\n')}`
  )
  const editor = page.locator('.editor-content')
  const scroll = editor.locator('.table-scroll')
  await scroll.evaluate(node => {
    node.scrollTop = 300
  })
  const header = (await editor.locator('th').first().boundingBox())!
  const region = (await scroll.boundingBox())!
  expect(Math.abs(header.y - region.y)).toBeLessThan(3)
  await page.screenshot({ path: test.info().outputPath('long-table.png') })
})

test('column resize has a keyboard route and Escape cancels a pointer preview', async ({ page }) => {
  await openDocument(page, source)
  const editor = page.locator('.editor-content')
  await caret(editor.getByText('林', { exact: true }))
  const handle = page.getByRole('separator', { name: '调整列宽 1', exact: true })
  await handle.focus()
  await page.keyboard.press('ArrowRight')
  const widths = await editor.locator('.table-block').getAttribute('data-table-widths')
  expect(widths).toBeTruthy()
  const box = (await handle.boundingBox())!
  await page.mouse.move(box.x + 4, box.y + 30)
  await page.mouse.down()
  await page.mouse.move(box.x + 90, box.y + 30)
  await page.keyboard.press('Escape')
  await page.mouse.up()
  await expect(editor.locator('.table-block')).toHaveAttribute('data-table-widths', widths!)
})

test('Shift-click column handles selects a range for batch deletion', async ({ page }) => {
  await openDocument(page, source)
  const editor = page.locator('.editor-content')
  await caret(editor.getByText('林', { exact: true }))
  await page.getByRole('button', { name: '列 1', exact: true }).click()
  await page.keyboard.press('Escape')
  await page.getByRole('button', { name: '列 2', exact: true }).click({ modifiers: ['Shift'] })
  await expect(editor.locator('.wg-selected-cell')).toHaveCount(8)
  await page.getByRole('menuitem', { name: '删除列', exact: true }).click()
  await expect(editor.locator('tr').first().locator('th')).toHaveCount(1)
  await expect(editor.locator('th')).toHaveText('状态')
  await page.keyboard.press('ControlOrMeta+z')
  await expect(editor.locator('tr').first().locator('th')).toHaveCount(3)
})

test('read-only tables retain scrolling and colors with no editing controls', async ({ page }) => {
  await page.goto('/playground/embedded.html')
  await page.getByLabel('Source target', { exact: true }).selectOption('first')
  await page
    .getByLabel('Host source', { exact: true })
    .fill(
      '<table widths="400,400"><tr><th background="#deedfc">Name</th><th>Value</th></tr><tr><td>Alpha</td><td>Beta</td></tr></table>'
    )
  await page.getByRole('button', { name: 'Apply source without moving focus', exact: true }).click()
  await page.getByRole('button', { name: 'Toggle read only', exact: true }).click()
  const editor = page.getByTestId('first-editor').locator('.editor-content')
  await expect(editor).toHaveAttribute('contenteditable', 'false')
  await expect(editor.locator('th').first()).toHaveCSS('background-color', 'rgb(222, 237, 252)')
  const scroll = editor.getByRole('region', { name: '表格', exact: true })
  await expect(scroll).toHaveAttribute('data-scroll-right', '')
  await scroll.focus()
  await expect(scroll).toBeFocused()
  await page.keyboard.press('ArrowRight')
  await expect.poll(() => scroll.evaluate(node => node.scrollLeft)).toBeGreaterThan(0)
  await expect(page.getByRole('button', { name: '表格操作', exact: true })).toHaveCount(0)
})

test('nested tables keep editing controls without offering a page-width layout', async ({ page }) => {
  await openDocument(page, '> | A | B |\n> | --- | --- |\n> | C | D |')
  const editor = page.locator('.editor-content')
  await caret(editor.getByText('C', { exact: true }))
  await page.getByRole('button', { name: '表格操作', exact: true }).click()
  await expect(page.getByRole('menuitemcheckbox', { name: '全宽表格', exact: true })).toHaveCount(0)
  await page.keyboard.press('Escape')
  await page.getByRole('button', { name: '添加行', exact: true }).click()
  await page.keyboard.type('Nested row')
  await expect(editor.locator('blockquote tr').last()).toContainText('Nested row')
  await reopen(page)
  await expect(editor.locator('blockquote tr')).toHaveCount(3)
})
