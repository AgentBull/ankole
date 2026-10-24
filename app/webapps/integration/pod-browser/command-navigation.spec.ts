import { state, request } from './fixtures'
import { expect, test, type Page } from '@playwright/test'
import { conversationRoute, listRoute, pageRoute } from './routes'

async function createDocument(page: Page, text?: string) {
  await page.goto(pageRoute(state.report_id))
  const { page: created } = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
    type: 'doc',
    title: `Command navigation ${crypto.randomUUID()}`
  })
  if (text) {
    await request(page, `/pages/${created.id}/content`, 'PUT', { base_revision: 0, xml: `<page><p>${text}</p></page>` })
  }
  await page.goto(pageRoute(created.id))
  return created.id
}

test('command shortcuts claim real editor selections before link or delete bindings run', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    const text = 'Alpha beta gamma'
    id = await createDocument(page, text)
    const editor = page.locator('.editor-content[contenteditable="true"]')
    await expect(editor).toHaveText(text)
    const menu = page.getByRole('dialog', { name: '搜索或跳转', exact: true })
    for (const { shortcut, select } of [
      { shortcut: 'Meta+k', select: true },
      { shortcut: 'Control+k', select: true },
      { shortcut: 'Control+k', select: false }
    ]) {
      await editor.evaluate((element, select) => {
        element.focus()
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT)
        let node = walker.nextNode()
        while (node && !node.textContent?.includes('Alpha beta gamma')) node = walker.nextNode()
        if (!node) throw new Error('The editor text node is not available')
        const selection = window.getSelection()!
        selection.setBaseAndExtent(node, 6, node, select ? 10 : 6)
      }, select)
      await expect.poll(() => page.evaluate(() => window.getSelection()?.toString())).toBe(select ? 'beta' : '')
      await page.keyboard.press(shortcut)
      await expect(menu.locator('[cmdk-input]')).toBeFocused()
      await expect(page.getByRole('dialog', { name: '编辑链接', exact: true })).toHaveCount(0)
      await expect(editor).toHaveText(text)
      await page.keyboard.press('Escape')
      await expect(editor).toBeFocused()
      await expect(editor).toHaveText(text)
    }
    expect((await request<{ content: { content: string } }>(page, `/pages/${id}`)).content.content).toContain(text)
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

for (const decision of ['proceed', 'cancel'] as const) {
  test(`a delayed new-chat composer receives command focus only after a blocked ${decision}`, async ({ browser }) => {
    const context = await browser.newContext({ baseURL: state.base_url })
    await context.addCookies(state.owner.cookies)
    const page = await context.newPage()
    let id: string | undefined
    let releaseAgents!: () => void
    const agentsGate = new Promise<void>(resolve => {
      releaseAgents = resolve
    })
    let agentsRequests = 0
    try {
      id = await createDocument(page)
      await page.route('**/api/v2/pod/agents', async route => {
        agentsRequests++
        await agentsGate
        await route.continue()
      })
      await page.route(`**/api/v2/pod/pages/${id}`, route =>
        route.request().method() === 'PATCH'
          ? route.fulfill({ status: 503, json: { error: 'Command navigation title save failed' } })
          : route.continue()
      )
      const failedSave = page.waitForResponse(
        response =>
          response.request().method() === 'PATCH' && new URL(response.url()).pathname === `/api/v2/pod/pages/${id}`
      )
      const title = page.getByRole('textbox', { name: '页面标题', exact: true })
      await title.fill('Unfinished command navigation title')
      await title.blur()
      expect((await failedSave).status()).toBe(503)
      await page.keyboard.press('ControlOrMeta+k')
      await page
        .getByRole('dialog', { name: '搜索或跳转', exact: true })
        .locator('[cmdk-item][data-value="new-chat"]')
        .click()
      const blocker = page.getByRole('dialog', { name: '修改尚未保存', exact: true })
      await expect(blocker).toBeVisible()
      await expect(page).toHaveURL(state.base_url + pageRoute(id))
      if (decision === 'cancel') {
        await blocker.getByRole('button', { name: '继续编辑', exact: true }).click()
        await expect(blocker).toBeHidden()
        expect(await page.evaluate(() => history.state?.usr?.focusComposer ?? null)).toBeNull()
        await page.getByRole('tab', { name: '对话', exact: true }).click()
        await page.getByRole('link', { name: '新对话', exact: true }).click()
        await expect(blocker).toBeVisible()
      }
      const downloaded = page.waitForEvent('download')
      await blocker.getByRole('button', { name: '下载草稿并离开', exact: true }).click()
      await (await downloaded).delete()
      await expect(page).toHaveURL(`${state.base_url}/`)
      await expect.poll(() => agentsRequests).toBe(1)
      const composer = page.getByRole('textbox', { name: '消息', exact: true })
      await expect(composer).toBeDisabled()
      const parkedFocus = page.getByRole('button', { name: '搜索或跳转', exact: true })
      await parkedFocus.focus()
      releaseAgents()
      await expect(composer).toBeEnabled()
      if (decision === 'proceed') await expect(composer).toBeFocused()
      else await expect(parkedFocus).toBeFocused()
      await expect.poll(() => page.evaluate(() => history.state?.usr?.focusComposer ?? null)).toBeNull()
      await parkedFocus.focus()
      await page.keyboard.press('ControlOrMeta+k')
      await page.keyboard.press('Escape')
      await expect(parkedFocus).toBeFocused()
    } finally {
      releaseAgents()
      await page.unrouteAll({ behavior: 'ignoreErrors' })
      if (id) await request(page, `/pages/${id}`, 'DELETE')
      await context.close()
    }
  })
}

test('one command menu restores focus, protects IME and keeps the native new-chat draft', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto('/')
    const composer = page.getByRole('textbox', { name: '消息', exact: true })
    await expect(composer).toBeEnabled()
    await composer.fill('Unsent draft retained by command navigation')
    await composer.dispatchEvent('keydown', { key: 'k', metaKey: true, isComposing: true })
    await expect(page.locator('.pod-command-dialog')).toBeHidden()
    await composer.press('ControlOrMeta+k')
    const menu = page.getByRole('dialog', { name: '搜索或跳转', exact: true })
    const input = menu.locator('[cmdk-input]')
    await expect(input).toBeFocused()
    await input.pressSequentially('jk')
    await expect(input).toHaveValue('jk')
    await input.fill('')
    await input.dispatchEvent('keydown', { key: 'Enter', isComposing: true })
    await expect(menu).toBeVisible()
    await input.press('Escape')
    await expect(menu).toBeHidden()
    await expect(composer).toBeFocused()
    await expect(composer).toHaveValue('Unsent draft retained by command navigation')
    await composer.press('ControlOrMeta+k')
    await input.fill('新对话')
    await input.press('Enter')
    await expect(menu).toBeHidden()
    await expect(composer).toBeFocused()
    await expect(composer).toHaveValue('Unsent draft retained by command navigation')

    await page.getByRole('button', { name: '搜索或跳转', exact: true }).click()
    await expect(input).toBeFocused()
    const report = await request<{ page: { title: string } }>(page, `/pages/${state.report_id}`)
    await input.fill(report.page.title)
    await menu.locator(`[cmdk-item][data-value="page:${state.report_id}"]`).click()
    await expect(page).toHaveURL(state.base_url + pageRoute(state.report_id))
    await expect(page.getByRole('tab', { name: '主页', exact: true })).toHaveAttribute('aria-selected', 'true')
    await page.keyboard.press('ControlOrMeta+k')
    await menu.locator('[cmdk-item][data-value="new-chat"]').click()
    await expect(menu).toBeHidden()
    await expect(page).toHaveURL(`${state.base_url}/`)
    await expect(composer).toBeFocused()
    await expect(composer).toHaveValue('Unsent draft retained by command navigation')

    await composer.press('ControlOrMeta+k')
    const chat = menu.locator('[cmdk-item][data-value^="chat:"]').first()
    await expect(chat).toBeVisible()
    const conversationID = (await chat.getAttribute('data-value'))!.slice('chat:'.length)
    await chat.click()
    await expect(page).toHaveURL(state.base_url + conversationRoute(conversationID))
    await expect(page.getByRole('tab', { name: '对话', exact: true })).toHaveAttribute('aria-selected', 'true')
    await page.keyboard.press('ControlOrMeta+k')
    await menu.locator('[cmdk-item][data-value="scope:private"]').click()
    await expect(page).toHaveURL(state.base_url + listRoute('private'))
    await expect(page.getByRole('tab', { name: '主页', exact: true })).toHaveAttribute('aria-selected', 'true')
  } finally {
    await context.close()
  }
})

test('content rows use real link focus for J/K without intercepting text input', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1440, height: 960 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(listRoute('search'))
    const input = page.getByRole('textbox', { name: '搜索页面', exact: true })
    await expect(input).toBeFocused()
    await input.pressSequentially('jk')
    await expect(input).toHaveValue('jk')
    await input.fill('')
    const rows = page.locator('a[data-pod-list-item]')
    await expect(rows.nth(1)).toBeVisible()
    await input.press('Tab')
    await expect(rows.nth(0)).toBeFocused()
    await page.keyboard.press('j')
    await expect(rows.nth(1)).toBeFocused()
    await page.keyboard.press('k')
    await expect(rows.nth(0)).toBeFocused()
    expect(await rows.nth(0).evaluate(element => element.getBoundingClientRect().height)).toBe(32)
    await expect(page.getByRole('main')).toHaveCount(1)
    const href = await rows.nth(0).getAttribute('href')
    await page.keyboard.press('Enter')
    await expect(page).toHaveURL(state.base_url + href)
  } finally {
    await context.close()
  }
})

test('mobile opens the same command menu from a closed or open sidebar', async ({ browser }) => {
  const context = await browser.newContext({
    baseURL: state.base_url,
    viewport: { width: 390, height: 844 },
    isMobile: true,
    hasTouch: true
  })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(pageRoute(state.report_id))
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()
    const menu = page.getByRole('dialog', { name: '搜索或跳转', exact: true })
    await page.keyboard.press('ControlOrMeta+k')
    await expect(menu.locator('[cmdk-input]')).toBeFocused()
    await page.keyboard.press('Escape')
    await expect(menu).toBeHidden()
    await page.getByRole('button', { name: '展开侧栏', exact: true }).click()
    const sidebar = page.getByRole('dialog', { name: '工作台导航', exact: true })
    await sidebar.getByRole('button', { name: '搜索或跳转', exact: true }).click()
    await expect(menu).toBeVisible()
    await expect(sidebar).toBeHidden()
    await page.keyboard.press('Escape')
    await expect(menu).toBeHidden()
    await expect(page.getByRole('button', { name: '展开侧栏', exact: true })).toBeFocused()
  } finally {
    await context.close()
  }
})

test('mobile keyboard navigation closes its sidebar when new chat keeps the current route', async ({ browser }) => {
  const context = await browser.newContext({
    baseURL: state.base_url,
    viewport: { width: 390, height: 844 },
    isMobile: true,
    hasTouch: true
  })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto('/')
    const composer = page.getByRole('textbox', { name: '消息', exact: true })
    await expect(composer).toBeEnabled()
    await page.getByRole('button', { name: '展开侧栏', exact: true }).click()
    const sidebar = page.getByRole('dialog', { name: '工作台导航', exact: true })
    await expect(sidebar).toBeVisible()
    await page.keyboard.press('ControlOrMeta+k')
    const menu = page.getByRole('dialog', { name: '搜索或跳转', exact: true })
    await menu.locator('[cmdk-item][data-value="new-chat"]').click()
    await expect(menu).toBeHidden()
    await expect(sidebar).toBeHidden()
    await expect(composer).toBeFocused()
  } finally {
    await context.close()
  }
})
