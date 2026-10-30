import { expect, test } from '@playwright/test'
import { request, state } from './fixtures'
import { listRoute, pageRoute } from './routes'

test('Recent retries a failed capabilities request independently of navigation', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const realtime = Promise.withResolvers<void>()
  let failCapabilities = true
  try {
    // Keep subscription reconciliation from racing the user's explicit retry.
    await page.route('**/api/v2/pod/realtime-token', async route => {
      await realtime.promise
      await route.continue()
    })
    await page.route(/\/api\/v2\/pod\/pages\/navigation(?:\?|$)/, route => route.abort())
    await page.route(/\/api\/v2\/pod\/pages\/children(?:\?|$)/, route => {
      const url = new URL(route.request().url())
      return failCapabilities && url.searchParams.get('scope') === 'space' ? route.abort() : route.continue()
    })
    await page.goto(listRoute('recent'))
    const main = page.getByRole('main')
    await expect(main.getByRole('alert')).toBeVisible({ timeout: 15000 })
    const create = main.getByRole('button', { name: '新建页面', exact: true })
    await expect(create).toHaveCount(0)
    failCapabilities = false
    await main.getByRole('button', { name: '重试', exact: true }).click()
    await expect(create).toBeEnabled()
    await expect(main.getByRole('alert')).toHaveCount(0)
  } finally {
    realtime.resolve()
    await context.close()
  }
})

for (const entry of [
  { scope: 'trash', selector: '.pod-sidebar-top', label: 'default sidebar' },
  ...['recent', 'favorites', 'shared', 'search'].map(scope => ({
    scope,
    selector: '.pod-content-list',
    label: scope
  }))
]) {
  test(`${entry.label} can create a document from a cold cache when navigation fails`, async ({ browser }) => {
    const context = await browser.newContext({ baseURL: state.base_url })
    await context.addCookies(state.owner.cookies)
    const page = await context.newPage()
    const realtime = Promise.withResolvers<void>()
    let navigationAttempts = 0
    let createdID: string | undefined
    try {
      await page.route('**/api/v2/pod/realtime-token', async route => {
        await realtime.promise
        await route.continue()
      })
      await page.route(/\/api\/v2\/pod\/pages\/navigation(?:\?|$)/, route => {
        navigationAttempts++
        return route.abort()
      })
      const capabilities = page.waitForResponse(response => {
        const url = new URL(response.url())
        return (
          response.request().method() === 'GET' &&
          url.pathname === '/api/v2/pod/pages/children' &&
          url.searchParams.get('scope') === 'space' &&
          !url.searchParams.has('parent_id') &&
          !url.searchParams.has('cursor')
        )
      })
      await page.goto(listRoute(entry.scope))
      const directory = await capabilities
      expect(directory.ok()).toBe(true)
      expect(await directory.json()).toMatchObject({
        principal_uid: state.owner.uid,
        can_create_space: true
      })
      await expect.poll(() => navigationAttempts).toBeGreaterThan(0)

      if (entry.scope !== 'trash') {
        await page.getByRole('tab', { name: '对话', exact: true }).click()
        await expect(
          page.locator('.pod-sidebar-top').getByRole('button', { name: '新建页面', exact: true })
        ).toHaveCount(0)
        // Joining invalidates content queries. Only the list can refresh root capabilities
        // here: the default create button is unmounted and navigation has failed.
        const refreshed = page.waitForResponse(response => {
          const url = new URL(response.url())
          return url.pathname === '/api/v2/pod/pages/children' && url.searchParams.get('scope') === 'space'
        })
        realtime.resolve()
        expect((await refreshed).ok()).toBe(true)
      } else {
        realtime.resolve()
      }

      const create = page.locator(entry.selector).getByRole('button', { name: '新建页面', exact: true })
      await expect(create).toBeEnabled()
      await create.click()
      const saved = page.waitForResponse(
        response => response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/pages'
      )
      await page.getByRole('menuitem', { name: '文档', exact: true }).click()
      const response = await saved
      expect(response.status()).toBe(201)
      createdID = ((await response.json()) as { page: { id: string } }).page.id
      await expect(page).toHaveURL(state.base_url + pageRoute(createdID))
      await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue('')
      const persisted = await request<{ page: Record<string, unknown> }>(page, `/pages/${createdID}`)
      expect(persisted.page).toMatchObject({
        id: createdID,
        type: 'doc',
        title: '',
        parent_id: null,
        private_owner_uid: null
      })
    } finally {
      realtime.resolve()
      try {
        if (createdID) await request(page, `/pages/${createdID}`, 'DELETE')
      } finally {
        await context.close()
      }
    }
  })
}
