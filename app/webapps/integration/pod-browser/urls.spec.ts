import { readFileSync } from 'node:fs'
import { expect, test, type BrowserContext } from '@playwright/test'
import { conversationRoute, pageRoute } from './routes'

const state = JSON.parse(readFileSync(process.env.POD_BROWSER_STATE_PATH!, 'utf8')) as {
  base_url: string
  tenant_id: string
  tenant_slug: string
  report_id: string
  conversation_id: string
  owner: { cookies: Parameters<BrowserContext['addCookies']>[0] }
}

test('Pod entry, reload and legacy links use the tenant host and short IDs with shared account proofs', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    const origin = new URL(state.base_url)
    expect(origin.hostname).toBe(`${state.tenant_slug}.ankole.localhost`)
    const foreign = new URL(state.base_url)
    foreign.hostname = `other-${state.tenant_slug}.ankole.localhost`
    expect((await context.cookies(foreign.href)).length).toBeGreaterThan(0)

    await page.goto(`/pod/pages/${state.report_id}?tenant_id=${state.tenant_id}`)
    await expect(page).toHaveURL(state.base_url + pageRoute(state.report_id))
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()
    expect(await page.locator('meta[name="ankole-pod"]').getAttribute('content')).toBe(state.tenant_id)
    await page.reload()
    await expect(page).toHaveURL(state.base_url + pageRoute(state.report_id))
    await expect(page.locator('.editor-content')).toBeVisible()

    await page.goto(`/conversations/${state.conversation_id}`)
    await expect(page).toHaveURL(state.base_url + conversationRoute(state.conversation_id))
    await expect(page.getByRole('region', { name: '对话消息', exact: true })).toBeVisible()
    const cookies = await context.cookies(state.base_url)
    expect(cookies.length).toBeGreaterThan(0)
    expect(cookies.every(cookie => cookie.domain === '.ankole.localhost' && cookie.path === '/')).toBe(true)
  } finally {
    await context.close()
  }
})
