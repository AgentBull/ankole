import { pageRoute, conversationRoute, uuidShorten } from './routes'
import { readFileSync, writeFileSync } from 'node:fs'
import { expect, test, type BrowserContext, type Dialog, type Page, type Route } from '@playwright/test'

const state = JSON.parse(readFileSync(process.env.POD_BROWSER_STATE_PATH!, 'utf8')) as {
  base_url: string
  tenant_id: string
  report_id: string
  database_id: string
  recovery_conversation_id: string
  owner: { uid: string; cookies: Parameters<BrowserContext['addCookies']>[0] }
  member: { uid: string; cookies: Parameters<BrowserContext['addCookies']>[0] }
}

async function request<T>(page: Page, path: string, method = 'GET', body?: unknown): Promise<T> {
  return page.evaluate(
    async ({ path, method, body }) => {
      const authentication = document.querySelector<HTMLMetaElement>('meta[name="ankole-authentication"]')?.content
      const tenant = document.querySelector<HTMLMetaElement>('meta[name="ankole-pod"]')?.content
      const csrf = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content
      const response = await fetch(`/.internal-apis/pod${path}`, {
        method,
        credentials: 'same-origin',
        headers: {
          accept: 'application/json',
          'content-type': 'application/json',
          ...(authentication ? { 'x-ankole-authentication': authentication } : {}),
          ...(tenant ? { 'x-ankole-pod': tenant } : {}),
          ...(csrf ? { 'x-csrf-token': csrf } : {})
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) })
      })
      if (!response.ok) throw new Error(`Pod ${method} ${path}: ${response.status} ${await response.text()}`)
      return response.status === 204 ? null : response.json()
    },
    { path, method, body }
  )
}

for (const width of [1440, 390]) {
  test(`a new standalone chat keeps its prompt beside the title at ${width}px`, async ({ browser }) => {
    const context = await browser.newContext({ baseURL: state.base_url, viewport: { width, height: 1000 } })
    await context.addCookies(state.owner.cookies)
    const page = await context.newPage()
    try {
      await page.goto('/')
      const title = page.getByRole('heading', { level: 1, name: '开始对话', exact: true })
      const input = page.getByRole('textbox', { name: '消息', exact: true })
      await expect(title).toBeVisible()
      await expect(input).toBeVisible()
      await expect
        .poll(async () => {
          const titleBounds = await title.boundingBox()
          const inputBounds = await input.boundingBox()
          if (!titleBounds || !inputBounds) return Number.POSITIVE_INFINITY
          return inputBounds.y - (titleBounds.y + titleBounds.height)
        })
        .toBeLessThan(96)
      const titleBounds = (await title.boundingBox())!
      const inputBounds = (await input.boundingBox())!
      expect(inputBounds.y).toBeGreaterThanOrEqual(titleBounds.y + titleBounds.height)
      expect(Math.abs(inputBounds.x - titleBounds.x)).toBeLessThan(24)
    } finally {
      await context.close()
    }
  })
}

test('page chat sends through the real API and reopens the same conversation in either view', async ({
  browser
}, testInfo) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const errors: string[] = []
  page.on('pageerror', error => errors.push(error.message))
  try {
    await page.goto(pageRoute(state.report_id))
    await page.getByRole('button', { name: '页面对话', exact: true }).click()
    const panel = page.getByRole('complementary', { name: '页面对话', exact: true })
    await expect(panel.getByText('当前页面: Browser report', { exact: true })).toBeVisible()
    await panel.getByRole('button', { name: '新对话', exact: true }).click()
    const message = `请更新此页面，保留现有内容 ${Date.now()}`
    await panel.getByRole('textbox', { name: '消息', exact: true }).fill(message)
    const response = page.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === '/.internal-apis/pod/conversations'
    )
    await panel.getByRole('button', { name: '发送消息', exact: true }).click()
    const submitted = await (await response).json()
    expect(submitted.conversation.pageID).toBe(state.report_id)
    const id = submitted.conversation.id as string
    await expect.poll(() => new URL(page.url()).searchParams.get('chat')).toBe(uuidShorten(id))
    const selectedTitle = panel.getByRole('heading', { level: 3, name: submitted.conversation.title, exact: true })
    await expect(selectedTitle).toBeVisible()
    await expect(panel.getByLabel('选择页面对话', { exact: true })).toBeVisible()
    await expect(
      panel.getByRole('region', { name: '对话消息', exact: true }).getByText(message, { exact: true })
    ).toBeVisible()
    await page.reload()
    await expect(selectedTitle).toBeVisible()
    await expect(
      panel.getByRole('region', { name: '对话消息', exact: true }).getByText(message, { exact: true })
    ).toBeVisible()
    await panel.getByRole('button', { name: '在对话页面打开', exact: true }).click()
    await expect(page).toHaveURL(url => url.pathname === conversationRoute(id))
    await expect(
      page.getByRole('region', { name: '对话消息', exact: true }).getByText(message, { exact: true })
    ).toBeVisible()
    // A page-associated Conversation also has a context link. The broad real-
    // story selector can choose it before any delivered message link exists.
    const contextLink = page.locator(`a.link[href*="${pageRoute(state.report_id)}"]`)
    await expect(contextLink).toHaveCount(1)
    const selectedHref = await contextLink.getAttribute('href')
    expect(new URL(selectedHref!, state.base_url).searchParams.get('chat')).toBe(uuidShorten(id))
    await contextLink.click()
    await expect.poll(() => new URL(page.url()).searchParams.get('chat')).toBe(uuidShorten(id))
    await expect(
      panel.getByRole('region', { name: '对话消息', exact: true }).getByText(message, { exact: true })
    ).toBeVisible()
    const opener = page.getByRole('button', { name: '页面对话', exact: true })
    await expect(opener).toHaveAttribute('aria-expanded', 'true')
    const navigationPath = testInfo.outputPath('context-link-navigation.json')
    writeFileSync(
      navigationPath,
      JSON.stringify({
        selected_href: selectedHref,
        page_url: page.url(),
        conversation_id: id,
        expanded_before_toggle: await opener.getAttribute('aria-expanded')
      })
    )
    await testInfo.attach('context-link-navigation', {
      path: navigationPath,
      contentType: 'application/json'
    })
    await page.screenshot({ path: testInfo.outputPath('context-link-open.png') })
    await opener.click()
    await expect(panel).toBeHidden()
    await expect.poll(() => new URL(page.url()).searchParams.get('chat')).toBeNull()
    await opener.click()
    await expect.poll(() => new URL(page.url()).searchParams.get('chat')).toBe(uuidShorten(id))
    await expect(panel.getByText('当前页面: Browser report', { exact: true })).toBeVisible()
    await expect(
      panel.getByRole('region', { name: '对话消息', exact: true }).getByText(message, { exact: true })
    ).toBeVisible()
    await page.reload()
    await expect.poll(() => new URL(page.url()).searchParams.get('chat')).toBe(uuidShorten(id))
    await expect(
      panel.getByRole('region', { name: '对话消息', exact: true }).getByText(message, { exact: true })
    ).toBeVisible()
    expect(errors).toEqual([])
  } finally {
    await context.close()
  }
})

test('page chat fits a small viewport and returns focus to its opener', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 390, height: 844 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(pageRoute(state.report_id))
    const opener = page.getByRole('button', { name: '页面对话', exact: true })
    await opener.click()
    const panel = page.getByRole('dialog', { name: '页面对话', exact: true })
    await expect(panel).toBeVisible()
    await expect(panel.getByRole('textbox', { name: '消息', exact: true })).toBeVisible()
    const bounds = await panel.boundingBox()
    expect(bounds?.width).toBeLessThanOrEqual(390)
    await panel.getByRole('button', { name: '关闭页面对话', exact: true }).click()
    await expect(panel).toBeHidden()
    await expect(opener).toBeFocused()
    await opener.press('Enter')
    await expect(panel).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(panel).toBeHidden()
    await expect(opener).toBeFocused()
    // A responsive Sheet can mount while focus belongs to an unrelated desktop control.
    await page.setViewportSize({ width: 1440, height: 900 })
    await opener.click()
    await expect(page.getByRole('complementary', { name: '页面对话', exact: true })).toBeVisible()
    await page.getByRole('button', { name: '更多操作', exact: true }).focus()
    await page.setViewportSize({ width: 390, height: 844 })
    await expect(panel).toBeVisible()
    await panel.getByRole('button', { name: '关闭页面对话', exact: true }).click()
    await expect(panel).toBeHidden()
    await expect(opener).toBeFocused()
  } finally {
    await context.close()
  }
})

test('a cold mobile page chat opens and closes its Sheet while the chat chunk is still loading', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 390, height: 844 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const held: Route[] = []
  const chatChunk = /\/chat-page-[^/]+\.js(?:\?.*)?$/
  let chunkResponses = 0
  page.on('response', response => {
    if (chatChunk.test(response.url())) chunkResponses++
  })
  await page.route(chatChunk, route => {
    held.push(route)
  })
  try {
    await page.goto(pageRoute(state.report_id))
    const editor = page.locator('.editor-content')
    await expect(editor).toBeVisible()
    expect((await editor.boundingBox())!.width).toBeGreaterThanOrEqual(300)
    const opener = page.getByRole('button', { name: '页面对话', exact: true })
    await opener.click()
    await expect.poll(() => held.length).toBeGreaterThan(0)
    const panel = page.getByRole('dialog', { name: '页面对话', exact: true })
    await expect(panel).toBeVisible()
    const close = panel.getByRole('button', { name: '关闭页面对话', exact: true })
    await expect(close).toBeEnabled()
    expect((await editor.boundingBox())!.width).toBeGreaterThanOrEqual(300)
    expect(chunkResponses).toBe(0)
    await close.click()
    await expect(panel).toBeHidden()
    await expect(opener).toBeFocused()
    expect(chunkResponses).toBe(0)
    expect((await editor.boundingBox())!.width).toBeGreaterThanOrEqual(300)
  } finally {
    await context.close()
  }
})

test('an unfinished page chat survives closing and navigation and warns before reload', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(pageRoute(state.report_id))
    const opener = page.getByRole('button', { name: '页面对话', exact: true })
    await opener.click()
    let panel = page.getByRole('complementary', { name: '页面对话', exact: true })
    await panel.getByRole('button', { name: '新对话', exact: true }).click()
    const draft = `保留尚未发送的修改要求 ${Date.now()}`
    await panel.getByRole('textbox', { name: '消息', exact: true }).fill(draft)
    await panel.getByRole('button', { name: '关闭页面对话', exact: true }).click()
    await opener.click()
    await expect(panel.getByRole('textbox', { name: '消息', exact: true })).toHaveValue(draft)
    await panel.getByRole('button', { name: '关闭页面对话', exact: true }).click()
    await page
      .locator(`a[href*="${pageRoute(state.database_id)}"]`)
      .first()
      .click()
    await expect.poll(() => new URL(page.url()).pathname).toBe(pageRoute(state.database_id))
    await page.goBack()
    await opener.click()
    panel = page.getByRole('complementary', { name: '页面对话', exact: true })
    const composer = panel.getByRole('textbox', { name: '消息', exact: true })
    await expect(composer).toHaveValue(draft)
    const documentStartedAt = await page.evaluate(() => performance.timeOrigin)
    const dialog = page.waitForEvent('dialog')
    // A canceled reload has no navigation to finish; call the browser action itself.
    const reload = page.evaluate(() => window.location.reload())
    const warning = await dialog
    expect(warning.type()).toBe('beforeunload')
    await warning.dismiss()
    await reload
    await expect(composer).toHaveValue(draft)
    expect(await page.evaluate(() => performance.timeOrigin)).toBe(documentStartedAt)
    await composer.fill('')
    const unexpectedWarnings: string[] = []
    const acceptUnexpectedWarning = async (warning: Dialog) => {
      unexpectedWarnings.push(warning.type())
      await warning.accept()
    }
    page.on('dialog', acceptUnexpectedWarning)
    try {
      await page.reload()
    } finally {
      page.off('dialog', acceptUnexpectedWarning)
    }
    expect(unexpectedWarnings).toEqual([])
    await expect(panel.getByRole('textbox', { name: '消息', exact: true })).toHaveValue('')
  } finally {
    await context.close()
  }
})

test('a failed first send retries the same request after the panel closes', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const requests: { conversationID: string; messageID: string; text: string }[] = []
  await page.route('**/.internal-apis/pod/conversations', async route => {
    if (route.request().method() !== 'POST') return route.continue()
    requests.push(route.request().postDataJSON())
    if (requests.length === 1) return route.abort('failed')
    return route.continue()
  })
  try {
    await page.goto(pageRoute(state.report_id))
    const opener = page.getByRole('button', { name: '页面对话', exact: true })
    await opener.click()
    const panel = page.getByRole('complementary', { name: '页面对话', exact: true })
    await panel.getByRole('button', { name: '新对话', exact: true }).click()
    const text = `断线后继续同一次委托 ${Date.now()}`
    await panel.getByRole('textbox', { name: '消息', exact: true }).fill(text)
    await panel.getByRole('button', { name: '发送消息', exact: true }).click()
    await expect(panel.getByRole('button', { name: '重试发送', exact: true })).toBeVisible()
    await panel.getByRole('button', { name: '关闭页面对话', exact: true }).click()
    await opener.click()
    await expect(panel.getByRole('textbox', { name: '消息', exact: true })).toHaveValue(text)
    await panel.getByRole('button', { name: '重试发送', exact: true }).click()
    await expect(
      panel.getByRole('region', { name: '对话消息', exact: true }).getByText(text, { exact: true })
    ).toBeVisible()
    expect(requests).toHaveLength(2)
    expect(requests[1]).toEqual(requests[0])
  } finally {
    await context.close()
  }
})

test('a successful first send is visible while its following history read is delayed', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const history = Promise.withResolvers<void>()
  await page.route('**/.internal-apis/pod/conversations/*', async route => {
    if (
      route.request().method() === 'GET' &&
      /\/conversations\/[0-9a-f-]+$/.test(new URL(route.request().url()).pathname)
    ) {
      await history.promise
    }
    await route.continue()
  })
  try {
    await page.goto(pageRoute(state.report_id, 'new'))
    const panel = page.getByRole('complementary', { name: '页面对话', exact: true })
    const text = `发送成功后立即可见 ${Date.now()}`
    await panel.getByRole('textbox', { name: '消息', exact: true }).fill(text)
    await panel.getByRole('button', { name: '发送消息', exact: true }).click()
    await expect(panel.getByRole('textbox', { name: '消息', exact: true })).toHaveValue('')
    await expect(
      panel.getByRole('region', { name: '对话消息', exact: true }).getByText(text, { exact: true })
    ).toBeVisible({ timeout: 3000 })
  } finally {
    history.resolve()
    await context.close()
  }
})

test('closing during the first send keeps its completion attached to the same conversation', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const posted = Promise.withResolvers<{ conversation: { id: string } }>()
  const acknowledgement = Promise.withResolvers<void>()
  await page.route('**/.internal-apis/pod/conversations', async route => {
    if (route.request().method() !== 'POST') return route.continue()
    const response = await route.fetch()
    posted.resolve(await response.json())
    await acknowledgement.promise
    await route.fulfill({ response })
  })
  try {
    await page.goto(pageRoute(state.report_id, 'new'))
    const panel = page.getByRole('complementary', { name: '页面对话', exact: true })
    const text = `等待确认时关闭面板 ${Date.now()}`
    await panel.getByRole('textbox', { name: '消息', exact: true }).fill(text)
    await panel.getByRole('button', { name: '发送消息', exact: true }).click()
    const saved = await posted.promise
    await panel.getByRole('button', { name: '关闭页面对话', exact: true }).click()
    await page.getByRole('button', { name: '页面对话', exact: true }).click()
    await expect(panel.getByRole('textbox', { name: '消息', exact: true })).toHaveValue(text)
    acknowledgement.resolve()
    await expect.poll(() => new URL(page.url()).searchParams.get('chat')).toBe(uuidShorten(saved.conversation.id))
    await expect(
      panel.getByRole('region', { name: '对话消息', exact: true }).getByText(text, { exact: true })
    ).toBeVisible()
    await expect(panel.getByRole('textbox', { name: '消息', exact: true })).toHaveValue('')
  } finally {
    acknowledgement.resolve()
    await context.close()
  }
})

test('a list refresh failure keeps the open chat and its draft while another tab posts', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const other = await context.newPage()
  let failedLists = 0
  try {
    await page.goto(pageRoute(state.report_id, 'new'))
    const panel = page.getByRole('complementary', { name: '页面对话', exact: true })
    const first = `双窗口对话 ${Date.now()}`
    await panel.getByRole('textbox', { name: '消息', exact: true }).fill(first)
    await panel.getByRole('button', { name: '发送消息', exact: true }).click()
    await expect.poll(() => new URL(page.url()).searchParams.get('chat')).not.toBe('new')
    await expect(
      panel.getByRole('region', { name: '对话消息', exact: true }).getByText(first, { exact: true })
    ).toBeVisible()
    const draft = '列表刷新失败时仍保留的草稿'
    await panel.getByRole('textbox', { name: '消息', exact: true }).fill(draft)
    await page.route('**/.internal-apis/pod/conversations?*', async route => {
      if (new URL(route.request().url()).searchParams.get('pageID') === state.report_id) {
        failedLists++
        return route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: { code: 'unavailable', message: 'List temporarily unavailable' } })
        })
      }
      return route.continue()
    })
    await other.goto(page.url())
    const otherPanel = other.getByRole('complementary', { name: '页面对话', exact: true })
    const next = `另一个窗口发出的消息 ${Date.now()}`
    await otherPanel.getByRole('textbox', { name: '消息', exact: true }).fill(next)
    await otherPanel.getByRole('button', { name: '发送消息', exact: true }).click()
    await expect.poll(() => failedLists).toBeGreaterThan(0)
    await expect(
      panel.getByRole('region', { name: '待发送', exact: true }).getByText(next, { exact: true })
    ).toBeVisible()
    await expect(panel.getByRole('textbox', { name: '消息', exact: true })).toHaveValue(draft)
  } finally {
    await context.close()
  }
})

test('deleting an idle chat in another window leaves its local draft available to copy', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const other = await context.newPage()
  try {
    await page.goto(pageRoute(state.report_id, state.recovery_conversation_id))
    const panel = page.getByRole('complementary', { name: '页面对话', exact: true })
    await expect(panel.getByRole('region', { name: '对话消息', exact: true })).toBeVisible()
    const draft = '对话在另一窗口删除后仍要取回的草稿'
    await panel.getByRole('textbox', { name: '消息', exact: true }).fill(draft)
    await other.goto(page.url())
    await request(other, `/conversations/${state.recovery_conversation_id}`, 'DELETE')
    await expect(panel.getByText('此对话不存在，或没有访问权限。', { exact: true })).toBeVisible()
    const recovery = panel.getByRole('region', { name: '保留的对话内容', exact: true })
    const text = recovery.getByRole('textbox')
    await expect(text).toHaveValue(draft)
    await expect(text).toHaveJSProperty('readOnly', true)
    await text.focus()
    await text.press('ControlOrMeta+A')
    expect(
      await text.evaluate(
        element => (element as HTMLTextAreaElement).selectionEnd - (element as HTMLTextAreaElement).selectionStart
      )
    ).toBe(draft.length)
    await expect(panel.getByRole('region', { name: '对话消息', exact: true })).toHaveCount(0)
    await expect(panel.getByRole('textbox', { name: '消息', exact: true })).toHaveCount(0)
  } finally {
    await context.close()
  }
})

test('revoking real page access leaves only the locally authored chat draft available to copy', async ({ browser }) => {
  const ownerContext = await browser.newContext({ baseURL: state.base_url })
  const memberContext = await browser.newContext({ baseURL: state.base_url })
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const owner = await ownerContext.newPage()
  const member = await memberContext.newPage()
  let pageID: string | undefined
  try {
    await owner.goto(pageRoute(state.report_id))
    const saved = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      type: 'doc',
      title: `Chat draft access ${Date.now()}`
    })
    pageID = saved.page.id
    const remoteContent = 'Saved page content must disappear after access is revoked'
    await request(owner, `/pages/${pageID}/content`, 'PUT', {
      base_revision: 0,
      xml: `<page><p>${remoteContent}</p></page>`
    })
    const initial = await request<{ sharing_version: string }>(owner, `/pages/${pageID}/sharing`)
    await request(owner, `/pages/${pageID}/sharing`, 'PUT', {
      sharing_version: initial.sharing_version,
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'edit' }
      ]
    })
    await member.goto(pageRoute(pageID, 'new'))
    await expect(member.getByText(remoteContent, { exact: true })).toBeVisible()
    const panel = member.getByRole('complementary', { name: '页面对话', exact: true })
    const draft = '这是尚未发送、需要复制保存的本地委托'
    await panel.getByRole('textbox', { name: '消息', exact: true }).fill(draft)
    const baseline = await request<{ sharing_version: string }>(owner, `/pages/${pageID}/sharing`)
    await request(owner, `/pages/${pageID}/sharing`, 'PUT', {
      sharing_version: baseline.sharing_version,
      inherit_permissions: false,
      grants: [{ principal_uid: state.owner.uid, role: 'manage' }]
    })
    const recovery = member.getByRole('region', { name: '保留的对话内容', exact: true })
    await expect(recovery).toBeVisible()
    const text = recovery.getByRole('textbox')
    await expect(text).toHaveValue(draft)
    await expect(text).toHaveJSProperty('readOnly', true)
    await text.focus()
    await text.press('ControlOrMeta+A')
    expect(
      await text.evaluate(
        element => (element as HTMLTextAreaElement).selectionEnd - (element as HTMLTextAreaElement).selectionStart
      )
    ).toBe(draft.length)
    await expect(member.getByText(remoteContent, { exact: true })).toHaveCount(0)
    await expect(panel).toHaveCount(0)
  } finally {
    try {
      if (pageID) await request(owner, `/pages/${pageID}`, 'DELETE')
    } finally {
      await ownerContext.close()
      await memberContext.close()
    }
  }
})
