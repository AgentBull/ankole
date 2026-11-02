import { readFileSync } from 'node:fs'
import { expect, test, type Browser, type Page } from '@playwright/test'
import { initSync, Spreadsheet } from '@ankole/kernel/spreadsheet-wasm'
import { strFromU8, unzipSync } from 'fflate'
import { closeRealtimeSocket, request, requestResponse, requestWithSharingVersion, state } from './fixtures'
import { pageRoute } from './routes'

const wasm = new URL('../../../kernel/dist/spreadsheet-wasm/ankole_spreadsheet_wasm_bg.wasm', import.meta.url)
const formula = (page: Page) => page.getByRole('textbox', { name: '单元格内容', exact: true })
const saved = (page: Page) => expect(page.getByRole('status').filter({ hasText: '所有更改已保存' })).toBeVisible()
const active = (page: Page) =>
  expect.poll(async () =>
    (await page.getByRole('status', { name: '当前单元格', exact: true }).textContent())?.replace(/[\u2068\u2069]/g, '')
  )

async function session(browser: Browser, identity: 'owner' | 'member' | 'viewer') {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1440, height: 1100 } })
  await context.addCookies(state[identity].cookies)
  return { context, page: await context.newPage() }
}

async function create(page: Page, title: string) {
  await page.goto(pageRoute(state.report_id))
  const { page: created } = await request<{ page: { id: string } }>(page, '/spreadsheet-pages', 'POST', {
    title,
    parent_id: state.report_id
  })
  await requestWithSharingVersion(page, `/pages/${created.id}/sharing`, 'PUT', {
    inherit_permissions: false,
    grants: [
      { principal_uid: state.owner.uid, role: 'manage' },
      { principal_uid: state.member.uid, role: 'edit' },
      { principal_uid: state.viewer.uid, role: 'view' }
    ]
  })
  await page.goto(pageRoute(created.id))
  await expect(page.getByRole('grid')).toBeVisible()
  return created.id
}

async function cell(page: Page, row: number, col: number, shift = false) {
  const bounds = (await page.getByRole('grid').boundingBox())!
  if (shift) await page.keyboard.down('Shift')
  await page.mouse.click(bounds.x + 48 + col * 64 + 16, bounds.y + 24 + row * 20 + 8)
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

test('cell undo, redo, TSV paste and IME composition preserve the committed workbook', async ({ browser }) => {
  const { context, page } = await session(browser, 'owner')
  let id: string | undefined
  try {
    id = await create(page, '采购核对与中文输入.xlsx')
    await enter(page, 0, 0, '采购订单')
    await cell(page, 0, 0)
    await page.getByRole('button', { name: '撤销', exact: true }).click()
    await active(page).toBe('A1：')
    await page.getByRole('button', { name: '重做', exact: true }).click()
    await active(page).toBe('A1：采购订单')

    await cell(page, 1, 0)
    await page.locator('textarea[aria-label^="编辑单元格"]').evaluate(element => {
      const data = new DataTransfer()
      data.setData('text/plain', 'SKU-001\t12\t18.5\nSKU-002\t8\t25')
      element.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true }))
    })
    await saved(page)
    await cell(page, 2, 2)
    await active(page).toBe('C3：25')
    await page.getByRole('button', { name: '撤销', exact: true }).click()
    await active(page).toBe('C3：')
    await page.getByRole('button', { name: '重做', exact: true }).click()
    await active(page).toBe('C3：25')

    await cell(page, 4, 0)
    const editor = page.locator('textarea[aria-label^="编辑单元格"]')
    await editor.dispatchEvent('compositionstart', { data: '' })
    await editor.fill('采购备注')
    await editor.dispatchEvent('keydown', { key: 'Enter', code: 'Enter', isComposing: true })
    await expect(editor).toHaveAttribute('data-editing', '')
    await expect(formula(page)).toHaveValue('采购备注')
    const duringComposition = await download(page)
    try {
      expect(duringComposition.cell_input(1, 'A5')).toBe('')
    } finally {
      duringComposition.free()
    }
    await editor.dispatchEvent('compositionend', { data: '采购备注' })
    await editor.press('Enter')
    await saved(page)
    const workbook = await download(page)
    try {
      expect(workbook.cell_input(1, 'A1')).toBe('采购订单')
      expect(workbook.cell_input(1, 'A2')).toBe('SKU-001')
      expect(workbook.cell_input(1, 'B2')).toBe('12')
      expect(workbook.cell_input(1, 'C3')).toBe('25')
      expect(workbook.cell_input(1, 'A5')).toBe('采购备注')
    } finally {
      workbook.free()
    }
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('formatting, sheet names and cross-sheet formulas survive a real download', async ({ browser }) => {
  const { context, page } = await session(browser, 'owner')
  let id: string | undefined
  try {
    id = await create(page, '季度销售格式.xlsx')
    await enter(page, 0, 0, '季度销售')
    await cell(page, 0, 0)
    for (const label of ['加粗', '斜体', '下划线', '居中', '自动换行']) {
      await page.getByRole('button', { name: label, exact: true }).click()
      await saved(page)
    }
    await page.getByRole('combobox', { name: '字号', exact: true }).click()
    await page.getByRole('option', { name: '18', exact: true }).click()
    await page.getByRole('button', { name: '文字颜色', exact: true }).click()
    await page.getByRole('button', { name: 'red-60', exact: true }).click()
    await page.getByRole('button', { name: '填充颜色', exact: true }).click()
    await page.getByRole('button', { name: 'yellow-20', exact: true }).click()
    await page.getByRole('button', { name: '边框', exact: true }).click()
    await page.getByRole('menuitem', { name: '所有边框', exact: true }).click()
    await saved(page)
    await cell(page, 0, 1, true)
    await page.getByRole('button', { name: '合并单元格', exact: true }).click()
    await saved(page)

    await enter(page, 2, 0, '1250.5')
    await cell(page, 2, 0)
    await page.getByRole('button', { name: '数字格式', exact: true }).click()
    await page.getByRole('menuitem', { name: '货币', exact: true }).click()
    await saved(page)
    await page.getByRole('button', { name: '添加工作表', exact: true }).click()
    const tabs = page.getByRole('navigation', { name: '工作表', exact: true })
    await expect(tabs.getByRole('button', { name: 'Sheet2', exact: true })).toBeVisible()
    await tabs.getByRole('button', { name: 'Sheet2', exact: true }).dblclick()
    await page.getByRole('textbox', { name: '工作表名称', exact: true }).fill('汇总')
    await page.getByRole('textbox', { name: '工作表名称', exact: true }).press('Enter')
    await enter(page, 0, 0, '=Sheet1!A3*2')
    await cell(page, 0, 0)
    await active(page).toBe('A1：2501')
    await tabs.getByRole('button', { name: 'Sheet1', exact: true }).dblclick()
    await page.getByRole('textbox', { name: '工作表名称', exact: true }).fill('销售 明细')
    await page.getByRole('textbox', { name: '工作表名称', exact: true }).press('Enter')
    await tabs.getByRole('button', { name: '汇总', exact: true }).click()
    await cell(page, 0, 0)
    await expect(formula(page)).toHaveValue("='销售 明细'!A3*2")
    await active(page).toBe('A1：2501')
    const workbook = await download(page)
    try {
      const sheets = JSON.parse(workbook.sheets())
      expect(sheets.map((sheet: { name: string }) => sheet.name)).toEqual(['销售 明细', '汇总'])
      const view = JSON.parse(workbook.viewport(1, 0, 0, 2, 1))
      const first = view.cells.find((entry: { row: number; col: number }) => entry.row === 0 && entry.col === 0)
      expect(view.styles[first.style]).toMatchObject({
        bold: true,
        italic: true,
        underline: true,
        h_align: 'center',
        wrap: true,
        font_size: 18
      })
      expect(view.merges).toHaveLength(1)
      expect(workbook.cell_input(2, 'A1')).toBe("='销售 明细'!A3*2")
    } finally {
      workbook.free()
    }
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('viewers follow live changes and reconnecting editors report deleted targets before restore', async ({
  browser
}) => {
  const owner = await session(browser, 'owner')
  const member = await session(browser, 'member')
  const viewer = await session(browser, 'viewer')
  let id: string | undefined
  try {
    id = await create(owner.page, '协作冲突核对.xlsx')
    await enter(owner.page, 0, 0, '保留原始记录')
    await member.page.goto(pageRoute(id))
    await viewer.page.goto(pageRoute(id))
    await expect(member.page.getByRole('grid')).toBeVisible()
    await expect(viewer.page.getByRole('grid')).toBeVisible()
    await expect(viewer.page.getByRole('button', { name: '加粗', exact: true })).toHaveCount(0)
    await expect(viewer.page.getByRole('button', { name: '版本历史', exact: true })).toHaveCount(0)
    await expect(formula(viewer.page)).toHaveAttribute('readonly', '')
    expect((await requestResponse(viewer.page, `/pages/${id}/spreadsheet/versions`)).status).toBe(403)
    await enter(owner.page, 1, 0, '实时库存 48')
    await cell(viewer.page, 1, 0)
    await active(viewer.page).toBe('A2：实时库存 48')

    await member.context.setOffline(true)
    await closeRealtimeSocket(member.page)
    await cell(member.page, 0, 0)
    await member.page.keyboard.insertText('离线编辑待确认')
    await member.page.keyboard.press('Enter')
    await cell(owner.page, 0, 0)
    await owner.page.getByRole('button', { name: '行和列', exact: true }).click()
    await owner.page.getByRole('menuitem', { name: '删除行', exact: true }).click()
    await saved(owner.page)
    await member.context.setOffline(false)
    await expect(member.page.getByText(/其他人删除了这些单元格/)).toBeVisible({ timeout: 30000 })
    await cell(member.page, 0, 0)
    await active(member.page).toBe('A1：实时库存 48')

    await owner.page.getByRole('button', { name: '版本历史', exact: true }).click()
    const versions = owner.page.getByRole('list', { name: '版本', exact: true })
    await versions
      .getByRole('listitem')
      .filter({ hasText: '创建' })
      .getByRole('button', { name: '恢复', exact: true })
      .click()
    await expect(owner.page.getByText('已恢复该版本，所有打开的编辑器都会重新加载。', { exact: true })).toBeVisible()
    await cell(member.page, 0, 0)
    await active(member.page).toBe('A1：')
    await cell(viewer.page, 0, 0)
    await active(viewer.page).toBe('A1：')
  } finally {
    await member.context.setOffline(false)
    if (id) await request(owner.page, `/pages/${id}`, 'DELETE')
    await owner.context.close()
    await member.context.close()
    await viewer.context.close()
  }
})

test('sorting, freezing, hiding and resizing persist through their toolbar and header controls', async ({
  browser
}) => {
  const { context, page } = await session(browser, 'owner')
  let id: string | undefined
  try {
    id = await create(page, '库存排序与布局.xlsx')
    await cell(page, 0, 0)
    await page.locator('textarea[aria-label^="编辑单元格"]').evaluate(element => {
      const data = new DataTransfer()
      data.setData('text/plain', '30\t华东仓\n10\t华北仓\n20\t华南仓')
      element.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true }))
    })
    await cell(page, 2, 1, true)
    await page.getByRole('button', { name: '按所选首列升序排序', exact: true }).click()
    await saved(page)
    await cell(page, 0, 0)
    await active(page).toBe('A1：10')
    await cell(page, 0, 1)
    await active(page).toBe('B1：华北仓')
    await expect(page.getByRole('button', { name: '撤销', exact: true })).toBeDisabled()
    await cell(page, 0, 0)
    await page.getByRole('button', { name: '冻结窗格', exact: true }).click()
    await page.getByRole('menuitem', { name: /冻结至第.*1.*行.*A.*列/ }).click()
    await saved(page)
    const bounds = (await page.getByRole('grid').boundingBox())!
    await page.mouse.move(bounds.x + 112, bounds.y + 12)
    await page.mouse.down()
    await page.mouse.move(bounds.x + 144, bounds.y + 12)
    await page.mouse.up()
    await saved(page)
    await page.mouse.move(bounds.x + 20, bounds.y + 44)
    await page.mouse.down()
    await page.mouse.move(bounds.x + 20, bounds.y + 54)
    await page.mouse.up()
    await saved(page)
    await page.mouse.click(bounds.x + 20, bounds.y + 62, { button: 'right' })
    await page.getByRole('menuitem', { name: '隐藏行', exact: true }).click()
    await saved(page)
    const workbook = await download(page)
    try {
      expect(workbook.cell_input(1, 'A1')).toBe('10')
      expect(workbook.cell_input(1, 'B1')).toBe('华北仓')
      expect(workbook.cell_input(1, 'A2')).toBe('20')
      expect(workbook.cell_input(1, 'B3')).toBe('华东仓')
      expect(JSON.parse(workbook.sheets())[0].freeze).toEqual([1, 1])
      const view = JSON.parse(workbook.viewport(1, 0, 0, 2, 1))
      expect(view.cols.find((entry: { index: number }) => entry.index === 0).size).toBeCloseTo(96, 0)
      expect(view.rows.find((entry: { index: number }) => entry.index === 0).size).toBeCloseTo(30, 0)
      expect(view.rows.find((entry: { index: number }) => entry.index === 1).hidden).toBe(true)
    } finally {
      workbook.free()
    }
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('notes and sheet ordering, colors and deletion reach the saved workbook', async ({ browser }) => {
  const { context, page } = await session(browser, 'owner')
  let id: string | undefined
  try {
    id = await create(page, '采购批注与工作表管理.xlsx')
    await enter(page, 0, 0, '待复核采购金额')
    await cell(page, 0, 0)
    await page.getByRole('button', { name: '批注', exact: true }).click()
    await page.getByRole('textbox', { name: '批注', exact: true }).fill('供应商已确认含税单价，等待财务复核。')
    await page.getByRole('button', { name: '保存批注', exact: true }).click()
    await saved(page)
    await page.keyboard.press('Escape')
    const tabs = page.getByRole('navigation', { name: '工作表', exact: true })
    for (const name of ['Sheet2', 'Sheet3']) {
      await page.getByRole('button', { name: '添加工作表', exact: true }).click()
      await expect(tabs.getByRole('button', { name, exact: true })).toHaveAttribute('aria-pressed', 'true')
    }
    await tabs.getByRole('button', { name: /工作表.*Sheet3.*的操作/ }).click()
    await page.getByRole('menuitem', { name: '标签颜色', exact: true }).hover()
    await page.getByRole('button', { name: 'blue-60', exact: true }).click()
    await page.keyboard.press('Escape')
    await page.keyboard.press('Escape')
    await tabs.getByRole('button', { name: /工作表.*Sheet3.*的操作/ }).click()
    await page.getByRole('menuitem', { name: '左移', exact: true }).click()
    await expect(tabs.getByRole('button', { name: /^Sheet[123]$/ })).toHaveText(['Sheet1', 'Sheet3', 'Sheet2'])
    await tabs.getByRole('button', { name: 'Sheet2', exact: true }).click()
    await tabs.getByRole('button', { name: /工作表.*Sheet2.*的操作/ }).click()
    await page.getByRole('menuitem', { name: '删除工作表', exact: true }).click()
    await page.getByRole('dialog').getByRole('button', { name: '删除工作表', exact: true }).click()
    await expect(tabs.getByRole('button', { name: 'Sheet2', exact: true })).toHaveCount(0)
    await tabs.getByRole('button', { name: 'Sheet1', exact: true }).click()
    await cell(page, 0, 0)
    await page.getByRole('button', { name: '行和列', exact: true }).click()
    await page.getByRole('menuitem', { name: '在左侧插入列', exact: true }).click()
    await saved(page)
    const workbook = await download(page)
    try {
      const sheets = JSON.parse(workbook.sheets())
      expect(sheets.map((sheet: { name: string }) => sheet.name)).toEqual(['Sheet1', 'Sheet3'])
      expect(sheets[1].tab_color).toMatch(/^#[0-9a-f]{6}$/i)
      expect(workbook.cell_input(1, 'B1')).toBe('待复核采购金额')
    } finally {
      workbook.free()
    }
    const response = await page.request.get(
      (await page.getByRole('link', { name: '下载', exact: true }).getAttribute('href'))!
    )
    const comments = Object.entries(unzipSync(await response.body()))
      .filter(([name]) => /comments?.*\.xml$/i.test(name))
      .map(([, bytes]) => strFromU8(bytes))
      .join('\n')
    expect(comments).toContain('供应商已确认含税单价，等待财务复核。')
    expect(comments).toContain('ref="B1"')
    await cell(page, 0, 1)
    await page.getByRole('button', { name: '批注', exact: true }).click()
    await page.getByRole('button', { name: '删除批注', exact: true }).click()
    await saved(page)
    await page.keyboard.press('Escape')
    const removed = await page.request.get(
      (await page.getByRole('link', { name: '下载', exact: true }).getAttribute('href'))!
    )
    expect(
      Object.entries(unzipSync(await removed.body()))
        .filter(([name]) => /comments?.*\.xml$/i.test(name))
        .map(([, bytes]) => strFromU8(bytes))
        .join('\n')
    ).not.toContain('供应商已确认含税单价')
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})
