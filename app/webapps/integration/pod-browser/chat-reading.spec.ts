import { state, request } from './fixtures'
import { expect, test } from '@playwright/test'
import { conversationRoute } from './routes'
import type { ConversationDetail } from '../../pod/api'

test('a long chat restores its reading anchor and bottom intent after switching chats', async ({
  browser
}, testInfo) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1440, height: 1000 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const errors: string[] = []
  page.on('pageerror', error => errors.push(error.message))
  try {
    const route = conversationRoute(state.history_conversation_id)
    await page.goto(route)
    const scroll = page.locator('.pod-chat-history-scroll')
    const anchor = page.locator('.pod-chat-human-text > .pod-chat-markdown').filter({ hasText: /^History item 0991$/ })
    await expect(page.locator('.pod-chat-human-message')).toHaveCount(500)
    await anchor.evaluate(element => {
      const container = element.closest<HTMLElement>('.pod-chat-history-scroll')!
      container.scrollTop += element.getBoundingClientRect().top - container.getBoundingClientRect().top - 37
    })
    const offset = () =>
      anchor.evaluate(
        element =>
          element.getBoundingClientRect().top - element.closest('.pod-chat-history-scroll')!.getBoundingClientRect().top
      )
    await expect.poll(offset).toBeCloseTo(37, 0)
    const before = await offset()
    await page.screenshot({ path: testInfo.outputPath('reading-before-switch.png') })

    await page.getByRole('tab', { name: '对话', exact: true }).click()
    const switchAway = async () => {
      await page.locator('.pod-chat-sidebar').getByRole('button', { name: '新对话', exact: true }).click()
      await expect(page.locator('.pod-chat-home').getByRole('heading', { level: 1 })).toContainText('Browser owner')
    }
    const returnToChat = async () => {
      await page.locator(`.pod-chat-row a[href="${route}"]`).click()
      await expect(page).toHaveURL(url => url.pathname === route)
    }
    await switchAway()
    await returnToChat()
    await expect.poll(offset).toBeCloseTo(before, 0)
    await page.screenshot({ path: testInfo.outputPath('reading-after-switch.png') })

    await page.setViewportSize({ width: 1100, height: 1000 })
    await expect.poll(offset).toBeCloseTo(before, 0)
    await switchAway()
    await returnToChat()
    await expect.poll(offset).toBeCloseTo(before, 0)

    await scroll.evaluate(element => element.scrollTo({ top: element.scrollHeight, behavior: 'instant' }))
    const bottomGap = () => scroll.evaluate(element => element.scrollHeight - element.clientHeight - element.scrollTop)
    await expect.poll(bottomGap).toBeLessThan(2)
    await switchAway()
    await returnToChat()
    await expect.poll(bottomGap).toBeLessThan(2)
    expect(errors).toEqual([])
  } finally {
    await context.close()
  }
})

test('a labeled network growth fixture preserves reading, then follows after Jump latest', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1440, height: 1000 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const id = state.history_conversation_id
  const detailPath = `/api/v2/pod/conversations/${id}`
  const eventsPath = `${detailPath}/events`
  const fixtureIDs = [crypto.randomUUID(), crypto.randomUUID()]
  let growth = 0
  let stopEvents = false
  try {
    // Keep the real API response. Only appended assistant content is a network fixture.
    await page.route(
      url => url.pathname === detailPath,
      async route => {
        const response = await route.fetch()
        const detail = (await response.json()) as ConversationDetail
        const lastSeq = detail.messageRange.lastSeq
        for (let index = 0; index < growth; index++) {
          detail.messages.push({
            id: fixtureIDs[index]!,
            seq: lastSeq + index + 1,
            authorType: 'agent',
            authorUID: detail.conversation.agents[0]!.uid,
            authorDisplayName: detail.conversation.agents[0]!.displayName,
            authorArchived: false,
            mentions: [],
            savedPages: [],
            kind: 'message',
            text: `## Network growth fixture ${index + 1}\n\n${Array.from({ length: 80 }, (_, line) => `Network fixture paragraph ${line + 1}: client scrolling evidence; no provider execution.`).join('\n\n')}`,
            createdAt: new Date().toISOString(),
            replyToMessageID: null,
            signalID: null,
            links: [],
            attachments: []
          })
        }
        detail.messageRange.lastSeq = lastSeq + growth
        await route.fulfill({ response, json: detail })
      }
    )
    // A finite SSE fixture reconnects and exercises the production detail reload path.
    await page.route(
      url => url.pathname === eventsPath,
      route =>
        route.fulfill(
          stopEvents
            ? { status: 204 }
            : {
                status: 200,
                contentType: 'text/event-stream',
                headers: { 'cache-control': 'no-cache' },
                body: `retry: 1000\nevent: conversation\ndata: ${JSON.stringify({ conversationID: id })}\n\n`
              }
        )
    )
    await page.goto(conversationRoute(id))
    const scroll = page.locator('.pod-chat-history-scroll')
    const anchor = page.locator('.pod-chat-human-text > .pod-chat-markdown').filter({ hasText: /^History item 0991$/ })
    await expect(anchor).toHaveCount(1)
    await anchor.evaluate(element => {
      const container = element.closest<HTMLElement>('.pod-chat-history-scroll')!
      container.scrollTop += element.getBoundingClientRect().top - container.getBoundingClientRect().top - 37
    })
    const offset = () =>
      anchor.evaluate(
        element =>
          element.getBoundingClientRect().top - element.closest('.pod-chat-history-scroll')!.getBoundingClientRect().top
      )
    await expect.poll(offset).toBeCloseTo(37, 0)
    const previousHeight = await scroll.evaluate(element => element.scrollHeight)
    growth = 1
    await expect(page.getByRole('heading', { name: 'Network growth fixture 1', exact: true })).toHaveCount(1)
    await expect.poll(() => scroll.evaluate(element => element.scrollHeight)).toBeGreaterThan(previousHeight + 1000)
    await expect.poll(offset).toBeCloseTo(37, 0)

    await page.getByRole('button', { name: '滚动到最新消息', exact: true }).click()
    const bottomGap = () => scroll.evaluate(element => element.scrollHeight - element.clientHeight - element.scrollTop)
    await expect.poll(bottomGap).toBeLessThan(2)
    growth = 2
    await expect(page.getByRole('heading', { name: 'Network growth fixture 2', exact: true })).toHaveCount(1)
    await expect.poll(bottomGap).toBeLessThan(2)
    // End the finite SSE fixture before removing handlers for its detail reloads.
    const stopped = page.waitForResponse(
      response => new URL(response.url()).pathname === eventsPath && response.status() === 204
    )
    stopEvents = true
    await stopped
  } finally {
    // Finish response transforms before closing the request context.
    await page.unrouteAll({ behavior: 'wait' })
    await context.close()
  }
})

test('conversation find loads older pages on demand and finds the first retained message', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1440, height: 1000 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const id = state.history_conversation_id
  const path = `/api/v2/pod/conversations/${id}`
  let pageRequests = 0
  let holdFirst = true
  let started!: () => void
  let release!: () => void
  const requested = new Promise<void>(resolve => {
    started = resolve
  })
  const gate = new Promise<void>(resolve => {
    release = resolve
  })
  try {
    await page.route(
      url => url.pathname === path && url.searchParams.has('beforeSeq'),
      async route => {
        pageRequests++
        if (holdFirst) {
          holdFirst = false
          started()
          await gate
        }
        await route.continue()
      }
    )
    await page.goto(conversationRoute(id))
    await expect(page.locator('.pod-chat-human-message')).toHaveCount(500)
    const draft = page.locator('.pod-chat-composer').getByRole('textbox', { name: '消息', exact: true })
    await draft.fill('Unsent search draft')
    await page.keyboard.press('Control+f')
    const find = page.getByRole('textbox', { name: '在会话内查找', exact: true })
    await expect(find).toBeFocused()
    await find.fill('   ')
    await expect(page.locator('.pod-chat-find [aria-live]')).toHaveText('0/0')
    expect(pageRequests).toBe(0)
    await find.fill('History item 0001')
    expect(pageRequests).toBe(0)
    await page.locator('.pod-chat-find').getByRole('button', { name: '加载更早消息', exact: true }).click()
    await requested
    await expect(page.locator('.pod-chat-find [aria-live]')).toContainText('+')
    await find.press('Escape')
    await expect(find).toBeHidden()
    release()
    await expect(page.locator('.pod-chat-human-message')).toHaveCount(1000)
    expect(pageRequests).toBe(1)
    await expect(draft).toBeFocused()
    await expect(draft).toHaveValue('Unsent search draft')

    await page.keyboard.press('Control+f')
    await find.fill('History item 0001')
    expect(pageRequests).toBe(1)
    await page.locator('.pod-chat-find').getByRole('button', { name: '加载更早消息', exact: true }).click()
    await expect(page.locator('.pod-chat-find [aria-live]')).toHaveText('1/1')
    await expect(page.locator('.pod-chat-human-message')).toHaveCount(1006)
    expect(pageRequests).toBe(2)
    await expect.poll(() => page.evaluate(() => CSS.highlights.get('pod-chat-find')?.size ?? 0)).toBe(1)
    const earliest = page
      .locator('.pod-chat-human-text > .pod-chat-markdown')
      .filter({ hasText: /^History item 0001$/ })
    await expect(earliest).toBeInViewport()
    await find.press('Escape')
    expect(await page.evaluate(() => CSS.highlights.has('pod-chat-find'))).toBe(false)
    await expect(draft).toBeFocused()
    await expect(draft).toHaveValue('Unsent search draft')
  } finally {
    release()
    await page.unrouteAll({ behavior: 'wait' })
    await context.close()
  }
})

test('conversation find updates when a recorded tool detail opens or closes', async ({ browser }) => {
  const material = (state as typeof state & { chat_workspace?: { conversation_id: string; first_reply_id: string } })
    .chat_workspace
  test.skip(!material, 'Start the dedicated fixture with POD_BROWSER_CHAT_WORKSPACE=true')
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1440, height: 1000 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(conversationRoute(material!.conversation_id))
    const message = page.locator(`[data-chat-message-id="${material!.first_reply_id}"]`)
    await message.locator('.pod-chat-work > summary').click()
    const step = message.locator('.pod-chat-tool-step').filter({ hasText: 'row_count' })
    await expect(step).not.toHaveAttribute('open', '')
    await page.locator('.pod-chat-history-scroll').focus()
    await page.keyboard.press('Control+f')
    const find = page.getByRole('textbox', { name: '在会话内查找', exact: true })
    await find.fill('row_count')
    await expect(page.locator('.pod-chat-find [aria-live]')).toHaveText('0/0')
    await step.locator(':scope > summary').click()
    await expect(page.locator('.pod-chat-find [aria-live]')).toHaveText('1/1')
    await expect.poll(() => page.evaluate(() => CSS.highlights.get('pod-chat-find')?.size ?? 0)).toBe(1)
    await step.locator(':scope > summary').click()
    await expect(page.locator('.pod-chat-find [aria-live]')).toHaveText('0/0')
    await expect.poll(() => page.evaluate(() => CSS.highlights.get('pod-chat-find')?.size ?? 0)).toBe(0)
    await find.press('Escape')
  } finally {
    await context.close()
  }
})

test('the home recent list keeps the latest room ahead of older pinned rooms', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1440, height: 1000 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const created: string[] = []
  const title = `Latest recent room ${crypto.randomUUID()}`
  try {
    await page.goto('/')
    for (let index = 0; index < 5; index++) {
      const id = crypto.randomUUID()
      await request(page, '/conversations', 'POST', {
        conversationID: id,
        messageID: crypto.randomUUID(),
        agentUID: state.agent_uid,
        text: index === 4 ? title : `Old pinned room ${index} ${id}`
      })
      created.push(id)
      if (index < 4) await request(page, `/conversations/${id}`, 'PATCH', { pinned: true })
    }
    await page.reload()
    await expect(page.locator('.pod-chat-recent-row').first()).toContainText(title)
    await expect(page.locator('.pod-chat-recent-row')).toHaveCount(3)
    await expect(page.locator('.pod-chat-recent-row').first()).toHaveAttribute('href', conversationRoute(created[4]!))
  } finally {
    for (const id of created) await request(page, `/conversations/${id}?forceStop=true`, 'DELETE')
    await context.close()
  }
})
