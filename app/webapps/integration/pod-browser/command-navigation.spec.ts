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
    // Other specs create pages, so the empty-query listing need not include the report; any page proves it loaded.
    await expect(menu.locator('[cmdk-item][data-value^="page:"]').first()).toBeVisible()
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

const createdTitles = new Map<string, string>()

async function createDocument(page: Page, text?: string) {
  await page.goto(pageRoute(state.report_id))
  const title = `Command navigation ${crypto.randomUUID()}`
  const { page: created } = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
    type: 'doc',
    title
  })
  createdTitles.set(created.id, title)
  if (text) {
    await request(page, `/pages/${created.id}/content`, 'PUT', { base_revision: 0, xml: `<page><p>${text}</p></page>` })
  }
  await page.goto(pageRoute(created.id, undefined, title))
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
    await expect(result.locator('[data-testid="search-snippet"] mark').first()).toBeVisible()
    await result.click()
    const baseDocRoute = pageRoute(id, undefined, createdTitles.get(id))
    await expect(page).toHaveURL(`${state.base_url}${baseDocRoute}?${new URLSearchParams({ find: text })}`)
    await expect(page.locator('.editor-content')).toHaveText(text)
    await expect(page.locator('.pod-page-find')).toBeVisible()
    await expect
      .poll(() =>
        page.evaluate(() => ({
          all: CSS.highlights?.get('pod-page-find')?.size ?? 0,
          current: CSS.highlights?.get('pod-page-find-current')?.size ?? 0
        }))
      )
      .toEqual({ all: 1, current: 1 })
    await page.locator('.pod-page-find input').press('Escape')
    await expect(page.locator('.pod-page-find')).toBeHidden()
    await expect(page).toHaveURL(state.base_url + baseDocRoute)

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
    const baseDocRoute = pageRoute(id, undefined, createdTitles.get(id))
    const result = page
      .locator('.pod-content-list')
      .locator(`a[href="${baseDocRoute}?${new URLSearchParams({ find: text })}"]`)
    await input.pressSequentially(text)
    await expect(input).toBeFocused()
    await expect.poll(() => new URL(page.url()).searchParams.get('q')).toBe(text)
    await expect(result).toBeVisible()
    await result.click()
    await expect(page.locator('.editor-content')).toHaveText(text)
    await expect(page.locator('.pod-page-find')).toBeVisible()
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
      // Gate only the new-chat discovery: the freshly loaded document must finish its own Agent discovery first.
      await expect(page.locator('.pod-sidebar-header').getByRole('link', { name: '新对话', exact: true })).toBeVisible()
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
      // The editor has spent longer than the 15 s query freshness window, so opening the menu rediscovers Agents.
      await page.clock.setSystemTime(Date.now() + 16_000)
      await page.keyboard.press('ControlOrMeta+k')
      await page
        .getByRole('dialog', { name: '搜索或跳转', exact: true })
        .locator('[cmdk-item][data-value="new-chat"]')
        .click()
      const blocker = page.getByRole('dialog', { name: '修改尚未保存', exact: true })
      await expect(blocker).toBeVisible()
      await expect(page).toHaveURL(state.base_url + pageRoute(id, undefined, createdTitles.get(id)))
      if (decision === 'cancel') {
        await blocker.getByRole('button', { name: '继续编辑', exact: true }).click()
        await expect(blocker).toBeHidden()
        expect(await page.evaluate(() => history.state?.focusComposer ?? null)).toBeNull()
        await page.getByRole('tab', { name: '对话', exact: true }).click()
        await page.locator('.pod-sidebar-header').getByRole('link', { name: '新对话', exact: true }).click()
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
    // New Chat opens a clean composer and keeps the unsent draft in local recovery.
    await expect(composer).toHaveValue('')
    const retained = page
      .getByRole('region', { name: '保留的对话内容', exact: true })
      .getByRole('textbox', { name: '本地内容 1', exact: true })
    await expect(retained).toHaveValue('Unsent draft retained by command navigation')

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
    await expect(composer).toHaveValue('')
    await expect(retained).toHaveValue('Unsent draft retained by command navigation')

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
    // On a phone the top bar keeps search one tap away without opening the sidebar.
    const search = page.getByRole('button', { name: '搜索或跳转', exact: true })
    await expect(search).toBeInViewport({ ratio: 1 })
    await search.click()
    await expect(menu).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(menu).toBeHidden()
    await expect(search).toBeFocused()
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

test('quick find previews sections, filters title-only, records recent searches, and scopes subtree search', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1440, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let parentID: string | undefined
  let childID: string | undefined
  try {
    await page.goto(pageRoute(state.report_id))
    const parentTitle = `Search parent ${crypto.randomUUID()}`
    const childTitle = `Search child ${crypto.randomUUID()}`
    const token = `UniqueQuickFindToken_${crypto.randomUUID().replaceAll('-', '')}`

    const { page: parent } = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'doc',
      title: parentTitle
    })
    parentID = parent.id
    const { page: child } = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'doc',
      parent_id: parent.id,
      title: childTitle
    })
    childID = child.id
    await request(page, `/pages/${child.id}/content`, 'PUT', {
      base_revision: 0,
      xml: `<page><h2>部署<strong>核查</strong></h2><p>发布前请确认 ${token} 已就绪（oﬃce）。</p><p>foo</p><p>bar</p></page>`
    })

    await page.goto(pageRoute(parent.id, undefined, parentTitle))
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(parentTitle)

    await page.keyboard.press('ControlOrMeta+k')
    const menu = page.getByRole('dialog', { name: '搜索或跳转', exact: true })
    const initialWidth = await menu.evaluate(el => Math.round(el.getBoundingClientRect().width))
    const input = menu.locator('[cmdk-input]')

    // Pressing ControlOrMeta+f inside the open Command dialog never opens PageFindBar underneath.
    await page.keyboard.press('ControlOrMeta+f')
    await expect(page.locator('.pod-page-find')).toBeHidden()

    await input.fill('nonexistent_zero_hit_query_99999')
    await expect(menu.locator('[cmdk-empty]')).toHaveText('没有匹配项')
    const emptyWidth = await menu.evaluate(el => Math.round(el.getBoundingClientRect().width))
    expect(emptyWidth).toBe(initialWidth)

    // Quoted + multi-term query recalls the page and preserves inline heading text without spacing artifacts.
    await input.fill(`"${token}" 已就绪`)

    const childItem = menu.locator(`[cmdk-item][data-value="page:${child.id}"]`)
    await expect(childItem).toBeVisible()
    await expect(childItem).toContainText('§ 部署核查')

    // Pressing Enter on a focused toolbar button toggles the filter instead of selecting the active CommandItem.
    const titleOnlyBtn = menu.getByRole('button', { name: '仅搜标题', exact: true })
    await titleOnlyBtn.focus()
    await page.keyboard.press('Enter')
    await expect(menu).toBeVisible()
    await expect(titleOnlyBtn).toHaveAttribute('aria-pressed', 'true')
    await expect(childItem).toBeHidden()
    await page.keyboard.press('Enter')
    await expect(titleOnlyBtn).toHaveAttribute('aria-pressed', 'false')
    await expect(childItem).toBeVisible()

    // Desktop preview pane lists headings and jumps directly to ?find=<q>&at=heading:部署核查.
    const previewPane = menu.getByTestId('command-preview-pane')
    await expect(previewPane).toBeVisible()
    const sectionBtn = previewPane.getByRole('button', { name: '§ 部署核查', exact: true })
    await sectionBtn.focus()
    await page.keyboard.press('Enter')

    await expect.poll(() => new URL(page.url()).searchParams.get('find')).toBe(`"${token}" 已就绪`)
    await expect.poll(() => new URL(page.url()).searchParams.get('at')).toBe('heading:部署核查')
    await expect(page.locator('.pod-page-find')).toBeVisible()
    await expect(page.locator('.pod-page-find [aria-live]')).toHaveText('1/2')
    await expect.poll(() => page.evaluate(() => CSS.highlights.get('pod-page-find')?.size ?? 0)).toBe(2)

    // Pressing ControlOrMeta+f when the Find Bar is already open focuses its input;
    // NFKC ligatures match and block boundaries prevent false cross-paragraph concatenation.
    await page.keyboard.press('ControlOrMeta+f')
    const findInput = page.locator('.pod-page-find input')
    await expect(findInput).toBeFocused()
    await findInput.fill('office')
    await expect(page.locator('.pod-page-find [aria-live]')).toHaveText('1/1')
    await findInput.fill('foobar')
    await expect(page.locator('.pod-page-find [aria-live]')).toHaveText('0/0')
    await findInput.fill('foo bar')
    await expect(page.locator('.pod-page-find [aria-live]')).toHaveText('1/1')
    await findInput.press('Escape')
    await expect(page.locator('.pod-page-find')).toBeHidden()

    // When PageChat is open and focused, ControlOrMeta+f stays scoped out of PageFindBar.
    const pageChatBtn = page.getByRole('button', { name: '助理', exact: true })
    if (await pageChatBtn.isVisible()) {
      await pageChatBtn.click()
      const pageChat = page.locator('.pod-page-chat')
      await expect(pageChat).toBeVisible()
      await pageChat.locator('textarea, input, button').first().focus()
      await page.keyboard.press('ControlOrMeta+f')
      await expect(page.locator('.pod-page-find')).toBeHidden()
      await pageChat.getByRole('button', { name: '关闭助理', exact: true }).click()
    }

    // Empty-query command menu lists Recent searches and keyboard Enter on the remove button deletes without replaying.
    await page.keyboard.press('ControlOrMeta+k')
    const recentEntry = menu.locator('[cmdk-item][data-value^="recent-search:"]').filter({ hasText: token })
    await expect(recentEntry).toBeVisible()
    const removeRecentBtn = recentEntry.getByRole('button', { name: /移除最近搜索/ })
    await removeRecentBtn.focus()
    await page.keyboard.press('Enter')
    await expect(recentEntry).toBeHidden()
    await expect(menu.locator('[cmdk-input]')).toHaveValue('')
    await page.keyboard.press('Escape')

    // /content/search?ancestor_id=<parentID> scopes results, highlights title matches, and filters by creator.
    await page.goto(`${listRoute('search')}?${new URLSearchParams({ ancestor_id: parent.id, q: 'Search child' })}`)
    await expect(page.getByTestId('search-filters')).toContainText(parentTitle)
    const resultRow = page.locator('a[data-pod-list-item]').filter({ hasText: childTitle })
    await expect(resultRow).toBeVisible()
    await expect(resultRow.locator('mark.pod-search-mark').first()).toBeVisible()
    await expect(page.getByTestId('search-filters').getByRole('combobox', { name: '创建者' })).toBeVisible()
  } finally {
    if (childID) await request(page, `/pages/${childID}`, 'DELETE')
    if (parentID) await request(page, `/pages/${parentID}`, 'DELETE')
    await context.close()
  }
})
