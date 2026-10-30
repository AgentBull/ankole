import { state, requestWithSharingVersion as request } from './fixtures'
import { pageRoute } from './routes'
import { expect, test } from '@playwright/test'
import type { BaseField, BaseRecord, RecordsResult, TableSchema } from '@ankole/applet-sdk/types'

const location = (id: string) => `${state.base_url}${pageRoute(id)}`

test('copying a shared base selects an editable destination and opens an independent persisted result', async ({
  browser
}) => {
  const ownerContext = await browser.newContext(),
    memberContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const owner = await ownerContext.newPage(),
    member = await memberContext.newPage()
  try {
    await owner.goto(location(state.report_id))
    await member.goto(location(state.report_id))
    const suffix = crypto.randomUUID()
    const readonlyTitle = `Shared source folder ${suffix}`,
      destinationTitle = `My copy folder ${suffix}`
    const copiedTitle = `Independent result ${suffix}`
    const { page: folder } = await request<{ page: { id: string } }>(member, '/pages', 'POST', {
      type: 'doc',
      title: readonlyTitle,
      private_owner_uid: state.member.uid
    })
    const { page: source } = await request<{ page: { id: string } }>(member, '/pages', 'POST', {
      type: 'base',
      title: `Shared source ${suffix}`,
      parent_id: folder.id
    })
    const { table } = await request<{ table: { id: string } }>(member, `/bases/${source.id}/tables`, 'POST', {
      name: 'Source records'
    })
    const schema = await request<TableSchema>(member, `/tables/${table.id}`)
    const primary = schema.fields.find(field => field.is_primary)!
    const { field: amount } = await request<{ field: BaseField }>(member, `/tables/${table.id}/fields`, 'POST', {
      name: 'Amount',
      type: 'number',
      config: {}
    })
    const { records: sourceRecords } = await request<{ records: BaseRecord[] }>(
      member,
      `/tables/${table.id}/records`,
      'POST',
      {
        creates: [{ data: { [primary.id]: 'Original source', [amount.id]: 23 } }]
      }
    )
    await request(member, `/pages/${folder.id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.member.uid, role: 'manage' },
        { principal_uid: state.owner.uid, role: 'view' }
      ]
    })
    await request(member, `/pages/${source.id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.member.uid, role: 'manage' },
        { principal_uid: state.owner.uid, role: 'edit' }
      ]
    })
    const { page: destination } = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      type: 'doc',
      title: destinationTitle,
      private_owner_uid: state.owner.uid
    })
    expect((await request<{ role: string }>(owner, `/pages/${folder.id}`)).role).toBe('view')
    expect((await request<{ role: string }>(owner, `/pages/${source.id}`)).role).toBe('edit')
    await owner.goto(location(source.id))
    await owner.getByRole('button', { name: 'Source records', exact: true }).click()
    await expect(owner.getByRole('spinbutton', { name: 'Amount', exact: true })).toHaveValue('23')
    await owner.getByRole('button', { name: '复制当前结果', exact: true }).click()
    const dialog = owner.getByRole('dialog', { name: '复制数据表', exact: true })
    const target = dialog.getByRole('combobox', { name: '保存到', exact: true })
    await expect(dialog.locator('.pod-selected-destination')).toContainText('原目标不可编辑，请重新选择')
    await expect(dialog.getByRole('button', { name: '复制', exact: true })).toBeDisabled()
    await target.fill(destinationTitle)
    await expect(target).toHaveAttribute('aria-expanded', 'true')
    const popup = await target.getAttribute('aria-controls')
    if (!popup) throw new Error('The copy destination has no controlled popup')
    const options = owner.locator(`[id=${JSON.stringify(popup)}]`)
    await expect(options.getByRole('option', { name: readonlyTitle, exact: true })).toHaveCount(0)
    await options.getByRole('option', { name: destinationTitle, exact: true }).click()
    await expect(dialog.locator('.pod-selected-destination')).toContainText(destinationTitle)
    await dialog.getByRole('textbox', { name: '页面标题', exact: true }).fill(copiedTitle)
    const copiedResponse = owner.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/v2/pod/tables/${table.id}/copy`
    )
    await dialog.getByRole('button', { name: '复制', exact: true }).click()
    const response = await copiedResponse
    expect(response.ok()).toBe(true)
    const copied = (await response.json()) as { page: { id: string; parent_id: string }; table: { id: string } }
    expect(copied.page.parent_id).toBe(destination.id)
    expect(copied.page.id).not.toBe(source.id)
    expect(copied.table.id).not.toBe(table.id)
    await expect(dialog).toHaveCount(0)
    const open = owner.getByRole('link', { name: '打开页面', exact: true })
    await expect(owner.getByRole('status').filter({ has: open })).toContainText('已复制为独立页面。')
    await expect(open).toBeVisible()
    expect(new URL((await open.getAttribute('href'))!, state.base_url).pathname).toBe(pageRoute(copied.page.id))
    const copiedSchema = await request<TableSchema>(owner, `/tables/${copied.table.id}`)
    const copiedPrimary = copiedSchema.fields.find(field => field.is_primary)!
    const copiedAmount = copiedSchema.fields.find(field => field.name === 'Amount')!
    const copiedRows = (await request<RecordsResult>(owner, `/tables/${copied.table.id}/query`, 'POST', {})).records
    expect(copiedRows).toHaveLength(1)
    expect(copiedRows[0]!.id).not.toBe(sourceRecords[0]!.id)
    expect(copiedRows[0]!.data).toEqual({ [copiedPrimary.id]: 'Original source', [copiedAmount.id]: 23 })
    await open.click()
    await expect(owner).toHaveURL(url => url.pathname === pageRoute(copied.page.id))
    await expect(owner.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(copiedTitle)
    await expect(owner.getByRole('spinbutton', { name: 'Amount', exact: true })).toHaveValue('23')
    await member.goto(location(source.id))
    await member.getByRole('button', { name: 'Source records', exact: true }).click()
    await member.getByRole('spinbutton', { name: 'Amount', exact: true }).fill('41')
    await member.getByRole('spinbutton', { name: 'Amount', exact: true }).press('Enter')
    await expect
      .poll(
        async () =>
          (await request<RecordsResult>(member, `/tables/${table.id}/query`, 'POST', {})).records[0]?.data[amount.id]
      )
      .toBe(41)
    await owner.reload()
    await expect(owner.getByRole('spinbutton', { name: 'Amount', exact: true })).toHaveValue('23')
    expect(
      (await request<RecordsResult>(owner, `/tables/${copied.table.id}/query`, 'POST', {})).records[0]?.data[
        copiedAmount.id
      ]
    ).toBe(23)
  } finally {
    await ownerContext.close()
    await memberContext.close()
  }
})
