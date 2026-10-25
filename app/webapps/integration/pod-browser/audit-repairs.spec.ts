import { state, request } from './fixtures'
import { expect, test } from '@playwright/test'
import type { DatabaseField, DatabaseRecord } from '@ankole/applet-sdk/types'
import { pageRoute } from './routes'

test.setTimeout(30_000)
const location = (id: string) => state.base_url + pageRoute(id)

test('remote writes preserve an unsent local draft and commit it through the original OT request', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  let held = 0
  let deliver = false
  let release: (() => void) | undefined
  await page.routeWebSocket('**/pod/socket/websocket*', socket => {
    const server = socket.connectToServer()
    socket.onMessage(message => {
      if (JSON.parse(message.toString())[3] === 'changes' && !deliver) {
        held++
        release ??= () => server.send(message)
        return
      }
      server.send(message)
    })
    server.onMessage(message => socket.send(message))
  })
  try {
    await page.goto(location(state.report_id))
    const created = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      title: 'Concurrent draft preservation',
      type: 'doc'
    })
    id = created.page.id
    const seeded = await request<{ page: { revision: number } }>(page, `/pages/${id}/content`, 'PUT', {
      base_revision: 0,
      xml: '<page><p>Initial</p></page>'
    })
    await page.goto(location(id))
    const editor = page.locator('.editor-content')
    await expect(editor).toHaveText('Initial')
    await editor.click()
    await page.keyboard.press('ControlOrMeta+End')
    await page.keyboard.insertText(' Local draft A')
    await expect.poll(() => held).toBeGreaterThan(0)
    const first = await request<{ page: { revision: number } }>(page, `/pages/${id}/content`, 'PUT', {
      base_revision: seeded.page.revision,
      xml: '<page><p>Remote name</p><p>Appended block</p></page>'
    })
    await expect(editor).toContainText('Remote name Local draft A')
    await expect(editor).toContainText('Appended block')
    await request(page, `/pages/${id}/content`, 'PUT', {
      base_revision: first.page.revision,
      xml: '<page><p>Corrected name</p><p>Appended block</p><p>Second block</p></page>'
    })
    await expect(editor).toContainText('Corrected name Local draft A')
    await expect(editor).toContainText('Second block')
    await expect(page.getByRole('button', { name: /导出保留的草稿/ })).toHaveCount(0)
    deliver = true
    release?.()
    await expect
      .poll(async () => (await request<{ content: { plain_text: string } }>(page, `/pages/${id}`)).content.plain_text)
      .toContain('Corrected name Local draft A')
    await page.reload()
    await expect(page.locator('.editor-content')).toContainText('Corrected name Local draft A')
    await expect(page.locator('.editor-content')).toContainText('Second block')
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('a virtualized row survives an attachment upload after focus and viewport leave it', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  const gate = Promise.withResolvers<void>()
  const started = Promise.withResolvers<void>()
  try {
    await page.goto(location(state.report_id))
    const saved = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      title: 'Upload retention review',
      type: 'database'
    })
    id = saved.page.id
    const { table } = await request<{ table: { id: string } }>(page, `/databases/${id}/tables`, 'POST', {
      name: 'Upload rows'
    })
    const { fields } = await request<{ fields: DatabaseField[] }>(page, `/tables/${table.id}`)
    const primary = fields.find(field => field.is_primary)!
    const { field } = await request<{ field: DatabaseField }>(page, `/tables/${table.id}/fields`, 'POST', {
      name: 'Evidence',
      type: 'attachment',
      config: {}
    })
    for (let offset = 0; offset < 600; offset += 200) {
      await request(page, `/tables/${table.id}/records`, 'POST', {
        creates: Array.from({ length: 200 }, (_, i) => ({
          data: { [primary.id]: `Row ${String(offset + i).padStart(4, '0')}` }
        }))
      })
    }
    await page.goto(location(id))
    const grid = page.getByRole('region', { name: '数据表记录', exact: true })
    const row = grid.locator('[data-grid-record]').first()
    await expect(row).toBeVisible()
    const rowID = await row.getAttribute('data-grid-record')
    await page.route(`**/api/v2/pod/pages/${id}/files`, async route => {
      if (route.request().method() !== 'POST') return route.continue()
      started.resolve()
      await gate.promise
      return route.continue()
    })
    await row.getByLabel('添加附件', { exact: true }).setInputFiles({
      name: 'evidence.txt',
      mimeType: 'text/plain',
      buffer: Buffer.from('Retained across virtual scroll')
    })
    await started.promise
    await page.getByRole('textbox', { name: '页面标题', exact: true }).focus()
    await grid.evaluate(element => {
      element.scrollTop = element.scrollHeight
    })
    await expect(grid.locator(`[data-grid-record="${rowID}"]`)).toHaveCount(1)
    expect(await grid.locator('[data-grid-record]').count()).toBeLessThan(100)
    gate.resolve()
    await expect
      .poll(async () => {
        const { records } = await request<{ records: DatabaseRecord[] }>(page, `/tables/${table.id}/query`, 'POST', {
          ids: [rowID]
        })
        return records[0]?.data[field.id]
      })
      .toMatchObject([{ name: 'evidence.txt' }])
    await page.reload()
    await expect(page.getByRole('link', { name: 'evidence.txt', exact: true })).toBeVisible()
  } finally {
    gate.resolve()
    if (id) await request(page, `/pages/${id}`, 'DELETE').catch(() => {})
    await context.close()
  }
})

test('bold editing does not toggle the sidebar, and the page shortcut still works outside inputs', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto(location(state.report_id))
    const saved = await request<{ page: { id: string; revision: number } }>(page, '/pages', 'POST', {
      title: 'Shortcut ownership review',
      type: 'doc'
    })
    id = saved.page.id
    await request(page, `/pages/${id}/content`, 'PUT', {
      base_revision: saved.page.revision,
      xml: '<page><p>Editable text</p></page>'
    })
    await page.goto(location(id))
    const editor = page.locator('.editor-content')
    await expect(editor).toContainText('Editable text')
    const sidebar = page.locator('[data-slot="sidebar"][data-state]')
    const before = await sidebar.getAttribute('data-state')
    await editor.click()
    await page.keyboard.press('ControlOrMeta+End')
    await page.keyboard.press('ControlOrMeta+b')
    await page.keyboard.insertText('Bold review')
    await expect(editor.locator('strong,b')).toContainText('Bold review')
    await expect(sidebar).toHaveAttribute('data-state', before!)
    await page.getByRole('textbox', { name: '页面标题', exact: true }).focus()
    await page.keyboard.press('ControlOrMeta+b')
    await expect(sidebar).toHaveAttribute('data-state', before!)
    await page.locator('body').click({ position: { x: 5, y: 5 } })
    await page.keyboard.press('ControlOrMeta+b')
    await expect(sidebar).not.toHaveAttribute('data-state', before!)
    await expect
      .poll(async () => (await request<{ content: { content: string } }>(page, `/pages/${id}`)).content.content)
      .toContain('Bold review')
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE').catch(() => {})
    await context.close()
  }
})
