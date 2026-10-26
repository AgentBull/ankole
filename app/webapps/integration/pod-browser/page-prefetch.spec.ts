import { state, request } from './fixtures'
import { pageRoute } from './routes'
import { writeFileSync } from 'node:fs'
import { expect, test, type Route } from '@playwright/test'

test('a cold page fetches its data before its lazy module and chat query changes do not refetch it', async ({
  browser
}, testInfo) => {
  const setup = await browser.newContext({ baseURL: state.base_url })
  await setup.addCookies(state.owner.cookies)
  const setupPage = await setup.newPage()
  let pageID: string | undefined
  const context = await browser.newContext({ baseURL: state.base_url, serviceWorkers: 'block' })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const cdp = await context.newCDPSession(page)
  await cdp.send('Network.enable')
  await cdp.send('Network.setCacheDisabled', { cacheDisabled: true })
  const held: Route[] = []
  const events: { event: string; elapsedMS: number }[] = []
  const started = Date.now()
  const record = (event: string) => events.push({ event, elapsedMS: Date.now() - started })
  const errors: string[] = []
  let released = false
  let pageRequests = 0
  let fetchedAt = 0
  page.on('pageerror', error => errors.push(error.message))
  page.on('request', request => {
    if (request.method() === 'GET' && new URL(request.url()).pathname === `/api/v2/pod/pages/${pageID}`) {
      pageRequests++
      record('page data requested')
    }
  })
  await page.route(/\/page-workspace-[^/]+\.js(?:\?.*)?$/, async route => {
    if (released) return route.continue()
    held.push(route)
    record('page module blocked')
  })
  try {
    await setupPage.goto('/')
    const created = await request<{ page: { id: string } }>(setupPage, '/pages', 'POST', {
      type: 'doc',
      title: 'Parallel page loading probe',
      private_owner_uid: state.owner.uid
    })
    pageID = created.page.id
    await request(setupPage, `/pages/${pageID}/content`, 'PUT', {
      base_revision: 0,
      xml: '<page><p>页面数据与代码并行加载。</p></page>'
    })
    const dataResponse = page.waitForResponse(
      response =>
        response.request().method() === 'GET' && new URL(response.url()).pathname === `/api/v2/pod/pages/${pageID}`
    )
    await page.goto(pageRoute(pageID), { waitUntil: 'commit' })
    await expect.poll(() => held.length).toBeGreaterThan(0)
    const response = await dataResponse
    expect(response.status()).toBe(200)
    expect(await response.finished()).toBeNull()
    fetchedAt = Date.now()
    record('page data finished while module blocked')
    expect(released).toBe(false)
    await expect(page.locator('.editor-content')).toHaveCount(0)
    expect(pageRequests).toBe(1)

    released = true
    record('page module released')
    await Promise.all(held.map(route => route.continue()))
    const editor = page.locator('.editor-content')
    await expect(editor).toBeVisible()
    await expect(editor).toContainText('页面数据与代码并行加载。')
    await editor.click()
    await page.keyboard.press('End')
    await page.keyboard.type('x')
    await expect(editor).toContainText('。x')
    await page.keyboard.press('ControlOrMeta+z')
    await expect(editor).not.toContainText('。x')
    await page.waitForLoadState('networkidle')
    record('editor usable without duplicate page GET')
    expect(pageRequests).toBe(1)

    // QueryClient freshness lasts 15s. Exercise query-only navigation after it expires,
    // so a duplicate loader call cannot be hidden by its fresh-cache short circuit.
    await new Promise(resolve => setTimeout(resolve, Math.max(0, fetchedAt + 16_000 - Date.now())))
    const opener = page.getByRole('button', { name: '页面对话', exact: true })
    await opener.click()
    const panel = page.getByRole('complementary', { name: '页面对话', exact: true })
    await expect(panel.getByRole('textbox', { name: '消息', exact: true })).toBeVisible()
    await expect.poll(() => new URL(page.url()).searchParams.has('chat')).toBe(true)
    await page.waitForLoadState('networkidle')
    record('page chat opened after page query became stale')
    expect(pageRequests).toBe(1)
    await panel.getByRole('button', { name: '关闭页面对话', exact: true }).click()
    await expect(panel).toBeHidden()
    await expect.poll(() => new URL(page.url()).searchParams.has('chat')).toBe(false)
    await page.waitForLoadState('networkidle')
    record('page chat closed without duplicate page GET')
    expect(pageRequests).toBe(1)
    expect(errors).toEqual([])
  } finally {
    const evidence = testInfo.outputPath('network-probe.json')
    writeFileSync(evidence, JSON.stringify({ events, pageRequests, errors, cacheDisabled: true }, null, 2))
    await testInfo.attach('page-prefetch-network-probe', {
      path: evidence,
      contentType: 'application/json'
    })
    await context.close()
    if (pageID) await request(setupPage, `/pages/${pageID}`, 'DELETE')
    await setup.close()
  }
})

test('a cold Base loads its table list and schema before the editor module is available', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, serviceWorkers: 'block' })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const held: Route[] = []
  let released = false
  let tableRequests = 0
  let schemaRequests = 0
  page.on('request', request => {
    const path = new URL(request.url()).pathname
    if (request.method() === 'GET' && path === `/api/v2/pod/bases/${state.base_id}`) tableRequests++
    if (request.method() === 'GET' && path === `/api/v2/pod/tables/${state.table_id}`) schemaRequests++
  })
  await page.route(/\/base-page-[^/]+\.js(?:\?.*)?$/, async route => {
    if (released) return route.continue()
    held.push(route)
  })
  try {
    const tables = page.waitForResponse(
      response =>
        response.request().method() === 'GET' &&
        new URL(response.url()).pathname === `/api/v2/pod/bases/${state.base_id}`
    )
    const schema = page.waitForResponse(
      response =>
        response.request().method() === 'GET' &&
        new URL(response.url()).pathname === `/api/v2/pod/tables/${state.table_id}`
    )
    await page.goto(pageRoute(state.base_id), { waitUntil: 'commit' })
    await expect.poll(() => held.length).toBeGreaterThan(0)
    expect((await tables).status()).toBe(200)
    expect((await schema).status()).toBe(200)
    expect(released).toBe(false)
    await expect(page.locator('.pod-base')).toHaveCount(0)
    const beforeMount = { tables: tableRequests, schema: schemaRequests }
    released = true
    await Promise.all(held.map(route => route.continue()))
    await expect(page.getByRole('spinbutton', { name: 'Amount', exact: true }).first()).toBeVisible()
    await page.waitForLoadState('networkidle')
    expect({ tables: tableRequests, schema: schemaRequests }).toEqual(beforeMount)
    await expect(page.getByText('正在加载数据表…', { exact: true })).toHaveCount(0)
    await expect(page.getByText('正在加载表结构…', { exact: true })).toHaveCount(0)
  } finally {
    released = true
    await Promise.all(held.map(route => route.continue().catch(() => {})))
    await context.close()
  }
})
