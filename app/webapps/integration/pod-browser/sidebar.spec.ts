import { state, request } from './fixtures'
import { listRoute, pageRoute } from './routes'
import { expect, test, type Page } from '@playwright/test'

async function create(page: Page, title: string, parentID?: string) {
  const result = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
    type: 'doc',
    title,
    ...(parentID ? { parent_id: parentID } : {})
  })
  return result.page.id
}

test('a dragged page keeps its new place after reload, undo restores it, and the row menu renames and reorders', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1365, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(pageRoute(state.report_id))
    const suffix = Date.now().toString(36)
    const parent = await create(page, `Drag parent ${suffix}`)
    const [first, second, third] = [`First ${suffix}`, `Second ${suffix}`, `Third ${suffix}`]
    for (const title of [first, second, third]) await create(page, title, parent)
    await page.goto(pageRoute(parent))
    const children = page.locator('.pod-tree-row', { has: page.locator(`a[href="${pageRoute(parent)}"]`) })
    await expect(children).toHaveCount(1)
    await children.getByRole('button', { name: `Drag parent ${suffix}`, exact: true }).click()
    const titles = () =>
      page
        .locator('li', { has: children })
        .locator('.pod-tree-children > li > .pod-tree-row .pod-tree-link')
        .allInnerTexts()
    await expect.poll(titles).toEqual([first, second, third])

    const row = (title: string) => page.locator('.pod-tree-row', { has: page.getByRole('link', { name: title }) })
    const moved = page.waitForResponse(response => response.url().endsWith('/move') && response.ok())
    await page.getByRole('link', { name: third, exact: true }).dragTo(row(first), { targetPosition: { x: 60, y: 2 } })
    await moved
    await expect.poll(titles).toEqual([third, first, second])
    await page.reload()
    await expect.poll(titles).toEqual([third, first, second])
    await expect(page.getByRole('link', { name: first, exact: true })).toHaveAttribute('draggable', 'true')
    await expect(page.getByRole('link', { name: second, exact: true })).toHaveAttribute('draggable', 'true')
    // Keep the target visible before mouse-down so dragTo does not scroll mid-drag.
    await row(second).scrollIntoViewIfNeeded()

    const again = page.waitForResponse(response => response.url().endsWith('/move') && response.ok())
    await page.getByRole('link', { name: first, exact: true }).dragTo(row(second), { targetPosition: { x: 60, y: 24 } })
    await again
    await expect.poll(titles).toEqual([third, second, first])
    await page.getByRole('button', { name: '撤销', exact: true }).click()
    await expect.poll(titles).toEqual([third, first, second])

    await row(second).click({ button: 'right' })
    await page.getByRole('menuitem', { name: '重命名', exact: true }).click()
    const field = page.getByRole('textbox', { name: new RegExp(`^重命名 .*${second}`) })
    await expect(field).toBeFocused()
    await field.fill(`Renamed ${suffix}`)
    await field.press('Enter')
    await expect(page.getByRole('link', { name: `Renamed ${suffix}`, exact: true })).toBeVisible()

    await page.getByRole('button', { name: new RegExp(`^.*${first}.* 的操作$`) }).click()
    await page.getByRole('menuitem', { name: '上移', exact: true }).click()
    await expect.poll(titles).toEqual([first, third, `Renamed ${suffix}`])
  } finally {
    await context.close()
  }
})

test('undo at the end of a loaded directory page restores the full sibling order', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1365, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let parent: string | undefined
  try {
    await page.goto(pageRoute(state.report_id))
    const prefix = `Paged move ${Date.now()}`
    parent = await create(page, prefix)
    const ids: string[] = []
    for (let index = 0; index < 201; index++) {
      ids.push(await create(page, `${prefix} ${index}`, parent))
    }
    await page.goto(pageRoute(parent))
    const parentRow = page.locator('.pod-tree-row', { has: page.locator(`a[href="${pageRoute(parent)}"]`) })
    await parentRow.getByRole('button', { name: prefix, exact: true }).click()
    const childRows = page.locator('li', { has: parentRow }).locator('.pod-tree-children > li > .pod-tree-row')
    await expect(childRows).toHaveCount(200)
    const source = childRows.filter({ has: page.getByRole('link', { name: `${prefix} 199`, exact: true }) })
    await source.click({ button: 'right' })
    const moved = page.waitForResponse(response => response.url().endsWith(`/pages/${ids[199]}/move`) && response.ok())
    await page.getByRole('menuitem', { name: '上移', exact: true }).click()
    expect((await (await moved).json()).undo.before_id).toBe(ids[200])
    await expect(childRows.nth(198).getByRole('link')).toHaveText(`${prefix} 199`)

    await page.getByRole('button', { name: '撤销', exact: true }).click()
    await expect(childRows.nth(199).getByRole('link')).toHaveText(`${prefix} 199`)
    const first = await request<{ pages: { id: string }[]; next_cursor: string }>(
      page,
      `/pages/children?parent_id=${parent}&limit=200`
    )
    const last = await request<{ pages: { id: string }[] }>(
      page,
      `/pages/children?parent_id=${parent}&limit=200&cursor=${encodeURIComponent(first.next_cursor)}`
    )
    expect([...first.pages, ...last.pages].map(row => row.id)).toEqual(ids)
  } finally {
    if (parent) await request(page, `/pages/${parent}`, 'DELETE')
    await context.close()
  }
})

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
      sidebar.locator('.pod-sidebar-top').getByRole('button', { name: '新建页面', exact: true })
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
        return {
          width: Number(bounds.width.toFixed(3)),
          height: Number(bounds.height.toFixed(3)),
          iconWidth: Number(icon.width.toFixed(3)),
          iconHeight: Number(icon.height.toFixed(3))
        }
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
