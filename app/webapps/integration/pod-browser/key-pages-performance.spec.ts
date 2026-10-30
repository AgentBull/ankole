import { mkdirSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { expect, test, type Page } from '@playwright/test'
import { state, request } from './fixtures'
import { pageRoute } from './routes'
import { finalSnapshot, instrument, profiles, snapshot } from './performance-measurement'

const outputDirectory = process.env.POD_PERFORMANCE_OUTPUT
const trashTitle = `Performance trash ${Date.now()}`
const contentScopes = ['space', 'private', 'shared', 'recent', 'favorites', 'search', 'trash'] as const
const consolePaths = [
  '',
  'agents',
  'tenants',
  'providers',
  'access/principals',
  'access/groups',
  'identity',
  'identity/mappings',
  'oidc-clients',
  'agent-library',
  'conversations',
  'signals',
  'schedules',
  'schedules/checkbacks',
  'webhooks',
  'automation-jobs',
  'settings',
  'worker-envs',
  'worker-providers',
  'workers',
  'background-agent-jobs',
  'brain/objects',
  'brain/claims',
  'brain/sources',
  'brain/suggestions',
  'brain/merge-suggestions',
  'brain/contradictions',
  'brain/health',
  'brain/search-preview',
  'brain/principal-audit'
] as const

const routes = [
  ...contentScopes.map(scope => ({ name: scope, url: `${state.base_url}/content/${scope}`, console: false })),
  { name: 'home', url: `${state.base_url}/`, console: false },
  { name: 'base', url: `${state.base_url}${pageRoute(state.base_id)}`, console: false },
  { name: 'applet', url: `${state.base_url}${pageRoute(state.applet_id)}`, console: false },
  { name: 'account', url: `${state.base_url}/me`, console: false },
  { name: 'pod-settings', url: `${state.base_url}/settings`, console: false },
  ...consolePaths.map(route => ({
    name: `console-${route.replaceAll('/', '-') || 'home'}`,
    url: `${state.console_url}/${route}?data_tenant=${state.tenant_id}`,
    console: true
  }))
]

async function ready(page: Page, route: (typeof routes)[number]) {
  if (route.console) {
    await expect(page.locator('main h2').first()).toBeVisible()
    await expect(page.locator('main h2').first()).not.toHaveText(/Page not found|This page could not be shown/)
    await expect(page.locator('main [data-slot="skeleton"]')).toHaveCount(0)
  } else if (route.name === 'base') {
    await expect(page.getByRole('spinbutton', { name: 'Amount', exact: true })).toHaveValue('10')
  } else if (route.name === 'applet') {
    await expect(page.frameLocator('iframe').getByRole('heading', { name: 'Tracker v1', exact: true })).toBeVisible()
  } else if (route.name === 'home') {
    await expect(page.getByRole('textbox', { name: '消息', exact: true })).toBeVisible()
  } else if (route.name === 'pod-settings') {
    await expect(page.locator('#space-name')).toHaveValue(state.tenant_name)
  } else if (route.name === 'account') {
    await expect(page.getByRole('textbox').first()).toHaveValue('Browser owner')
  } else {
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible()
    await expect(page.getByRole('status').filter({ hasText: '正在加载' })).toHaveCount(0)
    await expect(page.locator('[data-slot="skeleton"]')).toHaveCount(0)
    if (route.name === 'trash') await expect(page.getByText(trashTitle, { exact: true })).toBeVisible()
    if (route.name === 'space') {
      await expect(
        page.locator('.pod-content-list').getByRole('link', { name: 'Browser report', exact: true })
      ).toBeVisible()
    }
  }
}

test.describe('Key page laboratory performance', () => {
  test.skip(!outputDirectory, 'Set POD_PERFORMANCE_OUTPUT to collect local browser evidence')
  let trashID = ''
  test.beforeAll(async ({ browser }) => {
    if (!outputDirectory) return
    mkdirSync(outputDirectory, { recursive: true })
    const context = await browser.newContext()
    await context.addCookies(state.owner.cookies)
    const page = await context.newPage()
    try {
      await page.goto(state.base_url)
      const created = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
        type: 'doc',
        title: trashTitle,
        private_owner_uid: state.owner.uid
      })
      trashID = created.page.id
      await request(page, `/pages/${trashID}`, 'DELETE')
    } finally {
      await context.close()
    }
  })

  for (const profile of profiles.filter(profile => !profile.mobile)) {
    for (const route of routes) {
      test(`${profile.name} cold ${route.name}`, async ({ browser }, testInfo) => {
        test.setTimeout(30_000)
        const context = await browser.newContext({
          viewport: profile.viewport,
          locale: 'en-US',
          serviceWorkers: 'block'
        })
        await context.addCookies(route.console ? state.site_admin.cookies : state.owner.cookies)
        const page = await context.newPage()
        const errors: string[] = []
        page.on('pageerror', error => errors.push(error.message))
        const requests = await instrument(page, await context.newCDPSession(page), profile)
        const actions: { name: string; duration: number }[] = []
        const act = async (name: string, run: () => Promise<unknown>) => {
          const start = performance.now()
          await run()
          actions.push({ name, duration: performance.now() - start })
        }
        try {
          await page.goto(route.url, { waitUntil: 'domcontentloaded' })
          await ready(page, route)
          const usableAt = await page.evaluate(() => performance.now())
          await page.evaluate(() => document.fonts.ready)
          await page.waitForLoadState('networkidle')
          const initial = await snapshot(page)
          if (route.name === 'trash') {
            await act('search trash', async () => {
              const input = page.getByRole('textbox', { name: '搜索回收站', exact: true })
              await input.pressSequentially('Performance')
              await expect(page).toHaveURL(/q=Performance/)
              await expect(page.getByText(trashTitle, { exact: true })).toBeVisible()
            })
            await act('restore page', async () => {
              const row = page
                .locator('li')
                .filter({ hasText: trashTitle, has: page.getByRole('button', { name: '恢复', exact: true }) })
              await row.getByRole('button', { name: '恢复', exact: true }).click()
              await expect(row).toHaveCount(0)
            })
            await request(page, `/pages/${trashID}`, 'DELETE')
          } else if (route.name === 'search') {
            await act('search documents', async () => {
              const results = page.waitForResponse(response => {
                const url = new URL(response.url())
                return url.pathname.endsWith('/pages/search') && url.searchParams.get('query') === 'Browser report'
              })
              await page.getByRole('textbox', { name: '搜索页面', exact: true }).pressSequentially('Browser report')
              expect((await results).ok()).toBe(true)
              await expect(page).toHaveURL(/q=Browser/)
              await expect(
                page.locator('.pod-content-list').getByRole('link', { name: 'Browser report', exact: true })
              ).toBeVisible()
            })
          } else if (route.name === 'space') {
            await act('expand directory', async () => {
              const row = page
                .locator('.pod-tree-row')
                .filter({ has: page.getByRole('link', { name: 'Browser report', exact: true }) })
              await row.getByRole('button', { name: 'Browser report', exact: true }).click()
              await expect(
                page
                  .getByRole('region', { name: '空间', exact: true })
                  .getByRole('link', { name: 'Browser sales', exact: true })
              ).toBeVisible()
            })
            await act('switch to trash', async () => {
              await page.getByRole('link', { name: '回收站', exact: true }).click()
              await expect(page.getByText(trashTitle, { exact: true })).toBeVisible()
            })
            await act('return to cached directory', async () => {
              await page.getByRole('link', { name: '空间', exact: true }).click()
              await expect(
                page.locator('.pod-content-list').getByRole('link', { name: 'Browser report', exact: true })
              ).toBeVisible()
            })
          } else if (route.name === 'base') {
            await act('edit cell draft', async () => {
              const cell = page.getByRole('spinbutton', { name: 'Amount', exact: true })
              await cell.click()
              await cell.press('ControlOrMeta+a')
              await cell.pressSequentially('12')
              await expect(cell).toHaveValue('12')
              await cell.press('Escape')
              await expect(cell).toHaveValue('10')
            })
          } else if (route.name === 'applet') {
            await act('applet interaction', async () => {
              const frame = page.frameLocator('iframe')
              await frame.getByRole('button', { name: 'Local counter 0', exact: true }).click()
              await expect(frame.getByRole('button', { name: 'Local counter 1', exact: true })).toBeVisible()
            })
          } else if (route.console) {
            if (route.name === 'console-home') {
              await act('open agents', async () => {
                await page.getByRole('link', { name: 'Agents', exact: true }).click()
                await expect(page.locator('main h2').first()).toHaveText('Agents')
                await ready(page, { ...route, name: 'console-agents' })
              })
            }
            await act('navigate to overview', async () => {
              await page.getByRole('link', { name: 'Home', exact: true }).click()
              await expect(page.locator('main').getByRole('heading', { name: 'Home', exact: true })).toBeVisible()
              await ready(page, { ...route, name: 'console-home' })
            })
          } else if (route.name === 'home') {
            await act('type and clear message draft', async () => {
              const input = page.getByRole('textbox', { name: '消息', exact: true })
              await input.pressSequentially('Performance')
              await expect(input).toHaveValue('Performance')
              await input.press('ControlOrMeta+a')
              await input.press('Backspace')
            })
          } else if (route.name === 'pod-settings') {
            await act('open members', async () => {
              await page.getByRole('tab', { name: '成员与管理员', exact: true }).click()
              await expect(page.getByText('Browser member', { exact: true })).toBeVisible()
            })
          } else if (route.name === 'account') {
            await act('edit and discard profile draft', async () => {
              const input = page.getByRole('textbox').first()
              await input.click()
              await input.press('End')
              await input.pressSequentially('x')
              await input.press('Backspace')
              await expect(input).toHaveValue('Browser owner')
            })
          } else {
            await act('open cached space', async () => {
              await page.getByRole('link', { name: '空间', exact: true }).click()
              await expect(
                page.locator('.pod-content-list').getByRole('link', { name: 'Browser report', exact: true })
              ).toBeVisible()
            })
          }
          const final = await finalSnapshot(page)
          expect(final.timeOrigin, 'In-app navigation keeps the current document and its cache').toBe(
            initial.timeOrigin
          )
          const target = path.join(outputDirectory!, `${profile.name}-${route.name}-${testInfo.repeatEachIndex}.json`)
          writeFileSync(
            target,
            JSON.stringify(
              {
                observedAt: new Date().toISOString(),
                browserVersion: browser.version(),
                browserChannel: process.env.POD_BROWSER_CHANNEL ?? 'chromium',
                profile,
                route: route.name,
                usableAt,
                initial,
                final,
                actions,
                requests: [...requests.values()],
                errors,
                caveat:
                  'Local laboratory sample with cold browser cache. CWV uses web-vitals; scripted INP is not a field p75. Applet iframe interactions are outside the top-frame INP measurement.'
              },
              null,
              2
            )
          )
          await testInfo.attach('performance', { path: target, contentType: 'application/json' })
          await page.screenshot({ path: target.replace(/\.json$/, '.png') })
          expect(errors).toEqual([])
          expect([...requests.values()].filter(resource => (resource.status ?? 0) >= 500)).toEqual([])
        } finally {
          await context.close()
        }
      })
    }
  }
})
