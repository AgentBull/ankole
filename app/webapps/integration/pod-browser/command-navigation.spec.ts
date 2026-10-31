import { state, request } from './fixtures'
import { expect, test, type Page } from '@playwright/test'
import { conversationRoute, listRoute, pageRoute } from './routes'

test('command search coalesces a typing burst and opens the current result', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto('/')
    // The shortcut listener mounts with the shell, after navigation resolves.
    await expect(page.getByRole('button', { name: '搜索或跳转', exact: true })).toBeVisible()
    await page.keyboard.press('ControlOrMeta+k')
    const menu = page.getByRole('dialog', { name: '搜索或跳转', exact: true })
    const input = menu.locator('[cmdk-input]')
    await expect(menu.locator(`[cmdk-item][data-value="page:${state.report_id}"]`)).toBeVisible()
    const { page: report } = await request<{ page: { title: string } }>(page, `/pages/${state.report_id}`)
    const queries: string[] = []
    page.on('request', request => {
      const url = new URL(request.url())
      if (['/api/v2/pod/pages/search', '/api/v2/pod/conversations'].includes(url.pathname)) {
        const query = url.searchParams.get('query')
        if (query) queries.push(query)
      }
    })
    await input.pressSequentially(report.title, { delay: 20 })
    await expect(input).toHaveValue(report.title)
    await expect.poll(() => queries).toEqual([report.title, report.title])
    await menu.locator(`[cmdk-item][data-value="page:${state.report_id}"]`).click()
    await expect(page).toHaveURL(state.base_url + pageRoute(state.report_id))
    await expect(page.locator('.editor-content')).toBeVisible()
  } finally {
    await context.close()
  }
})

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

test('command search opens a document found by its body and keeps navigation commands searchable', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    const text = `Body-only search reference ${crypto.randomUUID()}`
    id = await createDocument(page, text)
    await page.goto(pageRoute(state.report_id))
    const menu = page.getByRole('dialog', { name: '搜索或跳转', exact: true })
    await page.getByRole('button', { name: '搜索或跳转', exact: true }).click()
    await menu.locator('[cmdk-input]').fill(text)
    const result = menu.locator(`[cmdk-item][data-value="page:${id}"]`)
    await expect(result).toBeVisible()
    await result.click()
    await expect(page).toHaveURL(state.base_url + pageRoute(id))
    await expect(page.locator('.editor-content')).toHaveText(text)

    await page.getByRole('button', { name: '搜索或跳转', exact: true }).click()
    await menu.locator('[cmdk-input]').fill('空间')
    await menu.locator('[cmdk-item][data-value="scope:space"]').click()
    await expect(page).toHaveURL(state.base_url + listRoute('space'))
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('a document search keeps its query when opening a result, going back, and reloading', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    const text = `Return to this body reference ${crypto.randomUUID()}`
    id = await createDocument(page, text)
    await page.goto(listRoute('search'))
    const input = page.getByRole('textbox', { name: '搜索页面', exact: true })
    const result = page.locator('.pod-content-list').locator(`a[href="${pageRoute(id)}"]`)
    await input.pressSequentially(text)
    await expect(input).toBeFocused()
    await expect.poll(() => new URL(page.url()).searchParams.get('q')).toBe(text)
    await expect(result).toBeVisible()
    await result.click()
    await expect(page.locator('.editor-content')).toHaveText(text)
    await page.goBack()
    await expect(input).toHaveValue(text)
    await expect(result).toBeVisible()
    await page.reload()
    await expect(input).toHaveValue(text)
    await expect(result).toBeVisible()
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('the link shortcut edits a selected link and every other command shortcut opens search', async ({ browser }) => {
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
    const linkForm = page.getByRole('dialog', { name: '编辑链接', exact: true })
    const mac = await page.evaluate(() => navigator.platform.includes('Mac'))
    // Control+K on Apple platforms deletes to the line end in the editor, so search claims it there.
    for (const { shortcut, select, link } of [
      { shortcut: mac ? 'Meta+k' : 'Control+k', select: true, link: true },
      { shortcut: mac ? 'Control+k' : 'Meta+k', select: true, link: false },
      { shortcut: mac ? 'Meta+k' : 'Control+k', select: false, link: false }
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
      if (link) {
        await expect(linkForm.getByLabel('链接地址', { exact: true })).toBeFocused()
        await expect(menu).toHaveCount(0)
      } else {
        await expect(menu.locator('[cmdk-input]')).toBeFocused()
        await expect(linkForm).toHaveCount(0)
      }
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

test('the link shortcut on selected code opens search because code has no links', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    id = await createDocument(page)
    await request(page, `/pages/${id}/content`, 'PUT', {
      base_revision: 0,
      xml: '<page><pre>const answer = 42</pre></page>'
    })
    await page.reload()
    const code = page.locator('.editor-content .editor-code-pre')
    await expect(code).toHaveText('const answer = 42')
    await code.click()
    await page.keyboard.press('End')
    await page.keyboard.press('Shift+Home')
    await expect.poll(() => page.evaluate(() => window.getSelection()?.toString())).toBe('const answer = 42')
    const mac = await page.evaluate(() => navigator.platform.includes('Mac'))
    await page.keyboard.press(mac ? 'Meta+k' : 'Control+k')
    await expect(page.getByRole('dialog', { name: '搜索或跳转', exact: true }).locator('[cmdk-input]')).toBeFocused()
    await expect(page.getByRole('dialog', { name: '编辑链接', exact: true })).toHaveCount(0)
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

for (const decision of ['proceed', 'cancel'] as const) {
  test(`a new-chat composer keeps command focus through delayed Agent discovery after a blocked ${decision}`, async ({
    browser
  }) => {
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
        expect(await page.evaluate(() => history.state?.focusComposer ?? null)).toBeNull()
        await page.getByRole('tab', { name: '对话', exact: true }).click()
        await page
          .getByRole('tabpanel', { name: '对话', exact: true })
          .getByRole('link', { name: '新对话', exact: true })
          .click()
        await expect(blocker).toBeVisible()
      }
      const downloaded = page.waitForEvent('download')
      await blocker.getByRole('button', { name: '下载草稿并离开', exact: true }).click()
      await (await downloaded).delete()
      await expect(page).toHaveURL(`${state.base_url}/`)
      await expect.poll(() => agentsRequests).toBe(1)
      const composer = page.getByRole('textbox', { name: '消息', exact: true })
      await expect(composer).toBeEditable()
      await expect(composer).toBeFocused()
      const parkedFocus = page.getByRole('button', { name: '搜索或跳转', exact: true })
      await parkedFocus.focus()
      releaseAgents()
      await expect(composer).toBeEnabled()
      await expect(parkedFocus).toBeFocused()
      await expect.poll(() => page.evaluate(() => history.state?.focusComposer ?? null)).toBeNull()
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
