import { expect, test } from '@playwright/test'
import { request, state } from './fixtures'
import { conversationRoute, pageRoute } from './routes'
import type { ConversationDetail, PodAgent } from '../../pod/api'

test('a colleague opens lazily, keeps one DM across reloads, and starts a separate group', async ({
  browser
}, info) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1440, height: 960 } })
  await context.addCookies(state.member.cookies)
  const page = await context.newPage()
  let groupID: string | undefined
  let dmID: string | undefined
  try {
    await page.goto('/')
    const directory = () => request<{ agents: PodAgent[] }>(page, '/agents')
    expect((await directory()).agents.find(agent => agent.uid === state.agent_uid)!.directConversationID).toBeNull()
    await page.locator(`a[href="/dm/${state.agent_uid}"]`).first().click()
    await expect(page).toHaveURL(url => url.pathname === `/dm/${state.agent_uid}`)
    await expect(page.getByRole('heading', { name: 'Browser content Agent', exact: true })).toBeVisible()
    expect((await directory()).agents.find(agent => agent.uid === state.agent_uid)!.directConversationID).toBeNull()
    await page.keyboard.press('ControlOrMeta+k')
    const search = page.locator('.pod-command-dialog')
    await search.getByRole('combobox').fill(`@${state.agent_uid}`)
    const colleague = search.getByRole('option').filter({ hasText: state.agent_uid })
    await expect(colleague).toHaveCount(1)
    await colleague.click()
    await expect(page).toHaveURL(url => url.pathname === `/dm/${state.agent_uid}`)
    await page.reload()
    await page.getByRole('textbox', { name: '消息', exact: true }).fill('请审阅采购合同。')
    const saved = page.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/conversations'
    )
    await page.getByRole('button', { name: '发送消息', exact: true }).click()
    const dm = (await (await saved).json()) as ConversationDetail
    dmID = dm.conversation.id
    expect(dm.conversation.conversationKind).toBe('colleague_dm')
    await page.reload()
    await expect(page.locator('.pod-room-header h1')).toContainText(`@${state.agent_uid}`)
    await expect(page.locator('.pod-room-header h1')).toContainText('Browser content Agent')
    await expect(page.getByRole('region', { name: '待发送', exact: true })).toContainText('请审阅采购合同。')
    expect((await directory()).agents.find(agent => agent.uid === state.agent_uid)!.directConversationID).toBe(
      dm.conversation.id
    )
    await page.keyboard.press('ControlOrMeta+k')
    await search.getByRole('combobox').fill(`@${state.agent_uid}`)
    await expect(colleague).toHaveCount(1)
    await colleague.click()

    await page.getByRole('button', { name: '新建群聊', exact: true }).click()
    const dialog = page.getByRole('dialog', { name: '新建群聊', exact: true })
    await expect(dialog.getByRole('textbox', { name: '群名', exact: true })).toHaveValue('Browser content Agent')
    await expect(dialog.getByRole('checkbox')).toBeChecked()
    await expect(dialog.getByRole('button', { name: '创建群聊', exact: true })).toBeDisabled()
    await dialog.getByRole('textbox', { name: '首条消息', exact: true }).fill('请一起审阅采购合同。')
    await dialog.getByRole('combobox').fill('Browser owner')
    await dialog.getByRole('option', { name: 'Browser owner', exact: true }).click()
    const created = page.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/conversations'
    )
    await dialog.getByRole('button', { name: '创建群聊', exact: true }).click()
    const group = (await (await created).json()) as ConversationDetail
    groupID = group.conversation.id
    expect(group.conversation.conversationKind).toBe('group')
    expect(groupID).not.toBe(dm.conversation.id)
    expect(group.conversation.participants.map(member => member.uid)).toContain(state.owner.uid)
    await expect(page).toHaveURL(url => url.pathname === conversationRoute(groupID!))
    const original = await request<ConversationDetail>(page, `/conversations/${dm.conversation.id}`)
    expect(original.conversation.roomMode).toBe('dm')
    expect(original.conversation.participants).toHaveLength(2)
    await page.goto(`/?agent=${state.agent_uid}`)
    await expect(page).toHaveURL(url => url.pathname === `/dm/${state.agent_uid}`)
    await expect(page.getByRole('region', { name: '待发送', exact: true })).toContainText('请审阅采购合同。')
    await page.screenshot({ path: info.outputPath('unique-colleague-dm.png') })
    await request(page, `/conversations/${dmID}?forceStop=true`, 'DELETE')
    dmID = undefined
    await expect(page).toHaveURL(`${state.base_url}/`)
    await page.locator(`a[href="/dm/${state.agent_uid}"]`).first().click()
    await expect(page.getByRole('heading', { name: 'Browser content Agent', exact: true })).toBeVisible()
    await page.getByRole('textbox', { name: '消息', exact: true }).fill('开始新的审阅。')
    const recreated = page.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/conversations'
    )
    await page.getByRole('button', { name: '发送消息', exact: true }).click()
    dmID = ((await (await recreated).json()) as ConversationDetail).conversation.id
    expect(dmID).not.toBe(dm.conversation.id)
    await expect(page).toHaveURL(url => url.pathname === `/dm/${state.agent_uid}`)
  } finally {
    if (groupID) await request(page, `/conversations/${groupID}?forceStop=true`, 'DELETE')
    if (dmID) await request(page, `/conversations/${dmID}?forceStop=true`, 'DELETE')
    await context.close()
  }
})

test('an assistant task carries its referenced pages into a separate group without copying private history', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let originID: string | undefined
  let groupID: string | undefined
  try {
    await page.goto('/')
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await input.fill('先在这里准备采购讨论。')
    const created = page.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/conversations'
    )
    await page.getByRole('button', { name: '发送消息', exact: true }).click()
    originID = ((await (await created).json()) as ConversationDetail).conversation.id
    await input.pressSequentially('稍后请团队讨论 @Browser report')
    await page.getByRole('option', { name: 'Browser report', exact: true }).click()
    const linked = page.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname.endsWith(`/conversations/${originID}/messages`)
    )
    await page.getByRole('button', { name: '发送消息', exact: true }).click()
    expect((await linked).ok()).toBe(true)

    // The participant avatars only list who is in the task; the summary and starting a group have their own buttons.
    const avatars = page.getByRole('button', { name: /^聊天成员：/ })
    await avatars.click()
    const members = page.getByRole('dialog', { name: '当前会话成员', exact: true })
    await expect(members.locator('.pod-chat-member')).toHaveCount(2)
    await expect(members.getByRole('button')).toHaveCount(0)
    await expect(avatars).toHaveAttribute('aria-expanded', 'true')
    await expect(page.getByRole('button', { name: '会话摘要', exact: true })).toHaveAttribute('aria-expanded', 'false')
    await expect(page.getByRole('complementary', { name: '会话摘要', exact: true })).toHaveCount(0)
    await page.keyboard.press('Escape')
    await expect(members).toBeHidden()
    await expect(avatars).toBeFocused()

    await page.getByRole('button', { name: '转为群聊', exact: true }).click()
    const dialog = page.getByRole('dialog', { name: '转为群聊', exact: true })
    const message = dialog.getByRole('textbox', { name: '首条消息', exact: true })
    await expect(message).toHaveValue(new RegExp(pageRoute(state.report_id)))
    const search = dialog.getByRole('combobox')
    await search.fill('Browser member')
    await dialog.getByRole('option', { name: 'Browser member', exact: true }).click()
    await search.fill(state.agent_uid)
    await dialog.getByRole('option', { name: new RegExp(`^Browser content Agent @${state.agent_uid}`) }).click()
    const grouped = page.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/conversations'
    )
    await dialog.getByRole('button', { name: '创建群聊', exact: true }).click()
    const group = (await (await grouped).json()) as ConversationDetail
    groupID = group.conversation.id
    expect(group.conversation.conversationKind).toBe('group')
    expect(group.artifacts.pageIDs).toContain(state.report_id)
    expect(group.conversation.agents.map(agent => agent.uid)).toEqual([state.agent_uid])
    const original = await request<ConversationDetail>(page, `/conversations/${originID}`)
    expect(original.conversation.conversationKind).toBe('assistant_task')
    expect(original.conversation.participants).toHaveLength(2)
    expect(group.messages.map(item => item.text).join('\n')).not.toContain('稍后请团队讨论')
  } finally {
    if (groupID) await request(page, `/conversations/${groupID}?forceStop=true`, 'DELETE')
    if (originID) await request(page, `/conversations/${originID}?forceStop=true`, 'DELETE')
    await context.close()
  }
})

test('New Chat starts a clean assistant draft and preserves the unfinished task', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto('/')
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await input.fill('尚未发送的采购任务')
    await page.getByRole('link', { name: /^新对话/ }).click()
    await expect(input).toHaveValue('')
    const kept = page.getByRole('region', { name: '保留的对话内容', exact: true })
    await expect(kept.getByRole('textbox')).toHaveValue('尚未发送的采购任务')
    await input.fill('第二项任务')
    await page.keyboard.press('ControlOrMeta+Shift+O')
    await expect(input).toHaveValue('')
    await expect(kept.getByRole('textbox')).toHaveCount(2)
    await expect(page.getByRole('combobox', { name: '选择 Agent', exact: true })).toHaveCount(0)
  } finally {
    await context.close()
  }
})

test('New Chat keeps the sidebar on Home while the viewer starts and continues a task', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let taskID: string | undefined
  try {
    await page.goto(pageRoute(state.report_id))
    const home = page.getByRole('tab', { name: '主页', exact: true })
    await expect(home).toHaveAttribute('aria-selected', 'true')
    await page.locator('.pod-sidebar-header').getByRole('link', { name: '新对话', exact: true }).click()
    await expect(page).toHaveURL(`${state.base_url}/`)
    await expect(home).toHaveAttribute('aria-selected', 'true')

    const created = page.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/conversations'
    )
    await page.getByRole('textbox', { name: '消息', exact: true }).fill('在主页旁边起一个任务')
    await page.getByRole('button', { name: '发送消息', exact: true }).click()
    taskID = ((await (await created).json()) as ConversationDetail).conversation.id
    await expect(page).toHaveURL(url => url.pathname === conversationRoute(taskID!))
    await expect(home).toHaveAttribute('aria-selected', 'true')

    await page.keyboard.press('ControlOrMeta+Shift+O')
    await expect(page).toHaveURL(`${state.base_url}/`)
    await expect(home).toHaveAttribute('aria-selected', 'true')

    await page.getByRole('tab', { name: '对话', exact: true }).click()
    await page.locator('.pod-sidebar-header').getByRole('link', { name: '新对话', exact: true }).click()
    await expect(page.getByRole('tab', { name: '对话', exact: true })).toHaveAttribute('aria-selected', 'true')
  } finally {
    if (taskID) await request(page, `/conversations/${taskID}?forceStop=true`, 'DELETE')
    await context.close()
  }
})

test('a guest uses granted colleagues and comments without assistant entry points', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.guest.cookies)
  const page = await context.newPage()
  let dmID: string | undefined
  try {
    await page.goto('/')
    await expect(page.locator(`a[href="/dm/${state.agent_uid}"]`).first()).toBeVisible()
    await expect(page.getByRole('link', { name: /^新对话/ })).toHaveCount(0)
    await page.keyboard.press('ControlOrMeta+k')
    await expect(page.locator('.pod-command-dialog').getByRole('option', { name: '新对话', exact: true })).toHaveCount(
      0
    )
    await page.keyboard.press('Escape')
    await page.keyboard.press('ControlOrMeta+Shift+O')
    await expect(page.getByRole('textbox', { name: '消息', exact: true })).toHaveCount(0)
    await page.goto(pageRoute(state.report_id))
    await expect(page.getByRole('button', { name: '助理', exact: true })).toHaveCount(0)
    await expect(page.getByRole('button', { name: '评论', exact: true }).first()).toBeVisible()
    await page.goto(`/dm/${state.agent_uid}`)
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await input.fill('/new')
    await expect(page.getByRole('option').filter({ hasText: '/new' })).toHaveCount(0)
    await input.fill('查看已授权的同事')
    const saved = page.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/conversations'
    )
    await page.getByRole('button', { name: '发送消息', exact: true }).click()
    const response = await saved
    expect(response.status()).toBe(201)
    const detail = (await response.json()) as ConversationDetail
    dmID = detail.conversation.id
    expect(detail.conversation.conversationKind).toBe('colleague_dm')
  } finally {
    if (dmID) await request(page, `/conversations/${dmID}?forceStop=true`, 'DELETE')
    await context.close()
  }
})
