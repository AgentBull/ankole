import { readFileSync } from 'node:fs'
import { expect, test, type BrowserContext } from '@playwright/test'
import { conversationRoute } from './routes'
import type { ConversationDetail } from '../../pod/api'

const state = JSON.parse(readFileSync(process.env.POD_BROWSER_STATE_PATH!, 'utf8')) as {
  base_url: string
  history_conversation_id: string
  owner: { cookies: Parameters<BrowserContext['addCookies']>[0] }
}

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
    const anchor = page.getByText('History item 0991', { exact: true })
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
      await page.getByRole('link', { name: '新对话', exact: true }).click()
      await expect(page.getByRole('heading', { name: '开始对话', exact: true })).toBeVisible()
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
  const detailPath = `/.internal-apis/pod/conversations/${id}`
  const fixtureIDs = [crypto.randomUUID(), crypto.randomUUID()]
  let growth = 0
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
            authorUID: detail.conversation.agent.uid,
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
      url => url.pathname === `${detailPath}/events`,
      route =>
        route.fulfill({
          status: 200,
          contentType: 'text/event-stream',
          headers: { 'cache-control': 'no-cache' },
          body: 'retry: 1000\nevent: message\ndata: {}\n\n'
        })
    )
    await page.goto(conversationRoute(id))
    const scroll = page.locator('.pod-chat-history-scroll')
    const anchor = page.getByText('History item 0991', { exact: true })
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
  } finally {
    await context.close()
  }
})
