import { state, request } from './fixtures'
import { listRoute, pageRoute } from './routes'
import { expect, test, type Locator, type Page } from '@playwright/test'

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
    const link = (title: string) => row(title).getByRole('link', { name: title, exact: true })
    const moved = page.waitForResponse(response => response.url().endsWith('/move') && response.ok())
    await link(third).dragTo(row(first), { targetPosition: { x: 60, y: 2 } })
    await moved
    await expect.poll(titles).toEqual([third, first, second])
    await page.reload()
    await expect(children.getByRole('button', { name: `Drag parent ${suffix}`, exact: true })).toHaveAttribute(
      'aria-expanded',
      'false'
    )
    await children.getByRole('button', { name: `Drag parent ${suffix}`, exact: true }).click()
    await expect.poll(titles).toEqual([third, first, second])
    await expect(link(first)).toHaveAttribute('draggable', 'true')
    await expect(link(second)).toHaveAttribute('draggable', 'true')
    // Keep the target visible before mouse-down so dragTo does not scroll mid-drag.
    await row(second).scrollIntoViewIfNeeded()

    const again = page.waitForResponse(response => response.url().endsWith('/move') && response.ok())
    await link(first).dragTo(row(second), { targetPosition: { x: 60, y: 24 } })
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
    await expect(link(`Renamed ${suffix}`)).toBeVisible()

    await row(first).hover()
    await row(first)
      .getByRole('button', { name: new RegExp(`^.*${first}.* 的操作$`) })
      .click()
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
    // Recent pages stay listed until the debounced query settles.
    await expect(page.getByRole('main').locator('a[data-pod-list-item]').first()).toHaveAttribute('href', destination)
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

test('a page listed in several Sidebar sections marks only the row the user followed', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1365, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto(pageRoute(state.report_id))
    const title = `Sidebar place ${Date.now().toString(36)}`
    id = (
      await request<{ page: { id: string } }>(page, '/pages', 'POST', {
        type: 'doc',
        title,
        private_owner_uid: state.owner.uid
      })
    ).page.id
    await page.goto(pageRoute(id))
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(title)

    const navigation = page.getByRole('navigation', { name: '页面导航', exact: true })
    const recentRow = navigation
      .getByRole('region', { name: '最近访问', exact: true })
      .getByRole('link', { name: title, exact: true })
    const treeRow = navigation
      .getByRole('region', { name: '私人页面', exact: true })
      .getByRole('link', { name: title, exact: true })
    await expect(recentRow).toBeVisible()
    await expect(treeRow).toBeVisible()

    // Favorite through the header so the same page appears in three sections.
    await page.locator('.pod-page-header').getByRole('button', { name: '☆ 收藏', exact: true }).click()
    const favoriteRow = navigation
      .getByRole('region', { name: '收藏', exact: true })
      .getByRole('link', { name: title, exact: true })
    await expect(favoriteRow).toBeVisible()
    const rows = [recentRow, favoriteRow, treeRow]
    const expectCurrent = async (current: Locator) => {
      // Move the pointer off the Sidebar so hover cannot masquerade as the current wash.
      await page.mouse.move(1000, 600)
      await expect(navigation.locator('a[aria-current="page"]')).toHaveCount(1)
      for (const row of rows) {
        const surface = row === treeRow ? row.locator('..') : row
        if (row === current) {
          await expect(row).toHaveAttribute('aria-current', 'page')
          await expect(surface).not.toHaveCSS('background-color', 'rgba(0, 0, 0, 0)')
        } else {
          await expect(row).not.toHaveAttribute('aria-current', 'page')
          await expect(surface).toHaveCSS('background-color', 'rgba(0, 0, 0, 0)')
        }
      }
    }

    // Direct navigation marks its tree; following a section marks only that section.
    await expectCurrent(treeRow)
    await recentRow.click()
    await expectCurrent(recentRow)
    await page.reload()
    await expectCurrent(recentRow)
    await favoriteRow.click()
    await expectCurrent(favoriteRow)
    await page.goBack()
    await expectCurrent(recentRow)
    await page.goForward()
    await expectCurrent(favoriteRow)
    await treeRow.click()
    await expectCurrent(treeRow)
    await page.reload()
    await expectCurrent(treeRow)

    // A native new-tab click follows the href without copying the old tab's history state.
    const opened = context.waitForEvent('page')
    await recentRow.click({ button: 'middle' })
    const newTab = await opened
    await expect(newTab).toHaveURL(state.base_url + pageRoute(id))
    const newNavigation = newTab.getByRole('navigation', { name: '页面导航', exact: true })
    await expect(newNavigation.locator('a[aria-current="page"]')).toHaveCount(1)
    await expect(
      newNavigation
        .getByRole('region', { name: '私人页面', exact: true })
        .getByRole('link', { name: title, exact: true })
    ).toHaveAttribute('aria-current', 'page')
    await newTab.close()
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE').catch(() => {})
    await context.close()
  }
})

test('desktop sidebar width persists and a collapsed sidebar can be previewed without expanding it', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1365, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(pageRoute(state.report_id))
    const handle = page.getByRole('separator', { name: '调整侧栏宽度', exact: true })
    const gap = page.locator('[data-slot="sidebar-gap"]')
    await expect(handle).toHaveAttribute('aria-valuenow', '248')
    const bounds = (await handle.boundingBox())!
    await page.mouse.move(bounds.x + bounds.width / 2, 400)
    await page.mouse.down()
    await page.mouse.move(bounds.x + bounds.width / 2 + 96, 400, { steps: 8 })
    await page.mouse.up()
    await expect(handle).toHaveAttribute('aria-valuenow', '344')
    await expect(gap).toHaveCSS('width', '344px')
    expect(await page.evaluate(() => localStorage.getItem('ankole.pod.sidebar-width'))).toBe('344')

    await page.reload()
    await expect(handle).toHaveAttribute('aria-valuenow', '344')
    await expect(gap).toHaveCSS('width', '344px')
    await handle.focus()
    await handle.press('ArrowRight')
    await expect(handle).toHaveAttribute('aria-valuenow', '360')
    await handle.press('Home')
    await expect(handle).toHaveAttribute('aria-valuenow', '248')
    await expect(gap).toHaveCSS('width', '248px')
    expect(await page.evaluate(() => localStorage.getItem('ankole.pod.sidebar-width'))).toBe('248')

    const sidebar = page.locator('[data-slot="sidebar"]')
    await page.getByRole('button', { name: '收起侧栏', exact: true }).click()
    await expect(sidebar).toHaveAttribute('data-state', 'collapsed')
    await expect(handle).toHaveCount(0)
    await page.mouse.move(900, 500)
    await expect(page.locator('.pod-sidebar-preview')).toHaveCount(0)

    await page.locator('.pod-sidebar-hover-rail').hover()
    const preview = page.locator('.pod-sidebar-preview')
    await expect(preview).toBeVisible()
    await expect(preview).toHaveCSS('left', '0px')
    await page.mouse.move(900, 500)
    await expect(preview).toHaveCount(0)
    await expect(sidebar).toHaveAttribute('data-state', 'collapsed')

    await page.locator('.pod-sidebar-hover-rail').hover()
    await expect(preview).toBeVisible()
    await preview.getByRole('button', { name: '收起侧栏', exact: true }).click()
    await expect(sidebar).toHaveAttribute('data-state', 'expanded')
    await expect(preview).toHaveCount(0)
    await expect(handle).toBeVisible()
  } finally {
    await context.close()
  }
})

test('sidebar pointer feedback yields immediately to keyboard, restored preferences, and reduced motion', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1440, height: 1000 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(pageRoute(state.report_id))
    const root = page.locator('.pod-nav-section-heading > .pod-tree-toggle').first()
    const icon = root.locator('.pod-nav-root-chevron')
    await root.click()
    await root.press('Space')
    expect(await icon.evaluate(element => getComputedStyle(element).transitionDuration)).toBe('0s')
    expect(
      await icon.evaluate(
        element => element.getAnimations().filter(animation => animation.playState === 'running').length
      )
    ).toBe(0)

    const writer = await context.newPage()
    await writer.goto(pageRoute(state.report_id))
    const remoteRoot = writer.locator('.pod-nav-section-heading > .pod-tree-toggle').first()
    const nextOpen = (await remoteRoot.getAttribute('aria-expanded')) !== 'true'
    await remoteRoot.click()
    await expect(root).toHaveAttribute('aria-expanded', String(nextOpen))
    expect(await icon.evaluate(element => getComputedStyle(element).transitionDuration)).toBe('0s')
    await writer.close()

    await page.emulateMedia({ reducedMotion: 'reduce' })
    await root.hover()
    await page.mouse.down()
    expect(await icon.evaluate(element => getComputedStyle(element).opacity)).toBe('0.65')
    await page.mouse.up()
    await root.press('Space')
    expect(await icon.evaluate(element => getComputedStyle(element).opacity)).toBe('1')
    expect(await icon.evaluate(element => getComputedStyle(element).transitionDuration)).toBe('0s')

    const heading = page
      .locator('.pod-nav-section-heading')
      .filter({ has: page.locator('.pod-nav-actions') })
      .first()
    const actions = heading.locator('.pod-nav-actions')
    await heading.hover()
    expect(await actions.evaluate(element => getComputedStyle(element).transitionDuration)).toBe('0.14s')
    await actions.getByRole('button').first().focus()
    expect(await actions.evaluate(element => getComputedStyle(element).transitionDuration)).toBe('0s')
    expect(await actions.evaluate(element => getComputedStyle(element).opacity)).toBe('1')
    await actions.getByRole('button').last().click()
    await expect(page.getByRole('menu')).toBeVisible()
    await page.mouse.move(1400, 950)
    expect(await actions.evaluate(element => getComputedStyle(element).opacity)).toBe('1')
    await page.keyboard.press('Escape')
    await root.focus()
    await page.mouse.move(1400, 950)
    expect(await actions.evaluate(element => getComputedStyle(element).transitionDuration)).toBe('0s')
    expect(await actions.evaluate(element => getComputedStyle(element).opacity)).toBe('0')
  } finally {
    await context.close()
  }
})
