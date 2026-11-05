import { readFileSync } from 'node:fs'
import { expect, test } from '@playwright/test'
import { request, state } from './fixtures'
import { conversationRoute, pageRoute } from './routes'
import type { ConversationDetail } from '../../pod/api'

test('room actions cancel rename, copy its link, and export the full paged transcript', async ({ browser }, info) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1440, height: 960 } })
  await context.addCookies(state.owner.cookies)
  await context.grantPermissions(['clipboard-read', 'clipboard-write'])
  const page = await context.newPage()
  const id = state.history_conversation_id
  try {
    await page.goto(conversationRoute(id))
    const header = page.locator('.pod-room-header')
    const original = (await request<ConversationDetail>(page, `/conversations/${id}`)).conversation.title
    await page.getByRole('tab', { name: '对话', exact: true }).click()
    const row = page.locator('.pod-chat-row').filter({ has: page.locator(`a[href="${conversationRoute(id)}"]`) })
    await row.click({ button: 'right' })
    await page.getByRole('menuitem', { name: '免打扰', exact: true }).click()
    await expect
      .poll(async () => (await request<ConversationDetail>(page, `/conversations/${id}`)).conversation.viewer.muted)
      .toBe(true)
    await row.click({ button: 'right' })
    await page.getByRole('menuitem', { name: '取消免打扰', exact: true }).click()
    await expect
      .poll(async () => (await request<ConversationDetail>(page, `/conversations/${id}`)).conversation.viewer.muted)
      .toBe(false)
    let writes = 0
    page.on('request', req => {
      if (req.method() === 'PATCH' && new URL(req.url()).pathname === `/api/v2/pod/conversations/${id}`) writes++
    })
    await row.click({ button: 'right' })
    await page.getByRole('menuitem', { name: '重命名会话', exact: true }).click()
    const sidebarRename = page
      .getByRole('tabpanel', { name: '对话', exact: true })
      .getByRole('textbox', { name: '重命名会话', exact: true })
    await expect(sidebarRename).toBeFocused()
    await sidebarRename.fill('Cancelled sidebar title')
    await sidebarRename.press('Escape')
    await expect(row).toContainText(original)
    expect(writes).toBe(0)
    await header.locator('.pod-chat-header-title').click()
    const title = header.getByRole('textbox', { name: '重命名会话', exact: true })
    await title.fill('Cancelled title')
    await title.press('Escape')
    await expect(header.locator('.pod-chat-header-title')).toHaveText(original)
    expect(writes).toBe(0)
    await header.getByRole('button', { name: '更多操作', exact: true }).click()
    await page.getByRole('menuitem', { name: '复制链接', exact: true }).click()
    await expect
      .poll(() => page.evaluate(() => navigator.clipboard.readText()))
      .toBe(new URL(conversationRoute(id), state.base_url).href)
    const download = page.waitForEvent('download')
    await header.getByRole('button', { name: '更多操作', exact: true }).click()
    await page.getByRole('menuitem', { name: '导出 Markdown 纪要', exact: true }).click()
    const exported = await download
    const path = info.outputPath('full-chat.md')
    await exported.saveAs(path)
    const text = readFileSync(path, 'utf8')
    expect(text).toContain('History item 0001')
    expect(text).toContain('History item 1006')
    expect([...text.matchAll(/^History item (\d{4})$/gm)].map(match => match[1])).toEqual(
      Array.from({ length: 1006 }, (_, index) => String(index + 1).padStart(4, '0'))
    )
    expect(writes).toBe(0)
  } finally {
    await context.close()
  }
})

test('the summary opens a real attachment preview and returns keyboard focus to its toggle', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 390, height: 844 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(conversationRoute(state.conversation_id))
    await page.locator('.pod-room-header').getByRole('button', { name: '会话摘要', exact: true }).click()
    const summary = page.getByRole('complementary', { name: '会话摘要', exact: true })
    const preview = summary.getByRole('button', { name: /^预览 / }).first()
    await expect(preview).toBeVisible()
    await preview.click()
    const dialog = page.getByRole('dialog')
    await expect(dialog).toBeVisible()
    await expect(dialog.getByRole('link', { name: '下载原文件', exact: true })).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(dialog).toBeHidden()
    await expect(preview).toBeFocused()
    await page.keyboard.press('Escape')
    await expect(summary).toBeHidden()
    await expect(page.locator('.pod-room-header').getByRole('button', { name: '会话摘要', exact: true })).toBeFocused()
  } finally {
    await context.close()
  }
})

test('a group message renders its quotation and structured Page reference without offering message-to-page save', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let conversationID: string | undefined
  try {
    await page.goto('/')
    const sourceID = crypto.randomUUID()
    const quote = 'Keep the original observation with the saved conclusion.'
    const room = await request<ConversationDetail>(page, '/conversations', 'POST', {
      conversationID: crypto.randomUUID(),
      messageID: sourceID,
      agentUID: state.agent_uid,
      roomMode: 'group',
      text: quote,
      deliveryMode: 'queue'
    })
    conversationID = room.conversation.id
    await request(page, `/conversations/${conversationID}/participants`, 'POST', { addUIDs: [state.member.uid] })
    const shared = await request<ConversationDetail>(page, `/conversations/${conversationID}`)
    expect(shared.conversation.roomMode).toBe('group')
    expect(shared.conversation.participants.filter(member => member.type === 'human')).toHaveLength(2)
    const messageID = crypto.randomUUID()
    const text = 'Review @Browser report before deciding.'
    await request(page, `/conversations/${conversationID}/messages`, 'POST', {
      messageID,
      text,
      deliveryMode: 'queue',
      links: [
        { kind: 'page', id: state.report_id },
        { kind: 'message', id: sourceID, quote }
      ]
    })
    await page.goto(conversationRoute(conversationID))
    const message = page.locator(`[data-chat-message-id="${messageID}"]`)
    await expect(message.locator('.pod-chat-quoted-message')).toHaveText(quote)
    const reportLink = message.getByRole('link', { name: 'Browser report', exact: true })
    await expect(reportLink).toBeVisible()
    await message.hover()
    await expect(message.getByRole('button', { name: '保存为页面', exact: true })).toHaveCount(0)
    await reportLink.click()
    await expect(page).toHaveURL(state.base_url + pageRoute(state.report_id))
  } finally {
    if (conversationID) {
      let current = await request<ConversationDetail>(page, `/conversations/${conversationID}`)
      for (const queue of current.pendingQueues) {
        for (const input of queue.inputs) {
          current = await request(page, `/conversations/${conversationID}/queue`, 'POST', {
            action: 'retract',
            agentUID: queue.agentUID,
            messageID: input.messageID,
            expectedVersion: current.pendingQueues.find(slot => slot.agentUID === queue.agentUID)!.queueVersion
          })
        }
      }
      await request(page, `/conversations/${conversationID}`, 'DELETE')
    }
    await context.close()
  }
})

test('a quotation selected during a real send remains in the draft after acceptance', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const started = Promise.withResolvers<void>()
  const release = Promise.withResolvers<void>()
  try {
    await page.goto('/')
    const sourceID = crypto.randomUUID()
    const room = await request<ConversationDetail>(page, '/conversations', 'POST', {
      conversationID: crypto.randomUUID(),
      messageID: sourceID,
      agentUID: state.agent_uid,
      roomMode: 'group',
      text: 'An earlier observation to quote.',
      deliveryMode: 'queue'
    })
    const id = room.conversation.id
    await request(page, `/conversations/${id}/participants`, 'POST', { addUIDs: [state.member.uid] })
    const shared = await request<ConversationDetail>(page, `/conversations/${id}`)
    expect(shared.conversation.roomMode).toBe('group')
    expect(shared.conversation.participants.filter(member => member.type === 'human')).toHaveLength(2)
    await page.goto(conversationRoute(id))
    const composer = page.locator('.pod-chat-composer')
    const input = composer.getByRole('textbox', { name: '消息', exact: true })
    const path = `/api/v2/pod/conversations/${id}/messages`
    await page.route(`**${path}`, async route => {
      started.resolve()
      await release.promise
      await route.continue()
    })
    await input.fill('A message awaiting acceptance.')
    const accepted = page.waitForResponse(
      response => response.request().method() === 'POST' && new URL(response.url()).pathname === path
    )
    await input.press('Enter')
    await started.promise
    await expect(input).toBeEditable()
    await expect(input).toBeFocused()
    const source = page.locator(`[data-chat-message-id="${sourceID}"]`)
    await source.hover()
    await source.getByRole('button', { name: '引用回复', exact: true }).click()
    release.resolve()
    const response = await accepted
    expect(response.status()).toBe(201)
    const persisted = (await response.json()) as ConversationDetail
    const sent = persisted.messages.findLast(message => message.authorType === 'human')!
    expect(sent.text).toBe('A message awaiting acceptance.')
    expect(sent.links).toEqual([])
    await expect(input).toBeEditable()
    await expect(input).toBeFocused()
    await expect(composer.locator('.pod-chat-quoted blockquote')).toHaveText('An earlier observation to quote.')
    await expect(input).toHaveValue('A message awaiting acceptance.')
  } finally {
    release.resolve()
    await context.close()
  }
})
