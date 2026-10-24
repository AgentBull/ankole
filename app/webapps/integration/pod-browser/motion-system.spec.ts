import { state } from './fixtures'
import { expect, test } from '@playwright/test'
import { conversationRoute, pageRoute, uuidShorten } from './routes'

test('mobile page chat completes its exit before it leaves the page', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 390, height: 844 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(pageRoute(state.report_id))
    const trigger = page.getByRole('button', { name: '页面对话', exact: true })
    await trigger.click()
    const sheet = page.locator('[data-slot="sheet-content"]')
    await expect(sheet).toBeVisible()
    await expect(sheet).not.toHaveAttribute('data-starting-style')
    expect(await sheet.evaluate(element => getComputedStyle(element).transitionProperty)).toContain('translate')
    const selected = new URL(page.url()).searchParams.get('chat')
    await sheet.getByRole('textbox', { name: '消息', exact: true }).fill('Unsent motion check')
    await sheet.getByRole('button', { name: '关闭页面对话', exact: true }).click()
    await expect(sheet).toHaveAttribute('data-ending-style', '')
    await expect(sheet.getByRole('textbox', { name: '消息', exact: true })).toHaveValue('Unsent motion check')
    await expect(sheet).toHaveCount(0)
    await expect(trigger).toBeFocused()
    await trigger.click()
    await expect(sheet.getByRole('textbox', { name: '消息', exact: true })).toHaveValue('Unsent motion check')
    expect(new URL(page.url()).searchParams.get('chat')).toBe(selected)
    await sheet.getByRole('textbox', { name: '消息', exact: true }).fill('')
  } finally {
    await context.close()
  }
})

test('reduced motion keeps the page chat fade and removes its movement', async ({ browser }) => {
  const context = await browser.newContext({
    baseURL: state.base_url,
    viewport: { width: 390, height: 844 },
    reducedMotion: 'reduce'
  })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(pageRoute(state.report_id))
    await page.getByRole('button', { name: '页面对话', exact: true }).click()
    const sheet = page.locator('[data-slot="sheet-content"]')
    await expect(sheet).toBeVisible()
    const motion = await sheet.evaluate(element => {
      const style = getComputedStyle(element)
      return { translate: style.translate, properties: style.transitionProperty, duration: style.transitionDuration }
    })
    expect(motion.translate).toBe('none')
    expect(motion.properties).toBe('opacity')
    expect(motion.duration).toBe('0.14s')
  } finally {
    await context.close()
  }
})

test('desktop sidebar shortcuts and page menus do not animate', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1365, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(pageRoute(state.report_id))
    await expect(page.getByRole('button', { name: '页面对话', exact: true })).toBeVisible()
    for (const slot of ['sidebar-gap', 'sidebar-container']) {
      expect(
        await page.locator(`[data-slot="${slot}"]`).evaluate(element => getComputedStyle(element).transitionDuration)
      ).toBe('0s')
    }
    await page.keyboard.press('Control+b')
    await expect(page.locator('[data-slot="sidebar-gap"]')).toHaveCSS('width', '0px')
    await page.keyboard.press('Control+b')
    await page.getByRole('button', { name: '更多操作', exact: true }).click()
    const menu = page.locator('[data-slot="dropdown-menu-content"]')
    await expect(menu).toBeVisible()
    await expect(menu).toHaveCSS('transition-property', 'none')
  } finally {
    await context.close()
  }
})

test('reduced motion jumps to the latest chat message in one scroll update', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, reducedMotion: 'reduce' })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(conversationRoute(state.history_conversation_id))
    const history = page.locator('.pod-chat-history-scroll')
    await expect(history).toBeVisible()
    await expect
      .poll(() => history.evaluate(element => element.scrollHeight - element.clientHeight))
      .toBeGreaterThan(100)
    await history.evaluate(element => {
      element.scrollTop = Math.max(0, element.scrollTop - 200)
    })
    const latest = page.getByRole('button', { name: '滚动到最新消息', exact: true })
    await expect(latest).toBeVisible()
    await history.evaluate(element => {
      const positions: number[] = []
      ;(element as HTMLElement & { motionPositions: number[] }).motionPositions = positions
      element.addEventListener('scroll', () => positions.push(element.scrollTop), { passive: true })
    })
    await latest.click()
    const result = await history.evaluate(element => ({
      positions: (element as HTMLElement & { motionPositions: number[] }).motionPositions,
      bottom: element.scrollHeight - element.clientHeight
    }))
    expect(result.positions.length).toBeGreaterThan(0)
    expect(result.positions.every(position => Math.abs(position - result.bottom) < 2)).toBe(true)
  } finally {
    await context.close()
  }
})

test('a successful first send during mobile exit does not reopen the closed page chat', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 390, height: 844 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const posted = Promise.withResolvers<{ conversation: { id: string } }>()
  const acknowledgement = Promise.withResolvers<void>()
  await page.route('**/api/v2/pod/conversations', async route => {
    if (route.request().method() !== 'POST') return route.continue()
    const response = await route.fetch()
    posted.resolve(await response.json())
    await acknowledgement.promise
    await route.fulfill({ response })
  })
  try {
    await page.goto(pageRoute(state.report_id, 'new'))
    const sheet = page.locator('[data-slot="sheet-content"]')
    const composer = sheet.getByRole('textbox', { name: '消息', exact: true })
    const text = `First-send acknowledgement during exit ${Date.now()}`
    await composer.fill(text)
    await sheet.getByRole('button', { name: '发送消息', exact: true }).click()
    const saved = await posted.promise
    await sheet.getByRole('button', { name: '关闭页面对话', exact: true }).click()
    await expect(sheet).toHaveAttribute('data-ending-style', '')
    acknowledgement.resolve()
    await expect(composer).toHaveValue('')
    await expect(sheet).toHaveCount(0)
    await expect(page).toHaveURL(url => url.pathname === pageRoute(state.report_id) && !url.searchParams.has('chat'))
    const trigger = page.getByRole('button', { name: '页面对话', exact: true })
    await expect(trigger).toBeFocused()
    await trigger.click()
    await expect(page).toHaveURL(url => url.searchParams.get('chat') === uuidShorten(saved.conversation.id))
    await expect(
      sheet.getByRole('region', { name: '对话消息', exact: true }).getByText(text, { exact: true })
    ).toBeVisible()
  } finally {
    acknowledgement.resolve()
    await page.unrouteAll({ behavior: 'wait' })
    await context.close()
  }
})
