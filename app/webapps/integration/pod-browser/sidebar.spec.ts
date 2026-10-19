import { listRoute, pageRoute } from './routes'
import { readFileSync } from 'node:fs'
import { expect, test, type BrowserContext } from '@playwright/test'

const state = JSON.parse(readFileSync(process.env.POD_BROWSER_STATE_PATH!, 'utf8')) as {
  base_url: string
  tenant_id: string
  report_id: string
  owner: { cookies: Parameters<BrowserContext['addCookies']>[0] }
}

test('Search focuses its input and result rows keep native link and keyboard behavior', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const destination = pageRoute(state.report_id)
  try {
    await page.goto(destination)
    const title = await page.getByRole('textbox', { name: '页面标题', exact: true }).inputValue()
    await page.goto(listRoute('search'))
    const search = page.getByRole('textbox', { name: '搜索页面', exact: true })
    await expect(search).toBeFocused()
    await page.keyboard.insertText(title)
    await expect(search).toHaveValue(title)
    const result = page.getByRole('main').getByRole('link', { name: title, exact: true })
    await expect(result).toHaveAttribute('href', destination)
    await search.press('Tab')
    await expect(result).toBeFocused()
    const bounds = (await result.boundingBox())!
    const searchURL = page.url()
    const newTab = context.waitForEvent('page')
    await result.click({ modifiers: ['ControlOrMeta'], position: { x: bounds.width - 12, y: bounds.height / 2 } })
    const opened = await newTab
    await expect(opened).toHaveURL(state.base_url + destination)
    await expect(page).toHaveURL(searchURL)
    await opened.close()
    await result.press('Enter')
    await expect(page).toHaveURL(state.base_url + destination)
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(title)
  } finally {
    await context.close()
  }
})

test('mobile navigation has touch targets and closes when reopening the current page', async ({ browser }) => {
  const context = await browser.newContext({
    baseURL: state.base_url,
    viewport: { width: 390, height: 844 },
    hasTouch: true,
    isMobile: true
  })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(pageRoute(state.report_id))
    await page.getByRole('button', { name: '展开侧栏', exact: true }).click()
    const sidebar = page.getByRole('dialog', { name: '工作台导航', exact: true })
    await expect(sidebar).toBeVisible()
    const currentPage = sidebar.locator(`a.pod-tree-link[href*="${pageRoute(state.report_id)}"]`)
    await expect(currentPage).toHaveAttribute('aria-current', 'page')
    await expect(
      sidebar.locator('.pod-workspace-row').getByRole('button', { name: '新建页面', exact: true })
    ).toHaveAttribute('title', '新建页面')
    for (const targets of [sidebar.locator('.pod-nav-link'), sidebar.locator('.pod-tree-link')]) {
      const heights = await targets.evaluateAll(elements =>
        elements.map(element => element.getBoundingClientRect().height)
      )
      expect(heights.length).toBeGreaterThan(0)
      expect(heights.every(height => height >= 40)).toBe(true)
    }
    const toggles = await sidebar.locator('.pod-tree-toggle').evaluateAll(elements =>
      elements.map(element => {
        const bounds = element.getBoundingClientRect()
        const icon = element.querySelector('svg')!.getBoundingClientRect()
        return { width: bounds.width, height: bounds.height, iconWidth: icon.width, iconHeight: icon.height }
      })
    )
    expect(toggles.length).toBeGreaterThan(0)
    for (const toggle of toggles) {
      expect(toggle.width).toBeGreaterThanOrEqual(32)
      expect(toggle.height).toBeGreaterThanOrEqual(32)
      expect(toggle.iconWidth).toBe(16)
      expect(toggle.iconHeight).toBe(16)
    }
    const route = page.url()
    await currentPage.click()
    await expect(sidebar).toBeHidden()
    await expect(page).toHaveURL(route)
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()
  } finally {
    await context.close()
  }
})
