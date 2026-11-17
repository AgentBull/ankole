import { expect, test } from '@playwright/test'
import { expectedVersions, withRecordIDs } from '@ankole/applet-sdk/records'
import type { BaseRecord } from '@ankole/applet-sdk/types'
import { createApplet, login, publishApplet, request, requestResponse, state } from './fixtures'
import { pageRoute } from './routes'

test('concrete draft previews reject replacement and history restores the published application', async ({ page }) => {
  await page.goto(state.base_url + pageRoute(state.report_id))
  await login(page, state.owner)
  const applet = await createApplet({ parent_id: state.report_id, title: 'Draft review workflow' })
  try {
    await publishApplet(applet.id, 0, state.publish_v1_files)
    const first = (
      await publishApplet(applet.id, 1, state.publish_v2_files, { draft: true, summary: 'First candidate' })
    ).draft!
    await page.goto(state.base_url + pageRoute(applet.id))
    await expect(page.frameLocator('iframe').getByRole('heading', { name: 'Tracker v1', exact: true })).toBeVisible()
    await page.getByRole('button', { name: '预览草稿', exact: true }).click()
    await expect(page.locator('iframe')).toHaveAttribute('src', new RegExp(`draft-${first.id}`))
    await expect(page.frameLocator('iframe').getByRole('heading', { name: 'Tracker v2', exact: true })).toBeVisible()
    const oldURL = await page.locator('iframe').getAttribute('src')
    const second = (
      await publishApplet(applet.id, 1, state.publish_v1_files, { draft: true, summary: 'Replacement candidate' })
    ).draft!
    expect(second.id).not.toBe(first.id)
    await expect(page.getByText('草稿已更新，请刷新预览最新草稿。')).toBeVisible()
    // A stale request may retire A, but only an explicit refresh can mount B.
    await expect(page.locator(`iframe[src*="draft-${second.id}"]`)).toHaveCount(0)
    const stale = await requestResponse(page, `/pages/${applet.id}/applet-draft/promote`, 'POST', {
      expected_draft_id: first.id,
      base_revision: 1
    })
    expect(stale.status).toBe(409)
    expect((await page.request.get(state.base_url + oldURL!)).status()).toBe(409)
    await page.getByRole('button', { name: '刷新草稿', exact: true }).click()
    await expect(page.locator('iframe')).toHaveAttribute('src', new RegExp(`draft-${second.id}`))
    await expect(page.frameLocator('iframe').getByRole('heading', { name: 'Tracker v1', exact: true })).toBeVisible()
    await page.getByRole('button', { name: '发布此草稿', exact: true }).click()
    await expect(page.locator('iframe')).toHaveAttribute('src', /\/2\/index.html$/)
    await publishApplet(applet.id, 2, state.publish_v2_files)
    await expect(page.frameLocator('iframe').getByRole('heading', { name: 'Tracker v2', exact: true })).toBeVisible()
    await page.getByRole('button', { name: '版本历史', exact: true }).click()
    const row = page
      .getByRole('dialog')
      .locator('div.space-y-2')
      .filter({ has: page.getByText('v1', { exact: true }) })
    await row.getByRole('button', { name: '恢复此版本', exact: true }).click()
    await page.keyboard.press('Escape')
    await expect(page.locator('iframe')).toHaveAttribute('src', /\/4\/index.html$/)
    await expect(page.frameLocator('iframe').getByRole('heading', { name: 'Tracker v1', exact: true })).toBeVisible()
  } finally {
    await request(page, `/pages/${applet.id}`, 'DELETE')
  }
})

test('rebinding refreshes record and backend route queries in both open tabs without reloading their iframe', async ({
  page,
  context
}) => {
  await page.goto(state.base_url + pageRoute(state.report_id))
  await login(page, state.owner)
  const applet = await createApplet({ parent_id: state.report_id, title: 'Binding replacement workflow' })
  const second = await context.newPage()
  let baseID: string | undefined
  let original: BaseRecord | undefined
  let submittedCapturedEdit = false
  try {
    const base = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      parent_id: state.report_id,
      title: 'Replacement data',
      type: 'base'
    })
    baseID = base.page.id
    const table = await request<{ table: { id: string } }>(page, `/bases/${baseID}/tables`, 'POST', {
      name: 'Replacement samples'
    })
    const amount = await request<{ field: { id: string } }>(page, `/tables/${table.table.id}/fields`, 'POST', {
      name: 'amount',
      type: 'number'
    })
    await request(page, `/tables/${table.table.id}/fields`, 'POST', { name: 'status', type: 'select' })
    await request(
      page,
      `/tables/${table.table.id}/records`,
      'POST',
      withRecordIDs({ creates: [321, 322, 323].map(value => ({ data: { [amount.field.id]: value } })) })
    )
    await publishApplet(applet.id, 0, state.publish_v1_files)
    original = (await request<{ records: BaseRecord[] }>(page, `/tables/${state.table_id}/query`, 'POST', {}))
      .records[0]!
    for (const tab of [page, second]) {
      await tab.goto(state.base_url + pageRoute(applet.id))
      await expect(tab.frameLocator('iframe').locator('.binding-record-count')).toHaveText('1 bound records')
      await expect(tab.frameLocator('iframe').locator('.binding-route-count')).toHaveText('1 route records')
      await tab
        .frameLocator('iframe')
        .getByRole('textbox', { name: 'Draft evaluation', exact: true })
        .fill('Keep my draft')
      await tab.locator('iframe').evaluate(frame => {
        ;(window as any).__bindingFrame = frame
      })
    }
    await page.frameLocator('iframe').getByRole('button', { name: 'Capture bound record', exact: true }).click()
    await expect(page.frameLocator('iframe').locator('.binding-capture-status')).toHaveText('Captured bound record')
    await page.getByRole('button', { name: '小应用设置', exact: true }).click()
    await page.getByRole('tab', { name: '数据绑定', exact: true }).click()
    await page.getByRole('button', { name: '选择数据表', exact: true }).click()
    await page.getByRole('combobox', { name: '选择 Base 页面' }).fill('Replacement data')
    await page.getByRole('option', { name: /Replacement data/ }).click()
    await page.getByRole('button', { name: 'Replacement samples', exact: true }).click()
    await page.getByRole('button', { name: '保存', exact: true }).click()
    await page.keyboard.press('Escape')
    for (const tab of [page, second]) {
      await expect(tab.frameLocator('iframe').locator('.binding-record-count')).toHaveText('3 bound records')
      await expect(tab.frameLocator('iframe').locator('.binding-route-count')).toHaveText('3 route records')
      await expect(
        tab.frameLocator('iframe').getByRole('textbox', { name: 'Draft evaluation', exact: true })
      ).toHaveValue('Keep my draft')
      expect(await tab.locator('iframe').evaluate(frame => (window as any).__bindingFrame === frame)).toBe(true)
    }
    const binding = await request<{ bindings: { samples: { fields: { amount: string } } } }>(
      page,
      `/pages/${applet.id}/applet-bindings`
    )
    expect(binding.bindings.samples.fields.amount).toBe(amount.field.id)
    const capturedWrite = page.waitForRequest(
      req => req.method() === 'POST' && new URL(req.url()).pathname.endsWith(`/tables/${state.table_id}/records`)
    )
    submittedCapturedEdit = true
    await page.frameLocator('iframe').getByRole('button', { name: 'Save captured edit', exact: true }).click()
    await expect(page.frameLocator('iframe').locator('.binding-capture-status')).toHaveText('Saved captured edit')
    expect((await capturedWrite).postDataJSON().data.updates[0]).toEqual({
      id: original.id,
      data: { [state.amount_field_id]: 909 },
      expected_versions: expectedVersions(original, { [state.amount_field_id]: 909 })
    })
    const source = await request<{ records: BaseRecord[] }>(page, `/tables/${state.table_id}/query`, 'POST', {})
    expect(source.records[0]!.data[state.amount_field_id]).toBe(909)
    const replacement = await request<{ records: BaseRecord[] }>(page, `/tables/${table.table.id}/query`, 'POST', {})
    expect(replacement.records.map(record => record.data[amount.field.id]).sort()).toEqual([321, 322, 323])
  } finally {
    if (submittedCapturedEdit && original) {
      const originalID = original.id
      const current = (
        await request<{ records: BaseRecord[] }>(page, `/tables/${state.table_id}/query`, 'POST', {})
      ).records.find(record => record.id === originalID)!
      const data = { [state.amount_field_id]: original.data[state.amount_field_id] ?? null }
      await request(page, `/tables/${state.table_id}/records`, 'POST', {
        updates: [{ id: current.id, data, expected_versions: expectedVersions(current, data) }]
      })
    }
    await second.close()
    await request(page, `/pages/${applet.id}`, 'DELETE')
    if (baseID) await request(page, `/pages/${baseID}`, 'DELETE')
  }
})

test('the element picker carries source coordinates into native comments and Page Chat', async ({ page }) => {
  await page.goto(state.base_url + pageRoute(state.report_id))
  await login(page, state.owner)
  const applet = await createApplet({ parent_id: state.report_id, title: 'Point and discuss' })
  try {
    await publishApplet(applet.id, 0, state.publish_v1_files)
    await page.goto(state.base_url + pageRoute(applet.id))
    const heading = page.frameLocator('iframe').getByRole('heading', { name: 'Tracker v1', exact: true })
    await expect(heading).toBeVisible()
    const source = await heading.getAttribute('data-ankole-src')
    expect(source).toMatch(/^src\/main.tsx:\d+$/)
    await page.getByRole('button', { name: '点选元素', exact: true }).click()
    await heading.click()
    await page.getByRole('button', { name: '在此添加评论', exact: true }).click()
    const panel = page.getByRole('complementary', { name: '评论', exact: true })
    await panel.getByRole('textbox', { name: '添加评论…', exact: true }).fill('Please clarify this heading')
    await panel.getByRole('button', { name: '发送', exact: true }).click()
    const thread = panel.locator('.pod-comment-thread').filter({ hasText: 'Please clarify this heading' })
    await expect(thread).toBeVisible()
    await expect(thread).toContainText(source!)
    const comments = await request<{ threads: { anchor: { kind: string; source: string; revision: number } }[] }>(
      page,
      `/pages/${applet.id}/comments`
    )
    expect(comments.threads[0]?.anchor).toMatchObject({ kind: 'applet_element', source, revision: 1 })
    await thread.locator('.pod-comment-quote').click()
    expect(await heading.evaluate(element => element.getAnimations().length)).toBeGreaterThan(0)
    await page.getByRole('button', { name: '发送到对话修改', exact: true }).click()
    const chat = page.locator('.pod-page-chat')
    await expect(chat).toBeVisible()
    await expect(chat.locator('textarea')).toHaveValue(new RegExp(applet.id))
    await expect(chat.locator('textarea')).toHaveValue(new RegExp(source!.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
    const draft = (await publishApplet(applet.id, 1, state.publish_v1_files, { draft: true })).draft!
    await page.getByRole('button', { name: '预览草稿', exact: true }).click()
    await expect(page.locator('iframe')).toHaveAttribute('data-applet-revision', `draft:${draft.id}`)
    await expect(heading).toBeVisible()
    await page.locator('.pod-page-actions').getByRole('button', { name: '评论', exact: true }).click()
    await thread.locator('.pod-comment-quote').click()
    expect(await heading.evaluate(element => element.getAnimations().length)).toBe(0)
  } finally {
    await request(page, `/pages/${applet.id}`, 'DELETE')
  }
})
