import { expect, test } from '@playwright/test'
import { state, request, requestResponse, requestWithSharingVersion } from './fixtures'
import { pageRoute } from './routes'

test('contributors fill the default table and upload record attachments while schema and table deletion require higher roles', async ({
  browser
}) => {
  const ownerContext = await browser.newContext(),
    memberContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const owner = await ownerContext.newPage(),
    member = await memberContext.newPage()
  let id: string | undefined
  try {
    await owner.goto(state.base_url + pageRoute(state.report_id))
    const created = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      type: 'database',
      title: 'Interview evaluations'
    })
    id = created.page.id
    const { tables } = await request<{ tables: { id: string; name: string }[] }>(owner, `/databases/${id}`)
    expect(tables).toHaveLength(1)
    expect(tables[0]!.name).toBe('Table 1')
    const table = tables[0]!
    const schema = await request<{ fields: { id: string; is_primary: boolean }[] }>(owner, `/tables/${table.id}`)
    const primary = schema.fields.find(field => field.is_primary)!
    const { field } = await request<{ field: { id: string } }>(owner, `/tables/${table.id}/fields`, 'POST', {
      name: 'Resume',
      type: 'attachment'
    })
    await request(owner, `/tables/${table.id}/records`, 'POST', { creates: [{ data: { [primary.id]: 'Interview' } }] })
    await requestWithSharingVersion(owner, `/pages/${id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'contribute' }
      ]
    })
    await member.goto(state.base_url + pageRoute(id))
    await expect(member.getByRole('button', { name: 'Table 1', exact: true })).toBeVisible()
    await expect(member.getByRole('button', { name: '新增记录', exact: true })).toBeVisible()
    await expect(member.getByRole('button', { name: '删除数据表', exact: true })).toHaveCount(0)
    const attachmentSaved = member.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/v2/pod/tables/${table.id}/records`
    )
    const attachment = member.getByLabel('添加附件', { exact: true }).first()
    await attachment.setInputFiles({
      name: 'resume.txt',
      mimeType: 'text/plain',
      buffer: Buffer.from('Candidate resume')
    })
    expect((await attachmentSaved).status()).toBe(201)
    await expect(member.getByRole('link', { name: 'resume.txt', exact: true })).toBeVisible()
    const records = await request<{ records: { data: Record<string, { path: string }[]> }[] }>(
      member,
      `/tables/${table.id}/query`,
      'POST',
      {}
    )
    expect(records.records[0]!.data[field.id]).toHaveLength(1)
    const deniedField = await requestResponse(member, `/tables/${table.id}/fields`, 'POST', {
      name: 'Forbidden column',
      type: 'text'
    })
    expect(deniedField.status).toBe(403)
    expect((await requestResponse(member, `/tables/${table.id}`, 'DELETE')).status).toBe(403)
    await owner.goto(state.base_url + pageRoute(id))
    await owner.getByRole('button', { name: '删除数据表', exact: true }).click()
    const dialog = owner.getByRole('dialog')
    await expect(dialog).toContainText('删除此数据表及其所有记录')
    await dialog.getByRole('button', { name: '删除数据表', exact: true }).click()
    await expect(dialog).toBeHidden()
    expect((await request<{ tables: unknown[] }>(owner, `/databases/${id}`)).tables).toEqual([])
  } finally {
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await Promise.all([ownerContext.close(), memberContext.close()])
  }
})
