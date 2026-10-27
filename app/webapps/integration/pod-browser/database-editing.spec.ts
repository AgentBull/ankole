import { state, requestWithSharingVersion as request } from './fixtures'
import { pageRoute } from './routes'
import { expect, test, type Page } from '@playwright/test'
import type { BaseField, BaseRecord, BaseView, RecordsResult, TableSchema } from '@ankole/applet-sdk/types'

const location = (id: string) => `${state.base_url}${pageRoute(id)}`

async function base(page: Page, title: string) {
  await page.goto(location(state.report_id))
  const { page: saved } = await request<{ page: { id: string } }>(page, '/pages', 'POST', { type: 'base', title })
  const { table } = await request<{ table: { id: string } }>(page, `/bases/${saved.id}/tables`, 'POST', {
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

test('the primary field can be renamed while its text type stays fixed', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let pageID: string | undefined
  try {
    const saved = await base(page, 'Primary field')
    pageID = saved.pageID
    await page.goto(location(saved.pageID))
    await page.getByRole('button', { name: 'Responses', exact: true }).click()
    await page.getByRole('button', { name: saved.primary.name, exact: true }).click()
    const dialog = page.getByRole('dialog')
    await expect(dialog.getByRole('combobox', { name: '字段类型', exact: true })).toBeDisabled()
    await dialog.getByRole('textbox', { name: '字段名称', exact: true }).fill('Title')
    await dialog.getByRole('button', { name: '保存字段', exact: true }).click()
    await expect(dialog).not.toBeVisible()
    const schema = await request<TableSchema>(page, `/tables/${saved.tableID}`)
    expect(schema.fields.find(field => field.is_primary)).toMatchObject({ name: 'Title', type: 'text' })
  } finally {
    if (pageID) await request(page, `/pages/${pageID}`, 'DELETE').catch(() => {})
    await context.close()
  }
})

for (const mode of ['inline', 'physical'] as const) {
  test(`a lost ${mode} create response can be retried without creating a second record`, async ({ browser }) => {
    const context = await browser.newContext()
    await context.addCookies(state.owner.cookies)
    const page = await context.newPage()
    let pageID: string | undefined
    try {
      const saved = await base(page, `Lost ${mode} response`)
      pageID = saved.pageID
      if (mode === 'physical') {
        await request(page, `/tables/${saved.tableID}/fields`, 'POST', {
          name: 'Related',
          type: 'link',
          config: { table_id: saved.tableID }
        })
      }
      await page.goto(location(saved.pageID))
      await page.getByRole('button', { name: 'Responses', exact: true }).click()
      await page.getByRole('button', { name: '新增记录', exact: true }).click()
      const dialog = page.getByRole('dialog', { name: '新增记录', exact: true })
      const name = dialog.getByRole('textbox', { name: saved.primary.name, exact: true })
      await name.fill('One order')
      const recordsURL = `**/api/v2/pod/tables/${saved.tableID}/records`
      let firstID = ''
      await page.route(
        recordsURL,
        async route => {
          firstID = route.request().postDataJSON().data.creates[0].id
          const response = await route.fetch()
          expect(response.ok()).toBe(true)
          await route.abort('connectionfailed')
        },
        { times: 1 }
      )
      await dialog.getByRole('button', { name: '提交记录', exact: true }).click()
      await expect(dialog.getByRole('alert')).toBeVisible()
      await expect(name).toHaveValue('One order')
      const committed = await request<RecordsResult>(page, `/tables/${saved.tableID}/query`, 'POST', {})
      expect(committed.records).toHaveLength(1)
      expect(committed.records[0]!.id).toBe(firstID)

      const retry = page.waitForResponse(response => response.url().endsWith(`/tables/${saved.tableID}/records`))
      await dialog.getByRole('button', { name: '提交记录', exact: true }).click()
      const response = await retry
      const rows = await request<RecordsResult>(page, `/tables/${saved.tableID}/query`, 'POST', {})
      expect(rows.records).toEqual(committed.records)
      expect(response.status()).toBe(409)
      expect(response.request().postDataJSON().data.creates[0].id).toBe(firstID)
      await expect(dialog.getByRole('alert')).toContainText('此记录已存在。请关闭表单并查看已保存的记录。')
      await dialog.getByRole('button', { name: '取消', exact: true }).click()
      await expect(page.locator(`[data-grid-record="${firstID}"]`)).toBeVisible()
    } finally {
      if (pageID) await request(page, `/pages/${pageID}`, 'DELETE').catch(() => {})
      await context.close()
    }
  })
}

test('an upload transport failure releases the edit snapshot before the next attachment change', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let pageID: string | undefined
  try {
    const saved = await base(page, 'Attachment upload recovery')
    pageID = saved.pageID
    const { field } = await request<{ field: BaseField }>(page, `/tables/${saved.tableID}/fields`, 'POST', {
      name: 'Evidence',
      type: 'attachment',
      config: {}
    })
    const { records } = await request<{ records: BaseRecord[] }>(page, `/tables/${saved.tableID}/records`, 'POST', {
      creates: [{ data: { [saved.primary.id]: 'Before upload', [field.id]: [] } }]
    })
    const record = records[0]!
    await page.goto(location(saved.pageID))
    await page.getByRole('button', { name: 'Responses', exact: true }).click()
    const row = page.locator(`[data-grid-record="${record.id}"]`)
    const file = row.getByLabel('添加附件', { exact: true })
    const uploadURL = `**/api/v2/pod/pages/${saved.pageID}/files`
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
    const saved = await base(page, 'Record response recovery')
    const { field: attachment } = await request<{ field: BaseField }>(page, `/tables/${saved.tableID}/fields`, 'POST', {
      name: 'Evidence',
      type: 'attachment',
      config: {}
    })
    await page.goto(location(saved.pageID))
    await page.getByRole('button', { name: 'Responses', exact: true }).click()
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
    await page.route(`**/api/v2/pod/tables/${saved.tableID}/records`, async route => {
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
    console.log('ROOT VALUE', await page.locator('.pod-base').innerText())
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
    await page.route(`**/api/v2/pod/pages/${saved.pageID}/files`, async route => {
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
    const saved = await base(page, 'Record lifecycle confirmation')
    await request(page, `/tables/${saved.tableID}/records`, 'POST', {
      creates: [{ data: { [saved.primary.id]: 'Keep until confirmed' } }]
    })
    await page.goto(location(saved.pageID))
    await page.getByRole('button', { name: 'Responses', exact: true }).click()
    await page.getByRole('button', { name: '删除', exact: true }).click()
    const confirmation = page.getByRole('dialog', { name: '删除记录？', exact: true })
    await expect(confirmation).toContainText('无法从页面回收站恢复')
    await confirmation.getByRole('button', { name: '取消', exact: true }).click()
    await expect(page.getByRole('textbox', { name: saved.primary.name, exact: true })).toHaveValue(
      'Keep until confirmed'
    )
    await page.getByRole('button', { name: '字段', exact: true }).click()
    await expect(page.getByRole('checkbox', { name: saved.primary.name, exact: true })).toBeDisabled()
    await page.keyboard.press('Escape')
    await page.getByRole('button', { name: '记录详情', exact: true }).click()
    const details = page.getByRole('dialog', { name: '记录详情', exact: true })
    await expect(details.getByRole('textbox', { name: saved.primary.name, exact: true })).toHaveValue(
      'Keep until confirmed'
    )
    await details.getByRole('button', { name: '关闭', exact: true }).last().click()
    await expect(details).toHaveCount(0)
    let fail = true
    const gate = Promise.withResolvers<void>(),
      started = Promise.withResolvers<void>()
    release = () => gate.resolve()
    await page.route(`**/api/v2/pod/tables/${saved.tableID}/records`, async route => {
      if (route.request().postDataJSON().data.deletes && fail) {
        fail = false
        await route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'Deletion unavailable' })
        })
      } else if (route.request().postDataJSON().data.creates) {
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
    const saved = await base(page, 'Shared view settings')
    const { field } = await request<{ field: BaseField }>(page, `/tables/${saved.tableID}/fields`, 'POST', {
      name: 'State',
      type: 'select',
      config: { options: [{ id: 'todo', name: 'To do' }] }
    })
    const { view } = await request<{ view: BaseView }>(page, `/tables/${saved.tableID}/views`, 'POST', {
      name: 'Board',
      type: 'kanban',
      config: {}
    })
    await page.goto(location(saved.pageID))
    await page.getByRole('button', { name: 'Responses', exact: true }).click()
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
    await page.getByRole('button', { name: 'Responses', exact: true }).click()
    await page.getByRole('button', { name: 'Board updated elsewhere', exact: true }).click()
    await expect(page.getByRole('combobox', { name: '选择分组字段', exact: true })).toContainText('State')
    await choose(page, '选择分组字段', saved.primary.name)
    await page.getByRole('button', { name: '放弃视图更改', exact: true }).click()
    await expect(page.getByRole('combobox', { name: '选择分组字段', exact: true })).toContainText('State')
  } finally {
    await context.close()
  }
})

test('a single relation uses one selection and closes while multiple relations keep their choices open', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let pageID: string | undefined
  try {
    const saved = await base(page, 'Relation choices')
    pageID = saved.pageID
    const { table: target } = await request<{ table: { id: string } }>(page, `/bases/${pageID}/tables`, 'POST', {
      name: 'Projects'
    })
    const targetSchema = await request<TableSchema>(page, `/tables/${target.id}`)
    const title = targetSchema.fields.find(field => field.is_primary)!
    const { records: projects } = await request<RecordsResult>(page, `/tables/${target.id}/records`, 'POST', {
      creates: [{ data: { [title.id]: 'Alpha' } }, { data: { [title.id]: 'Beta' } }]
    })
    const alpha = projects.find(record => record.data[title.id] === 'Alpha')!
    const beta = projects.find(record => record.data[title.id] === 'Beta')!
    const single = (
      await request<{ field: BaseField }>(page, `/tables/${saved.tableID}/fields`, 'POST', {
        name: 'Project',
        type: 'link',
        config: { table_id: target.id, multiple: false }
      })
    ).field
    const multiple = (
      await request<{ field: BaseField }>(page, `/tables/${saved.tableID}/fields`, 'POST', {
        name: 'Projects',
        type: 'link',
        config: { table_id: target.id, multiple: true }
      })
    ).field
    const { records } = await request<RecordsResult>(page, `/tables/${saved.tableID}/records`, 'POST', {
      creates: [{ data: { [saved.primary.id]: 'Work item' } }]
    })
    const recordID = records[0]!.id
    const values = async () =>
      (await request<RecordsResult>(page, `/tables/${saved.tableID}/query`, 'POST', { ids: [recordID] })).records[0]!
        .data
    await page.goto(location(pageID))
    await page.getByRole('button', { name: 'Responses', exact: true }).click()
    const row = page.locator(`[data-grid-record="${recordID}"]`)
    await row.getByRole('button', { name: /^Project:/ }).click()
    await expect(page.getByRole('radiogroup', { name: 'Project', exact: true })).toBeVisible()
    await page.screenshot({ path: test.info().outputPath('single-relation-picker.png') })
    await page
      .getByRole('radiogroup', { name: 'Project', exact: true })
      .getByRole('radio', { name: 'Alpha', exact: true })
      .click()
    await expect(page.getByRole('radiogroup')).toHaveCount(0)
    await expect.poll(async () => (await values())[single.id]).toEqual([alpha.id])
    await row.getByRole('button', { name: /^Project:/ }).click()
    await page.getByRole('radio', { name: 'Beta', exact: true }).click()
    await expect.poll(async () => (await values())[single.id]).toEqual([beta.id])
    await row.getByRole('button', { name: /^Project:/ }).click()
    await page.getByRole('button', { name: '清除', exact: true }).click()
    await expect.poll(async () => (await values())[single.id]).toBeUndefined()
    await expect(row.getByRole('button', { name: /^Project:/ })).toContainText('选择')
    await row.getByRole('button', { name: /^Projects:/ }).click()
    await page.getByRole('checkbox', { name: 'Alpha', exact: true }).check()
    await expect(page.getByRole('checkbox', { name: 'Beta', exact: true })).toBeVisible()
    await expect.poll(async () => (await values())[multiple.id]).toEqual([alpha.id])
    await page.getByRole('checkbox', { name: 'Beta', exact: true }).check()
    await expect.poll(async () => (await values())[multiple.id]).toEqual([alpha.id, beta.id])
    await page.getByRole('button', { name: '完成', exact: true }).click()
    await expect(page.getByRole('checkbox', { name: 'Alpha', exact: true })).toHaveCount(0)
    await page.getByRole('button', { name: '筛选与排序', exact: true }).click()
    await page.getByRole('button', { name: '添加筛选条件', exact: true }).click()
    await choose(page, '筛选字段', 'Projects')
    await page
      .getByRole('dialog')
      .getByRole('button', { name: /^Projects:/ })
      .click()
    await page
      .getByRole('radiogroup', { name: 'Projects', exact: true })
      .getByRole('radio', { name: 'Beta', exact: true })
      .click()
    await expect(page.getByRole('radiogroup')).toHaveCount(0)
    await page.getByRole('button', { name: '应用', exact: true }).click()
    await page.getByRole('button', { name: '为所有人保存视图', exact: true }).click()
    await expect
      .poll(async () => (await request<TableSchema>(page, `/tables/${saved.tableID}`)).views[0]!.config.filter)
      .toMatchObject({
        conditions: [{ field_id: multiple.id, operator: 'contains', value: beta.id }]
      })
  } finally {
    if (pageID) await request(page, `/pages/${pageID}`, 'DELETE').catch(() => {})
    await context.close()
  }
})

for (const type of ['kanban', 'gallery'] as const) {
  test(`${type} cards show the fields selected for the view without a four-field cutoff`, async ({ browser }) => {
    const context = await browser.newContext()
    await context.addCookies(state.owner.cookies)
    const page = await context.newPage()
    let pageID: string | undefined
    try {
      const saved = await base(page, 'Card field choices')
      pageID = saved.pageID
      const fields: BaseField[] = []
      for (let index = 1; index <= 6; index++) {
        fields.push(
          (
            await request<{ field: BaseField }>(page, `/tables/${saved.tableID}/fields`, 'POST', {
              name: `Detail ${index}`,
              type: 'text'
            })
          ).field
        )
      }
      const stage = (
        await request<{ field: BaseField }>(page, `/tables/${saved.tableID}/fields`, 'POST', {
          name: 'Stage',
          type: 'select',
          config: { options: [{ id: 'open', name: 'Open' }] }
        })
      ).field
      await request(page, `/tables/${saved.tableID}/records`, 'POST', {
        creates: [
          {
            data: {
              [saved.primary.id]: 'Visible record',
              [stage.id]: 'open',
              ...Object.fromEntries(fields.map((field, index) => [field.id, `Value ${index + 1}`]))
            }
          }
        ]
      })
      await request(page, `/tables/${saved.tableID}/views`, 'POST', {
        name: 'Chosen cards',
        type,
        config: { group_field_id: stage.id, visible_fields: [fields[5]!.id] }
      })
      await page.goto(location(pageID))
      await page.getByRole('button', { name: 'Responses', exact: true }).click()
      await page.getByRole('button', { name: 'Chosen cards', exact: true }).click()
      const card = page.locator('.pod-base-workspace article')
      await expect(card).toHaveCount(1)
      await expect(card).toContainText('Value 6')
      await expect(card).not.toContainText('Value 1')
      await page.getByRole('button', { name: '字段', exact: true }).click()
      await expect(page.getByRole('checkbox', { name: saved.primary.name, exact: true })).toBeChecked()
      await expect(page.getByRole('checkbox', { name: saved.primary.name, exact: true })).toBeDisabled()
      await page.getByRole('checkbox', { name: 'Detail 1', exact: true }).check()
      await page.getByRole('checkbox', { name: 'Detail 6', exact: true }).uncheck()
      await page.keyboard.press('Escape')
      await expect(card).toContainText('Value 1')
      await expect(card).not.toContainText('Value 6')
      await card.getByRole('button', { name: 'Visible record', exact: true }).click()
      const details = page.getByRole('dialog', { name: '记录详情', exact: true })
      await expect(details.getByRole('textbox', { name: 'Detail 6', exact: true })).toHaveValue('Value 6')
      await details.getByRole('button', { name: '关闭', exact: true }).last().click()
    } finally {
      if (pageID) await request(page, `/pages/${pageID}`, 'DELETE').catch(() => {})
      await context.close()
    }
  })
}

test('a new board immediately groups by an existing single-choice field', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let pageID: string | undefined
  try {
    const saved = await base(page, 'Ready board')
    pageID = saved.pageID
    const { field } = await request<{ field: BaseField }>(page, `/tables/${saved.tableID}/fields`, 'POST', {
      name: 'Stage',
      type: 'select',
      config: { options: [{ id: 'open', name: 'Open' }] }
    })
    await request(page, `/tables/${saved.tableID}/records`, 'POST', {
      creates: [{ data: { [saved.primary.id]: 'Ready item', [field.id]: 'open' } }]
    })
    await page.goto(location(pageID))
    await page.getByRole('button', { name: 'Responses', exact: true }).click()
    await page.getByRole('button', { name: '+ 视图', exact: true }).click()
    await page.getByRole('menuitem', { name: '看板', exact: true }).click()
    await expect(page.getByRole('combobox', { name: '选择分组字段', exact: true })).toContainText('Stage')
    await expect(page.getByRole('heading', { name: 'Open 1', exact: true })).toBeVisible()
    await expect(page.locator('.pod-base-workspace article')).toContainText('Ready item')
    const schema = await request<TableSchema>(page, `/tables/${saved.tableID}`)
    expect(schema.views.find(view => view.type === 'kanban')?.config.group_field_id).toBe(field.id)
  } finally {
    if (pageID) await request(page, `/pages/${pageID}`, 'DELETE').catch(() => {})
    await context.close()
  }
})

test('board filtering starts at the first page of its matching records', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let pageID: string | undefined
  try {
    const saved = await base(page, 'Board query navigation')
    pageID = saved.pageID
    const { field } = await request<{ field: BaseField }>(page, `/tables/${saved.tableID}/fields`, 'POST', {
      name: 'Stage',
      type: 'select',
      config: {
        options: [
          { id: 'open', name: 'Open' },
          { id: 'closed', name: 'Closed' }
        ]
      }
    })
    for (let start = 0; start < 2001; start += 200) {
      await request(page, `/tables/${saved.tableID}/records`, 'POST', {
        creates: Array.from({ length: Math.min(200, 2001 - start) }, (_, offset) => {
          const index = start + offset
          return {
            data: {
              [saved.primary.id]: `${index < 20 ? 'Match' : 'Other'} ${String(index).padStart(4, '0')}`,
              [field.id]: index < 121 ? 'open' : 'closed'
            }
          }
        })
      })
    }
    const schema = await request<{ mode: string }>(page, `/tables/${saved.tableID}`)
    expect(schema.mode).toBe('remote')
    await request(page, `/tables/${saved.tableID}/views`, 'POST', {
      name: 'Paged board',
      type: 'kanban',
      config: { group_field_id: field.id, sort: [{ field_id: saved.primary.id, direction: 'asc' }] }
    })
    await page.goto(location(pageID))
    await page.getByRole('button', { name: 'Responses', exact: true }).click()
    await page.getByRole('button', { name: 'Paged board', exact: true }).click()
    const column = page
      .locator('.pod-base-workspace section')
      .filter({ has: page.getByRole('heading', { name: /^Open / }) })
    await expect(column.getByRole('button', { name: '下一页', exact: true })).toBeEnabled()
    await column.getByRole('button', { name: '下一页', exact: true }).click()
    await expect(column.getByRole('button', { name: '上一页', exact: true })).toBeEnabled()
    await expect(column.locator('article')).toHaveCount(21)
    await page.getByRole('button', { name: /^筛选与排序/ }).click()
    await page.getByRole('button', { name: '添加筛选条件', exact: true }).click()
    await choose(page, '筛选条件', '包含文字')
    await page.getByRole('dialog').getByRole('textbox', { name: saved.primary.name, exact: true }).fill('Match')
    await page.getByRole('button', { name: '应用', exact: true }).click()
    await expect(column.locator('article')).toHaveCount(20)
    await expect(column).toContainText('Match 0000')
    await expect(column.getByRole('button', { name: '上一页', exact: true })).toHaveCount(0)
  } finally {
    if (pageID) await request(page, `/pages/${pageID}`, 'DELETE').catch(() => {})
    await context.close()
  }
})
