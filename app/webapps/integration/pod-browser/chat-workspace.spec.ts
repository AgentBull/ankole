import { expect, test, type Browser, type Page } from '@playwright/test'
import { state, request, requestResponse } from './fixtures'
import { conversationRoute, pageRoute } from './routes'
import type { ConversationDetail } from '../../pod/api'
import { writeFileSync } from 'node:fs'

type Material = {
  page_id: string
  conversation_id: string
  first_reply_id: string
  second_reply_id: string
  colleague_uid: string
  clarify_conversation_id: string
  clarify_message_id: string
  reference_decision_conversation_id: string
  interleaved_conversation_id: string
  interleaved_question_id: string
  interleaved_reply_id: string
  queue_conversation_id: string
  queue_message_ids: string[]
  execution_conversation_id: string
  linked_job_id: string
  live_conversation_id: string
  live_trigger_path: string
  live_agent_uids: string[]
}
const material = (state as typeof state & { chat_workspace?: Material }).chat_workspace
test.skip(!material, 'Start the dedicated fixture with POD_BROWSER_CHAT_WORKSPACE=true')
test.use({ actionTimeout: 15000 })

async function ownerPage(browser: Browser, width = 1440) {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width, height: 960 } })
  await context.addCookies(state.owner.cookies)
  return { context, page: await context.newPage() }
}

async function detail(page: Page, id = material!.conversation_id) {
  return request<ConversationDetail>(page, `/conversations/${id}`)
}

for (const width of [1440, 390]) {
  test(`the ${width}px chat home puts the hero composer beside the greeting and fills a useful starter`, async ({
    browser
  }, info) => {
    const { context, page } = await ownerPage(browser, width)
    try {
      await page.goto('/')
      const home = page.locator('.pod-chat-home')
      const greeting = home.getByRole('heading', { level: 1 })
      const composer = home.locator('.pod-chat-composer')
      await expect(greeting).toContainText('Browser owner')
      await expect(composer).toBeVisible()
      await expect(home.locator('.pod-chat-starters button')).toHaveCount(4)
      const input = composer.getByRole('textbox', { name: '消息', exact: true })
      const before = (await composer.boundingBox())!
      const title = (await greeting.boundingBox())!
      expect(before.y).toBeGreaterThan(title.y)
      expect(before.y - title.y - title.height).toBeLessThan(160)
      expect(before.width).toBeLessThanOrEqual(Math.min(820, width))
      expect(before.y).toBeLessThan(960 * 0.7)
      await home.getByRole('button', { name: '调研并整理空间文档', exact: true }).click()
      await expect(input).toHaveValue('调研并整理空间文档')
      await expect(home.locator('.pod-chat-starters button')).toHaveCount(0)
      await input.fill('Keep my detailed request instead of replacing it with a starter')
      await expect(home.locator('.pod-chat-starters button')).toHaveCount(0)
      await expect(input).toHaveValue('Keep my detailed request instead of replacing it with a starter')
      await input.fill('')
      await expect(home.locator('.pod-chat-starters button')).toHaveCount(4)
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
      for (const recent of await home.locator('.pod-chat-recent-row').all()) {
        const bounds = (await recent.boundingBox())!
        expect(bounds.x + bounds.width).toBeLessThanOrEqual(width)
        await expect(recent.locator('.pod-chat-recent-copy > span').first()).toHaveCSS('text-overflow', 'ellipsis')
      }
      await page.screenshot({ path: info.outputPath(`chat-home-${width}.png`), fullPage: true })
    } finally {
      await context.close()
    }
  })
}

test('room navigation persists pinning, text search, one inline rename and an invited colleague', async ({
  browser
}, info) => {
  const { context, page } = await ownerPage(browser)
  const id = material!.conversation_id
  try {
    await page.goto(conversationRoute(id))
    const header = page.locator('.pod-room-header')
    await expect(header).toBeVisible()
    const original = (await detail(page)).conversation.title
    const row = page.locator('.pod-chat-row').filter({ has: page.locator(`a[href="${conversationRoute(id)}"]`) })
    await row.getByRole('button', { name: /的操作$/ }).click()
    await page.getByRole('menuitem', { name: '置顶', exact: true }).click()
    await expect.poll(async () => (await detail(page)).conversation.viewer.pinned).toBe(true)
    await expect(
      page
        .locator('.pod-chat-sidebar > section')
        .filter({ has: row })
        .getByRole('heading', { name: '置顶', exact: true })
    ).toBeVisible()
    await page.getByRole('button', { name: '搜索或跳转', exact: true }).click()
    const command = page.getByRole('dialog', { name: '搜索或跳转', exact: true })
    await command.getByRole('combobox', { name: '搜索或跳转', exact: true }).fill('verified evidence')
    await expect(command.locator(`[cmdk-item][data-value="chat:${id}"]`)).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(command).toHaveCount(0)
    let renames = 0
    page.on('request', incoming => {
      if (
        incoming.method() === 'PATCH' &&
        new URL(incoming.url()).pathname === `/api/v2/pod/conversations/${id}` &&
        typeof incoming.postDataJSON()?.data?.title === 'string'
      ) {
        renames++
      }
    })
    await header.locator('.pod-chat-header-title').click()
    const title = header.getByRole('textbox', { name: '重命名会话', exact: true })
    await title.fill('Workspace UX review')
    await title.press('Enter')
    await expect(header.locator('.pod-chat-header-title')).toHaveText('Workspace UX review')
    await expect.poll(async () => (await detail(page)).conversation.title).toBe('Workspace UX review')
    expect(renames).toBe(1)
    await header.getByRole('button', { name: '邀请协作', exact: true }).last().click()
    const invite = page.getByRole('dialog', { name: '邀请协作', exact: true })
    await invite.getByRole('option', { name: /Browser member/ }).click()
    await invite.getByRole('button', { name: /^邀请（/ }).click()
    await expect
      .poll(async () => (await detail(page)).conversation.participants.some(person => person.uid === state.member.uid))
      .toBe(true)
    await expect(invite.locator('.pod-chat-members')).toContainText('Browser member')
    await invite.getByRole('switch', { name: /允许 .*Browser planning Agent.*主动插话/ }).click()
    await expect(invite.getByRole('switch', { name: /允许 .*Browser planning Agent.*主动插话/ })).toBeChecked()
    await expect
      .poll(
        async () =>
          (await detail(page)).conversation.agents.find(agent => agent.uid === material!.colleague_uid)?.mayIntervene
      )
      .toBe(true)
    await page.screenshot({ path: info.outputPath('chat-invite.png') })
    await page.keyboard.press('Escape')
    await page.reload()
    await expect(header.locator('.pod-chat-header-title')).toHaveText('Workspace UX review')
    await request(page, `/conversations/${id}`, 'PATCH', { title: original, pinned: false })
  } finally {
    await context.close()
  }
})

test('a recorded turn restores its rich answer and complete work after refresh, with find, summary, quote and save', async ({
  browser
}, info) => {
  const { context, page } = await ownerPage(browser)
  await context.grantPermissions(['clipboard-read', 'clipboard-write'])
  try {
    await page.goto(conversationRoute(material!.conversation_id))
    const message = page.locator(`[data-chat-message-id="${material!.first_reply_id}"]`)
    await expect(message.getByRole('heading', { name: 'Workspace findings' })).toBeVisible()
    await expect(message.locator('.pod-chat-message-identity')).toContainText('Browser content Agent')
    const rail = page.getByRole('navigation', { name: '对话轮次', exact: true })
    await expect(rail.getByRole('button')).toHaveCount(4)
    await rail.getByRole('button').first().hover()
    await expect(rail.locator('.pod-chat-turn-preview')).toContainText('Review the workspace evidence.')
    await expect(rail.locator('.pod-chat-turn-preview')).toContainText('Workspace findings')
    await rail.getByRole('button').first().click()
    await expect(
      page.locator('.pod-chat-history-scroll').getByText('Review the workspace evidence.', { exact: true }).first()
    ).toBeInViewport()
    await expect(
      page.locator(`[data-chat-message-id="${material!.second_reply_id}"] .pod-chat-message-identity`)
    ).toContainText('Browser planning Agent')
    const work = message.locator('.pod-chat-work')
    await expect(work).not.toHaveAttribute('open', '')
    await work.locator(':scope > summary').click()
    await expect(message.getByText('Read page Workspace reference', { exact: true })).toBeVisible()
    await expect(message.getByText('Queried Tasks (18 rows)', { exact: true })).toBeVisible()
    await message.getByText('Queried Tasks (18 rows)', { exact: true }).click()
    await expect(message.locator('.pod-chat-tool-detail pre').last()).toContainText('"row_count": 18')
    await expect(message.locator('table')).toContainText('Tasks')
    await expect(message.locator('.katex')).toBeVisible()
    await expect(message.locator('.shiki')).toBeVisible()
    await message.getByRole('button', { name: '自动换行', exact: true }).click()
    await expect(message.getByRole('button', { name: '自动换行', exact: true })).toHaveAttribute('aria-pressed', 'true')
    await message.getByRole('button', { name: '复制代码', exact: true }).click()
    await expect
      .poll(() => page.evaluate(() => navigator.clipboard.readText()))
      .toBe('const total = 42\nconsole.log(total)')
    await message.screenshot({ path: info.outputPath('chat-work-expanded.png') })
    await page.keyboard.press('Control+f')
    const find = page.getByRole('textbox', { name: '在会话内查找', exact: true })
    await find.fill('workspace')
    await expect.poll(() => page.evaluate(() => CSS.highlights.get('pod-chat-find')?.size ?? 0)).toBeGreaterThan(2)
    const match = await page.locator('.pod-chat-find [aria-live]').textContent()
    await find.press('Enter')
    await expect(page.locator('.pod-chat-find [aria-live]')).not.toHaveText(match!)
    await find.press('Escape')
    expect(await page.evaluate(() => CSS.highlights.has('pod-chat-find'))).toBe(false)
    await page.keyboard.press('Control+i')
    const summary = page.getByRole('complementary', { name: '会话摘要', exact: true })
    await expect(summary.getByRole('heading', { name: 'AI 同事', exact: true })).toBeVisible()
    await expect(summary).toContainText('Browser planning Agent')
    await expect(summary.getByRole('link', { name: 'Chat workspace reference', exact: true })).toBeVisible()
    await summary.getByRole('button', { name: '关闭', exact: true }).focus()
    await page.keyboard.press('Escape')
    await expect(summary).toBeHidden()
    await expect(page.getByRole('button', { name: '会话摘要', exact: true })).toBeFocused()
    await page.keyboard.press('Control+i')
    await expect(summary).toBeVisible()
    await page.keyboard.press('Control+i')
    await expect(summary).toBeHidden()
    await message.hover()
    await message.getByRole('button', { name: '引用回复', exact: true }).click()
    await expect(page.locator('.pod-chat-quoted')).toContainText('Workspace findings')
    const selected = await message.locator('.shiki code').evaluate(element => {
      const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT)
      const first = walker.nextNode()!
      const range = document.createRange()
      range.setStart(first, 0)
      let remaining = element.textContent!.indexOf('\n') + 1
      let node: Node | null = first
      while (node) {
        const length = node.textContent!.length
        if (remaining <= length) {
          range.setEnd(node, remaining)
          break
        }
        remaining -= length
        node = walker.nextNode()
      }
      window.getSelection()!.removeAllRanges()
      window.getSelection()!.addRange(range)
      return range.toString()
    })
    expect(selected).toBe('const total = 42\n')
    await message.getByRole('button', { name: '引用回复', exact: true }).click()
    expect(await page.locator('.pod-chat-quoted blockquote').textContent()).toBe(selected)
    await page.reload()
    await expect(work).not.toHaveAttribute('open', '')
    await work.locator(':scope > summary').click()
    await expect(message.getByText('Read page Workspace reference', { exact: true })).toBeVisible()
    await expect(message.getByText('Queried Tasks (18 rows)', { exact: true })).toBeVisible()
    await message.hover()
    await message.getByRole('button', { name: '保存为页面', exact: true }).click()
    const save = page.getByRole('dialog', { name: '保存对话成果', exact: true })
    await save.getByRole('textbox', { name: '页面标题', exact: true }).fill('Workspace saved result')
    await save.getByRole('button', { name: '保存', exact: true }).click()
    await expect(save).toBeHidden()
    await expect(page).toHaveURL(url => url.pathname === conversationRoute(material!.conversation_id))
    await expect(message.locator('.pod-chat-saved-page')).toContainText('Workspace saved result')
    await page.reload()
    await expect(message.locator('.pod-chat-saved-page')).toContainText('Workspace saved result')
    await page.screenshot({ path: info.outputPath('chat-turn-restored.png') })
  } finally {
    await context.close()
  }
})

test('page chat resizes within its limits and switches real shared access with immediate revocation', async ({
  browser
}, info) => {
  const { context, page } = await ownerPage(browser)
  const viewer = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1440, height: 960 } })
  await viewer.addCookies(state.viewer.cookies)
  const other = await viewer.newPage()
  const id = material!.conversation_id
  try {
    await page.goto(pageRoute(material!.page_id, id))
    const panel = page.getByRole('complementary', { name: '页面对话', exact: true })
    await expect(panel).toBeVisible()
    const resize = panel.getByRole('separator', { name: '调整页面会话宽度', exact: true })
    await expect(resize).toHaveAttribute('aria-valuenow', '400')
    await resize.focus()
    for (let i = 0; i < 10; i++) await resize.press('ArrowLeft')
    await expect(resize).toHaveAttribute('aria-valuenow', '480')
    for (let i = 0; i < 15; i++) await resize.press('ArrowRight')
    await expect(resize).toHaveAttribute('aria-valuenow', '360')
    const bounds = (await resize.boundingBox())!
    await page.mouse.move(bounds.x + bounds.width / 2, bounds.y + 100)
    await page.mouse.down()
    await page.mouse.move(bounds.x + bounds.width / 2 - 64, bounds.y + 100, { steps: 8 })
    await page.mouse.up()
    await expect(resize).toHaveAttribute('aria-valuenow', '424')
    await panel.getByRole('combobox', { name: '会话可见范围', exact: true }).click()
    await page.getByRole('option', { name: '跟本页协作者共享', exact: true }).click()
    await expect.poll(async () => (await detail(page)).conversation.accessScope).toBe('anchor_page')
    await other.goto(conversationRoute(id))
    await expect(other.getByRole('heading', { name: 'Workspace findings' })).toBeVisible()
    await other.getByRole('textbox', { name: '消息', exact: true }).fill('My unsent review notes')
    await panel.getByRole('combobox', { name: '会话可见范围', exact: true }).click()
    await page.getByRole('option', { name: '仅受邀成员可见', exact: true }).click()
    await expect.poll(async () => (await detail(page)).conversation.accessScope).toBe('participants')
    await expect(other.getByRole('alert')).toHaveText('此对话不存在，或没有访问权限。')
    await expect(other.getByRole('textbox', { name: '本地内容 1', exact: true })).toHaveValue('My unsent review notes')
    await expect(other.getByRole('textbox', { name: '消息', exact: true })).toHaveCount(0)
    await expect(other.getByText('Workspace findings', { exact: true })).toBeHidden()
    await panel.screenshot({ path: info.outputPath('chat-page-panel-424.png') })
    await panel.getByRole('button', { name: '在对话页面打开', exact: true }).click()
    await expect(page).toHaveURL(url => url.pathname === conversationRoute(id))
    await expect(page.getByRole('heading', { name: 'Workspace findings' })).toBeVisible()
    await page.screenshot({ path: info.outputPath('chat-page-context.png') })
  } finally {
    await context.close()
    await viewer.close()
  }
})

test('two teammates answer one real decision concurrently and see the same durable winner', async ({
  browser
}, info) => {
  const { context, page } = await ownerPage(browser)
  const teammate = await browser.newContext({ baseURL: state.base_url })
  await teammate.addCookies(state.member.cookies)
  const other = await teammate.newPage()
  const id = material!.clarify_conversation_id
  try {
    await Promise.all([page.goto(conversationRoute(id)), other.goto(conversationRoute(id))])
    const card = page.locator('.pod-chat-choice-card'),
      otherCard = other.locator('.pod-chat-choice-card')
    await expect(card).toHaveAttribute('data-state', 'pending')
    await expect(otherCard).toHaveAttribute('data-state', 'pending')
    for (const target of [page, other]) {
      await target.evaluate(() => {
        Reflect.set(window, '__choiceAlertCount', 0)
        new MutationObserver(changes => {
          for (const change of changes) {
            for (const node of change.addedNodes) {
              if (node instanceof Element && (node.matches('[role="alert"]') || node.querySelector('[role="alert"]'))) {
                Reflect.set(window, '__choiceAlertCount', Reflect.get(window, '__choiceAlertCount') + 1)
              }
            }
          }
        }).observe(document.querySelector('.pod-chat-choice-card')!, { childList: true, subtree: true })
      })
    }
    let ready = 0
    let release!: () => void
    const gate = new Promise<void>(resolve => {
      release = resolve
    })
    // Both real browser requests reach the production adapter after both people act.
    for (const target of [page, other]) {
      await target.route('**/interactions/*/answer', async route => {
        if (++ready === 2) release()
        await gate
        await route.continue()
      })
    }
    const response = (target: Page) =>
      target.waitForResponse(
        incoming => incoming.request().method() === 'POST' && new URL(incoming.url()).pathname.endsWith('/answer')
      )
    const answered = Promise.all([response(page), response(other)])
    await page.locator('.pod-chat-history-scroll').focus()
    await Promise.all([
      page.keyboard.press('1'),
      otherCard.getByRole('button', { name: /Keep a private draft/ }).click()
    ])
    const responses = await answered
    expect(responses.map(incoming => incoming.status()).sort()).toEqual([201, 409])
    await expect(card).toHaveAttribute('data-state', 'answered')
    await expect(otherCard).toHaveAttribute('data-state', 'answered')
    await expect(card.getByRole('alert')).toHaveCount(0)
    await expect(otherCard.getByRole('alert')).toHaveCount(0)
    for (const target of [page, other]) {
      expect(await target.evaluate(() => Reflect.get(window, '__choiceAlertCount'))).toBe(0)
    }
    const winner = responses[0]!.status() === 201 ? 'Browser owner' : 'Browser member'
    await expect(card.locator('.pod-chat-choice-outcome')).toContainText(winner)
    await expect(otherCard.locator('.pod-chat-choice-outcome')).toContainText(winner)
    const latest = await detail(page, id)
    expect(latest.pendingInteractions).toHaveLength(0)
    const answerMessage = latest.messages.findLast(message => message.authorType === 'human')!
    expect(answerMessage.authorUID).toBe(responses[0]!.status() === 201 ? state.owner.uid : state.member.uid)
    await Promise.all([page.reload(), other.reload()])
    await expect(card).toHaveAttribute('data-state', 'answered')
    await expect(otherCard).toHaveAttribute('data-state', 'answered')
    for (const choice of await card.getByRole('button').all()) await expect(choice).toBeDisabled()
    await page.screenshot({ path: info.outputPath('chat-decision-winner.png') })
  } finally {
    await context.close()
    await teammate.close()
  }
})

test('queued inputs retain real per-Agent order through drag, steer, edit and retract', async ({ browser }, info) => {
  const { context, page } = await ownerPage(browser)
  const id = material!.queue_conversation_id
  try {
    await page.goto(conversationRoute(id))
    const queue = page.locator('.pod-chat-queued-strip')
    const row = (text: string) =>
      queue.locator('.pod-chat-queue-item').filter({ has: page.getByText(text, { exact: true }) })
    await expect(queue.locator('.pod-chat-queue-item')).toHaveCount(3)
    const gamma = row('Queue gamma')
    const target = (await gamma.boundingBox())!
    await row('Queue alpha')
      .locator('.pod-chat-drag-handle')
      .dragTo(gamma, { targetPosition: { x: 30, y: target.height - 2 } })
    await expect
      .poll(async () =>
        (await detail(page, id)).pendingQueues
          .find(item => item.agentUID === state.agent_uid)
          ?.inputs.map(input => input.messageID)
      )
      .toEqual([material!.queue_message_ids[1], material!.queue_message_ids[2], material!.queue_message_ids[0]])
    await row('Queue beta').getByRole('button', { name: '立即并入当前轮次', exact: true }).click()
    await expect
      .poll(
        async () =>
          (await detail(page, id)).pendingQueues
            .find(queue => queue.agentUID === state.agent_uid)!
            .inputs.find(input => input.messageID === material!.queue_message_ids[1])?.deliveryMode
      )
      .toBe('steer')
    await gamma.getByRole('button', { name: '编辑待发送消息', exact: true }).click()
    const input = page.locator('.pod-chat-composer').getByRole('textbox', { name: '消息', exact: true })
    await expect(input).toHaveValue('Queue gamma')
    await expect(row('Queue alpha').getByRole('button', { name: '编辑待发送消息', exact: true })).toBeDisabled()
    await expect(row('Queue beta').getByRole('button', { name: '撤回到草稿', exact: true })).toBeDisabled()
    await expect(row('Queue alpha').getByRole('button', { name: '立即并入当前轮次', exact: true })).toBeEnabled()
    await input.fill('Queue gamma revised')
    await page.locator('.pod-chat-composer').getByRole('button', { name: '保存消息', exact: true }).click()
    await expect(row('Queue gamma revised')).toBeVisible()
    await input.fill('Unsent additional instruction')
    const uploaded = page.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/attachments'
    )
    await row('Queue beta').getByRole('button', { name: '撤回到草稿', exact: true }).click()
    await expect(row('Queue beta')).toHaveCount(0)
    expect(
      (await detail(page, id)).pendingQueues
        .find(queue => queue.agentUID === state.agent_uid)!
        .inputs.some(queued => queued.messageID === material!.queue_message_ids[1])
    ).toBe(false)
    await expect(input).toHaveValue('Unsent additional instruction\n\nQueue beta')
    const attachment = page.locator('.pod-chat-composer').getByRole('list', { name: '附件', exact: true })
    await expect(attachment.getByText('workspace-queue-note.txt', { exact: true })).toBeVisible()
    await expect(attachment.getByRole('status')).toHaveText('已就绪')
    const restoredUpload = await uploaded
    expect(restoredUpload.ok()).toBe(true)
    expect((await restoredUpload.json()).name).toBe('workspace-queue-note.txt')
    await attachment.getByRole('button', { name: /预览 .*workspace-queue-note.txt/ }).click()
    const preview = page.getByRole('dialog', { name: 'workspace-queue-note.txt', exact: true })
    await expect(preview.locator('pre')).toHaveText('Queue attachment evidence.\n')
    await page.keyboard.press('Escape')
    await expect(preview).toBeHidden()
    await page.screenshot({ path: info.outputPath('chat-queue.png') })
    expect((await requestResponse(page, `/conversations/${id}`)).status).toBe(200)
  } finally {
    await context.close()
  }
})

test('a long recorded conversation keeps every loaded turn reachable from the rail keyboard', async ({
  browser
}, info) => {
  const { context, page } = await ownerPage(browser)
  try {
    await page.goto(conversationRoute(state.history_conversation_id))
    const rail = page.getByRole('navigation', { name: '对话轮次', exact: true })
    await expect(rail).toBeVisible()
    await expect.poll(() => rail.getByRole('button').count()).toBeGreaterThan(3)
    const ticks = rail.locator('.pod-chat-turn-ticks')
    expect(await ticks.evaluate(element => element.scrollHeight > element.clientHeight)).toBe(true)
    await rail.getByRole('button').first().focus()
    await page.keyboard.press('End')
    const last = rail.getByRole('button').last()
    await expect(last).toBeFocused()
    await expect(last).toBeInViewport()
    await page.keyboard.press('Enter')
    await expect(
      page.locator('.pod-chat-history-scroll').getByText('History item 1006', { exact: true })
    ).toBeInViewport()
    await page.screenshot({ path: info.outputPath('chat-long-history-rail.png') })
  } finally {
    await context.close()
  }
})

test('a group queue edit recovers the selected Agent version while preserving its local draft and the other queue', async ({
  browser
}, info) => {
  const { context, page } = await ownerPage(browser)
  const colleague = material!.colleague_uid
  try {
    await page.goto('/')
    await expect(page.locator('.pod-chat-home')).toBeVisible()
    const created = await request<ConversationDetail>(page, '/conversations', 'POST', {
      conversationID: crypto.randomUUID(),
      messageID: crypto.randomUUID(),
      agentUIDs: [state.agent_uid, colleague],
      text: `Independent group queue recovery ${crypto.randomUUID()}`
    })
    const id = created.conversation.id
    const slot = (data: ConversationDetail, uid: string) => data.pendingQueues.find(queue => queue.agentUID === uid)!
    for (const agentUID of [state.agent_uid, colleague]) {
      await request(page, `/conversations/${id}/queue`, 'POST', {
        action: 'stop',
        agentUID,
        commandID: crypto.randomUUID()
      })
    }
    const add = (text: string, targetAgentUID: string) =>
      request<ConversationDetail>(page, `/conversations/${id}/messages`, 'POST', {
        messageID: crypto.randomUUID(),
        text,
        targetAgentUID,
        deliveryMode: 'queue'
      })
    await add('Agent A unchanged request one', state.agent_uid)
    await add('Agent A unchanged request two', state.agent_uid)
    const baseline = await add('Agent B original request', colleague)
    for (const queue of baseline.pendingQueues) {
      expect(queue.paused).toBe(true)
      expect(queue.workStatus.state).toBe('idle')
    }
    const agentA = slot(baseline, state.agent_uid)
    const target = slot(baseline, colleague).inputs.find(input => input.text === 'Agent B original request')!
    expect(slot(baseline, colleague).queueVersion).not.toBe(slot(baseline, state.agent_uid).queueVersion)
    await page.goto(conversationRoute(id))
    await expect(page.locator('.pod-chat-queued-strip')).toContainText('待发送队列已暂停')
    await expect(page.getByText('正在回复…', { exact: true })).toHaveCount(0)
    const composer = page.locator('.pod-chat-composer')
    const input = composer.getByRole('textbox', { name: '消息', exact: true })
    const row = (text: string) =>
      page.locator('.pod-chat-queue-item').filter({ has: page.getByText(text, { exact: true }) })
    const save = async (expectedStatus: number, expectedVersion: string) => {
      const saved = page.waitForResponse(
        response =>
          new URL(response.url()).pathname === `/api/v2/pod/conversations/${id}/queue` &&
          response.request().method() === 'POST' &&
          response.request().postDataJSON().data.action === 'edit'
      )
      await composer.getByRole('button', { name: '保存消息', exact: true }).click()
      const response = await saved
      expect(response.status()).toBe(expectedStatus)
      expect(response.request().postDataJSON().data).toMatchObject({
        agentUID: colleague,
        messageID: target.messageID,
        expectedVersion
      })
      return response.json() as Promise<ConversationDetail>
    }
    await input.fill('Independent unsent group draft')
    await row('Agent B original request').getByRole('button', { name: '编辑待发送消息', exact: true }).click()
    const recipient = composer.getByRole('combobox', { name: '选择 Agent', exact: true })
    await expect(recipient).toBeDisabled()
    await expect(recipient).toHaveText(baseline.conversation.agents.find(agent => agent.uid === colleague)!.displayName)
    await input.fill('Agent B local revised request')
    const changed = await add('Agent B concurrent follow-up', colleague)
    await save(409, slot(baseline, colleague).queueVersion)
    await expect(input).toHaveValue('Agent B local revised request')
    const refresh = page.getByRole('button', { name: '刷新后继续编辑', exact: true })
    await refresh.click()
    await expect(refresh).toHaveCount(0)
    await expect(input).toHaveValue('Agent B local revised request')
    const rebased = await save(201, slot(changed, colleague).queueVersion)
    expect(slot(rebased, colleague).inputs.find(input => input.messageID === target.messageID)?.text).toBe(
      'Agent B local revised request'
    )
    expect(slot(rebased, state.agent_uid)).toEqual(agentA)
    await expect(input).toHaveValue('Independent unsent group draft')
    await expect(recipient).toBeEnabled()

    await row('Agent B local revised request').getByRole('button', { name: '编辑待发送消息', exact: true }).click()
    await input.fill('Agent B second local draft')
    const remotelyEdited = await request<ConversationDetail>(page, `/conversations/${id}/queue`, 'POST', {
      action: 'edit',
      agentUID: colleague,
      messageID: target.messageID,
      text: 'Agent B saved by another browser',
      expectedVersion: slot(rebased, colleague).queueVersion
    })
    await save(409, slot(rebased, colleague).queueVersion)
    await expect(input).toHaveValue('Agent B second local draft')
    await expect(page.locator('blockquote').filter({ hasText: 'Agent B saved by another browser' })).toBeVisible()
    await page.getByRole('button', { name: '加载已保存版本', exact: true }).click()
    await expect(input).toHaveValue('Agent B saved by another browser')
    await expect(refresh).toHaveCount(0)
    await input.fill('Agent B final reconciled request')
    const reconciled = await save(201, slot(remotelyEdited, colleague).queueVersion)
    expect(slot(reconciled, state.agent_uid)).toEqual(agentA)
    expect(slot(reconciled, colleague).inputs.map(queued => queued.text)).toEqual([
      'Agent B final reconciled request',
      'Agent B concurrent follow-up'
    ])
    await expect(input).toHaveValue('Independent unsent group draft')
    await page.reload()
    await expect(row('Agent B final reconciled request')).toBeVisible()
    expect(slot(await detail(page, id), state.agent_uid)).toEqual(agentA)

    await row('Agent B final reconciled request').getByRole('button', { name: '编辑待发送消息', exact: true }).click()
    const withReference = await detail(page, id)
    await request<ConversationDetail>(page, `/conversations/${id}/queue`, 'POST', {
      action: 'edit',
      agentUID: colleague,
      messageID: target.messageID,
      text: 'Agent B final reconciled request',
      links: [{ kind: 'page', id: material!.page_id }],
      expectedVersion: slot(withReference, colleague).queueVersion
    })
    await input.fill('Keep this local wording during a reference conflict')
    await save(409, slot(withReference, colleague).queueVersion)
    await expect(page.getByRole('button', { name: '加载已保存版本', exact: true })).toBeVisible()
    await page.getByRole('button', { name: '加载已保存版本', exact: true }).click()
    await expect(input).toHaveValue('Agent B final reconciled request')
    await expect(composer.locator('.pod-chat-draft-page')).toContainText('Chat workspace reference')
    await composer.getByRole('button', { name: '取消编辑', exact: true }).click()
    await page.screenshot({ path: info.outputPath('chat-group-queue-recovery.png') })
  } finally {
    await context.close()
  }
})

test('a linked execution opens real paged records, retries a rejected cursor and preserves chronological reading', async ({
  browser
}, info) => {
  test.skip(!material!.execution_conversation_id, 'Use fresh recorded execution materials')
  const { context, page } = await ownerPage(browser)
  const id = material!.execution_conversation_id
  const path = `/api/v2/pod/conversations/${id}/executions/background_agent_job/${material!.linked_job_id}`
  try {
    await page.goto(conversationRoute(id))
    const card = page.locator('.pod-chat-linked-run').filter({ hasText: 'Recorded workspace execution' })
    await expect(card).toContainText('Browser content Agent')
    let requests = 0
    page.on('request', incoming => {
      if (new URL(incoming.url()).pathname === path) requests++
    })
    expect(requests).toBe(0)
    let rejectFirst = true
    await page.route(
      url => url.pathname === path,
      async route => {
        if (rejectFirst) {
          rejectFirst = false
          const url = new URL(route.request().url())
          url.searchParams.set('cursor', 'recorded-invalid-cursor')
          return route.continue({ url: url.toString() })
        }
        return route.continue()
      }
    )
    const rejected = page.waitForResponse(
      response => new URL(response.url()).pathname === path && response.status() === 422
    )
    await card.click()
    await rejected
    const drawer = page.getByRole('dialog', { name: 'Recorded workspace execution', exact: true })
    await expect(drawer).toBeInViewport({ ratio: 1 })
    await expect(drawer.getByRole('alert')).toBeVisible()
    const first = page.waitForResponse(
      response => new URL(response.url()).pathname === path && response.status() === 200
    )
    await drawer.getByRole('button', { name: '重试', exact: true }).click()
    let nextCursor = (await (await first).json()).nextCursor as string | null | undefined
    expect(nextCursor).toBeTruthy()
    const more = drawer.getByRole('button', { name: '加载更早的执行记录', exact: true })
    for (let pageNumber = 0; pageNumber < 10 && nextCursor; pageNumber++) {
      const cursor = nextCursor
      const loaded = page.waitForResponse(
        response =>
          new URL(response.url()).pathname === path &&
          new URL(response.url()).searchParams.get('cursor') === cursor &&
          response.status() === 200
      )
      await more.click()
      const body = await (await loaded).json()
      const marker = /Recorded execution step \d+\./.exec(body.text)?.[0]
      expect(marker).toBeDefined()
      await expect(drawer.getByText(marker!, { exact: true })).toHaveCount(1)
      nextCursor = body.nextCursor
    }
    expect(nextCursor).toBeFalsy()
    await expect(more).toHaveCount(0)
    await expect(drawer).toBeInViewport({ ratio: 1 })
    for (let step = 1; step <= 45; step++) {
      await expect(drawer.getByText(`Recorded execution step ${step}.`, { exact: true })).toHaveCount(1)
    }
    await expect(drawer).not.toContainText('Recorded private model context')
    const text = (await drawer.textContent())!
    expect(text.indexOf('Recorded execution step 1.')).toBeLessThan(text.indexOf('Recorded execution step 45.'))
    await drawer.screenshot({ path: info.outputPath('chat-execution-full-records.png') })
    await page.keyboard.press('Escape')
    await expect(drawer).toBeHidden()
    await expect(card).toBeFocused()
    await card.click()
    await expect(drawer.getByText('Recorded execution step 1.', { exact: true })).toBeVisible()
    await expect(drawer.getByText('Recorded execution step 45.', { exact: true })).toHaveCount(1)
  } finally {
    await page.unrouteAll({ behavior: 'wait' })
    await context.close()
  }
})

test('recorded Gateway events keep two live answers and long thinking separate through the real SSE adapter', async ({
  browser
}, info) => {
  test.skip(!material!.live_trigger_path, 'Use fresh recorded live materials')
  const { context, page } = await ownerPage(browser)
  const id = material!.live_conversation_id
  try {
    const connected = page.waitForResponse(
      response =>
        new URL(response.url()).pathname === `/api/v2/pod/conversations/${id}/events` && response.status() === 200
    )
    await page.goto(conversationRoute(id))
    await connected
    await expect(page.getByText('Recorded evidence is ready for the two colleagues.', { exact: true })).toBeVisible()
    writeFileSync(material!.live_trigger_path, 'start recorded Gateway publication', { mode: 0o600 })
    const first = page.locator(`[data-live-agent="${material!.live_agent_uids[0]}"]`)
    const second = page.locator(`[data-live-agent="${material!.live_agent_uids[1]}"]`)
    await expect(page.locator('[data-live-agent]')).toHaveCount(2)
    await expect(first).toContainText('Recorded colleague 1 answer: independent workspace result 1.')
    await expect(second).toContainText('Recorded colleague 2 answer: independent workspace result 2.')
    await expect(first).not.toContainText('independent workspace result 2.')
    await expect(second).not.toContainText('independent workspace result 1.')
    await expect(first.locator('.pod-chat-thinking')).not.toHaveAttribute('open', '')
    await expect(second.locator('.pod-chat-thinking')).not.toHaveAttribute('open', '')
    await page.screenshot({ path: info.outputPath('chat-parallel-recorded-live.png') })
    const thinking = first.locator('.pod-chat-thinking > summary')
    await thinking.click()
    await expect(first.getByText(/Recorded colleague 1 reasoning 18:/)).toBeVisible()
    await expect(second.locator('.pod-chat-thinking')).not.toHaveAttribute('open', '')
    const fold = first.locator('.pod-chat-work > summary')
    await fold.focus()
    await fold.press('Enter')
    await expect(first.locator('.pod-chat-work')).not.toHaveAttribute('open', '')
    await expect(fold).toBeFocused()
    await fold.press('Enter')
    await expect(first.locator('.pod-chat-work')).toHaveAttribute('open', '')
    const history = page.locator('.pod-chat-work').first()
    await history.locator(':scope > summary').click()
    await history.getByText('Check the recorded workspace', { exact: true }).click()
    await expect(history.locator('.pod-chat-command-terminal')).toContainText('git status --short')
    await expect(history.locator('.pod-chat-command-terminal')).toContainText(/退出码.*0/)
    await history.screenshot({ path: info.outputPath('chat-recorded-command.png') })
  } finally {
    await context.close()
  }
})

test('interleaved colleagues keep the answer attached to its real question and prevent editing an older own message', async ({
  browser
}, info) => {
  const { context, page } = await ownerPage(browser)
  try {
    await page.goto(conversationRoute(material!.interleaved_conversation_id))
    const reply = page.locator(`[data-chat-message-id="${material!.interleaved_reply_id}"]`)
    const origin = page.locator(`[data-chat-message-id="${material!.interleaved_question_id}"]`)
    const source = reply.getByRole('button', {
      name: '回复 \u2068Browser owner\u2069：\u2068Review the access decision.\u2069',
      exact: true
    })
    await expect(source).toBeVisible()
    await expect(reply).toContainText('The access review has one unresolved owner.')
    const rail = page.getByRole('navigation', { name: '对话轮次', exact: true })
    await rail.getByRole('button').first().hover()
    await expect(rail.locator('.pod-chat-turn-preview')).toContainText('The access review has one unresolved owner.')
    await expect(rail.locator('.pod-chat-turn-preview')).not.toContainText('The launch checklist is ready.')
    await rail.getByRole('button').nth(1).hover()
    await expect(rail.locator('.pod-chat-turn-preview')).toContainText('The launch checklist is ready.')
    await expect(rail.locator('.pod-chat-turn-preview')).not.toContainText(
      'The access review has one unresolved owner.'
    )
    await source.click()
    await expect(origin).toBeFocused()
    await expect(origin).toBeInViewport()
    await page.locator('.pod-room-header .pod-chat-header-title').click()
    const title = page.getByRole('textbox', { name: '重命名会话', exact: true })
    await title.fill('Interleaved workspace review')
    await title.press('Enter')
    await expect(page.locator('.pod-room-header .pod-chat-header-title')).toHaveText('Interleaved workspace review')
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await input.focus()
    await input.press('ArrowUp')
    await expect(input).toHaveValue('')
    await expect(page.getByRole('button', { name: '取消编辑', exact: true })).toHaveCount(0)
    await page.screenshot({ path: info.outputPath('chat-interleaved-source.png') })
  } finally {
    await context.close()
  }
})

test('an older pending decision stays actionable and a referenced answer preserves its complete message', async ({
  browser
}, info) => {
  const { context, page } = await ownerPage(browser)
  const id = material!.reference_decision_conversation_id
  try {
    await page.goto(conversationRoute(id))
    const initial = await detail(page, id)
    expect(initial.messages).toHaveLength(500)
    expect(initial.pendingInteractions).toHaveLength(1)
    const pending = initial.pendingInteractions[0]!
    expect(initial.messages.some(message => message.id === pending.messageID)).toBe(false)
    const question = page.locator('.pod-chat-choice-card')
    await expect(question).toHaveAttribute('data-state', 'pending')
    await expect(question).toContainText('Where should the workspace report go?')
    await expect(question.getByRole('button', { name: /Publish to the shared page/ })).toBeEnabled()
    const composer = page.locator('.pod-chat-composer')
    const input = composer.getByRole('textbox', { name: '消息', exact: true })
    // A room comment does not become an answer just because one question is pending.
    await input.fill('I am still collecting the room evidence.')
    const commentSent = page.waitForResponse(
      response => response.request().method() === 'POST' && new URL(response.url()).pathname.endsWith('/messages')
    )
    await input.press('Enter')
    const comment = await commentSent
    expect(comment.status()).toBe(201)
    expect(((await comment.json()) as ConversationDetail).pendingInteractions).toHaveLength(1)
    await expect(input).toHaveValue('')
    await input.fill('Keep my answer draft')
    await question.getByRole('textbox', { name: '你的回答', exact: true }).fill('An answer started in the card')
    await question.getByRole('button', { name: '带引用或附件回答', exact: true }).click()
    const answerContext = composer.locator('.pod-chat-answer-context')
    await expect(answerContext).toContainText('Where should the workspace report go?')
    await expect(composer.getByRole('combobox', { name: '选择 Agent', exact: true })).toBeDisabled()
    await answerContext.getByRole('button', { name: '退出作答', exact: true }).click()
    await expect(answerContext).toHaveCount(0)
    await expect(input).toHaveValue('Keep my answer draft\n\nAn answer started in the card')
    await expect(input).toBeFocused()
    await question.getByRole('button', { name: '带引用或附件回答', exact: true }).click()
    await input.fill('Use @Chat')
    await page.getByRole('option', { name: 'Chat workspace reference', exact: true }).click()
    await input.pressSequentially(' for this answer.')
    await input.pressSequentially(' @Browser member')
    await page.getByRole('option', { name: 'Browser member', exact: true }).click()
    const quoted = initial.messages.findLast(message => message.authorType === 'human')!
    const quotedRow = page.locator(`[data-chat-message-id="${quoted.id}"]`)
    await quotedRow.hover()
    await quotedRow.getByRole('button', { name: '引用回复', exact: true }).click()
    await expect(composer.locator('.pod-chat-quoted')).toContainText(quoted.text)
    await expect(composer.locator('.pod-chat-draft-page')).toContainText('Chat workspace reference')
    const choose = page.waitForEvent('filechooser')
    await composer.getByRole('button', { name: '添加文件', exact: true }).click()
    await (
      await choose
    ).setFiles({
      name: 'decision-evidence.txt',
      mimeType: 'text/plain',
      buffer: Buffer.from('Actual evidence attached to the answer.\n')
    })
    const files = composer.getByRole('list', { name: '附件', exact: true })
    await expect(files.getByRole('status')).toHaveText('已就绪')
    await page.setViewportSize({ width: 390, height: 960 })
    await expect(answerContext).toBeInViewport()
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await page.screenshot({ path: info.outputPath('chat-answer-context-mobile.png') })
    await page.setViewportSize({ width: 1440, height: 960 })
    let ordinaryMessages = 0
    page.on('request', request => {
      if (request.method() === 'POST' && new URL(request.url()).pathname.endsWith('/messages')) ordinaryMessages++
    })
    const sent = page.waitForResponse(
      response => response.request().method() === 'POST' && new URL(response.url()).pathname.endsWith('/answer')
    )
    await input.press('Enter')
    const result = await sent
    expect(result.status()).toBe(201)
    expect(ordinaryMessages).toBe(0)
    const body = result.request().postDataJSON().data
    expect(body.links).toEqual([
      { kind: 'page', id: material!.page_id },
      { kind: 'message', id: quoted.id, quote: quoted.text }
    ])
    expect(body.attachments).toHaveLength(1)
    expect(body.mentions).toEqual([{ type: 'human', uid: state.member.uid, displayName: 'Browser member' }])
    const persisted = (await result.json()) as ConversationDetail
    expect(persisted.pendingInteractions).toHaveLength(0)
    const saved = persisted.messages.findLast(message => message.authorType === 'human')!
    expect(saved.text).toBe(body.text)
    expect(saved.links).toEqual(body.links)
    expect(saved.mentions).toEqual(body.mentions)
    expect(saved.attachments.map(file => file.name)).toEqual(['decision-evidence.txt'])
    await expect(input).toHaveValue('')
    await expect(composer.locator('.pod-chat-quoted')).toHaveCount(0)
    await expect(composer.locator('.pod-chat-draft-page')).toHaveCount(0)
    await expect(answerContext).toHaveCount(0)
    await expect(files).toHaveCount(0)
    await page.screenshot({ path: info.outputPath('chat-older-decision-reference.png') })
  } finally {
    await context.close()
  }
})
