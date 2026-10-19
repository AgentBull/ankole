import { readFileSync } from 'node:fs'
import { expect, test, type BrowserContext, type Page } from '@playwright/test'
import { conversationRoute } from './routes'

const state = JSON.parse(readFileSync(process.env.POD_BROWSER_STATE_PATH!, 'utf8')) as {
  base_url: string
  chat_controls_conversation_id: string
  chat_controls_reply_id: string
  chat_regenerate_conversation_id: string
  chat_regenerate_reply_id: string
  chat_failed_conversation_id: string
  chat_failed_reply_id: string
  owner: { cookies: Parameters<BrowserContext['addCookies']>[0] }
}
type Detail = {
  conversation: { id: string }
  pendingInputs: { messageID: string; text: string; deliveryMode: string }[]
  queuePaused: boolean
  queueVersion: string
  retryableMessageID: string | null
  messages: { id: string; text: string }[]
}

function request(page: Page, path: string, method: 'DELETE'): Promise<null>
function request(page: Page, path: string, method?: string, body?: unknown): Promise<Detail>
async function request(page: Page, path: string, method = 'GET', body?: unknown): Promise<Detail | null> {
  return page.evaluate(
    async ({ path, method, body }) => {
      const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content ?? ''
      const response = await fetch(`/.internal-apis/pod${path}`, {
        method,
        headers: {
          accept: 'application/json',
          'content-type': 'application/json',
          'x-ankole-authentication': meta('ankole-authentication'),
          'x-ankole-pod': meta('ankole-pod'),
          'x-csrf-token': meta('csrf-token')
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) })
      })
      if (!response.ok) throw new Error(`${method} ${path}: ${response.status} ${await response.text()}`)
      return response.status === 204 ? null : response.json()
    },
    { path, method, body }
  )
}

async function mutation(page: Page, id: string, action: string, act: () => Promise<unknown>) {
  const response = page.waitForResponse(
    response =>
      new URL(response.url()).pathname === `/.internal-apis/pod/conversations/${id}/queue` &&
      response.request().method() === 'POST' &&
      response.request().postDataJSON().action === action
  )
  await act()
  const result = await response
  expect(result.status()).toBe(200)
  return result.json() as Promise<Detail>
}

test('a touch chat edits, orders, removes and releases real durable pending inputs without losing a composer draft', async ({
  browser
}, testInfo) => {
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
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await input.fill(`Initial queue request ${crypto.randomUUID()}`)
    let sends = 0
    page.on('request', request => {
      if (request.method() === 'POST' && /\/conversations(?:\/[^/]+\/messages)?$/.test(new URL(request.url()).pathname))
        sends++
    })
    await input.dispatchEvent('keydown', { key: 'Enter', keyCode: 229, isComposing: true })
    expect(sends).toBe(0)
    await input.press('Shift+Enter')
    await expect(input).toHaveValue(/\n$/)
    const created = page.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === '/.internal-apis/pod/conversations'
    )
    await input.press('Enter')
    const first = (await (await created).json()) as Detail
    const id = first.conversation.id
    await expect(page).toHaveURL(url => url.pathname === conversationRoute(id))
    await mutation(page, id, 'stop', () => page.getByRole('button', { name: '停止回复', exact: true }).click())
    const queue = page.getByRole('region', { name: '待发送', exact: true })
    await expect(queue.getByRole('heading', { name: '待发送队列已暂停', exact: true })).toBeVisible()
    await page.getByRole('combobox', { name: '后续消息处理方式', exact: true }).click()
    await page.getByRole('option', { name: '排队发送', exact: true }).click()
    const add = async (text: string) => {
      const response = page.waitForResponse(
        response =>
          response.request().method() === 'POST' &&
          new URL(response.url()).pathname === `/.internal-apis/pod/conversations/${id}/messages`
      )
      await input.fill(text)
      await input.press('Enter')
      const result = await response
      expect(result.status()).toBe(200)
      return result.json() as Promise<Detail>
    }
    await add('Second queued request')
    const three = await add('Third queued request')
    const secondID = three.pendingInputs.find(item => item.text === 'Second queued request')!.messageID
    const thirdID = three.pendingInputs.find(item => item.text === 'Third queued request')!.messageID
    await input.fill('Independent unsent draft')
    const second = queue
      .locator('li.pod-chat-queue-item')
      .filter({ has: page.getByText('Second queued request', { exact: true }) })
    await second.getByRole('button', { name: '编辑待发送消息', exact: true }).click()
    await expect(input).toBeFocused()
    await input.fill('Edited second queued request')
    await request(page, `/conversations/${id}/messages`, 'POST', {
      messageID: crypto.randomUUID(),
      text: 'Concurrent unrelated request',
      deliveryMode: 'queue'
    })
    const stale = page.waitForResponse(
      response =>
        new URL(response.url()).pathname === `/.internal-apis/pod/conversations/${id}/queue` &&
        response.request().method() === 'POST' &&
        response.request().postDataJSON().action === 'edit'
    )
    await input.press('Enter')
    expect((await stale).status()).toBe(409)
    await expect(input).toHaveValue('Edited second queued request')
    await page.getByRole('button', { name: '刷新后继续编辑', exact: true }).click()
    await expect(page.getByRole('button', { name: '刷新后继续编辑', exact: true })).toHaveCount(0)
    await expect(input).toHaveValue('Edited second queued request')
    const edited = await mutation(page, id, 'edit', () => input.press('Enter'))
    expect(edited.pendingInputs.find(item => item.messageID === secondID)?.text).toBe('Edited second queued request')
    await expect(input).toHaveValue('Independent unsent draft')
    const concurrent = queue
      .locator('li.pod-chat-queue-item')
      .filter({ has: page.getByText('Concurrent unrelated request', { exact: true }) })
    await mutation(page, id, 'remove', () =>
      concurrent.getByRole('button', { name: '移除待发送消息', exact: true }).click()
    )
    const third = queue
      .locator('li.pod-chat-queue-item')
      .filter({ has: page.getByText('Third queued request', { exact: true }) })
    const ordered = await mutation(page, id, 'reorder', () =>
      third.getByRole('button', { name: '提前发送', exact: true }).click()
    )
    expect(ordered.pendingInputs.map(item => item.messageID)).toEqual([
      three.pendingInputs[0]!.messageID,
      thirdID,
      secondID
    ])
    await input.fill('')
    await page.reload()
    const reopened = await request(page, `/conversations/${id}`)
    expect(reopened.queuePaused).toBe(true)
    expect(reopened.pendingInputs.map(item => item.messageID)).toEqual(
      ordered.pendingInputs.map(item => item.messageID)
    )
    await mutation(page, id, 'remove', () => third.getByRole('button', { name: '移除待发送消息', exact: true }).click())
    const replay = await request(page, `/conversations/${id}/messages`, 'POST', {
      messageID: thirdID,
      text: 'Third queued request',
      deliveryMode: 'queue'
    })
    expect(replay.pendingInputs.some(item => item.messageID === thirdID)).toBe(false)
    expect(replay.messages.some(item => item.id === thirdID)).toBe(false)
    const editedRow = queue
      .locator('li.pod-chat-queue-item')
      .filter({ has: page.getByText('Edited second queued request', { exact: true }) })
    const released = await mutation(page, id, 'send_now', () =>
      editedRow.getByRole('button', { name: '立即发送这条', exact: true }).click()
    )
    expect(released.queuePaused).toBe(true)
    expect(released.pendingInputs[0]).toMatchObject({ messageID: secondID, deliveryMode: 'steer' })
    const resumed = await mutation(page, id, 'resume', () =>
      page.getByRole('button', { name: '继续发送队列', exact: true }).click()
    )
    expect(resumed.queuePaused).toBe(false)
    await page.screenshot({ path: testInfo.outputPath('mobile-durable-chat-queue.png') })
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)
  } finally {
    page.removeAllListeners('dialog')
    page.on('dialog', dialog => dialog.accept())
    await context.close()
  }
})

test('a completed message copies exact code and text, then edits and retries through the real API', async ({
  browser
}, testInfo) => {
  const context = await browser.newContext({
    baseURL: state.base_url,
    permissions: ['clipboard-read', 'clipboard-write']
  })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    const id = state.chat_controls_conversation_id
    await page.goto(conversationRoute(id))
    await page.getByRole('button', { name: '复制代码', exact: true }).click()
    expect(await page.evaluate(() => navigator.clipboard.readText())).toBe('const total = 42\nconsole.log(total)\n')
    const human = page.locator('.pod-chat-human-message').filter({ hasText: 'Original completed edit request' })
    await human.hover()
    await human.getByRole('button', { name: '复制消息', exact: true }).click()
    expect(await page.evaluate(() => navigator.clipboard.readText())).toBe('Original completed edit request')
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await input.fill('Independent next draft')
    await human.getByRole('button', { name: '编辑并重新生成', exact: true }).click()
    await expect(input).toBeFocused()
    await expect(input).toHaveValue('Original completed edit request')
    await expect(page.getByText('重新生成会保留已完成的页面、数据库和应用修改。', { exact: true }).last()).toBeVisible()
    await input.fill('Edited request through the actual API')
    let committed: Detail | undefined
    const commandIDs: string[] = []
    const queuePath = `/.internal-apis/pod/conversations/${id}/queue`
    page.on('request', request => {
      if (
        request.method() === 'POST' &&
        new URL(request.url()).pathname === queuePath &&
        request.postDataJSON().action === 'edit_last'
      )
        commandIDs.push(request.postDataJSON().commandID)
    })
    await page.route(`**${queuePath}`, async route => {
      if (route.request().postDataJSON().action !== 'edit_last' || committed) return route.continue()
      const response = await route.fetch()
      expect(response.status()).toBe(200)
      committed = await response.json()
      await route.abort('failed')
    })
    await input.press('Enter')
    await expect.poll(() => committed).not.toBeUndefined()
    await expect(page.getByRole('button', { name: '保存消息', exact: true })).toBeEnabled()
    await expect(input).toHaveValue('Edited request through the actual API')
    const result = await mutation(page, id, 'edit_last', () => input.press('Enter'))
    expect(commandIDs).toHaveLength(2)
    expect(commandIDs[1]).toBe(commandIDs[0])
    expect(result.messages.some(message => message.id === state.chat_controls_reply_id)).toBe(false)
    expect(result.pendingInputs).toHaveLength(1)
    expect(result.pendingInputs[0]!.text).toBe('Edited request through the actual API')
    await expect(input).toHaveValue('Independent next draft')
    await input.fill('')
    await page.reload()
    const refreshed = await request(page, `/conversations/${id}`)
    expect(refreshed.messages.some(message => message.text === 'Edited request through the actual API')).toBe(true)
    expect(refreshed.messages.some(message => message.id === state.chat_controls_reply_id)).toBe(false)
    await page.screenshot({ path: testInfo.outputPath('chat-edited-last-message.png') })
  } finally {
    await context.close()
  }
})

test('regenerate replaces only the last reply and accepts an actual retry input', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    const id = state.chat_regenerate_conversation_id
    await page.goto(conversationRoute(id))
    const agent = page.locator('.pod-chat-agent-message').filter({ hasText: 'Completed UI material.' })
    await agent.hover()
    const result = await mutation(page, id, 'regenerate', () =>
      agent.getByRole('button', { name: '重新生成', exact: true }).click()
    )
    expect(result.messages.some(message => message.id === state.chat_regenerate_reply_id)).toBe(false)
    expect(result.messages.filter(message => message.text === 'Original completed regenerate request')).toHaveLength(1)
    expect(result.pendingInputs).toHaveLength(1)
    await expect(page.getByRole('button', { name: '重新生成', exact: true })).toHaveCount(0)
    await page.reload()
    expect(
      (await request(page, `/conversations/${id}`)).messages.some(
        message => message.id === state.chat_regenerate_reply_id
      )
    ).toBe(false)
  } finally {
    await context.close()
  }
})

test('a real dead-letter notice retries the reply once and restores the accepted request after refresh', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    const id = state.chat_failed_conversation_id
    await page.goto(conversationRoute(id))
    const initial = await request(page, `/conversations/${id}`)
    expect(initial.retryableMessageID).toBe(state.chat_failed_reply_id)
    await expect(page.getByRole('button', { name: '重试发送', exact: true })).toHaveCount(0)
    const retry = page.getByRole('button', { name: '重试回复', exact: true })
    await page.locator('.pod-chat-agent-message').filter({ has: retry }).hover()
    await expect(retry.locator('..')).toHaveCSS('opacity', '1')
    const result = await mutation(page, id, 'regenerate', () => retry.click())
    expect(result.messages.some(message => message.id === state.chat_failed_reply_id)).toBe(false)
    expect(result.messages.filter(message => message.text === 'Original failed reply request')).toHaveLength(1)
    expect(result.pendingInputs).toHaveLength(1)
    expect(result.pendingInputs[0]!.text).toBe('Original failed reply request')
    expect(result.retryableMessageID).toBeNull()
    await expect(page.getByRole('button', { name: '重试回复', exact: true })).toHaveCount(0)
    await page.reload()
    const restored = await request(page, `/conversations/${id}`)
    expect(restored.pendingInputs.map(input => input.messageID)).toEqual(
      result.pendingInputs.map(input => input.messageID)
    )
    expect(restored.messages.some(message => message.id === state.chat_failed_reply_id)).toBe(false)
  } finally {
    await context.close()
  }
})

test('reordering follow-ups preserves the still-pending first request shown in the timeline', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto('/')
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await input.fill('First request waiting for Main startup')
    const accepted = page.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === '/.internal-apis/pod/conversations'
    )
    await input.press('Enter')
    const firstResponse = await accepted
    expect(firstResponse.status()).toBe(200)
    const first = (await firstResponse.json()) as Detail
    id = first.conversation.id
    const firstID = first.pendingInputs[0]!.messageID
    await expect(page).toHaveURL(url => url.pathname === conversationRoute(id!))
    await page.getByRole('combobox', { name: '后续消息处理方式', exact: true }).click()
    await page.getByRole('option', { name: '排队发送', exact: true }).click()
    const add = async (text: string) => {
      const response = page.waitForResponse(
        response =>
          response.request().method() === 'POST' &&
          new URL(response.url()).pathname === `/.internal-apis/pod/conversations/${id}/messages`
      )
      await input.fill(text)
      await input.press('Enter')
      const result = await response
      expect(result.status()).toBe(200)
      return result.json() as Promise<Detail>
    }
    await add('Second queued follow-up')
    const third = await add('Third queued follow-up')
    expect(third.pendingInputs).toHaveLength(3)
    const secondID = third.pendingInputs.find(item => item.text === 'Second queued follow-up')!.messageID
    const thirdID = third.pendingInputs.find(item => item.text === 'Third queued follow-up')!.messageID
    const queue = page.getByRole('region', { name: '待发送', exact: true })
    await expect(
      page.locator('.pod-chat-human-message').getByText('First request waiting for Main startup')
    ).toBeVisible()
    await expect(queue.getByText('First request waiting for Main startup', { exact: true })).toHaveCount(0)
    const second = queue.locator('li.pod-chat-queue-item').filter({ hasText: 'Second queued follow-up' })
    const saved = await mutation(page, id, 'reorder', () =>
      second.getByRole('button', { name: '延后发送', exact: true }).click()
    )
    expect(saved.pendingInputs.map(item => item.messageID)).toEqual([firstID, thirdID, secondID])
    await page.reload()
    const restored = await request(page, `/conversations/${id}`)
    expect(restored.pendingInputs.map(item => item.messageID)).toEqual([firstID, thirdID, secondID])
    await expect(queue.locator('li.pod-chat-queue-item').first()).toContainText('Third queued follow-up')
    await expect(
      page.locator('.pod-chat-human-message').getByText('First request waiting for Main startup')
    ).toBeVisible()
  } finally {
    if (id) {
      let detail = await request(page, `/conversations/${id}`)
      for (const pending of detail.pendingInputs) {
        detail = await request(page, `/conversations/${id}/queue`, 'POST', {
          action: 'remove',
          messageID: pending.messageID,
          expectedVersion: detail.queueVersion
        })
      }
      await request(page, `/conversations/${id}`, 'DELETE')
    }
    await context.close()
  }
})
