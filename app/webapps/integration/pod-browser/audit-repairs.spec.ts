import { state, request } from './fixtures'
import { readFileSync } from 'node:fs'
import { expect, test } from '@playwright/test'
import type { DatabaseField, DatabaseRecord } from '@ankole/applet-sdk/types'
import { pageRoute, listRoute } from './routes'

test.setTimeout(30_000)
const location = (id: string) => state.base_url + pageRoute(id)

test('a late automatic recovery cannot replace edits made after a manual reload', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const started = Promise.withResolvers<void>()
  const release = Promise.withResolvers<void>()
  let id: string | undefined
  let held = 0
  await page.routeWebSocket('**/pod/socket/websocket*', ws => {
    const server = ws.connectToServer()
    ws.onMessage(message => {
      if (JSON.parse(message.toString())[3] === 'changes') {
        held++
        return
      }
      server.send(message)
    })
    server.onMessage(message => ws.send(message))
  })
  try {
    await page.goto(location(state.report_id))
    const saved = await request<{ page: { id: string; revision: number } }>(page, '/pages', 'POST', {
      title: 'Overlapping draft recovery',
      type: 'doc'
    })
    id = saved.page.id
    await request(page, `/pages/${id}/content`, 'PUT', {
      base_revision: saved.page.revision,
      xml: '<page><p>Initial</p></page>'
    })
    await page.goto(location(id))
    const editor = page.locator('.editor-content')
    await expect(editor).toContainText('Initial')
    await editor.click()
    await page.keyboard.press('ControlOrMeta+End')
    await page.keyboard.insertText('First local draft')
    await expect.poll(() => held).toBeGreaterThan(0)
    const latest = await request<{ page: { revision: number } }>(page, `/pages/${id}`)
    let reads = 0
    await page.route(`**/api/v2/pod/pages/${id}`, async route => {
      if (route.request().method() !== 'GET' || ++reads !== 1) return route.continue()
      const response = await route.fetch()
      expect(response.ok()).toBe(true)
      started.resolve()
      await release.promise
      await route.fulfill({ response })
    })
    await request(page, `/pages/${id}/content`, 'PUT', {
      base_revision: latest.page.revision,
      xml: '<page><p>Remote reset</p></page>'
    })
    await started.promise
    await page.getByRole('button', { name: '重新读取文档', exact: true }).click()
    await expect(editor).toContainText('Remote reset')
    await expect(editor).not.toContainText('First local draft')
    await editor.click()
    await page.keyboard.press('ControlOrMeta+End')
    await page.keyboard.insertText('Latest local draft')
    await expect(editor).toContainText('Latest local draft')
    const delivered = page.waitForEvent('requestfinished', {
      predicate: request => request.method() === 'GET' && request.url().endsWith(`/pages/${id}`)
    })
    release.resolve()
    await delivered
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
    await expect(editor).toContainText('Latest local draft')
    const download = page.waitForEvent('download')
    await page.getByRole('button', { name: /导出保留的草稿/ }).click()
    expect(readFileSync((await (await download).path())!, 'utf8')).toContain('First local draft')
  } finally {
    release.resolve()
    if (id) await request(page, `/pages/${id}`, 'DELETE').catch(() => {})
    await context.close()
  }
})

test('two external document resets keep both local drafts exportable and protect navigation', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  let held = 0
  await page.routeWebSocket('**/pod/socket/websocket*', ws => {
    const server = ws.connectToServer()
    ws.onMessage(message => {
      const frame = JSON.parse(message.toString())
      if (frame[3] === 'changes') {
        held++
        return
      }
      server.send(message)
    })
    server.onMessage(message => ws.send(message))
  })
  try {
    await page.goto(location(state.report_id))
    const saved = await request<{ page: { id: string; revision: number } }>(page, '/pages', 'POST', {
      title: 'Recovery owner review',
      type: 'doc'
    })
    id = saved.page.id
    await request(page, `/pages/${id}/content`, 'PUT', {
      base_revision: saved.page.revision,
      xml: '<page><p>Initial</p></page>'
    })
    await page.goto(location(id))
    const editor = page.locator('.editor-content')
    await expect(editor).toContainText('Initial')
    for (const [local, remote] of [
      ['Local draft A', 'Remote one'],
      ['Local draft B', 'Remote two']
    ]) {
      await editor.click()
      await page.keyboard.press('ControlOrMeta+End')
      await page.keyboard.insertText(local!)
      await expect.poll(() => held).toBeGreaterThan(0)
      const latest = await request<{ page: { revision: number } }>(page, `/pages/${id}`)
      await request(page, `/pages/${id}/content`, 'PUT', {
        base_revision: latest.page.revision,
        xml: `<page><p>${remote}</p></page>`
      })
      await expect(editor).toContainText(remote!)
      await expect(editor).not.toContainText(local!)
    }
    const exportButtons = page.getByRole('button', { name: /导出保留的草稿/ })
    await expect(exportButtons).toHaveCount(2)
    for (let i = 0; i < 2; i++) {
      const download = page.waitForEvent('download')
      await exportButtons.nth(i).click()
      const file = await download
      expect(readFileSync((await file.path())!, 'utf8')).toContain(i === 0 ? 'Local draft A' : 'Local draft B')
    }
    await page
      .getByRole('navigation', { name: '页面导航' })
      .getByRole('link', { name: '最近访问', exact: true })
      .click()
    await expect(page.getByRole('dialog', { name: '修改尚未保存' })).toBeVisible()
    const download = page.waitForEvent('download')
    await page.getByRole('button', { name: '下载草稿并离开', exact: true }).click()
    const file = await download
    const backup = JSON.parse(readFileSync((await file.path())!, 'utf8'))
    expect(backup.recoveryDrafts).toHaveLength(2)
    expect(backup.recoveryDrafts[0]).toContain('Local draft A')
    expect(backup.recoveryDrafts[1]).toContain('Local draft B')
    await expect(page).toHaveURL(state.base_url + listRoute('recent'))
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE').catch(() => {})
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
