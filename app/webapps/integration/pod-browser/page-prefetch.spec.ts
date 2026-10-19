import { pageRoute } from './routes'
import { readFileSync, writeFileSync } from 'node:fs'
import { expect, test, type BrowserContext, type Page, type Route } from '@playwright/test'

const state = JSON.parse(readFileSync(process.env.POD_BROWSER_STATE_PATH!, 'utf8')) as {
  base_url: string
  tenant_id: string
  owner: { uid: string; cookies: Parameters<BrowserContext['addCookies']>[0] }
}

async function request<T>(page: Page, path: string, method = 'GET', body?: unknown): Promise<T> {
  return page.evaluate(
    async ({ path, method, body }) => {
      const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content
      const response = await fetch(`/.internal-apis/pod${path}`, {
        method,
        credentials: 'same-origin',
        headers: {
          accept: 'application/json',
          'content-type': 'application/json',
          'x-ankole-authentication': meta('ankole-authentication')!,
          'x-ankole-pod': meta('ankole-pod')!,
          'x-csrf-token': meta('csrf-token')!
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) })
      })
      if (!response.ok) throw new Error(`Pod ${method} ${path}: ${response.status}`)
      return response.status === 204 ? null : response.json()
    },
    { path, method, body }
  )
}

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
    if (request.method() === 'GET' && new URL(request.url()).pathname === `/.internal-apis/pod/pages/${pageID}`) {
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
        response.request().method() === 'GET' &&
        new URL(response.url()).pathname === `/.internal-apis/pod/pages/${pageID}`
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
