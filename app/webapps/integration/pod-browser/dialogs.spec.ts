import { readFileSync } from 'node:fs'
import { expect, test, type BrowserContext, type Locator, type Page } from '@playwright/test'
import type { DatabaseField, DatabaseTable, TableSchema } from '@ankole/applet-sdk/types'
import { pageRoute } from './routes'

const state = JSON.parse(readFileSync(process.env.POD_BROWSER_STATE_PATH!, 'utf8')) as {
  base_url: string
  report_id: string
  owner: { uid: string; cookies: Parameters<BrowserContext['addCookies']>[0] }
}

async function request<T>(page: Page, path: string, method = 'GET', body?: unknown): Promise<T> {
  return page.evaluate(
    async ({ path, method, body }) => {
      const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content ?? ''
      const response = await fetch(`/.internal-apis/pod${path}`, {
        method,
        credentials: 'same-origin',
        headers: {
          accept: 'application/json',
          'content-type': 'application/json',
          'x-ankole-authentication': meta('ankole-authentication'),
          'x-ankole-pod': meta('ankole-pod'),
          'x-csrf-token': meta('csrf-token')
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) })
      })
      if (!response.ok) throw new Error(`${method} ${path}: ${response.status} ${await response.text()}`)
      return response.status === 204 ? null : response.json()
    },
    { path, method, body }
  )
}

async function choose(page: Page, trigger: Locator, option: string) {
  await trigger.click()
  await expect(trigger).toHaveAttribute('aria-expanded', 'true')
  const id = await trigger.getAttribute('aria-controls')
  if (!id) throw new Error('The selection has no popup')
  await page
    .locator(`[id=${JSON.stringify(id)}]`)
    .getByRole('option', { name: option, exact: true })
    .click()
  await expect(trigger).toHaveAttribute('aria-expanded', 'false')
}

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

test('sidebar creation focuses its title, keeps failed Chinese text and type, and submits one real Page with Enter', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const gate = Promise.withResolvers<void>()
  const started = Promise.withResolvers<void>()
  let created: string | undefined
  let calls = 0
  try {
    await page.goto(pageRoute(state.report_id))
    await page.locator('.pod-workspace-row').getByRole('button', { name: '新建页面', exact: true }).click()
    const dialog = page.getByRole('dialog', { name: '新建页面', exact: true })
    const title = dialog.getByRole('textbox', { name: '标题', exact: true })
    await expect(title).toBeFocused()
    const name = `季度销售复盘 ${crypto.randomUUID()}`
    await page.keyboard.insertText(name)
    const type = dialog.getByRole('combobox', { name: '页面类型', exact: true })
    await choose(page, type, 'Database')
    await page.route('**/.internal-apis/pod/pages', async route => {
      if (route.request().method() !== 'POST') return route.continue()
      calls++
      expect(route.request().postDataJSON()).toMatchObject({ title: name, type: 'database' })
      expect(route.request().postDataJSON().parent_id).toBeUndefined()
      if (calls === 1)
        return route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: { code: 'creation_unavailable', message: 'Creation unavailable' } })
        })
      started.resolve()
      await gate.promise
      const response = await route.fetch()
      const body = await response.json()
      created = body.page.id
      await route.fulfill({ response })
    })
    await title.press('Enter')
    await expect(dialog.getByText('Creation unavailable', { exact: true })).toBeVisible()
    await expect(title).toHaveValue(name)
    await expect(type).toHaveText('Database')
    await expect(page).toHaveURL(state.base_url + pageRoute(state.report_id))
    await title.press('Enter')
    await started.promise
    await expect(title).toBeDisabled()
    await expect(type).toBeDisabled()
    await expect(dialog.getByRole('button', { name: '关闭', exact: true })).toHaveCount(0)
    await page.keyboard.press('Escape')
    await expect(dialog).toBeVisible()
    await expect(dialog.getByRole('button', { name: '取消', exact: true })).toBeDisabled()
    expect(calls).toBe(2)
    gate.resolve()
    await expect(dialog).toHaveCount(0)
    expect(created).toBeTruthy()
    await expect(page).toHaveURL(state.base_url + pageRoute(created!))
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(name)
    await page.reload()
    await expect(page).toHaveURL(state.base_url + pageRoute(created!))
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(name)
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
  let databaseID: string | undefined
  try {
    await page.goto(pageRoute(state.report_id))
    const { page: database } = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'database',
      title: `Dialog forms ${crypto.randomUUID()}`
    })
    databaseID = database.id
    await page.goto(pageRoute(database.id))
    await page.getByRole('button', { name: '+ 数据表', exact: true }).click()
    const tableDialog = page.getByRole('dialog', { name: '新建数据表', exact: true })
    const tableName = tableDialog.getByRole('textbox', { name: '数据表名称', exact: true })
    await expect(tableName).toBeFocused()
    await tableName.fill('客户台账')
    await tableName.press('Enter')
    await expect(tableDialog).toHaveCount(0)
    const { tables } = await request<{ tables: DatabaseTable[] }>(page, `/databases/${database.id}`)
    expect(tables).toHaveLength(1)
    expect(tables[0]!.name).toBe('客户台账')
    const table = tables[0]!
    await page.getByRole('button', { name: '+ 视图', exact: true }).click()
    const viewDialog = page.getByRole('dialog', { name: '新建视图', exact: true })
    const viewName = viewDialog.getByRole('textbox', { name: '视图名称', exact: true })
    await expect(viewName).toBeFocused()
    await viewName.fill('客户看板')
    await choose(page, viewDialog.getByRole('combobox', { name: '视图类型', exact: true }), '看板')
    await viewName.press('Enter')
    await expect(viewDialog).toHaveCount(0)
    const schema = await request<TableSchema>(page, `/tables/${table.id}`)
    expect(schema.views.filter(view => view.name === '客户看板' && view.type === 'kanban')).toHaveLength(1)
    const { field } = await request<{ field: DatabaseField }>(page, `/tables/${table.id}/fields`, 'POST', {
      name: 'Keep field',
      type: 'text',
      config: {}
    })
    const primary = schema.fields.find(field => field.is_primary)!
    await request(page, `/tables/${table.id}/records`, 'POST', { creates: [{ data: { [primary.id]: 'Keep record' } }] })
    await page.reload()
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
  } finally {
    if (databaseID) await request(page, `/pages/${databaseID}`, 'DELETE')
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
  let databaseID: string | undefined
  try {
    await page.goto(pageRoute(state.report_id))
    const { page: database } = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'database',
      title: `Mobile forms ${crypto.randomUUID()}`
    })
    databaseID = database.id
    const { table } = await request<{ table: DatabaseTable }>(page, `/databases/${database.id}/tables`, 'POST', {
      name: 'Mobile records'
    })
    for (let index = 1; index <= 16; index++)
      await request(page, `/tables/${table.id}/fields`, 'POST', { name: `Property ${index}`, type: 'text', config: {} })
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
    await page.goto(pageRoute(database.id))
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
    const people = recordDialog.getByRole('button', { name: 'Assignee： 选择', exact: true })
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
    if (databaseID) await request(page, `/pages/${databaseID}`, 'DELETE')
    await context.close()
  }
})
