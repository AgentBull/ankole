import { state, request } from './fixtures'
import { listRoute, pageRoute } from './routes'
import { writeFileSync } from 'node:fs'
import { expect, test, type Route } from '@playwright/test'

for (const intent of ['hover', 'focus'] as const) {
  test(`${intent} preloads Page code and data together without recording a visit`, async ({ browser }) => {
    const context = await browser.newContext({ baseURL: state.base_url, serviceWorkers: 'block' })
    await context.addCookies(state.owner.cookies)
    const setup = await context.newPage()
    const page = await context.newPage()
    const held: Route[] = []
    let released = false
    let pageID: string | undefined
    let reads = 0
    let writes = 0
    page.on('request', request => {
      const path = new URL(request.url()).pathname
      if (request.method() === 'GET' && path === `/api/v2/pod/pages/${pageID}`) reads++
      if (request.method() !== 'GET' && path === `/api/v2/pod/pages/${pageID}/user-state`) writes++
    })
    await page.route(/\/page-workspace-[^/]+\.js(?:\?.*)?$/, async route => {
      if (released) return route.continue()
      held.push(route)
    })
    try {
      await setup.goto(listRoute('trash'))
      const title = `Page ${intent} ${crypto.randomUUID()}`
      const created = await request<{ page: { id: string } }>(setup, '/pages', 'POST', { type: 'doc', title })
      pageID = created.page.id
      await page.goto(listRoute('space'))
      const link = page
        .getByRole('region', { name: '空间', exact: true })
        .getByRole('link', { name: title, exact: true })
      await expect(link).toBeVisible()
      await page.waitForLoadState('networkidle')
      const details = page.waitForResponse(
        response =>
          response.request().method() === 'GET' && new URL(response.url()).pathname === `/api/v2/pod/pages/${pageID}`
      )
      await link[intent]()
      await expect.poll(() => held.length).toBeGreaterThan(0)
      expect((await details).ok()).toBe(true)
      expect(reads).toBe(1)
      expect(writes).toBe(0)
      expect(new URL(page.url()).pathname).toBe(listRoute('space'))

      released = true
      await Promise.all(held.map(route => route.continue()))
      await link.click()
      await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(title)
      await expect(page.locator('.editor-content')).toBeVisible()
      await page.waitForLoadState('networkidle')
      expect(reads).toBe(1)
      expect(writes).toBe(1)
    } finally {
      released = true
      await Promise.all(held.map(route => route.continue().catch(() => {})))
      if (pageID) await request(setup, `/pages/${pageID}`, 'DELETE')
      await context.close()
    }
  })
}

test('page data loads in parallel and cached navigation does not wait for revalidation', async ({
  browser
}, testInfo) => {
  const setup = await browser.newContext({ baseURL: state.base_url })
  await setup.addCookies(state.owner.cookies)
  const setupPage = await setup.newPage()
  const title = `Parallel page loading probe ${Date.now()}`
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
  let trashed = false
  const pageRefresh = Promise.withResolvers<void>()
  const directoryRefresh = Promise.withResolvers<void>()
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
      title,
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

    await page.getByRole('link', { name: '回收站', exact: true }).click()
    await expect(page.getByRole('heading', { name: '回收站', exact: true })).toBeVisible()
    let heldPageReads = 0
    await page.route(`**/api/v2/pod/pages/${pageID}`, async route => {
      if (route.request().method() === 'GET') {
        heldPageReads++
        await pageRefresh.promise
      }
      await route.continue()
    })
    await page
      .getByRole('region', { name: '私人页面', exact: true })
      .getByRole('link', { name: title, exact: true })
      .click()
    await expect.poll(() => heldPageReads).toBeGreaterThan(0)
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(title)
    record('cached page visible while its revalidation is blocked')
    const refreshed = page.waitForResponse(
      response =>
        response.request().method() === 'GET' && new URL(response.url()).pathname === `/api/v2/pod/pages/${pageID}`
    )
    pageRefresh.resolve()
    expect((await refreshed).status()).toBe(200)

    let heldDirectoryReads = 0
    await page.route(/\/api\/v2\/pod\/pages(?:\/(?:children|navigation))?(?:\?|$)/, async route => {
      if (route.request().method() === 'GET') {
        heldDirectoryReads++
        await directoryRefresh.promise
      }
      await route.continue()
    })
    await page.locator('.pod-page-header').getByRole('button', { name: '更多操作', exact: true }).click()
    const removed = page.waitForResponse(
      response =>
        response.request().method() === 'DELETE' && new URL(response.url()).pathname === `/api/v2/pod/pages/${pageID}`
    )
    await page.getByRole('menuitem', { name: '移到回收站', exact: true }).click()
    expect((await removed).ok()).toBe(true)
    trashed = true
    await expect.poll(() => heldDirectoryReads).toBeGreaterThan(0)
    await expect(page).toHaveURL(state.base_url + listRoute('private'))
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toHaveCount(0)
    record('deleted page exited while directory revalidation is blocked')
    directoryRefresh.resolve()
    expect(errors).toEqual([])
  } finally {
    pageRefresh.resolve()
    directoryRefresh.resolve()
    const evidence = testInfo.outputPath('network-probe.json')
    writeFileSync(evidence, JSON.stringify({ events, pageRequests, errors, cacheDisabled: true }, null, 2))
    await testInfo.attach('page-prefetch-network-probe', {
      path: evidence,
      contentType: 'application/json'
    })
    await context.close()
    if (pageID && !trashed) await request(setupPage, `/pages/${pageID}`, 'DELETE')
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
