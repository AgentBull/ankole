import { state, request } from './fixtures'
import { pageRoute, listRoute } from './routes'
import { expect, test } from '@playwright/test'
import type { BaseField, BaseRecord } from '@ankole/applet-sdk/types'

const location = (id: string) => `${state.base_url}${pageRoute(id)}`

test('a 2,000-row local grid renders a window and preserves an edited row beyond the viewport', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let savedID: string | undefined
  try {
    await page.goto(location(state.report_id))
    const saved = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'base',
      title: 'Virtual grid review'
    })
    savedID = saved.page.id
    const { table } = await request<{ table: { id: string } }>(page, `/bases/${savedID}/tables`, 'POST', {
      name: '2000 records'
    })
    const { fields } = await request<{ fields: BaseField[] }>(page, `/tables/${table.id}`)
    const primary = fields.find(field => field.is_primary)!
    for (let offset = 0; offset < 2000; offset += 200) {
      await request(page, `/tables/${table.id}/records`, 'POST', {
        creates: Array.from({ length: 200 }, (_, index) => ({
          data: { [primary.id]: `Record ${String(offset + index).padStart(4, '0')}` }
        }))
      })
    }
    await page.goto(location(savedID))
    await page.getByRole('button', { name: '2000 records', exact: true }).click()
    await expect(page.getByRole('status').filter({ hasText: '2,000 条记录' })).toBeVisible()
    const grid = page.getByRole('region', { name: '数据表记录', exact: true })
    await expect.poll(() => grid.locator('[data-grid-record]').count()).toBeGreaterThan(0)
    const initialMounted = await grid.locator('[data-grid-record]').count()
    expect(initialMounted).toBeLessThan(100)
    const input = grid.getByRole('textbox', { name: primary.name, exact: true }).first()
    const rowID = await input.locator('xpath=ancestor::tr').getAttribute('data-grid-record')
    await input.fill('Uncommitted review draft')
    await grid.evaluate(element => {
      element.scrollTop = element.scrollHeight
    })
    await expect(grid.locator(`[data-grid-record="${rowID}"]`).getByRole('textbox')).toHaveValue(
      'Uncommitted review draft'
    )
    expect(await grid.locator('[data-grid-record]').count()).toBeLessThan(100)
    await grid.locator(`[data-grid-record="${rowID}"]`).getByRole('textbox').press('Enter')
    await expect
      .poll(async () => {
        const result = await request<{ records: BaseRecord[] }>(page, `/tables/${table.id}/query`, 'POST', {
          ids: [rowID]
        })
        return result.records[0]?.data[primary.id]
      })
      .toBe('Uncommitted review draft')
    await grid.evaluate(element => {
      element.scrollTop = 0
    })
    await expect(grid.getByRole('textbox', { name: primary.name, exact: true }).first()).toHaveValue(
      'Uncommitted review draft'
    )
    const returnedMounted = await grid.locator('[data-grid-record]').count()
    expect(returnedMounted).toBeLessThan(100)
    console.log('2000-row Grid windowing:', JSON.stringify({ total: 2000, initialMounted, returnedMounted }))
  } finally {
    if (savedID) await request(page, `/pages/${savedID}`, 'DELETE').catch(() => {})
    await context.close()
  }
})

test('a document rejoins after a first-token 503 and revocation hides the cached editor', async ({ browser }) => {
  const ownerContext = await browser.newContext(),
    memberContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const owner = await ownerContext.newPage(),
    member = await memberContext.newPage()
  const errors: string[] = []
  member.on('pageerror', error => errors.push(error.message))
  let savedID: string | undefined
  try {
    await owner.goto(location(state.report_id))
    const saved = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      type: 'doc',
      title: 'Document reconnection review'
    })
    savedID = saved.page.id
    let failed = false
    await member.route('**/api/v2/pod/realtime-token', route => {
      if (!failed) {
        failed = true
        return route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'Temporarily unavailable' })
        })
      }
      return route.continue()
    })
    await member.goto(location(savedID))
    await expect.poll(() => failed).toBe(true)
    const editor = member.locator('.editor-content[contenteditable=true]')
    await expect(editor).toBeVisible()
    await editor.click()
    await member.keyboard.type('Recovered after token outage')
    await expect
      .poll(async () => {
        const result = await request<{ content: { content: string } }>(owner, `/pages/${savedID}`)
        return result.content.content
      })
      .toContain('Recovered after token outage')
    const baseline = await request<{ sharing_version: string }>(owner, `/pages/${savedID}/sharing`)
    await request(owner, `/pages/${savedID}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [],
      sharing_version: baseline.sharing_version
    })
    await expect(member.locator('.editor-content')).toHaveCount(0)
    await expect(member.getByRole('alert').first()).toBeVisible()
    expect(errors).toEqual([])
  } finally {
    if (savedID) await request(owner, `/pages/${savedID}`, 'DELETE').catch(() => {})
    await ownerContext.close()
    await memberContext.close()
  }
})

test('prototype-named content scopes cannot crash the Pod shell', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const errors: string[] = []
  page.on('pageerror', error => errors.push(error.message))
  try {
    for (const scope of ['constructor', 'toString', '__proto__']) {
      await page.goto(`${state.base_url}${listRoute(scope)}`)
      await expect(page.getByRole('heading', { name: '空间', exact: true })).toBeVisible()
    }
    expect(errors).toEqual([])
  } finally {
    await context.close()
  }
})

test('link labels are batched by target table and follow target edits', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let savedID: string | undefined
  try {
    await page.goto(location(state.report_id))
    const saved = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'base',
      title: 'Reference batching review'
    })
    savedID = saved.page.id
    const source = (
      await request<{ table: { id: string } }>(page, `/bases/${savedID}/tables`, 'POST', { name: 'Source' })
    ).table
    const target = (
      await request<{ table: { id: string } }>(page, `/bases/${savedID}/tables`, 'POST', { name: 'Target' })
    ).table
    const sourceSchema = await request<{ fields: BaseField[]; views: { id: string; version: number }[] }>(
      page,
      `/tables/${source.id}`
    )
    const sourceName = sourceSchema.fields.find(field => field.is_primary)!
    const targetName = (await request<{ fields: BaseField[] }>(page, `/tables/${target.id}`)).fields.find(
      field => field.is_primary
    )!
    const relation = (
      await request<{ field: BaseField }>(page, `/tables/${source.id}/fields`, 'POST', {
        name: 'Related',
        type: 'link',
        config: { table_id: target.id, multiple: false }
      })
    ).field
    const targets = (
      await request<{ records: BaseRecord[] }>(page, `/tables/${target.id}/records`, 'POST', {
        creates: Array.from({ length: 200 }, (_, index) => ({
          data: { [targetName.id]: `Target ${String(index).padStart(3, '0')}` }
        }))
      })
    ).records
    await request(page, `/tables/${source.id}/records`, 'POST', {
      creates: targets.map(record => ({
        data: { [sourceName.id]: record.data[targetName.id], [relation.id]: [record.id] }
      }))
    })
    await request(page, `/views/${sourceSchema.views[0]!.id}`, 'PATCH', {
      version: sourceSchema.views[0]!.version,
      config: { sort: [{ field_id: sourceName.id, direction: 'asc' }] }
    })
    const targetZero = targets.find(record => record.data[targetName.id] === 'Target 000')!
    let targetQueries = 0
    page.on('request', request => {
      if (new URL(request.url()).pathname === `/api/v2/pod/tables/${target.id}/query`) targetQueries++
    })
    await page.goto(location(savedID))
    await page.getByRole('button', { name: 'Source', exact: true }).click()
    await expect(page.getByRole('button', { name: 'Related： Target 000', exact: true })).toBeVisible()
    expect(targetQueries).toBeLessThanOrEqual(4)
    await request(page, `/tables/${target.id}/records`, 'POST', {
      updates: [
        { id: targetZero.id, data: { [targetName.id]: 'Renamed target' }, expected_versions: targetZero.versions }
      ]
    })
    await expect(page.getByRole('button', { name: 'Related： Renamed target', exact: true })).toBeVisible()
    expect(targetQueries).toBeLessThanOrEqual(6)
  } finally {
    if (savedID) await request(page, `/pages/${savedID}`, 'DELETE').catch(() => {})
    await context.close()
  }
})

test('sharing conflicts retain the draft until an explicit latest-version retry', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let savedID: string | undefined
  try {
    await page.goto(location(state.report_id))
    const saved = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'doc',
      title: 'Sharing conflict review'
    })
    savedID = saved.page.id
    await page.goto(location(savedID))
    await page.getByRole('button', { name: '分享', exact: true }).click()
    const dialog = page.getByRole('dialog', { name: '分享页面', exact: true })
    const inherit = dialog.getByRole('checkbox')
    await expect(inherit).toBeChecked()
    await inherit.uncheck()
    const baseline = await request<{ sharing_version: string; grants: unknown[] }>(page, `/pages/${savedID}/sharing`)
    await request(page, `/pages/${savedID}/sharing`, 'PUT', {
      inherit_permissions: true,
      grants: [{ principal_uid: state.member.uid, role: 'view' }],
      sharing_version: baseline.sharing_version
    })
    await dialog.getByRole('button', { name: '保存分享设置', exact: true }).click()
    await expect(dialog.getByRole('alert')).toContainText('分享设置已由其他人修改')
    await expect(inherit).not.toBeChecked()
    const unchanged = await request<{ inherit_permissions: boolean; grants: unknown[] }>(
      page,
      `/pages/${savedID}/sharing`
    )
    expect(unchanged.inherit_permissions).toBe(true)
    expect(unchanged.grants).toHaveLength(1)
    await dialog.getByRole('button', { name: '保留我的设置并读取最新版本', exact: true }).click()
    await expect(dialog.getByRole('status')).toContainText('已读取最新版本')
    await expect(inherit).not.toBeChecked()
    await dialog.getByRole('button', { name: '保存分享设置', exact: true }).click()
    await expect(dialog).toHaveCount(0)
    const confirmed = await request<{
      inherit_permissions: boolean
      grants: { principal_uid: string | null; role: string }[]
    }>(page, `/pages/${savedID}/sharing`)
    expect(confirmed.inherit_permissions).toBe(false)
    // Disabling inheritance retains the actor's manage access in the domain.
    expect(confirmed.grants.map(({ principal_uid, role }) => ({ principal_uid, role }))).toEqual([
      { principal_uid: state.owner.uid, role: 'manage' }
    ])
  } finally {
    if (savedID) await request(page, `/pages/${savedID}`, 'DELETE').catch(() => {})
    await context.close()
  }
})

test('a large realtime delta crosses the local byte threshold and uses the server fallback', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let savedID: string | undefined
  try {
    await page.goto(location(state.report_id))
    const saved = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'base',
      title: 'Local byte threshold review'
    })
    savedID = saved.page.id
    const { table } = await request<{ table: { id: string } }>(page, `/bases/${savedID}/tables`, 'POST', {
      name: 'Large values'
    })
    const schema = await request<{ fields: BaseField[]; views: { id: string; version: number }[] }>(
      page,
      `/tables/${table.id}`
    )
    const primary = schema.fields.find(field => field.is_primary)!
    const { field } = await request<{ field: BaseField }>(page, `/tables/${table.id}/fields`, 'POST', {
      name: 'Payload',
      type: 'text',
      config: {}
    })
    await request(page, `/views/${schema.views[0]!.id}`, 'PATCH', {
      version: schema.views[0]!.version,
      config: { visible_fields: [primary.id], sort: [{ field_id: primary.id, direction: 'asc' }] }
    })
    const { records } = await request<{ records: BaseRecord[] }>(page, `/tables/${table.id}/records`, 'POST', {
      creates: Array.from({ length: 5 }, (_, index) => ({
        data: { [primary.id]: `Large ${index}`, [field.id]: 'x'.repeat(820_000) }
      }))
    })
    let remoteQueries = 0
    page.on('response', response => {
      if (new URL(response.url()).pathname !== `/api/v2/pod/tables/${table.id}/query`) return
      if (response.ok() && !response.request().postDataJSON().data?.local) remoteQueries++
    })
    await page.goto(location(savedID))
    await page.getByRole('button', { name: 'Large values', exact: true }).click()
    await expect(page.getByRole('status').filter({ hasText: '5 条记录' })).toBeVisible()
    await expect(page.getByRole('textbox', { name: primary.name, exact: true }).first()).toHaveValue('Large 0')
    expect((await request<{ mode: string }>(page, `/tables/${table.id}`)).mode).toBe('local')
    remoteQueries = 0
    await request(page, `/tables/${table.id}/records`, 'POST', {
      updates: [
        { id: records[0]!.id, data: { [field.id]: 'x'.repeat(990_000) }, expected_versions: records[0]!.versions }
      ]
    })
    await expect.poll(() => remoteQueries).toBeGreaterThan(0)
    expect((await request<{ mode: string }>(page, `/tables/${table.id}`)).mode).toBe('remote')
    await expect(page.getByRole('textbox', { name: primary.name, exact: true }).first()).toHaveValue('Large 0')
    await page.getByRole('button', { name: primary.name, exact: true }).click()
    await expect(page.getByRole('dialog')).toBeVisible()
    await expect(page.getByRole('alert')).toHaveCount(0)
  } finally {
    if (savedID) await request(page, `/pages/${savedID}`, 'DELETE').catch(() => {})
    await context.close()
  }
})

test('record deletion keeps the confirmation snapshot after a remote edit', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let savedID: string | undefined
  try {
    await page.goto(location(state.report_id))
    const saved = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'base',
      title: 'Delete snapshot review'
    })
    savedID = saved.page.id
    const { table } = await request<{ table: { id: string } }>(page, `/bases/${savedID}/tables`, 'POST', {
      name: 'Deletion review'
    })
    const { fields } = await request<{ fields: BaseField[] }>(page, `/tables/${table.id}`)
    const primary = fields.find(field => field.is_primary)!
    const { records } = await request<{ records: BaseRecord[] }>(page, `/tables/${table.id}/records`, 'POST', {
      creates: [{ data: { [primary.id]: 'Before confirmation' } }]
    })
    await page.goto(location(savedID))
    await page.getByRole('button', { name: 'Deletion review', exact: true }).click()
    const grid = page.getByRole('region', { name: '数据表记录', exact: true })
    await grid.getByRole('button', { name: '删除', exact: true }).click()
    const dialog = page.getByRole('dialog', { name: '删除记录？', exact: true })
    await expect(dialog).toContainText('Before confirmation')
    await request(page, `/tables/${table.id}/records`, 'POST', {
      updates: [
        { id: records[0]!.id, data: { [primary.id]: 'Changed elsewhere' }, expected_versions: records[0]!.versions }
      ]
    })
    await expect(page.locator('[data-grid-record] input').first()).toHaveValue('Changed elsewhere')
    await expect(dialog).toContainText('Before confirmation')
    await dialog.getByRole('button', { name: '确认删除', exact: true }).click()
    await expect(dialog.getByRole('alert')).toContainText('此记录已变化')
    const retained = await request<{ records: BaseRecord[] }>(page, `/tables/${table.id}/query`, 'POST', {
      ids: [records[0]!.id]
    })
    expect(retained.records[0]?.data[primary.id]).toBe('Changed elsewhere')
    await dialog.getByRole('button', { name: '取消', exact: true }).click()
    await grid.getByRole('button', { name: '删除', exact: true }).click()
    await expect(dialog).toContainText('Changed elsewhere')
    await dialog.getByRole('button', { name: '确认删除', exact: true }).click()
    await expect(dialog).toHaveCount(0)
    await expect(grid.locator('[data-grid-record]')).toHaveCount(0)
  } finally {
    if (savedID) await request(page, `/pages/${savedID}`, 'DELETE').catch(() => {})
    await context.close()
  }
})
