import { state, request } from './fixtures'
import { expect, test } from '@playwright/test'
import type { BaseField, BaseRecord } from '@ankole/applet-sdk/types'
import { pageRoute } from './routes'

test.setTimeout(30_000)
const location = (id: string) => state.base_url + pageRoute(id)

for (const cancel of [false, true]) {
  test(`${cancel ? 'canceling' : 'committing'} a cross-column IME replacement preserves remote HTTP writes through the real page socket`, async ({
    browser
  }) => {
    const context = await browser.newContext()
    await context.addCookies(state.owner.cookies)
    const page = await context.newPage()
    let id: string | undefined
    const batches: Array<{ base_revision: number }> = []
    page.on('websocket', socket => {
      socket.on('framesent', ({ payload }) => {
        const frame = JSON.parse(payload.toString()) as unknown[]
        if (frame[2] === `page:${id}` && frame[3] === 'changes') {
          batches.push(frame[4] as { base_revision: number })
        }
      })
    })
    const source = (after: string) =>
      `<page><columns><column><p>Left</p><p>Left second</p></column><column><p>Right</p></column></columns><p>${after}</p></page>`
    let client: Awaited<ReturnType<typeof context.newCDPSession>> | undefined
    try {
      await page.goto(location(state.report_id))
      const created = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
        title: 'IME with concurrent remote text',
        type: 'doc'
      })
      id = created.page.id
      const seeded = await request<{ page: { revision: number } }>(page, `/pages/${id}/content`, 'PUT', {
        base_revision: 0,
        xml: source('After')
      })
      await page.goto(location(id))
      const editor = page.locator('.editor-content')
      await expect(editor.locator('p')).toHaveText(['Left', 'Left second', 'Right', 'After'])
      const columns = editor.locator('.editor-column')
      const left = (await columns.first().locator('p').first().boundingBox())!
      const right = (await columns.last().locator('p').first().boundingBox())!
      await page.mouse.move(left.x - 65, left.y + 2)
      await page.mouse.down()
      await page.mouse.move(right.x + 80, right.y + right.height - 2, { steps: 16 })
      await page.mouse.up()
      await expect(page.locator('.editor-selected-block')).toHaveText(['Left', 'Right'])
      client = await context.newCDPSession(page)
      // CDP drives the native browser composition path; OS IME acceptance is separate.
      await client.send('Input.imeSetComposition', { text: 'zh', selectionStart: 2, selectionEnd: 2 })
      await expect(columns).toHaveCount(2)
      await page.evaluate(() => {
        const probe = { node: getSelection()!.anchorNode!, ended: 0 }
        const target = window as Window & { imeProbe?: typeof probe }
        target.imeProbe = probe
        document.addEventListener('compositionend', () => probe.ended++)
      })
      let revision = seeded.page.revision
      for (const after of ['Remote After', 'Latest After']) {
        const remote = await request<{ page: { revision: number } }>(page, `/pages/${id}/content`, 'PUT', {
          base_revision: revision,
          xml: source(after)
        })
        revision = remote.page.revision
        await expect(editor).toContainText(after)
        await expect(columns).toHaveCount(2)
        expect(
          await page.evaluate(() => {
            const probe = (window as Window & { imeProbe?: { node: Node; ended: number } }).imeProbe!
            return {
              connected: probe.node.isConnected,
              same: getSelection()!.anchorNode === probe.node,
              ended: probe.ended
            }
          })
        ).toEqual({ connected: true, same: true, ended: 0 })
        expect(batches).toHaveLength(0)
      }
      if (cancel) await client.send('Input.imeSetComposition', { text: '', selectionStart: 0, selectionEnd: 0 })
      else await client.send('Input.insertText', { text: '中' })
      const expected = [cancel ? '' : '中', 'Left second', 'Latest After']
      await expect(columns).toHaveCount(0)
      await expect(editor.locator(':scope > p')).toHaveText(expected)
      await expect.poll(() => batches.length).toBeGreaterThan(0)
      expect(batches[0]!.base_revision).toBe(revision)
      await expect
        .poll(async () => (await request<{ page: { revision: number } }>(page, `/pages/${id}`)).page.revision)
        .toBeGreaterThan(revision)
      await editor.focus()
      await page.keyboard.press('ControlOrMeta+z')
      await expect(columns).toHaveCount(2)
      await expect(editor.locator('p')).toHaveText(['Left', 'Left second', 'Right', 'Latest After'])
      await page.keyboard.press('ControlOrMeta+Shift+z')
      await expect(columns).toHaveCount(0)
      await expect(editor.locator(':scope > p')).toHaveText(expected)
      await expect
        .poll(async () => {
          const saved = await request<{ content: { content: string } }>(page, `/pages/${id}`)
          return page.evaluate(xml => {
            const document = new DOMParser().parseFromString(xml, 'application/xml')
            return Array.from(document.documentElement.children).map(element => ({
              tag: element.tagName,
              text: element.textContent
            }))
          }, saved.content.content)
        })
        .toEqual(expected.map(text => ({ tag: 'p', text })))
      const saved = await request<{ page: { revision: number }; content: { content: string } }>(page, `/pages/${id}`)
      await page.reload()
      await expect(page.locator('.editor-content > p')).toHaveText(expected)
      await expect(page.locator('.editor-column')).toHaveCount(0)
      const reloaded = await request<{ page: { revision: number }; content: { content: string } }>(page, `/pages/${id}`)
      expect(reloaded.content.content).toBe(saved.content.content)
      expect(reloaded.page.revision).toBe(saved.page.revision)
    } finally {
      await client?.detach()
      if (id) await request(page, `/pages/${id}`, 'DELETE')
      await context.close()
    }
  })
}

test('remote writes preserve an unconfirmed local draft and commit it through the original OT request', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  let held = 0
  let deliver = false
  let release: (() => void) | undefined
  let original: { reference: unknown; payload: unknown } | undefined
  let originalReply: { status?: string } | undefined
  await page.routeWebSocket('**/pod/socket/websocket*', socket => {
    const server = socket.connectToServer()
    socket.onMessage(message => {
      const frame = JSON.parse(message.toString()) as unknown[]
      if (frame[2] === `page:${id}` && frame[3] === 'changes' && !deliver) {
        held++
        original ??= { reference: frame[1], payload: structuredClone(frame[4]) }
        // Forward the captured frame without rebuilding its request identity or payload.
        release ??= () => server.send(message)
        return
      }
      server.send(message)
    })
    server.onMessage(message => {
      const frame = JSON.parse(message.toString()) as unknown[]
      if (original && frame[2] === `page:${id}` && frame[1] === original.reference && frame[3] === 'phx_reply') {
        originalReply = frame[4] as { status?: string }
      }
      socket.send(message)
    })
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
    expect(original?.payload).toMatchObject({
      base_revision: seeded.page.revision,
      client_id: expect.any(String),
      client_seq: expect.any(Number)
    })
    expect((await request<{ content: { content: string } }>(page, `/pages/${id}`)).content.content).toBe(
      '<page><p>Initial</p></page>'
    )
    const draft = 'Local draft A'
    let revision = seeded.page.revision
    let previousName = 'Initial'
    for (const paragraphs of [
      ['Remote name', 'Appended block'],
      ['Corrected name', 'Appended block', 'Second block']
    ]) {
      const saved = await request<{ page: { revision: number } }>(page, `/pages/${id}/content`, 'PUT', {
        base_revision: revision,
        xml: `<page>${paragraphs.map(text => `<p>${text}</p>`).join('')}</page>`
      })
      revision = saved.page.revision
      for (const text of paragraphs) await expect(editor).toContainText(text)
      await expect(editor).toContainText(draft)
      const text = await editor.textContent()
      expect(text!.split(draft)).toHaveLength(2)
      expect(text).not.toContain(previousName)
      previousName = paragraphs[0]!
    }
    await expect(page.getByRole('button', { name: /导出保留的草稿/ })).toHaveCount(0)
    expect(originalReply).toBeUndefined()
    deliver = true
    release?.()
    await expect.poll(() => originalReply).toMatchObject({ status: 'ok' })
    await expect
      .poll(async () => {
        const saved = await request<{ page: { revision: number }; content: { plain_text: string } }>(
          page,
          `/pages/${id}`
        )
        return { committed: saved.page.revision > revision, copies: saved.content.plain_text.split(draft).length - 1 }
      })
      .toEqual({ committed: true, copies: 1 })
    const saved = await request<{
      page: { revision: number }
      content: { content: string; plain_text: string }
    }>(page, `/pages/${id}`)
    for (const text of ['Corrected name', 'Appended block', 'Second block']) {
      expect(saved.content.plain_text).toContain(text)
    }
    expect(saved.content.plain_text).not.toContain('Initial')
    expect(saved.content.plain_text).not.toContain('Remote name')
    const paragraphs = await page.evaluate(xml => {
      const document = new DOMParser().parseFromString(xml, 'application/xml')
      return Array.from(document.documentElement.children).map(element => element.textContent ?? '')
    }, saved.content.content)
    test.info().annotations.push({
      type: 'draft-position',
      description: `Retained draft paragraph: ${paragraphs.findIndex(text => text.includes(draft)) + 1}`
    })
    await expect(editor.locator(':scope > p')).toHaveText(paragraphs)
    await page.reload()
    await expect(page.locator('.editor-content > p')).toHaveText(paragraphs)
    const reloaded = await request<{ page: { revision: number }; content: { content: string } }>(page, `/pages/${id}`)
    expect(reloaded.content.content).toBe(saved.content.content)
    expect(reloaded.page.revision).toBe(saved.page.revision)
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
      type: 'base'
    })
    id = saved.page.id
    const { table } = await request<{ table: { id: string } }>(page, `/bases/${id}/tables`, 'POST', {
      name: 'Upload rows'
    })
    const { fields } = await request<{ fields: BaseField[] }>(page, `/tables/${table.id}`)
    const primary = fields.find(field => field.is_primary)!
    const { field } = await request<{ field: BaseField }>(page, `/tables/${table.id}/fields`, 'POST', {
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
    await page.getByRole('button', { name: 'Upload rows', exact: true }).click()
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
        const { records } = await request<{ records: BaseRecord[] }>(page, `/tables/${table.id}/query`, 'POST', {
          ids: [rowID]
        })
        return records[0]?.data[field.id]
      })
      .toMatchObject([{ name: 'evidence.txt' }])
    await page.reload()
    await page.getByRole('button', { name: 'Upload rows', exact: true }).click()
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
