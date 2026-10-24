import { state } from './fixtures'
import { expect, test } from '@playwright/test'
import { conversationRoute } from './routes'

test('a long chat loads real earlier windows without losing messages or the reading position', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const errors: string[] = []
  page.on('pageerror', error => errors.push(error.message))
  try {
    await page.goto(conversationRoute(state.history_conversation_id))
    const messages = page.locator('.pod-chat-human-message')
    const scroll = page.locator('.pod-chat-history-scroll')
    const earlier = page.getByRole('button', { name: '加载更早的消息', exact: true })
    await expect(messages).toHaveCount(500)
    await expect(page.getByText('History item 1006', { exact: true })).toBeVisible()
    await scroll.evaluate(element => element.scrollTo({ top: 0, behavior: 'instant' }))
    await expect(earlier).toBeVisible()
    const anchor = page.getByText('History item 0507', { exact: true })
    const before = await anchor.boundingBox()
    expect(before).not.toBeNull()
    const loaded = page.waitForResponse(response => {
      const url = new URL(response.url())
      return (
        url.pathname === `/api/v2/pod/conversations/${state.history_conversation_id}` &&
        url.searchParams.has('beforeSeq')
      )
    })
    await earlier.click()
    expect((await loaded).status()).toBe(200)
    await expect(messages).toHaveCount(1000)
    await expect.poll(async () => (await anchor.boundingBox())?.y).toBeCloseTo(before!.y, 0)
    await scroll.evaluate(element => element.scrollTo({ top: 0, behavior: 'instant' }))
    await earlier.click()
    await expect(messages).toHaveCount(1006)
    await expect(earlier).toHaveCount(0)
    const texts = await messages.locator('.pod-chat-human-text').allTextContents()
    expect(texts).toEqual(
      Array.from({ length: 1006 }, (_, index) => `History item ${String(index + 1).padStart(4, '0')}`)
    )
    await page.reload()
    await expect(messages).toHaveCount(500)
    await expect(page.getByText('History item 1006', { exact: true })).toBeVisible()
    expect(errors).toEqual([])
  } finally {
    await context.close()
  }
})
