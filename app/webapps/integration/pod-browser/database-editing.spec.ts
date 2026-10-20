import { state, requestWithSharingVersion as request } from './fixtures'
import { pageRoute } from './routes'
import { expect, test, type Page } from '@playwright/test'
import type { DatabaseField, DatabaseRecord, DatabaseView, RecordsResult, TableSchema } from '@ankole/applet-sdk/types'

const location = (id: string) => `${state.base_url}${pageRoute(id)}`

async function database(page: Page, title: string) {
  await page.goto(location(state.report_id))
  const { page: saved } = await request<{ page: { id: string } }>(page, '/pages', 'POST', { type: 'database', title })
  const { table } = await request<{ table: { id: string } }>(page, `/databases/${saved.id}/tables`, 'POST', {
    name: 'Responses'
  })
  const schema = await request<TableSchema>(page, `/tables/${table.id}`)
  const primary = schema.fields.find(field => field.is_primary)!
  return { pageID: saved.id, tableID: table.id, primary, schema }
}

async function choose(page: Page, name: string, option: string) {
  const trigger = page.getByRole('combobox', { name, exact: true })
  await trigger.click()
  await expect(trigger).toHaveAttribute('aria-expanded', 'true')
  const popup = await trigger.getAttribute('aria-controls')
  if (!popup) throw new Error(`Select ${name} has no popup`)
  await page
    .locator(`[id=${JSON.stringify(popup)}]`)
    .getByRole('option', { name: option, exact: true })
    .click()
  await expect(trigger).toHaveAttribute('aria-expanded', 'false')
}

test('an upload transport failure releases the edit snapshot before the next attachment change', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let pageID: string | undefined
  try {
    const saved = await database(page, 'Attachment upload recovery')
    pageID = saved.pageID
    const { field } = await request<{ field: DatabaseField }>(page, `/tables/${saved.tableID}/fields`, 'POST', {
      name: 'Evidence',
      type: 'attachment',
      config: {}
    })
    const { records } = await request<{ records: DatabaseRecord[] }>(page, `/tables/${saved.tableID}/records`, 'POST', {
      creates: [{ data: { [saved.primary.id]: 'Before upload', [field.id]: [] } }]
    })
    const record = records[0]!
    await page.goto(location(saved.pageID))
    const row = page.locator(`[data-grid-record="${record.id}"]`)
    const file = row.getByLabel('添加附件', { exact: true })
    const uploadURL = `**/.internal-apis/pod/pages/${saved.pageID}/files`
    await page.route(uploadURL, route => route.abort('connectionfailed'), { times: 1 })
    await file.setInputFiles({ name: 'interrupted.txt', mimeType: 'text/plain', buffer: Buffer.from('Interrupted') })
    await expect(row.getByRole('alert')).toBeVisible()
    await expect(file).toBeEnabled()

    await request(page, `/tables/${saved.tableID}/records`, 'POST', {
      updates: [
        {
          id: record.id,
          data: { [saved.primary.id]: 'Changed elsewhere', [field.id]: null },
          expected_versions: record.versions
        }
      ]
    })
    await expect(row.getByRole('textbox', { name: saved.primary.name, exact: true })).toHaveValue('Changed elsewhere')
    const current = (await request<RecordsResult>(page, `/tables/${saved.tableID}/query`, 'POST', { ids: [record.id] }))
      .records[0]!
    expect(current.versions[field.id]).not.toBe(record.versions[field.id])

    await file.setInputFiles({
      name: 'recovered.txt',
      mimeType: 'text/plain',
      buffer: Buffer.from('Saved after recovery')
    })
    await expect(row.getByRole('link', { name: 'recovered.txt', exact: true })).toBeVisible()
    await expect(row.getByRole('alert')).toHaveCount(0)
    const result = (await request<RecordsResult>(page, `/tables/${saved.tableID}/query`, 'POST', { ids: [record.id] }))
      .records[0]!
    expect(result.data[field.id]).toEqual([expect.objectContaining({ name: 'recovered.txt' })])
  } finally {
    if (pageID) await request(page, `/pages/${pageID}`, 'DELETE').catch(() => {})
    await context.close()
  }
})

test('new-record dialog retains failed answers, freezes a pending submission, and resets every successful response', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  page.on('console', message => console.log('PAGE', message.text()))
  let release: (() => void) | undefined
  let releaseUpload: (() => void) | undefined
  try {
    const saved = await database(page, 'Record response recovery')
    const { field: attachment } = await request<{ field: DatabaseField }>(
      page,
      `/tables/${saved.tableID}/fields`,
      'POST',
      {
        name: 'Evidence',
        type: 'attachment',
        config: {}
      }
    )
    await page.goto(location(saved.pageID))
    const dialog = () => page.getByRole('dialog', { name: '新增记录', exact: true })
    const open = async () => {
      await page.getByRole('button', { name: '新增记录', exact: true }).click()
      await expect(dialog()).toBeVisible()
    }
    await open()
    const name = dialog().getByRole('textbox', { name: saved.primary.name, exact: true })
    await name.fill('First response')
    await expect(name).toHaveValue('First response')
    let requests = 0
    const started = Promise.withResolvers<void>()
    const gate = Promise.withResolvers<void>()
    release = () => gate.resolve()
    await page.route(`**/.internal-apis/pod/tables/${saved.tableID}/records`, async route => {
      console.log('WRITE BODY', route.request().postData())
      requests++
      if (requests === 1) {
        await route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'Temporarily unavailable' })
        })
      } else if (requests === 2) {
        started.resolve()
        await gate.promise
        await route.continue()
      } else await route.continue()
    })
    await dialog().getByRole('button', { name: '提交记录', exact: true }).click()
    console.log('DIALOGS', await page.getByRole('dialog').count())
    console.log(
      'INPUTS',
      await page.locator('input[aria-label="Name"]').evaluateAll(els => els.map(e => (e as HTMLInputElement).value))
    )
    console.log('ROOT VALUE', await page.locator('.pod-database').innerText())
    await expect(name).toHaveValue('First response')
    await expect(dialog().getByText('Temporarily unavailable', { exact: true })).toBeVisible()
    await expect
      .poll(
        async () => (await request<RecordsResult>(page, `/tables/${saved.tableID}/query`, 'POST', {})).records.length
      )
      .toBe(0)
    await dialog().getByRole('button', { name: '提交记录', exact: true }).click()
    await started.promise
    await expect(name).toBeDisabled()
    await expect(dialog().getByRole('button', { name: '正在提交…', exact: true })).toBeDisabled()
    await name.locator('xpath=ancestor::form').dispatchEvent('submit')
    expect(requests).toBe(2)
    release()
    await expect(dialog()).toHaveCount(0)
    await expect
      .poll(
        async () => (await request<RecordsResult>(page, `/tables/${saved.tableID}/query`, 'POST', {})).records.length
      )
      .toBe(1)
    await open()
    await expect(name).toHaveValue('')
    await name.fill('Second response')
    await dialog().getByRole('button', { name: '提交记录', exact: true }).click()
    await expect(dialog()).toHaveCount(0)
    await expect
      .poll(async () =>
        (await request<RecordsResult>(page, `/tables/${saved.tableID}/query`, 'POST', {})).records
          .map(row => row.data[saved.primary.id])
          .sort()
      )
      .toEqual(['First response', 'Second response'])
    const uploadStarted = Promise.withResolvers<void>(),
      uploadGate = Promise.withResolvers<void>()
    releaseUpload = () => uploadGate.resolve()
    await page.route(`**/.internal-apis/pod/pages/${saved.pageID}/files`, async route => {
      if (route.request().method() !== 'POST') return route.continue()
      uploadStarted.resolve()
      await uploadGate.promise
      await route.continue()
    })
    await open()
    await name.fill('Response with evidence')
    const evidence = Buffer.from('Saved alongside this response.')
    await dialog().getByLabel('添加附件', { exact: true }).setInputFiles({
      name: 'evidence.txt',
      mimeType: 'text/plain',
      buffer: evidence
    })
    await uploadStarted.promise
    await expect(dialog().getByRole('button', { name: '提交记录', exact: true })).toBeDisabled()
    await expect(dialog().getByText('正在上传附件，请稍候再提交。', { exact: true })).toBeVisible()
    await name.locator('xpath=ancestor::form').dispatchEvent('submit')
    // One failed request and two successful creates have already been sent.
    expect(requests).toBe(3)
    uploadGate.resolve()
    await expect(dialog().getByRole('link', { name: 'evidence.txt', exact: true })).toBeVisible()
    await expect(dialog().getByRole('button', { name: '提交记录', exact: true })).toBeEnabled()
    await dialog().getByRole('button', { name: '提交记录', exact: true }).click()
    await expect(dialog()).toHaveCount(0)
    const response = (await request<RecordsResult>(page, `/tables/${saved.tableID}/query`, 'POST', {})).records.find(
      row => row.data[saved.primary.id] === 'Response with evidence'
    )
    expect(response?.data[attachment.id]).toEqual([
      expect.objectContaining({ name: 'evidence.txt', size: evidence.length })
    ])
  } finally {
    release?.()
    releaseUpload?.()
    await context.close()
  }
})

test('record deletion requires confirmation, retains failures, and prevents closing an active create', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let release: (() => void) | undefined
  try {
    const saved = await database(page, 'Record lifecycle confirmation')
    await request(page, `/tables/${saved.tableID}/records`, 'POST', {
      creates: [{ data: { [saved.primary.id]: 'Keep until confirmed' } }]
    })
    await page.goto(location(saved.pageID))
    await page.getByRole('button', { name: '删除', exact: true }).click()
    const confirmation = page.getByRole('dialog', { name: '删除记录？', exact: true })
    await expect(confirmation).toContainText('无法从页面回收站恢复')
    await confirmation.getByRole('button', { name: '取消', exact: true }).click()
    await expect(page.getByRole('textbox', { name: saved.primary.name, exact: true })).toHaveValue(
      'Keep until confirmed'
    )
    let fail = true
    const gate = Promise.withResolvers<void>(),
      started = Promise.withResolvers<void>()
    release = () => gate.resolve()
    await page.route(`**/.internal-apis/pod/tables/${saved.tableID}/records`, async route => {
      if (route.request().postDataJSON().deletes && fail) {
        fail = false
        await route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'Deletion unavailable' })
        })
      } else if (route.request().postDataJSON().creates) {
        started.resolve()
        await gate.promise
        await route.continue()
      } else await route.continue()
    })
    await page.getByRole('button', { name: '删除', exact: true }).click()
    await confirmation.getByRole('button', { name: '确认删除', exact: true }).click()
    await expect(confirmation.getByText('Deletion unavailable', { exact: true })).toBeVisible()
    await confirmation.getByRole('button', { name: '确认删除', exact: true }).click()
    await expect(confirmation).toHaveCount(0)
    await expect(page.getByText('当前视图没有记录。可以调整筛选条件或新增记录。', { exact: true })).toBeVisible()
    await page.getByRole('button', { name: '新增记录', exact: true }).click()
    const create = page.getByRole('dialog', { name: '新增记录', exact: true })
    await create.getByRole('textbox', { name: saved.primary.name, exact: true }).fill('Pending create')
    await create.getByRole('button', { name: '提交记录', exact: true }).click()
    await started.promise
    await expect(create.getByRole('button', { name: '关闭', exact: true })).toHaveCount(0)
    await page.keyboard.press('Escape')
    await expect(create).toBeVisible()
    await expect(create.getByRole('button', { name: '取消', exact: true })).toBeDisabled()
    await expect(create.getByRole('textbox', { name: saved.primary.name, exact: true })).toBeDisabled()
    release()
    await expect(create).toHaveCount(0)
    await expect(page.getByRole('textbox', { name: saved.primary.name, exact: true })).toHaveValue('Pending create')
  } finally {
    release?.()
    await context.close()
  }
})

test('view settings preview locally, save explicitly, and keep the draft on a real version conflict', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    const saved = await database(page, 'Shared view settings')
    const { field } = await request<{ field: DatabaseField }>(page, `/tables/${saved.tableID}/fields`, 'POST', {
      name: 'State',
      type: 'select',
      config: { options: [{ id: 'todo', name: 'To do' }] }
    })
    const { view } = await request<{ view: DatabaseView }>(page, `/tables/${saved.tableID}/views`, 'POST', {
      name: 'Board',
      type: 'kanban',
      config: {}
    })
    await page.goto(location(saved.pageID))
    await expect(page.getByRole('navigation', { name: '数据视图' }).getByRole('button').first()).toHaveText('Grid')
    await expect(page.getByRole('button', { name: 'Grid', exact: true })).toHaveAttribute('aria-pressed', 'true')
    await page.getByRole('button', { name: 'Board', exact: true }).click()
    await choose(page, '选择分组字段', 'State')
    await expect(page.getByRole('button', { name: '为所有人保存视图', exact: true })).toBeVisible()
    expect(
      (await request<TableSchema>(page, `/tables/${saved.tableID}`)).views.find(item => item.id === view.id)?.config
        .group_field_id
    ).toBeUndefined()
    await request(page, `/views/${view.id}`, 'PATCH', { name: 'Board updated elsewhere', version: view.version })
    await page.getByRole('button', { name: '为所有人保存视图', exact: true }).click()
    await expect(page.getByRole('button', { name: '将当前设置保存到最新视图', exact: true })).toBeEnabled()
    await expect(page.getByRole('combobox', { name: '选择分组字段', exact: true })).toContainText('State')
    expect(
      (await request<TableSchema>(page, `/tables/${saved.tableID}`)).views.find(item => item.id === view.id)?.config
        .group_field_id
    ).toBeUndefined()
    await page.getByRole('button', { name: '将当前设置保存到最新视图', exact: true }).click()
    await expect(page.getByText('视图设置尚未保存。', { exact: true })).toHaveCount(0)
    expect(
      (await request<TableSchema>(page, `/tables/${saved.tableID}`)).views.find(item => item.id === view.id)?.config
        .group_field_id
    ).toBe(field.id)
    await page.reload()
    await page.getByRole('button', { name: 'Board updated elsewhere', exact: true }).click()
    await expect(page.getByRole('combobox', { name: '选择分组字段', exact: true })).toContainText('State')
    await choose(page, '选择分组字段', saved.primary.name)
    await page.getByRole('button', { name: '放弃视图更改', exact: true }).click()
    await expect(page.getByRole('combobox', { name: '选择分组字段', exact: true })).toContainText('State')
  } finally {
    await context.close()
  }
})
