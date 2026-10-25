import { state, request as podRequest, selectChatAgent } from './fixtures'
import { expect, test, type Page } from '@playwright/test'
import { conversationRoute } from './routes'

import type { ConversationDetail as Detail } from '../../pod/api'

function agentQueue(detail: Detail) {
  const queue = detail.pendingQueues.find(queue => queue.agentUID === state.agent_uid)
  expect(queue).toBeDefined()
  return queue!
}

function request(page: Page, path: string, method: 'DELETE'): Promise<null>
function request(page: Page, path: string, method?: string, body?: unknown): Promise<Detail>
async function request(page: Page, path: string, method = 'GET', body?: unknown): Promise<Detail | null> {
  return podRequest(page, path, method, body)
}

async function mutation(page: Page, id: string, action: string, act: () => Promise<unknown>) {
  const response = page.waitForResponse(
    response =>
      new URL(response.url()).pathname === `/api/v2/pod/conversations/${id}/queue` &&
      response.request().method() === 'POST' &&
      response.request().postDataJSON().data.action === action
  )
  await act()
  const result = await response
  expect(result.status()).toBe(201)
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
    await selectChatAgent(page)
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await input.fill(`Initial queue request ${crypto.randomUUID()}`)
    let sends = 0
    page.on('request', request => {
      if (
        request.method() === 'POST' &&
        /\/conversations(?:\/[^/]+\/messages)?$/.test(new URL(request.url()).pathname)
      ) {
        sends++
      }
    })
    await input.dispatchEvent('keydown', { key: 'Enter', keyCode: 229, isComposing: true })
    expect(sends).toBe(0)
    await input.press('Shift+Enter')
    await expect(input).toHaveValue(/\n$/)
    const created = page.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/conversations'
    )
    await input.press('Enter')
    const first = (await (await created).json()) as Detail
    const id = first.conversation.id
    await expect(page).toHaveURL(url => url.pathname === conversationRoute(id))
    await mutation(page, id, 'stop', () => page.getByRole('button', { name: '停止回复', exact: true }).click())
    const queue = page.getByRole('region', { name: '待发送', exact: true })
    await expect(queue.getByRole('heading', { name: / · 待发送队列已暂停 \(1\)$/ })).toBeVisible()
    const add = async (text: string) => {
      const response = page.waitForResponse(
        response =>
          response.request().method() === 'POST' &&
          new URL(response.url()).pathname === `/api/v2/pod/conversations/${id}/messages`
      )
      await input.fill(text)
      await input.press('Enter')
      const result = await response
      expect(result.status()).toBe(201)
      return result.json() as Promise<Detail>
    }
    await add('Second queued request')
    const three = await add('Third queued request')
    expect(agentQueue(three).inputs.every(input => input.deliveryMode === 'queue')).toBe(true)
    const secondID = agentQueue(three).inputs.find(item => item.text === 'Second queued request')!.messageID
    const thirdID = agentQueue(three).inputs.find(item => item.text === 'Third queued request')!.messageID
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
        new URL(response.url()).pathname === `/api/v2/pod/conversations/${id}/queue` &&
        response.request().method() === 'POST' &&
        response.request().postDataJSON().data.action === 'edit'
    )
    await input.press('Enter')
    expect((await stale).status()).toBe(409)
    await expect(input).toHaveValue('Edited second queued request')
    await page.getByRole('button', { name: '刷新后继续编辑', exact: true }).click()
    await expect(page.getByRole('button', { name: '刷新后继续编辑', exact: true })).toHaveCount(0)
    await expect(input).toHaveValue('Edited second queued request')
    const edited = await mutation(page, id, 'edit', () => input.press('Enter'))
    expect(agentQueue(edited).inputs.find(item => item.messageID === secondID)?.text).toBe(
      'Edited second queued request'
    )
    await expect(input).toHaveValue('Independent unsent draft')
    const concurrent = queue
      .locator('li.pod-chat-queue-item')
      .filter({ has: page.getByText('Concurrent unrelated request', { exact: true }) })
    await mutation(page, id, 'retract', () =>
      concurrent.getByRole('button', { name: '撤回到草稿', exact: true }).click()
    )
    const third = queue
      .locator('li.pod-chat-queue-item')
      .filter({ has: page.getByText('Third queued request', { exact: true }) })
    await third.getByRole('button', { name: '调整队列顺序', exact: true }).click()
    const ordered = await mutation(page, id, 'reorder', () =>
      page.getByRole('menuitem', { name: '上移', exact: true }).click()
    )
    expect(agentQueue(ordered).inputs.map(item => item.messageID)).toEqual([
      agentQueue(three).inputs[0]!.messageID,
      thirdID,
      secondID
    ])
    await input.fill('')
    await page.reload()
    const reopened = await request(page, `/conversations/${id}`)
    expect(agentQueue(reopened).paused).toBe(true)
    expect(agentQueue(reopened).inputs.map(item => item.messageID)).toEqual(
      agentQueue(ordered).inputs.map(item => item.messageID)
    )
    await mutation(page, id, 'retract', () => third.getByRole('button', { name: '撤回到草稿', exact: true }).click())
    const replay = await request(page, `/conversations/${id}/messages`, 'POST', {
      messageID: thirdID,
      text: 'Third queued request',
      deliveryMode: 'queue'
    })
    expect(agentQueue(replay).inputs.some(item => item.messageID === thirdID)).toBe(false)
    expect(replay.messages.some(item => item.id === thirdID)).toBe(false)
    const editedRow = queue
      .locator('li.pod-chat-queue-item')
      .filter({ has: page.getByText('Edited second queued request', { exact: true }) })
    const released = await mutation(page, id, 'steer', () =>
      editedRow.getByRole('button', { name: '立即并入当前轮次', exact: true }).click()
    )
    expect(agentQueue(released).paused).toBe(true)
    expect(agentQueue(released).inputs[0]).toMatchObject({ messageID: secondID, deliveryMode: 'steer' })
    const resumed = await mutation(page, id, 'resume', () =>
      page.getByRole('button', { name: '继续发送队列', exact: true }).click()
    )
    expect(agentQueue(resumed).paused).toBe(false)
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
    expect(
      await podRequest<boolean>(page, `/conversations/${id}/participants`, 'POST', {
        addUIDs: [state.chat_workspace.colleague_uid]
      })
    ).toBe(true)
    const invited = await request(page, `/conversations/${id}`)
    const colleague = invited.conversation.agents.find(agent => agent.uid === state.chat_workspace.colleague_uid)!
    const recipient = page.getByRole('combobox', { name: '选择 Agent', exact: true })
    await recipient.click()
    await page.getByRole('option', { name: colleague.displayName, exact: true }).click()
    await expect(recipient).toContainText(colleague.displayName)
    await page.getByRole('button', { name: '复制代码', exact: true }).click()
    expect(await page.evaluate(() => navigator.clipboard.readText())).toBe('const total = 42\nconsole.log(total)')
    const human = page.locator('.pod-chat-human-message').filter({ hasText: 'Original completed edit request' })
    await human.hover()
    await human.getByRole('button', { name: '复制消息', exact: true }).click()
    expect(await page.evaluate(() => navigator.clipboard.readText())).toBe('Original completed edit request')
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await input.fill('Independent next draft')
    await expect(human.getByRole('button', { name: '编辑并重新生成', exact: true })).toHaveAttribute(
      'title',
      /重新生成会保留已完成的页面、数据库和应用修改。/
    )
    await human.getByRole('button', { name: '编辑并重新生成', exact: true }).click()
    await expect(input).toBeFocused()
    await expect(input).toHaveValue('Original completed edit request')
    await input.fill('Edited request through the actual API')
    let committed: Detail | undefined
    const commandIDs: string[] = []
    const queuePath = `/api/v2/pod/conversations/${id}/queue`
    page.on('request', request => {
      if (
        request.method() === 'POST' &&
        new URL(request.url()).pathname === queuePath &&
        request.postDataJSON().data.action === 'edit_last'
      ) {
        expect(request.postDataJSON().data.agentUID).toBe(state.agent_uid)
        commandIDs.push(request.postDataJSON().data.commandID)
      }
    })
    await page.route(`**${queuePath}`, async route => {
      if (route.request().postDataJSON().data.action !== 'edit_last' || committed) return route.continue()
      const response = await route.fetch()
      expect(response.status()).toBe(201)
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
    expect(agentQueue(result).inputs).toHaveLength(1)
    expect(agentQueue(result).inputs[0]!.text).toBe('Edited request through the actual API')
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
      agent.getByRole('button', { name: '重试回复', exact: true }).click()
    )
    expect(result.messages.some(message => message.id === state.chat_regenerate_reply_id)).toBe(false)
    expect(result.messages.filter(message => message.text === 'Original completed regenerate request')).toHaveLength(1)
    expect(agentQueue(result).inputs).toHaveLength(1)
    await expect(page.getByRole('button', { name: '重试回复', exact: true })).toHaveCount(0)
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
    expect(agentQueue(initial).retryableMessageID).toBe(state.chat_failed_reply_id)
    await expect(page.getByRole('button', { name: '重试发送', exact: true })).toHaveCount(0)
    const retry = page.getByRole('button', { name: '重试回复', exact: true })
    await page.locator('.pod-chat-agent-message').filter({ has: retry }).hover()
    await expect(retry.locator('..')).toHaveCSS('opacity', '1')
    const result = await mutation(page, id, 'regenerate', () => retry.click())
    expect(result.messages.some(message => message.id === state.chat_failed_reply_id)).toBe(false)
    expect(result.messages.filter(message => message.text === 'Original failed reply request')).toHaveLength(1)
    expect(agentQueue(result).inputs).toHaveLength(1)
    expect(agentQueue(result).inputs[0]!.text).toBe('Original failed reply request')
    expect(agentQueue(result).retryableMessageID).toBeNull()
    await expect(page.getByRole('button', { name: '重试回复', exact: true })).toHaveCount(0)
    await page.reload()
    const restored = await request(page, `/conversations/${id}`)
    expect(agentQueue(restored).inputs.map(input => input.messageID)).toEqual(
      agentQueue(result).inputs.map(input => input.messageID)
    )
    expect(restored.messages.some(message => message.id === state.chat_failed_reply_id)).toBe(false)
  } finally {
    await context.close()
  }
})

test('reordering follow-ups preserves the first shared message and its Agent queue projection', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto('/')
    await selectChatAgent(page)
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await input.fill('First request waiting for Main startup')
    const accepted = page.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/conversations'
    )
    await input.press('Enter')
    const firstResponse = await accepted
    expect(firstResponse.status()).toBe(201)
    const first = (await firstResponse.json()) as Detail
    id = first.conversation.id
    const firstID = agentQueue(first).inputs[0]!.messageID
    await expect(page).toHaveURL(url => url.pathname === conversationRoute(id!))
    const add = async (text: string) => {
      const response = page.waitForResponse(
        response =>
          response.request().method() === 'POST' &&
          new URL(response.url()).pathname === `/api/v2/pod/conversations/${id}/messages`
      )
      await input.fill(text)
      await input.press('Enter')
      const result = await response
      expect(result.status()).toBe(201)
      return result.json() as Promise<Detail>
    }
    await add('Second queued follow-up')
    const third = await add('Third queued follow-up')
    expect(agentQueue(third).inputs.every(input => input.deliveryMode === 'queue')).toBe(true)
    expect(agentQueue(third).inputs).toHaveLength(3)
    const secondID = agentQueue(third).inputs.find(item => item.text === 'Second queued follow-up')!.messageID
    const thirdID = agentQueue(third).inputs.find(item => item.text === 'Third queued follow-up')!.messageID
    const queue = page.getByRole('region', { name: '待发送', exact: true })
    const firstMessage = page
      .locator('.pod-chat-human-message')
      .getByText('First request waiting for Main startup', { exact: true })
    await expect(firstMessage).toHaveCount(0)
    await expect(queue.getByText('First request waiting for Main startup', { exact: true })).toHaveCount(1)
    await expect(input).toBeEditable()
    const second = queue.locator('li.pod-chat-queue-item').filter({ hasText: 'Second queued follow-up' })
    await second.getByRole('button', { name: '调整队列顺序', exact: true }).click()
    const saved = await mutation(page, id, 'reorder', () =>
      page.getByRole('menuitem', { name: '下移', exact: true }).click()
    )
    expect(agentQueue(saved).inputs.map(item => item.messageID)).toEqual([firstID, thirdID, secondID])
    await page.reload()
    const restored = await request(page, `/conversations/${id}`)
    expect(agentQueue(restored).inputs.map(item => item.messageID)).toEqual([firstID, thirdID, secondID])
    await expect(queue.locator('li.pod-chat-queue-item').nth(1)).toContainText('Third queued follow-up')
    await expect(firstMessage).toHaveCount(0)
  } finally {
    if (id) {
      let detail = await request(page, `/conversations/${id}`)
      for (const pending of agentQueue(detail).inputs) {
        detail = await request(page, `/conversations/${id}/queue`, 'POST', {
          action: 'retract',
          messageID: pending.messageID,
          agentUID: state.agent_uid,
          expectedVersion: agentQueue(detail).queueVersion
        })
      }
      await request(page, `/conversations/${id}`, 'DELETE')
    }
    await context.close()
  }
})
