import { pageRoute } from './routes'
import { readFileSync } from 'node:fs'
import { expect, test, type Browser, type BrowserContext, type Page } from '@playwright/test'
import type { DatabaseField, DatabaseRecord, DatabaseView, Filter } from '@ankole/applet-sdk/types'

type Identity = { cookies: Parameters<BrowserContext['addCookies']>[0] }
const state = JSON.parse(readFileSync(process.env.POD_BROWSER_STATE_PATH!, 'utf8')) as {
  base_url: string
  tenant_id: string
  report_id: string
  owner: Identity
  member: Identity
}
const location = (id: string) => `${state.base_url}${pageRoute(id)}`

async function request<T>(page: Page, path: string, method = 'GET', body?: unknown): Promise<T> {
  if (method === 'PUT' && path.endsWith('/sharing')) {
    const baseline = await request<{ sharing_version: string }>(page, path)
    body = { ...(body as Record<string, unknown>), sharing_version: baseline.sharing_version }
  }
  return page.evaluate(
    async ({ path, method, body }) => {
      const metadata = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content
      const response = await fetch(`/.internal-apis/pod${path}`, {
        method,
        credentials: 'same-origin',
        headers: {
          accept: 'application/json',
          'content-type': 'application/json',
          'x-ankole-authentication': metadata('ankole-authentication') ?? '',
          'x-ankole-pod': metadata('ankole-pod') ?? '',
          'x-csrf-token': metadata('csrf-token') ?? ''
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) })
      })
      if (!response.ok) throw new Error(`Pod ${method} ${path}: ${response.status} ${await response.text()}`)
      return response.status === 204 ? null : response.json()
    },
    { path, method, body }
  )
}

async function choose(page: Page, name: string, option: string, index = 0) {
  const dialog = page.getByRole('dialog')
  const scope = (await dialog.getByRole('combobox', { name, exact: true }).count()) ? dialog : page
  const trigger = scope.getByRole('combobox', { name, exact: true }).nth(index)
  await trigger.click()
  await expect(trigger).toHaveAttribute('aria-expanded', 'true')
  const popup = await trigger.getAttribute('aria-controls')
  if (!popup) throw new Error(`${name} has no controlled popup`)
  await page
    .locator(`[id=${JSON.stringify(popup)}]`)
    .getByRole('option', { name: option, exact: true })
    .click()
  await expect(trigger).toHaveAttribute('aria-expanded', 'false')
}

async function businessTable(browser: Browser) {
  const ownerContext = await browser.newContext(),
    memberContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const owner = await ownerContext.newPage(),
    member = await memberContext.newPage()
  await owner.goto(location(state.report_id))
  const { page } = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
    type: 'database',
    title: `Database controls ${crypto.randomUUID()}`,
    parent_id: state.report_id
  })
  const { table } = await request<{ table: { id: string } }>(owner, `/databases/${page.id}/tables`, 'POST', {
    name: 'Business records'
  })
  const schema = () => request<{ fields: DatabaseField[]; views: DatabaseView[] }>(owner, `/tables/${table.id}`)
  const primary = (await schema()).fields.find(field => field.is_primary)!
  const addField = async (name: string, type: string, config = {}) =>
    (await request<{ field: DatabaseField }>(owner, `/tables/${table.id}/fields`, 'POST', { name, type, config })).field
  const revenue = await addField('Revenue', 'number')
  const stage = await addField('Stage', 'select', {
    options: [
      { id: 'open', name: 'Open' },
      { id: 'closed', name: 'Closed' }
    ]
  })
  const memo = await addField('Memo', 'text')
  const { records } = await request<{ records: DatabaseRecord[] }>(owner, `/tables/${table.id}/records`, 'POST', {
    creates: [{ data: { [primary.id]: 'Oak', [revenue.id]: 10, [stage.id]: 'open', [memo.id]: 'Keep this value' } }]
  })
  const read = async () =>
    (await request<{ records: DatabaseRecord[] }>(owner, `/tables/${table.id}/query`, 'POST', {})).records
  await owner.goto(location(page.id))
  await member.goto(location(page.id))
  await expect(owner.getByRole('spinbutton', { name: 'Revenue', exact: true })).toHaveValue('10')
  await expect(owner.getByRole('columnheader').first()).toHaveText(primary.name)
  await expect(owner.getByRole('columnheader').nth(1)).toHaveText('Revenue')
  await expect(member.getByRole('spinbutton', { name: 'Revenue', exact: true })).toHaveValue('10')
  return {
    owner,
    member,
    table,
    primary,
    revenue,
    stage,
    memo,
    record: records[0]!,
    schema,
    read,
    close: () => Promise.all([ownerContext.close(), memberContext.close()])
  }
}

test('cell drafts survive another person’s edit, require explicit conflict retry, and respect Enter, Escape, Tab and IME', async ({
  browser
}) => {
  const fixture = await businessTable(browser)
  const { owner, member, table, revenue, read } = fixture
  const cell = owner.getByRole('spinbutton', { name: 'Revenue', exact: true })
  const other = member.getByRole('spinbutton', { name: 'Revenue', exact: true })
  try {
    await cell.fill('17')
    const remoteUpdate = owner.waitForResponse(async response => {
      if (!response.url().includes(`/tables/${table.id}/query`) || response.status() !== 200) return false
      const body = (await response.json()) as { records: DatabaseRecord[] }
      return body.records.some(record => record.data[revenue.id] === 22)
    })
    await other.fill('22')
    await other.press('Enter')
    await remoteUpdate
    await expect(cell).toHaveValue('17')
    const conflict = owner.waitForResponse(
      response => response.url().endsWith(`/tables/${table.id}/records`) && response.status() === 409
    )
    await cell.press('Enter')
    await conflict
    await expect(owner.getByRole('button', { name: '重试保存', exact: true })).toBeVisible()
    await expect(cell).toHaveValue('17')
    expect((await read())[0]!.data[revenue.id]).toBe(22)
    await owner.getByRole('button', { name: '重试保存', exact: true }).click()
    await expect.poll(async () => (await read())[0]!.data[revenue.id]).toBe(17)
    await expect(other).toHaveValue('17')
    await expect(owner.getByRole('button', { name: '重试保存', exact: true })).toHaveCount(0)

    await cell.fill('99')
    await cell.press('Escape')
    await expect(cell).toHaveValue('17')
    expect((await read())[0]!.data[revenue.id]).toBe(17)

    let writes = 0
    const recordWrite = (req: { url(): string; method(): string }) => {
      if (req.url().endsWith(`/tables/${table.id}/records`) && req.method() === 'POST') writes++
    }
    owner.on('request', recordWrite)
    await cell.fill('23')
    await cell.dispatchEvent('compositionstart')
    await cell.dispatchEvent('keydown', { key: 'Enter', code: 'Enter', isComposing: true, bubbles: true })
    await expect(cell).toBeFocused()
    expect(writes).toBe(0)
    expect((await read())[0]!.data[revenue.id]).toBe(17)
    await cell.dispatchEvent('compositionend')
    await cell.press('Enter')
    await expect.poll(async () => (await read())[0]!.data[revenue.id]).toBe(23)
    await expect(cell).toBeEnabled()
    await cell.fill('24')
    await cell.press('Tab')
    await expect.poll(async () => (await read())[0]!.data[revenue.id]).toBe(24)
    expect(writes).toBe(2)
    owner.off('request', recordWrite)
  } finally {
    await fixture.close()
  }
})

test('field editing cancels cleanly and requires confirmation before converting or permanently deleting values', async ({
  browser
}) => {
  const fixture = await businessTable(browser)
  const { owner, memo, revenue, schema, read } = fixture
  try {
    await owner.getByRole('button', { name: 'Revenue', exact: true }).click()
    await owner.getByRole('textbox', { name: '字段名称', exact: true }).fill('Discarded name')
    await owner.getByRole('button', { name: '取消', exact: true }).click()
    await owner.getByRole('button', { name: 'Revenue', exact: true }).click()
    await expect(owner.getByRole('textbox', { name: '字段名称', exact: true })).toHaveValue('Revenue')
    await owner.getByRole('button', { name: '取消', exact: true }).click()

    await owner.getByRole('button', { name: 'Memo', exact: true }).click()
    await choose(owner, '字段类型', '公式')
    await owner.getByRole('textbox', { name: '公式', exact: true }).fill('[Revenue] * 2')
    await owner.getByRole('button', { name: '保存字段', exact: true }).click()
    await expect(owner.getByRole('button', { name: '确认更改字段', exact: true })).toBeVisible()
    expect((await schema()).fields.find(field => field.id === memo.id)?.type).toBe('text')
    expect((await read())[0]!.data[memo.id]).toBe('Keep this value')
    await owner.getByRole('button', { name: '取消', exact: true }).click()
    await owner.getByRole('button', { name: '取消', exact: true }).click()

    await owner.getByRole('button', { name: 'Memo', exact: true }).click()
    await owner.getByRole('button', { name: '删除字段', exact: true }).click()
    await expect(owner.getByRole('button', { name: '确认删除字段', exact: true })).toBeVisible()
    expect((await schema()).fields.some(field => field.id === memo.id)).toBe(true)
    expect((await read())[0]!.data[memo.id]).toBe('Keep this value')
    await owner.getByRole('button', { name: '取消', exact: true }).click()
    await expect(owner.getByRole('button', { name: '确认删除字段', exact: true })).toHaveCount(0)
    await owner.getByRole('button', { name: '删除字段', exact: true }).click()
    await owner.getByRole('button', { name: '确认删除字段', exact: true }).click()
    await expect(owner.getByRole('dialog')).toHaveCount(0)
    expect((await schema()).fields.some(field => field.id === memo.id)).toBe(false)
    expect((await read())[0]!.data[memo.id]).toBeUndefined()
    expect((await schema()).fields.find(field => field.id === revenue.id)?.type).toBe('number')

    await owner.getByRole('button', { name: '+ 字段', exact: true }).first().click()
    await owner.getByRole('textbox', { name: '字段名称', exact: true }).fill('New property')
    await owner.getByRole('button', { name: '保存字段', exact: true }).click()
    await expect(owner.getByRole('dialog')).toHaveCount(0)
    await owner.getByRole('button', { name: '+ 字段', exact: true }).first().click()
    await expect(owner.getByRole('textbox', { name: '字段名称', exact: true })).toHaveValue('')
    await owner.getByRole('button', { name: '取消', exact: true }).click()
  } finally {
    await fixture.close()
  }
})

test('a typed filter can be applied directly without an extra blur or keyboard action', async ({ browser }) => {
  const fixture = await businessTable(browser)
  const { owner } = fixture
  try {
    const trigger = owner.getByRole('button', { name: '筛选与排序', exact: true })
    await trigger.click()
    const editor = owner.getByRole('dialog', { name: '筛选与排序', exact: true })
    await expect(editor).toBeVisible()
    await expect(owner.getByRole('columnheader', { name: 'Revenue', exact: true })).toBeVisible()
    const anchor = (await trigger.boundingBox())!
    const popup = (await editor.boundingBox())!
    const anchorGap = Math.min(
      Math.abs(popup.y - anchor.y - anchor.height),
      Math.abs(anchor.y - popup.y - popup.height)
    )
    expect(anchorGap).toBeLessThanOrEqual(16)
    await owner.getByRole('button', { name: '添加筛选条件', exact: true }).click()
    await expect(owner.getByRole('alert')).toHaveCount(0)
    const value = owner.getByRole('dialog').getByRole('textbox', { name: 'Name', exact: true })
    await value.fill('No matching company')
    await expect(value).toBeFocused()
    await owner.getByRole('button', { name: '应用', exact: true }).click()
    await expect(owner.getByRole('dialog', { name: '筛选与排序', exact: true })).toBeHidden()
    await expect(owner.getByRole('button', { name: '筛选与排序 · 1', exact: true })).toBeFocused()
    await expect(owner.getByRole('status').filter({ hasText: '0 条记录' })).toBeVisible()
  } finally {
    await fixture.close()
  }
})

test('a numeric filter preserves fractional typing and Escape restores its previous value', async ({ browser }) => {
  const fixture = await businessTable(browser)
  const { owner, schema } = fixture
  const savedValue = async () => {
    const filter = (await schema()).views[0]!.config.filter as Filter | undefined
    return filter?.conditions[0]?.value
  }
  try {
    await owner.getByRole('button', { name: '筛选与排序', exact: true }).click()
    await owner.getByRole('button', { name: '添加筛选条件', exact: true }).click()
    await choose(owner, '筛选字段', 'Revenue')
    const value = owner.getByRole('dialog').getByRole('spinbutton', { name: 'Revenue', exact: true })
    await value.pressSequentially('1.05')
    await expect(value).toHaveValue('1.05')
    await owner.getByRole('button', { name: '应用', exact: true }).click()
    await expect(owner.getByRole('dialog')).toBeHidden()
    await owner.getByRole('button', { name: '为所有人保存视图', exact: true }).click()
    await expect.poll(savedValue).toBe(1.05)
    await owner.getByRole('button', { name: '筛选与排序 · 1', exact: true }).click()
    await value.fill('10')
    await value.press('Escape')
    await expect(value).toHaveValue('1.05')
    await owner.getByRole('button', { name: '应用', exact: true }).click()
    await expect(owner.getByRole('dialog')).toBeHidden()
    expect(await savedValue()).toBe(1.05)
  } finally {
    await fixture.close()
  }
})

test('filters keep field-compatible values, cancel drafts, and persist their OR logic and sort priority only on save', async ({
  browser
}) => {
  const fixture = await businessTable(browser)
  const { owner, table, primary, revenue, stage, schema } = fixture
  try {
    await request(owner, `/tables/${table.id}/records`, 'POST', {
      creates: [{ data: { [primary.id]: 'Pine', [revenue.id]: 20, [stage.id]: 'closed' } }]
    })
    await owner.getByRole('button', { name: '筛选与排序', exact: true }).click()
    await owner.getByRole('button', { name: '添加筛选条件', exact: true }).click()
    await choose(owner, '筛选字段', 'Revenue')
    const comparison = owner.getByRole('combobox', { name: '筛选条件', exact: true })
    await comparison.click()
    await expect(owner.getByRole('option', { name: '包含文字', exact: true })).toHaveCount(0)
    await owner.getByRole('option', { name: '大于', exact: true }).click()
    await owner.getByRole('dialog').getByRole('spinbutton', { name: 'Revenue', exact: true }).fill('12')
    await owner.getByRole('dialog').getByRole('spinbutton', { name: 'Revenue', exact: true }).blur()
    await owner.getByRole('button', { name: '添加筛选条件', exact: true }).click()
    await choose(owner, '筛选字段', 'Stage', 1)
    await choose(owner, 'Stage', 'Open')
    await choose(owner, '筛选组合', '满足任一条件')
    await owner.getByRole('button', { name: '添加排序字段', exact: true }).click()
    await choose(owner, '排序字段', 'Revenue')
    await owner.getByRole('button', { name: '添加排序字段', exact: true }).click()
    await choose(owner, '排序字段', primary.name, 1)
    await owner.getByRole('button', { name: '提高第 2 项排序优先级', exact: true }).click()
    await owner.getByRole('button', { name: '应用', exact: true }).click()
    await expect(owner.getByRole('spinbutton', { name: 'Revenue', exact: true })).toHaveCount(2)
    expect((await schema()).views[0]!.config.filter).toBeUndefined()
    await owner.getByRole('button', { name: '为所有人保存视图', exact: true }).click()
    await expect(owner.getByText('视图设置尚未保存。', { exact: true })).toHaveCount(0)
    const saved = (await schema()).views[0]!.config
    expect(saved.filter).toMatchObject({
      conjunction: 'or',
      conditions: [
        { field_id: revenue.id, operator: 'gt', value: 12 },
        { field_id: stage.id, operator: 'is', value: 'open' }
      ]
    })
    expect(saved.sort).toEqual([
      { field_id: primary.id, direction: 'asc' },
      { field_id: revenue.id, direction: 'asc' }
    ])
    await owner.getByRole('button', { name: /^筛选与排序/ }).click()
    await expect(owner.getByRole('combobox', { name: '筛选组合', exact: true })).toContainText('满足任一条件')
    await choose(owner, '筛选组合', '满足所有条件')
    await owner.getByRole('button', { name: '取消', exact: true }).click()
    await owner.getByRole('button', { name: /^筛选与排序/ }).click()
    await expect(owner.getByRole('combobox', { name: '筛选组合', exact: true })).toContainText('满足任一条件')
    await owner.getByRole('button', { name: '取消', exact: true }).click()
  } finally {
    await fixture.close()
  }
})

test('deleted filter and calculation fields remain explicit repair choices instead of silently changing the query', async ({
  browser
}) => {
  const fixture = await businessTable(browser)
  const { owner, member, revenue, schema } = fixture
  try {
    await owner.getByRole('button', { name: '分组统计', exact: true }).click()
    await choose(owner, '统计方式', '求和')
    await expect(owner.getByRole('alert').filter({ hasText: '请选择有效的统计和分组字段。' })).toBeVisible()
    await choose(owner, '统计字段', 'Revenue')
    const summary = owner.getByRole('combobox', { name: '统计方式', exact: true }).locator('xpath=ancestor::div[2]')
    await expect(summary.getByRole('cell', { name: '10', exact: true })).toBeVisible()

    await owner.getByRole('button', { name: '筛选与排序', exact: true }).click()
    await owner.getByRole('button', { name: '添加筛选条件', exact: true }).click()
    await choose(owner, '筛选字段', 'Revenue')
    await choose(owner, '筛选条件', '不为空')
    await request(member, `/fields/${revenue.id}`, 'DELETE', {
      version: (await schema()).fields.find(field => field.id === revenue.id)!.version
    })
    await expect(owner.getByRole('combobox', { name: '筛选字段', exact: true })).toContainText(
      '已删除的字段，请重新选择'
    )
    await expect(owner.getByRole('button', { name: '应用', exact: true })).toBeDisabled()
    await owner.getByRole('button', { name: '移除', exact: true }).click()
    await owner.getByRole('button', { name: '应用', exact: true }).click()
    await expect(owner.getByRole('combobox', { name: '统计字段', exact: true })).toContainText(
      '字段已删除或不支持此统计，请重新选择'
    )
    await expect(summary.getByRole('table')).toHaveCount(0)
    await expect(owner.getByRole('alert').filter({ hasText: '请选择有效的统计和分组字段。' })).toBeVisible()
    await choose(owner, '统计方式', '计数')
    await choose(owner, '统计字段', '所有记录')
    await expect(summary.getByRole('cell', { name: '1', exact: true })).toBeVisible()
  } finally {
    await fixture.close()
  }
})
