import { readFileSync } from 'node:fs'
import { expect, test, type Browser, type Page } from '@playwright/test'
import { initSync, Spreadsheet } from '@ankole/kernel/spreadsheet-wasm'
import { request, state } from './fixtures'
import { pageRoute } from './routes'

const wasm = new URL('../../../kernel/dist/spreadsheet-wasm/ankole_spreadsheet_wasm_bg.wasm', import.meta.url)
const formula = (page: Page) => page.getByRole('textbox', { name: '单元格内容', exact: true })
const saved = (page: Page) => expect(page.getByRole('status').filter({ hasText: '所有更改已保存' })).toBeVisible()
const active = (page: Page) =>
  expect.poll(async () =>
    (await page.getByRole('status', { name: '当前单元格', exact: true }).textContent())?.replace(/[⁨⁩]/g, '')
  )

async function session(browser: Browser) {
  const context = await browser.newContext({
    baseURL: state.base_url,
    viewport: { width: 1440, height: 1100 },
    permissions: ['clipboard-read', 'clipboard-write']
  })
  await context.addCookies(state.owner.cookies)
  return { context, page: await context.newPage() }
}

async function create(page: Page, title: string) {
  await page.goto(pageRoute(state.report_id))
  const { page: created } = await request<{ page: { id: string } }>(page, '/spreadsheet-pages', 'POST', {
    title,
    parent_id: state.report_id
  })
  await page.goto(pageRoute(created.id))
  await expect(page.getByRole('grid')).toBeVisible()
  return created.id
}

/** The screen point of a cell's upper-left area at the default 64×20 grid. */
async function point(page: Page, row: number, col: number, dx = 16, dy = 8) {
  const bounds = (await page.getByRole('grid').boundingBox())!
  return { x: bounds.x + 48 + col * 64 + dx, y: bounds.y + 24 + row * 20 + dy }
}

async function cell(page: Page, row: number, col: number, shift = false) {
  const { x, y } = await point(page, row, col)
  if (shift) await page.keyboard.down('Shift')
  await page.mouse.click(x, y)
  if (shift) await page.keyboard.up('Shift')
}

async function enter(page: Page, row: number, col: number, text: string) {
  await cell(page, row, col)
  await page.keyboard.insertText(text)
  await page.keyboard.press('Enter')
  await saved(page)
}

async function download(page: Page) {
  await saved(page)
  const href = (await page.getByRole('link', { name: '下载', exact: true }).getAttribute('href'))!
  const response = await page.request.get(href)
  expect(response.ok()).toBe(true)
  initSync({ module: readFileSync(wasm) })
  return Spreadsheet.open(new Uint8Array(await response.body()), '[]')
}

test('suggestions, AutoSum, pointing at cells and F4 build formulas', async ({ browser }) => {
  const { context, page } = await session(browser)
  let id: string | undefined
  try {
    id = await create(page, '公式工具.xlsx')
    await enter(page, 0, 0, '10')
    await enter(page, 1, 0, '20')
    await enter(page, 2, 0, '30')

    await cell(page, 3, 0)
    await page.getByRole('button', { name: '公式', exact: true }).click()
    await page.getByRole('menuitem', { name: /求和/ }).click()
    await expect(formula(page)).toHaveValue('=SUM(A1:A3)')
    await page.keyboard.press('Enter')
    await saved(page)
    await cell(page, 3, 0)
    await active(page).toBe('A4：60')

    await cell(page, 0, 1)
    await page.keyboard.insertText('=av')
    const suggestions = page.getByRole('listbox', { name: '函数建议', exact: true })
    await expect(suggestions.getByRole('option').first()).toContainText('AVERAGE')
    await page.keyboard.press('Tab')
    await expect(formula(page)).toHaveValue('=AVERAGE(')
    await expect(page.getByRole('tooltip', { name: '函数参数', exact: true })).toContainText('AVERAGE(')
    await cell(page, 0, 0)
    await cell(page, 2, 0, true)
    await expect(formula(page)).toHaveValue('=AVERAGE(A1:A3')
    await page.keyboard.insertText(')')
    await page.keyboard.press('Enter')
    await saved(page)

    await cell(page, 1, 1)
    await page.keyboard.insertText('=A1')
    await page.keyboard.press('F4')
    await expect(formula(page)).toHaveValue('=$A$1')
    await page.keyboard.press('Enter')
    await saved(page)

    // A formula waiting for an operand takes a reference from another sheet.
    await page.getByRole('button', { name: '添加工作表', exact: true }).click()
    await saved(page)
    await enter(page, 0, 0, '5')
    await page
      .getByRole('navigation', { name: '工作表', exact: true })
      .getByRole('button', { name: 'Sheet1', exact: true })
      .click()
    await cell(page, 2, 1)
    await page.keyboard.insertText('=SUM(')
    await page
      .getByRole('navigation', { name: '工作表', exact: true })
      .getByRole('button', { name: 'Sheet2', exact: true })
      .click()
    await cell(page, 0, 0)
    await expect(formula(page)).toHaveValue('=SUM(Sheet2!A1')
    await page.keyboard.insertText(')')
    await page.keyboard.press('Enter')
    await saved(page)
    await expect(
      page.getByRole('navigation', { name: '工作表', exact: true }).getByRole('button', { name: 'Sheet1', exact: true })
    ).toHaveAttribute('aria-pressed', 'true')

    await page.getByRole('button', { name: '公式', exact: true }).click()
    await page.getByRole('menuitem', { name: '全部函数…', exact: true }).click()
    const dialog = page.getByRole('dialog', { name: '插入函数', exact: true })
    await dialog.getByRole('textbox', { name: '搜索函数', exact: true }).fill('VLOOKUP')
    await expect(dialog).toContainText('在表格首列查找值')
    await dialog.getByRole('button', { name: '插入', exact: true }).click()
    await expect(formula(page)).toHaveValue('=VLOOKUP(')
    await page.keyboard.press('Escape')

    const workbook = await download(page)
    try {
      expect(workbook.cell_input(1, 'A4')).toBe('=SUM(A1:A3)')
      expect(workbook.cell_input(1, 'B1')).toBe('=AVERAGE(A1:A3)')
      expect(workbook.cell_input(1, 'B2')).toBe('=$A$1')
      expect(workbook.cell_input(1, 'B3')).toBe('=SUM(Sheet2!A1)')
    } finally {
      workbook.free()
    }
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('the fill handle, rich copy and paste, cell shifts, freezing and statistics reach the saved workbook', async ({
  browser
}) => {
  const { context, page } = await session(browser)
  let id: string | undefined
  try {
    id = await create(page, '单元格操作.xlsx')
    await enter(page, 0, 0, '1')
    await enter(page, 1, 0, '2')
    await cell(page, 0, 0)
    await cell(page, 1, 0, true)
    // The fill handle sits on the selection's bottom-right corner.
    const handle = await point(page, 1, 0, 63, 19)
    const target = await point(page, 4, 0, 30, 10)
    await page.mouse.move(handle.x, handle.y)
    await page.mouse.down()
    await page.mouse.move(target.x, target.y, { steps: 4 })
    await page.mouse.up()
    await saved(page)
    await expect(page.getByRole('button', { name: '填充选项', exact: true })).toBeVisible()
    const stats = page.getByRole('status', { name: '选区统计', exact: true })
    await expect.poll(async () => (await stats.textContent())?.replace(/[\u2068\u2069]/g, '')).toContain('求和：15')

    await enter(page, 0, 1, '=A1*10')
    await cell(page, 0, 1)
    await page.keyboard.press('ControlOrMeta+C')
    // The copy writes the system clipboard asynchronously; a person pastes long after it lands.
    await expect.poll(() => page.evaluate(() => navigator.clipboard.readText())).toBe('10')
    await cell(page, 1, 3)
    await page.keyboard.press('ControlOrMeta+V')
    await saved(page)
    await cell(page, 1, 3)
    await expect(formula(page)).toHaveValue('=C2*10')

    await enter(page, 0, 4, '右移')
    const shifted = await point(page, 0, 4)
    await page.mouse.click(shifted.x, shifted.y, { button: 'right' })
    await page.getByRole('menuitem', { name: '插入', exact: true }).hover()
    await page.getByRole('menuitem', { name: '插入单元格，右移', exact: true }).click()
    await saved(page)

    await page.getByRole('button', { name: '冻结窗格', exact: true }).click()
    await page.getByRole('menuitem', { name: '冻结首行', exact: true }).click()
    await saved(page)

    const workbook = await download(page)
    try {
      expect(['A3', 'A4', 'A5'].map(at => workbook.cell_input(1, at))).toEqual(['3', '4', '5'])
      expect(workbook.cell_input(1, 'D2')).toBe('=C2*10')
      expect(workbook.cell_input(1, 'E1')).toBe('')
      expect(workbook.cell_input(1, 'F1')).toBe('右移')
      expect(JSON.parse(workbook.sheets())[0].freeze).toEqual([1, 0])
    } finally {
      workbook.free()
    }
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('pictures float over cells, sit in cells, move, convert and survive the download', async ({ browser }) => {
  const { context, page } = await session(browser)
  let id: string | undefined
  try {
    id = await create(page, '图片.xlsx')
    const png = Buffer.from(
      await page.evaluate(async () => {
        const canvas = new OffscreenCanvas(60, 40)
        const context = canvas.getContext('2d')!
        context.fillStyle = '#2f6fed'
        context.fillRect(0, 0, 60, 40)
        const bytes = new Uint8Array(await (await canvas.convertToBlob({ type: 'image/png' })).arrayBuffer())
        return [...bytes]
      })
    )
    const choose = async (item: string) => {
      const chooser = page.waitForEvent('filechooser')
      await page.getByRole('button', { name: '插入图片', exact: true }).click()
      await page.getByRole('menuitem', { name: item, exact: true }).click()
      await (await chooser).setFiles({ name: 'logo.png', mimeType: 'image/png', buffer: png })
      await saved(page)
    }

    await cell(page, 0, 0)
    await choose('浮动图片')
    await cell(page, 4, 2)
    await choose('单元格图片')

    // Drag the floating picture two columns to the right.
    const grab = await point(page, 0, 0, 10, 10)
    await page.mouse.move(grab.x, grab.y)
    await page.mouse.down()
    await page.mouse.move(grab.x + 128, grab.y, { steps: 4 })
    await page.mouse.up()
    await saved(page)

    let workbook = await download(page)
    try {
      const images = JSON.parse(workbook.images(1))
      expect(images).toHaveLength(1)
      expect(images[0]).toMatchObject({ cell: 'C1', width: 60, height: 40 })
      expect(workbook.cell_picture(1, 'C5').length).toBeGreaterThan(0)
    } finally {
      workbook.free()
    }

    const moved = await point(page, 0, 2, 10, 10)
    await page.mouse.click(moved.x, moved.y, { button: 'right' })
    await page.getByRole('menuitem', { name: '转为单元格图片', exact: true }).click()
    await saved(page)
    workbook = await download(page)
    try {
      expect(JSON.parse(workbook.images(1))).toHaveLength(0)
      expect(workbook.cell_picture(1, 'C1').length).toBeGreaterThan(0)
    } finally {
      workbook.free()
    }
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('the keyboard opens the cell and header menus and the filter list, fills, paints formats, and moves pictures', async ({
  browser
}) => {
  const { context, page } = await session(browser)
  let id: string | undefined
  try {
    id = await create(page, '键盘操作.xlsx')
    const editor = page.getByRole('textbox', { name: /^编辑单元格/ })
    await enter(page, 0, 0, '1')

    await cell(page, 0, 0)
    await page.keyboard.press('Shift+ArrowDown')
    await page.keyboard.press('Shift+ArrowDown')
    await page.keyboard.press('Shift+F10')
    await page.getByRole('menuitem', { name: '填充', exact: true }).hover()
    await page.getByRole('menuitem', { name: '向下填充序列', exact: true }).click()
    await saved(page)

    await page.keyboard.press('ArrowUp')
    await page.keyboard.press('Shift+Space')
    await page.keyboard.press('Shift+F10')
    await page.getByRole('menuitem', { name: '冻结至此行', exact: true }).click()
    await saved(page)

    await cell(page, 0, 0)
    await page.keyboard.press('Shift+ArrowDown')
    await page.keyboard.press('Shift+ArrowDown')
    await page.getByRole('button', { name: '数据', exact: true }).click()
    await page.getByRole('menuitem', { name: '创建筛选', exact: true }).click()
    await saved(page)
    await cell(page, 0, 0)
    await page.keyboard.press('Alt+ArrowDown')
    await expect(page.getByRole('dialog').getByText(/^筛选/)).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(editor).toBeFocused()

    await page.getByRole('button', { name: '加粗', exact: true }).click()
    await saved(page)
    await page.getByRole('button', { name: '格式刷', exact: true }).click()
    await page.keyboard.press('ArrowRight')
    await page.keyboard.press('Enter')
    await saved(page)
    await expect(page.getByRole('button', { name: '加粗', exact: true })).toHaveAttribute('aria-pressed', 'true')

    await page.getByRole('button', { name: '文字颜色', exact: true }).click()
    await expect(page.getByRole('button', { name: '红色', exact: true })).toBeVisible()
    await page.keyboard.press('Escape')

    const png = Buffer.from(
      await page.evaluate(async () => {
        const canvas = new OffscreenCanvas(60, 40)
        canvas.getContext('2d')!.fillRect(0, 0, 60, 40)
        return [...new Uint8Array(await (await canvas.convertToBlob({ type: 'image/png' })).arrayBuffer())]
      })
    )
    await cell(page, 5, 0)
    const chooser = page.waitForEvent('filechooser')
    await page.getByRole('button', { name: '插入图片', exact: true }).click()
    await page.getByRole('menuitem', { name: '浮动图片', exact: true }).click()
    await (await chooser).setFiles({ name: 'logo.png', mimeType: 'image/png', buffer: png })
    await saved(page)
    // The grid reloads its picture list after the save, so the shortcut selects the picture once that list arrives.
    await expect(async () => {
      await editor.press('ControlOrMeta+Alt+KeyP')
      await expect(page.getByRole('status').filter({ hasText: /已选中图片/ })).toBeVisible({ timeout: 1000 })
    }).toPass()
    await page.keyboard.press('ArrowRight')
    await saved(page)

    let workbook = await download(page)
    try {
      expect(['A1', 'A2', 'A3'].map(at => workbook.cell_input(1, at))).toEqual(['1', '2', '3'])
      expect(JSON.parse(workbook.sheets())[0].freeze).toEqual([1, 0])
      expect(JSON.parse(workbook.images(1))[0]).toMatchObject({ cell: 'B6' })
    } finally {
      workbook.free()
    }
    await page.keyboard.press('Delete')
    await saved(page)
    workbook = await download(page)
    try {
      expect(JSON.parse(workbook.images(1))).toHaveLength(0)
    } finally {
      workbook.free()
    }
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('larger fonts grow their row, and Command+Z undoes formats and merges', async ({ browser }) => {
  const { context, page } = await session(browser)
  let id: string | undefined
  try {
    id = await create(page, '撤销格式.xlsx')
    await enter(page, 0, 0, 'dasd啊')
    await enter(page, 2, 0, '左')
    await enter(page, 2, 1, '右')
    await cell(page, 0, 0)
    await page.getByRole('combobox', { name: '字号', exact: true }).click()
    await page.getByRole('option', { name: '24', exact: true }).click()
    await saved(page)

    await cell(page, 0, 0)
    await page.getByRole('button', { name: '加粗', exact: true }).click()
    await saved(page)
    await page.keyboard.press('ControlOrMeta+Z')
    await saved(page)

    // Row 1 is taller now, so row 3 sits lower than the default grid puts it.
    const third = await point(page, 2, 0)
    const rowOneGrowth = 44 - 20
    await page.mouse.click(third.x, third.y + rowOneGrowth)
    await page.keyboard.down('Shift')
    await page.mouse.click(third.x + 64, third.y + rowOneGrowth)
    await page.keyboard.up('Shift')
    await page.getByRole('button', { name: '合并单元格', exact: true }).click()
    await saved(page)
    await page.keyboard.press('ControlOrMeta+Z')
    await saved(page)

    const workbook = await download(page)
    try {
      const view = JSON.parse(workbook.viewport(1, 0, 0, 2, 1))
      const style = (row: number, col: number) =>
        view.styles[
          view.cells.find((entry: { row: number; col: number }) => entry.row === row && entry.col === col).style
        ]
      expect(style(0, 0)).toMatchObject({ font_size: 24, bold: false })
      expect(view.rows.find((entry: { index: number }) => entry.index === 0).size).toBeGreaterThan(40)
      expect(view.merges).toEqual([])
      expect(workbook.cell_input(1, 'B3')).toBe('右')
    } finally {
      workbook.free()
    }
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})
