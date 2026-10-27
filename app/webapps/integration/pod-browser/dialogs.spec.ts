import { state, request } from './fixtures'
import { expect, test, type Locator, type Page } from '@playwright/test'
import type { BaseField, BaseTable, TableSchema } from '@ankole/applet-sdk/types'
import { pageRoute } from './routes'

async function inViewport(page: Page, dialog: Locator) {
  await expect(dialog).toBeInViewport({ ratio: 1 })
  const bounds = await dialog.boundingBox()
  const viewport = page.viewportSize()!
  expect(bounds).not.toBeNull()
  expect(bounds!.x).toBeGreaterThanOrEqual(15)
  expect(bounds!.y).toBeGreaterThanOrEqual(15)
  expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(viewport.width - 15)
  expect(bounds!.y + bounds!.height).toBeLessThanOrEqual(viewport.height - 15)
}

test('sidebar type menu stays anchored, dismisses naturally, retries a failed creation and opens an untitled Page', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const gate = Promise.withResolvers<void>()
  let created: string | undefined
  let calls = 0
  try {
    await page.goto(pageRoute(state.report_id))
    const trigger = page.locator('.pod-sidebar-top').getByRole('button', { name: '新建页面', exact: true })
    await expect(trigger).toBeEnabled()
    await trigger.focus()
    await trigger.press('Enter')
    const menu = page.getByRole('menu', { name: '新建页面', exact: true })
    await expect(menu).toBeVisible()
    await expect(page.getByRole('dialog', { name: '新建页面', exact: true })).toHaveCount(0)
    await expect(menu.getByRole('menuitem')).toHaveText(['文档', '多维表', '文件'])
    await expect(menu.getByRole('menuitem', { name: '文档', exact: true })).toBeFocused()
    const anchor = (await trigger.boundingBox())!,
      popup = (await menu.boundingBox())!
    expect(Math.abs(popup.x - anchor.x)).toBeLessThanOrEqual(2)
    expect(popup.y - anchor.y - anchor.height).toBeGreaterThanOrEqual(0)
    expect(popup.y - anchor.y - anchor.height).toBeLessThanOrEqual(12)
    await page.keyboard.press('Escape')
    await expect(menu).toHaveCount(0)
    await expect(trigger).toBeFocused()
    await trigger.click()
    await page.locator('.pod-page-title').click()
    await expect(menu).toHaveCount(0)
    expect(calls).toBe(0)
    await page.route('**/api/v2/pod/pages', async route => {
      if (route.request().method() !== 'POST') return route.continue()
      calls++
      expect(route.request().postDataJSON().data).toMatchObject({ title: '', type: 'base' })
      expect(route.request().postDataJSON().data.parent_id).toBeUndefined()
      if (calls === 1) {
        return route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: { code: 'creation_unavailable', message: 'Creation unavailable' } })
        })
      }
      await gate.promise
      const response = await route.fetch()
      const body = await response.json()
      created = body.page.id
      await route.fulfill({ response })
    })
    await trigger.click()
    await menu.getByRole('menuitem', { name: '多维表', exact: true }).click()
    await expect(menu).toHaveCount(0)
    await expect(page.getByText('Creation unavailable', { exact: true })).toBeVisible()
    await expect(trigger).toBeEnabled()
    await expect(page).toHaveURL(state.base_url + pageRoute(state.report_id))
    await trigger.focus()
    await trigger.press('Enter')
    await expect(menu.getByRole('menuitem', { name: '文档', exact: true })).toBeFocused()
    await page.keyboard.press('ArrowDown')
    await expect(menu.getByRole('menuitem', { name: '多维表', exact: true })).toBeFocused()
    await page.keyboard.press('Enter')
    await expect.poll(() => calls).toBe(2)
    await expect(menu).toHaveCount(0)
    await expect(trigger).toBeDisabled()
    await expect(trigger).toHaveAttribute('aria-busy', 'true')
    expect(calls).toBe(2)
    gate.resolve()
    await expect(page).not.toHaveURL(state.base_url + pageRoute(state.report_id))
    expect(created).toBeTruthy()
    await expect(page).toHaveURL(state.base_url + pageRoute(created!))
    const title = page.getByRole('textbox', { name: '页面标题', exact: true })
    await expect(title).toHaveValue('')
    const name = `季度销售复盘 ${crypto.randomUUID()}`
    await title.fill(name)
    await title.blur()
    await expect
      .poll(async () => (await request<{ page: { title: string } }>(page, `/pages/${created}`)).page.title)
      .toBe(name)
    await page.reload()
    await expect(title).toHaveValue(name)
    expect(calls).toBe(2)
  } finally {
    gate.resolve()
    if (created) await request(page, `/pages/${created}`, 'DELETE')
    await context.close()
  }
})

test('table and view forms submit with Enter while field and record deletion return focus to Cancel', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let baseID: string | undefined
  try {
    await page.goto(pageRoute(state.report_id))
    const { page: base } = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'base',
      title: `Dialog forms ${crypto.randomUUID()}`
    })
    baseID = base.id
    await page.goto(pageRoute(base.id))
    await page.getByRole('button', { name: '+ 数据表', exact: true }).click()
    const tableName = page.getByRole('textbox', { name: '数据表名称', exact: true })
    await expect(tableName).toBeFocused()
    await tableName.fill('客户台账')
    await tableName.press('Enter')
    await expect(tableName).toHaveCount(0)
    const { tables } = await request<{ tables: BaseTable[] }>(page, `/bases/${base.id}`)
    expect(tables).toHaveLength(2)
    const table = tables.find(table => table.name === '客户台账')!
    expect(table).toBeDefined()
    await page.getByRole('button', { name: '+ 视图', exact: true }).click()
    await page.getByRole('menuitem', { name: '看板', exact: true }).click()
    await page.getByRole('button', { name: '看板', exact: true }).dblclick()
    const viewName = page.getByRole('textbox', { name: '视图名称', exact: true })
    await expect(viewName).toBeFocused()
    await viewName.fill('客户看板')
    await viewName.press('Enter')
    await expect(viewName).toHaveCount(0)
    const schema = await request<TableSchema>(page, `/tables/${table.id}`)
    expect(schema.views.filter(view => view.name === '客户看板' && view.type === 'kanban')).toHaveLength(1)
    const { field } = await request<{ field: BaseField }>(page, `/tables/${table.id}/fields`, 'POST', {
      name: 'Keep field',
      type: 'text',
      config: {}
    })
    const primary = schema.fields.find(field => field.is_primary)!
    await request(page, `/tables/${table.id}/records`, 'POST', { creates: [{ data: { [primary.id]: 'Keep record' } }] })
    await page.reload()
    await page.getByRole('button', { name: '客户台账', exact: true }).click()
    await page.getByRole('button', { name: schema.views.find(view => view.type === 'grid')!.name, exact: true }).click()
    const fieldTrigger = page.getByRole('columnheader').getByRole('button', { name: field.name, exact: true })
    await fieldTrigger.click()
    const fieldDialog = page.getByRole('dialog', { name: '编辑字段', exact: true })
    await fieldDialog.getByRole('button', { name: '删除字段', exact: true }).click()
    const cancelField = fieldDialog.getByRole('button', { name: '取消', exact: true })
    await expect(cancelField).toBeFocused()
    await cancelField.press('Enter')
    await expect(fieldDialog).toBeVisible()
    await expect(fieldDialog.getByRole('button', { name: '确认删除字段', exact: true })).toHaveCount(0)
    expect((await request<TableSchema>(page, `/tables/${table.id}`)).fields.some(item => item.id === field.id)).toBe(
      true
    )
    await cancelField.click()
    await expect(fieldTrigger).toBeFocused()
    await page.getByRole('button', { name: '删除', exact: true }).click()
    const deleteRecord = page.getByRole('dialog', { name: '删除记录？', exact: true })
    const cancelRecord = deleteRecord.getByRole('button', { name: '取消', exact: true })
    await expect(cancelRecord).toBeFocused()
    await cancelRecord.press('Enter')
    await expect(deleteRecord).toHaveCount(0)
    await expect(page.getByRole('textbox', { name: primary.name, exact: true })).toHaveValue('Keep record')
    await page.getByRole('button', { name: '视图操作', exact: true }).click()
    await page.getByRole('menuitem', { name: '删除视图', exact: true }).click()
    const deleteView = page.getByRole('dialog', { name: '删除视图', exact: true })
    await deleteView.getByRole('button', { name: '删除视图', exact: true }).click()
    await expect(deleteView).toBeHidden()
    const remaining = await request<TableSchema>(page, `/tables/${table.id}`)
    expect(remaining.views.map(view => view.name)).toEqual(['客户看板'])
  } finally {
    if (baseID) await request(page, `/pages/${baseID}`, 'DELETE')
    await context.close()
  }
})

test('390px long record and field dialogs scroll their body and keep actions visible; people selection stays anchored', async ({
  browser
}) => {
  const context = await browser.newContext({
    baseURL: state.base_url,
    viewport: { width: 390, height: 620 },
    isMobile: true,
    hasTouch: true
  })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let baseID: string | undefined
  try {
    await page.goto(pageRoute(state.report_id))
    const { page: base } = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'base',
      title: `Mobile forms ${crypto.randomUUID()}`
    })
    baseID = base.id
    const { table } = await request<{ table: BaseTable }>(page, `/bases/${base.id}/tables`, 'POST', {
      name: 'Mobile records'
    })
    for (let index = 1; index <= 16; index++) {
      await request(page, `/tables/${table.id}/fields`, 'POST', { name: `Property ${index}`, type: 'text', config: {} })
    }
    await request(page, `/tables/${table.id}/fields`, 'POST', {
      name: 'Assignee',
      type: 'user',
      config: { multiple: false }
    })
    await request(page, `/tables/${table.id}/fields`, 'POST', {
      name: 'Long select',
      type: 'select',
      config: {
        options: Array.from({ length: 24 }, (_, index) => ({ id: String(index), name: `Option ${index + 1}` }))
      }
    })
    await page.goto(pageRoute(base.id))
    await page.getByRole('button', { name: 'Mobile records', exact: true }).click()
    const fieldTrigger = page.getByRole('columnheader').getByRole('button', { name: 'Long select', exact: true })
    await fieldTrigger.click()
    const fieldDialog = page.getByRole('dialog', { name: '编辑字段', exact: true })
    await inViewport(page, fieldDialog)
    const fieldBody = fieldDialog.locator('.pod-dialog-body')
    expect(await fieldBody.evaluate(element => element.scrollHeight > element.clientHeight)).toBe(true)
    const lastOption = fieldDialog.getByRole('textbox', { name: '选项 24', exact: true })
    await lastOption.scrollIntoViewIfNeeded()
    await expect(lastOption).toBeInViewport({ ratio: 1 })
    expect(await fieldBody.evaluate(element => element.scrollTop)).toBeGreaterThan(0)
    await expect(fieldDialog.getByRole('heading', { name: '编辑字段', exact: true })).toBeInViewport({ ratio: 1 })
    await expect(fieldDialog.getByRole('button', { name: '保存字段', exact: true })).toBeInViewport({ ratio: 1 })
    await fieldDialog.getByRole('button', { name: '取消', exact: true }).click()

    await page.getByRole('button', { name: '新增记录', exact: true }).click()
    const recordDialog = page.getByRole('dialog', { name: '新增记录', exact: true })
    await inViewport(page, recordDialog)
    const body = recordDialog.locator('.pod-dialog-body')
    expect(await body.evaluate(element => element.scrollHeight > element.clientHeight)).toBe(true)
    const lastProperty = recordDialog.getByRole('textbox', { name: 'Property 16', exact: true })
    await lastProperty.scrollIntoViewIfNeeded()
    await expect(lastProperty).toBeInViewport({ ratio: 1 })
    expect(await body.evaluate(element => element.scrollTop)).toBeGreaterThan(0)
    await expect(recordDialog.getByRole('heading', { name: '新增记录', exact: true })).toBeInViewport({ ratio: 1 })
    await expect(recordDialog.getByRole('button', { name: '提交记录', exact: true })).toBeInViewport({ ratio: 1 })
    const people = recordDialog.getByRole('button', { name: 'Assignee: 选择', exact: true })
    await people.scrollIntoViewIfNeeded()
    await people.click()
    await expect(people).toHaveAttribute('aria-expanded', 'true')
    const controlled = await people.getAttribute('aria-controls')
    if (!controlled) throw new Error('People trigger has no controlled popup')
    const picker = page.locator(`[id=${JSON.stringify(controlled)}]`)
    await expect(picker.getByRole('textbox', { name: '搜索候选项', exact: true })).toBeFocused()
    await expect(picker).toBeInViewport({ ratio: 1 })
    const anchor = (await people.boundingBox())!,
      popup = (await picker.boundingBox())!
    expect(
      Math.min(Math.abs(popup.y - anchor.y - anchor.height), Math.abs(anchor.y - popup.y - popup.height))
    ).toBeLessThanOrEqual(12)
    await page.keyboard.press('Escape')
    await expect(picker).toHaveCount(0)
    await expect(recordDialog).toBeVisible()
    await expect(people).toBeFocused()
    await recordDialog.getByRole('button', { name: '取消', exact: true }).click()
  } finally {
    if (baseID) await request(page, `/pages/${baseID}`, 'DELETE')
    await context.close()
  }
})

test('choosing a file creates one named Page with its bytes and replaces it by drag and drop', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto(pageRoute(state.report_id))
    let writes = 0
    page.on('request', request => {
      if (request.method() === 'POST' && new URL(request.url()).pathname === '/api/v2/pod/file-pages') writes++
    })
    const trigger = page.locator('.pod-sidebar-top').getByRole('button', { name: '新建页面', exact: true })
    await trigger.click()
    const chosen = page.waitForEvent('filechooser')
    await page.getByRole('menuitem', { name: '文件', exact: true }).click()
    const chooser = await chosen
    expect(writes).toBe(0)
    const created = page.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/file-pages'
    )
    const original = Buffer.from('First uploaded report')
    await chooser.setFiles({ name: 'Quarterly report.txt', mimeType: 'text/plain', buffer: original })
    const response = await created
    expect(response.ok()).toBe(true)
    id = (await response.json()).page.id
    await expect(page).toHaveURL(state.base_url + pageRoute(id!))
    const title = page.getByRole('textbox', { name: '页面标题', exact: true })
    await expect(title).toHaveValue('Quarterly report.txt')
    const download = page.getByRole('link', { name: '下载原文件', exact: true })
    expect(await (await page.request.get((await download.getAttribute('href'))!)).body()).toEqual(original)
    expect(writes).toBe(1)
    await title.fill('Renamed report')
    await expect
      .poll(async () => (await request<{ page: { title: string } }>(page, `/pages/${id}`)).page.title)
      .toBe('Renamed report')
    const transfer = await page.evaluateHandle(() => {
      const data = new DataTransfer()
      data.items.add(new File(['Updated report'], 'Revised.txt', { type: 'text/plain' }))
      return data
    })
    await download.locator('xpath=ancestor::section[1]').dispatchEvent('drop', { dataTransfer: transfer })
    await expect(download).toHaveAttribute('download', 'Revised.txt')
    expect(await (await page.request.get((await download.getAttribute('href'))!)).text()).toBe('Updated report')
    await expect(title).toHaveValue('Renamed report')
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})
