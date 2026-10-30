import { expect, test, type Page } from '@playwright/test'
import { request, selectChatAgent, state } from './fixtures'
import { conversationRoute } from './routes'
import type { ConversationDetail, PodAgent } from '../../pod/api'

test('the composer grows, wraps and shrinks with native field sizing', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1440, height: 960 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto('/')
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await expect(input).toBeEditable()
    const native = await page.evaluate(() => CSS.supports('field-sizing', 'content'))
    const height = () => input.evaluate(element => element.getBoundingClientRect().height)
    await input.fill('')
    const emptyHeight = await height()
    await input.fill('A wrapping draft with enough words to fill several lines. '.repeat(4))
    await page.setViewportSize({ width: 390, height: 844 })
    await expect.poll(height).toBeGreaterThan(emptyHeight)
    await input.fill(Array.from({ length: 30 }, (_, index) => `Line ${index}`).join('\n'))
    await expect.poll(height).toBe(240)
    expect(await input.evaluate(element => element.scrollHeight > element.clientHeight)).toBe(true)
    if (native) expect(await input.evaluate(element => element.style.height)).toBe('')
    await input.fill('')
    await expect.poll(height).toBe(emptyHeight)
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  } finally {
    await context.close()
  }
})

test('removing a Page mention preserves surrounding text and literal punctuation', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto('/')
    const created = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'doc',
      title: 'C++ plan (2026)'
    })
    id = created.page.id
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await input.pressSequentially('Review @C++ plan')
    await page.getByRole('option', { name: 'C++ plan (2026)', exact: true }).click()
    await input.pressSequentially('with the team.')
    await page.locator('.pod-chat-draft-page').getByRole('button', { name: '关闭', exact: true }).click()
    await expect(input).toHaveValue('Review with the team.')
    await expect(page.locator('.pod-chat-draft-page')).toHaveCount(0)
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

async function removeRoom(page: Page, id: string) {
  let detail = await request<ConversationDetail>(page, `/conversations/${id}`)
  for (const queue of detail.pendingQueues) {
    for (const input of queue.inputs) {
      detail = await request<ConversationDetail>(page, `/conversations/${id}/queue`, 'POST', {
        action: 'retract',
        agentUID: queue.agentUID,
        messageID: input.messageID,
        expectedVersion: detail.pendingQueues.find(slot => slot.agentUID === queue.agentUID)!.queueVersion
      })
    }
  }
  await request(page, `/conversations/${id}`, 'DELETE')
}

test('edited code is visible while syntax highlighting waits for the new text', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto('/')
    const messageID = crypto.randomUUID()
    const room = await request<ConversationDetail>(page, '/conversations', 'POST', {
      conversationID: crypto.randomUUID(),
      messageID,
      agentUID: state.agent_uid,
      text: '```js\nconst original = 1\n```',
      deliveryMode: 'queue'
    })
    id = room.conversation.id
    await request(page, `/conversations/${id}/participants`, 'POST', { addUIDs: [state.member.uid] })
    await page.goto(conversationRoute(id))
    const code = page.locator(`[data-chat-message-id="${messageID}"] .pod-chat-code`)
    await expect(code.locator('.shiki code')).toHaveText('const original = 1')
    await page.getByRole('button', { name: '编辑待发送消息', exact: true }).click()
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await input.fill('```js\nconst revised = 2\n```')
    await page.clock.install()
    await page.clock.pauseAt(new Date())
    const saved = page.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/v2/pod/conversations/${id}/queue`
    )
    await input.press('Enter')
    expect((await saved).ok()).toBe(true)
    await expect(code.locator('code')).toHaveText('const revised = 2')
    await expect(code.locator('.shiki')).toHaveCount(0)
    await page.clock.runFor(180)
    await expect(code.locator('.shiki code')).toHaveText('const revised = 2')
  } finally {
    await page.clock.resume()
    if (id) await removeRoom(page, id)
    await context.close()
  }
})

test('inline mention search keeps the draft focused and sends the selected Agent through the real API', async ({
  browser
}, info) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 390, height: 844 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto('/')
    const { agents } = await request<{ agents: PodAgent[] }>(page, '/agents')
    const agent = agents.find(agent => agent.uid === state.agent_uid)!
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await input.pressSequentially('Use @Chat workspace')
    await page.getByRole('option', { name: 'Chat workspace reference Browser report', exact: true }).click()
    const reference = page.locator('.pod-chat-draft-page')
    await expect(reference).toContainText('Chat workspace reference')
    await reference.getByRole('button', { name: '关闭', exact: true }).click()
    await expect(input).toHaveValue('Use ')
    await input.fill('请')
    await input.pressSequentially('@Chat workspace')
    await expect(
      page.getByRole('option', { name: 'Chat workspace reference Browser report', exact: true })
    ).toBeVisible()
    await input.press('Escape')
    await input.fill('')
    const query = agent.displayName.split(/\s+/).find(word => word.length > 2) || agent.displayName
    await input.pressSequentially(`Ask @${query}`)
    const list = page.getByRole('listbox', { name: '补全建议', exact: true })
    await expect(list.getByRole('option', { name: agent.displayName, exact: true })).toBeVisible()
    await expect(input).toBeFocused()
    await expect(page.locator('.pod-chat-composer-picker input')).toHaveCount(0)
    const count = await list.getByRole('option').count()
    const target = list.getByRole('option', { name: agent.displayName, exact: true })
    for (let step = 0; step < count; step++) {
      if ((await target.getAttribute('aria-selected')) === 'true') break
      await input.press('ArrowDown')
    }
    await expect(target).toHaveAttribute('aria-selected', 'true')
    expect(count).toBeGreaterThan(1)
    await input.press('ArrowDown')
    await expect(target).toHaveAttribute('aria-selected', 'false')
    await input.press('ArrowUp')
    await expect(target).toHaveAttribute('aria-selected', 'true')
    await expect(list.getByRole('option', { selected: true })).toHaveAccessibleName(agent.displayName)
    await input.pressSequentially(agent.displayName.slice(query.length))
    await expect(input).toHaveValue(`Ask @${agent.displayName}`)
    await expect(target).toHaveAttribute('aria-selected', 'true')
    await input.press('Tab')
    await expect(input).toBeFocused()
    await expect(input).toHaveValue(`Ask @${agent.displayName} `)
    await expect(list).toHaveCount(0)
    await input.pressSequentially('please review our plan')
    const created = page.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/conversations'
    )
    await input.press('Enter')
    const result = await created
    expect(result.status()).toBe(201)
    expect(result.request().postDataJSON().data.mentions).toEqual([
      { type: 'agent', uid: agent.uid, displayName: agent.displayName }
    ])
    const detail = (await result.json()) as ConversationDetail
    id = detail.conversation.id
    await expect(page).toHaveURL(url => url.pathname === conversationRoute(id!))
    expect(detail.messages.find(message => message.authorType === 'human')?.mentions).toContainEqual(
      expect.objectContaining({ type: 'agent', uid: agent.uid })
    )
    for (let number = 1; number <= 5; number++) {
      await input.fill(`Follow-up ${number}`)
      const saved = page.waitForResponse(
        response =>
          response.request().method() === 'POST' &&
          new URL(response.url()).pathname === `/api/v2/pod/conversations/${id}/messages`
      )
      await input.press('Enter')
      expect((await saved).status()).toBe(201)
    }
    const queue = page.locator('.pod-chat-queued-strip')
    await expect(queue.locator('.pod-chat-queue-item')).toHaveCount(6)
    await expect(queue.getByRole('heading')).toHaveText(`${agent.displayName} · 待发送 (6)`)
    await expect(page.getByRole('combobox', { name: '选择 Agent', exact: true })).toHaveText(agent.displayName)
    expect((await queue.boundingBox())!.height).toBeLessThanOrEqual(176)
    expect((await input.boundingBox())!.y + (await input.boundingBox())!.height).toBeLessThanOrEqual(844)
    await expect(input).toBeEditable()
    await page.screenshot({ path: info.outputPath('chat-inline-mention-mobile-queue.png'), fullPage: true })
  } finally {
    if (id) await removeRoom(page, id)
    await context.close()
  }
})

test('IME and Escape preserve the draft while inline slash completion executes an explicit keyboard choice', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto('/')
    await selectChatAgent(page)
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    let sends = 0
    page.on('request', request => {
      if (
        request.method() === 'POST' &&
        /\/conversations(?:\/[^/]+\/messages)?$/.test(new URL(request.url()).pathname)
      ) {
        sends++
      }
    })
    await input.pressSequentially('@')
    await expect(page.getByRole('listbox', { name: '补全建议', exact: true })).toBeVisible()
    await input.press('Escape')
    await expect(page.locator('.pod-chat-composer-picker')).toHaveCount(0)
    await expect(input).toBeFocused()
    await expect(input).toHaveValue('@')
    await input.dispatchEvent('compositionstart')
    await input.dispatchEvent('keydown', { key: 'Enter', keyCode: 229, isComposing: true })
    await input.dispatchEvent('keydown', { key: 'Tab', isComposing: true })
    await input.press('Enter')
    expect(sends).toBe(0)
    await expect(page.locator('.pod-chat-composer-picker')).toHaveCount(0)
    await input.dispatchEvent('compositionend')
    await input.fill('Slash command working draft')
    const created = page.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/conversations'
    )
    await input.press('Enter')
    const detail = (await (await created).json()) as ConversationDetail
    id = detail.conversation.id
    await expect(page).toHaveURL(url => url.pathname === conversationRoute(id!))
    await input.fill('Keep this draft\n/mod')
    await expect(page.getByRole('listbox', { name: '补全建议', exact: true })).toBeVisible()
    await input.press('Escape')
    await input.pressSequentially('el')
    await expect(page.locator('.pod-chat-composer-picker')).toHaveCount(0)
    await expect(input).toHaveValue('Keep this draft\n/model')
    await input.fill('Keep this draft\n')
    await input.pressSequentially('/ren')
    const list = page.getByRole('listbox', { name: '补全建议', exact: true })
    await expect(list.getByRole('option')).toHaveCount(1)
    await expect(list.getByRole('option')).toContainText('/rename')
    await expect(input).toBeFocused()
    await input.press('Tab')
    const rename = page.locator('.pod-room-header').getByRole('textbox', { name: '重命名会话', exact: true })
    await expect(rename).toBeFocused()
    await expect(input).toHaveValue('Keep this draft\n')
    const title = `Keyboard renamed ${crypto.randomUUID()}`
    await rename.fill(title)
    const renamed = page.waitForResponse(
      response =>
        response.request().method() === 'PATCH' &&
        new URL(response.url()).pathname === `/api/v2/pod/conversations/${id}` &&
        response.request().postDataJSON().data.title === title
    )
    await rename.press('Enter')
    expect((await renamed).ok()).toBe(true)
    expect((await request<ConversationDetail>(page, `/conversations/${id}`)).conversation.title).toBe(title)
    await expect(input).toHaveValue('Keep this draft\n')
  } finally {
    if (id) await removeRoom(page, id)
    await context.close()
  }
})

test('a mention inserted at a selected range keeps the caret and removing its complete name cannot wake that Agent', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto('/')
    const created = await request<ConversationDetail>(page, '/conversations', 'POST', {
      conversationID: crypto.randomUUID(),
      messageID: crypto.randomUUID(),
      agentUIDs: [state.agent_uid, state.chat_workspace.colleague_uid],
      text: 'Independent mention editing check'
    })
    id = created.conversation.id
    await request(page, `/conversations/${id}/participants`, 'POST', {
      agentUID: state.chat_workspace.colleague_uid,
      mayIntervene: false
    })
    await page.goto(conversationRoute(id))
    await selectChatAgent(page)
    const colleague = created.conversation.agents.find(agent => agent.uid === state.chat_workspace.colleague_uid)!
    const before = (await request<ConversationDetail>(page, `/conversations/${id}`)).pendingQueues
      .find(queue => queue.agentUID === colleague.uid)!
      .inputs.map(input => input.messageID)
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await input.fill('Ask replace now')
    await input.press('Home')
    for (let position = 0; position < 4; position++) await input.press('ArrowRight')
    for (let position = 0; position < 8; position++) await input.press('Shift+ArrowRight')
    await page.getByRole('button', { name: '提及同事、Agent 或页面', exact: true }).click()
    await expect(input).toBeFocused()
    await input.pressSequentially(
      colleague.displayName.split(/\s+/).find(word => word.length > 2) || colleague.displayName
    )
    await page
      .getByRole('listbox', { name: '补全建议', exact: true })
      .getByRole('option', { name: colleague.displayName, exact: true })
      .click()
    await expect(input).toBeFocused()
    await expect(input).toHaveValue(`Ask @${colleague.displayName} now`)
    await input.pressSequentially('please ')
    await expect(input).toHaveValue(`Ask @${colleague.displayName} please now`)
    await input.fill(`Ask @${colleague.displayName}2 instead`)
    const sent = page.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/v2/pod/conversations/${id}/messages`
    )
    await input.press('Enter')
    const response = await sent
    expect(response.status()).toBe(201)
    expect(response.request().postDataJSON().data.mentions).toEqual([])
    expect(response.request().postDataJSON().data.targetAgentUID).toBe(state.agent_uid)
    const saved = (await response.json()) as ConversationDetail
    expect(
      saved.pendingQueues.find(queue => queue.agentUID === colleague.uid)!.inputs.map(input => input.messageID)
    ).toEqual(before)
    expect(
      saved.pendingQueues
        .find(queue => queue.agentUID === state.agent_uid)!
        .inputs.some(input => input.text === `Ask @${colleague.displayName}2 instead`)
    ).toBe(true)
    await input.fill('Keep this draft when my recipient leaves')
    await request(page, `/conversations/${id}/participants`, 'POST', { removeUIDs: [state.agent_uid] })
    await expect(page.locator('.pod-chat-agent-banner')).toContainText('所选 Agent 已不可用')
    await expect(input).toHaveValue('Keep this draft when my recipient leaves')
    await expect(
      page.locator('.pod-chat-composer').getByRole('button', { name: '发送消息', exact: true })
    ).toBeDisabled()
    await page.getByRole('combobox', { name: '选择 Agent', exact: true }).click()
    await expect(
      page.getByRole('option', {
        name: `${created.conversation.agents.find(agent => agent.uid === state.agent_uid)!.displayName} (不可用)`,
        exact: true
      })
    ).toBeDisabled()
    await page.getByRole('option', { name: colleague.displayName, exact: true }).click()
    await expect(page.locator('.pod-chat-agent-banner')).toHaveCount(0)
    const redirected = page.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/v2/pod/conversations/${id}/messages`
    )
    await input.press('Enter')
    const redirectedResponse = await redirected
    expect(redirectedResponse.status()).toBe(201)
    expect(redirectedResponse.request().postDataJSON().data.targetAgentUID).toBe(colleague.uid)
    expect(redirectedResponse.request().postDataJSON().data.text).toBe('Keep this draft when my recipient leaves')
  } finally {
    if (id) {
      await request(page, `/conversations/${id}/participants`, 'POST', { addUIDs: [state.agent_uid] })
      await removeRoom(page, id)
    }
    await context.close()
  }
})

test('taking back one Agent input restores a colleague mention and references without replaying another Agent', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto('/')
    const { agents } = await request<{ agents: PodAgent[] }>(page, '/agents')
    const agent = agents.find(item => item.uid === state.agent_uid)!
    const colleague = agents.find(item => item.uid === state.chat_workspace.colleague_uid)!
    const created = await request<ConversationDetail>(page, '/conversations', 'POST', {
      conversationID: crypto.randomUUID(),
      messageID: crypto.randomUUID(),
      agentUIDs: [agent.uid, colleague.uid],
      targetAgentUID: agent.uid,
      text: 'Begin a shared review',
      deliveryMode: 'queue'
    })
    id = created.conversation.id
    for (const uid of [agent.uid, colleague.uid]) {
      await request(page, `/conversations/${id}/queue`, 'POST', {
        action: 'stop',
        agentUID: uid,
        commandID: crypto.randomUUID()
      })
    }
    const messageID = crypto.randomUUID()
    const text = `@Browser member @${colleague.displayName} Review this shared reference.`
    await request<ConversationDetail>(page, `/conversations/${id}/messages`, 'POST', {
      messageID,
      text,
      targetAgentUID: agent.uid,
      deliveryMode: 'queue',
      mentions: [
        { type: 'human', uid: state.member.uid, displayName: 'Browser member' },
        { type: 'agent', uid: colleague.uid, displayName: colleague.displayName }
      ],
      links: [{ kind: 'page', id: state.report_id }]
    })
    await page.goto(conversationRoute(id))
    const queue = page
      .locator('.pod-chat-queue')
      .filter({ has: page.getByRole('heading', { name: new RegExp(`^${agent.displayName} ·`) }) })
    const row = queue.locator('.pod-chat-queue-item').filter({ hasText: text })
    await row.getByRole('button', { name: '撤回到草稿', exact: true }).click()
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await expect(input).toHaveValue(text)
    await expect(page.locator('.pod-chat-draft-page')).toContainText('Browser report')
    const sent = page.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/v2/pod/conversations/${id}/messages`
    )
    await input.press('Enter')
    const result = await sent
    expect(result.status()).toBe(201)
    expect(result.request().postDataJSON().data.mentions).toEqual([
      { type: 'human', uid: state.member.uid, displayName: 'Browser member' }
    ])
    const saved = (await result.json()) as ConversationDetail
    expect(
      saved.pendingQueues.find(slot => slot.agentUID === colleague.uid)!.inputs.map(item => item.messageID)
    ).toEqual([messageID])
    expect(saved.pendingQueues.find(slot => slot.agentUID === agent.uid)!.inputs.map(item => item.messageID)).toEqual([
      ...created.pendingQueues.find(slot => slot.agentUID === agent.uid)!.inputs.map(item => item.messageID),
      result.request().postDataJSON().data.messageID
    ])
    await expect(page.locator('.pod-chat-invite-notice')).toContainText('Browser member')
  } finally {
    if (id) await removeRoom(page, id)
    await context.close()
  }
})
