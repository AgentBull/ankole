import { expect, test, type Page, type WebSocket } from '@playwright/test'
import { closeRealtimeSocket, request, state } from './fixtures'
import { pageRoute } from './routes'

const editor = (page: Page) => page.locator('.pod-document .editor-content')
const comments = (page: Page) => page.getByRole('complementary', { name: '评论', exact: true })
const commentButton = (page: Page) =>
  page.locator('.pod-page-header').getByRole('button', { name: '评论', exact: true })

async function saved(page: Page, id: string, text: string) {
  await expect
    .poll(async () => (await request<{ content: { plain_text: string } }>(page, `/pages/${id}`)).content.plain_text)
    .toBe(text)
}

async function selectFirstParagraph(page: Page, text: string) {
  await editor(page).locator('p').first().click()
  await page.keyboard.press('ControlOrMeta+Home')
  for (let i = 0; i < text.length; i++) await page.keyboard.press('Shift+ArrowRight')
  await expect.poll(() => page.evaluate(() => getSelection()?.toString())).toBe(text)
}

async function create(page: Page, title: string) {
  await page.goto(state.base_url + pageRoute(state.report_id))
  const { page: created } = await request<{ page: { id: string } }>(page, '/pages', 'POST', { type: 'doc', title })
  await page.goto(state.base_url + pageRoute(created.id))
  await expect(editor(page)).toBeVisible()
  return created.id
}

test('comments follow a real cut move, contributors can comment without editing, and replies survive root deletion', async ({
  browser
}, info) => {
  const context = await browser.newContext({
    permissions: ['clipboard-read', 'clipboard-write'],
    viewport: { width: 1440, height: 900 }
  })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const memberContext = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await memberContext.addCookies(state.member.cookies)
  const member = await memberContext.newPage()
  let id: string | undefined
  try {
    id = await create(page, 'Comment collaboration')
    await editor(page).locator('p').first().click()
    await page.keyboard.insertText('Quoted paragraph')
    await page.keyboard.press('Enter')
    await page.keyboard.insertText('Tail')
    await saved(page, id, 'Quoted paragraph\nTail')
    await selectFirstParagraph(page, 'Quoted paragraph')
    await page.locator('.selection-toolbar').getByRole('button', { name: '评论', exact: true }).click()
    await comments(page).getByRole('textbox', { name: '添加评论…', exact: true }).fill('Please clarify this paragraph.')
    await comments(page).getByRole('button', { name: '发送', exact: true }).click()
    const thread = comments(page).locator('.pod-comment-thread').first()
    await expect(thread).toBeVisible()
    await expect(editor(page).locator('[data-comment-ids]')).toHaveCount(1)
    await comments(page).getByRole('button', { name: '关闭', exact: true }).click()

    await selectFirstParagraph(page, 'Quoted paragraph')
    await page.keyboard.press('ControlOrMeta+x')
    await page.keyboard.press('ControlOrMeta+End')
    await page.keyboard.press('Enter')
    await page.keyboard.press('ControlOrMeta+v')
    await expect
      .poll(async () => {
        const data = await request<{ content: { plain_text: string; content: string } }>(page, `/pages/${id}`)
        return (
          data.content.plain_text.indexOf('Tail') < data.content.plain_text.indexOf('Quoted paragraph') &&
          data.content.content.includes('<comment ')
        )
      })
      .toBe(true)
    await commentButton(page).click()
    await expect(thread.getByText('原文已删除', { exact: true })).toHaveCount(0)

    const sharing = await request<{ sharing_version: string }>(page, `/pages/${id}/sharing`)
    await request(page, `/pages/${id}/sharing`, 'PUT', {
      sharing_version: sharing.sharing_version,
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'contribute' }
      ]
    })
    await member.goto(state.base_url + pageRoute(id))
    await expect(member.getByRole('textbox', { name: '页面标题', exact: true })).toHaveCount(0)
    await commentButton(member).click()
    const memberThread = comments(member)
      .locator('.pod-comment-thread')
      .filter({ hasText: 'Please clarify this paragraph.' })
    await memberThread.getByRole('button', { name: '回复', exact: true }).click()
    await memberThread.getByRole('textbox', { name: '回复', exact: true }).fill('A reply from a contributor.')
    await memberThread.getByRole('button', { name: '发送', exact: true }).click()
    await expect(thread.getByText('A reply from a contributor.', { exact: true })).toBeVisible()
    await thread.locator('.pod-comment-entry').first().getByRole('button', { name: '更多操作', exact: true }).click()
    await page.getByRole('menuitem', { name: '删除评论', exact: true }).click()
    await expect(thread.getByText('评论已删除', { exact: true })).toBeVisible()
    await expect(thread.getByText('A reply from a contributor.', { exact: true })).toBeVisible()
    await page.screenshot({ path: info.outputPath('comments-collaboration.png') })
    await comments(page).getByRole('button', { name: '关闭', exact: true }).click()
    await page.setViewportSize({ width: 375, height: 812 })
    await commentButton(page).click()
    const mobileComments = page.getByRole('dialog', { name: '评论', exact: true })
    await expect(mobileComments).toBeVisible()
    await expect(mobileComments.getByRole('textbox', { name: '添加评论…', exact: true })).toBeVisible()
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await page.screenshot({ path: info.outputPath('comments-mobile.png') })
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
    await memberContext.close()
  }
})

test('history previews and restores through OT while keeping resolved discussions and deleted anchors', async ({
  browser
}, info) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    id = await create(page, 'History restore')
    await editor(page).locator('p').first().click()
    await page.keyboard.insertText('Quoted paragraph')
    await saved(page, id, 'Quoted paragraph')
    await selectFirstParagraph(page, 'Quoted paragraph')
    await page.locator('.selection-toolbar').getByRole('button', { name: '评论', exact: true }).click()
    await comments(page).getByRole('textbox', { name: '添加评论…', exact: true }).fill('Discussion stays resolved.')
    await comments(page).getByRole('button', { name: '发送', exact: true }).click()
    await comments(page).getByRole('button', { name: '解决', exact: true }).click()
    await comments(page).getByRole('button', { name: '关闭', exact: true }).click()
    await editor(page).locator('p').first().click()
    await page.keyboard.press('ControlOrMeta+End')
    await page.keyboard.insertText(' after review')
    await saved(page, id, 'Quoted paragraph after review')

    const openHistory = async () => {
      await page.locator('.pod-page-header').getByRole('button', { name: '更多操作', exact: true }).click()
      await page.getByRole('menuitem', { name: '版本历史', exact: true }).click()
      return page.getByRole('dialog', { name: '版本历史', exact: true })
    }
    const history = await openHistory()
    await expect.poll(async () => (await history.boundingBox())?.width ?? 0).toBeGreaterThanOrEqual(1000)
    await history
      .locator('.pod-document-history-list')
      .getByRole('button', { name: /创建文档/ })
      .click()
    const previewTitle = history.getByRole('heading', { name: 'History restore', exact: true })
    await expect(previewTitle).toBeVisible()
    expect(await previewTitle.evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true)
    await expect(history.locator('.pod-document-history-preview .editor-content')).toHaveText('')
    await page.screenshot({ path: info.outputPath('history-preview.png') })
    await page.setViewportSize({ width: 375, height: 812 })
    await expect(history).toBeVisible()
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    const previewBounds = (await history.locator('.pod-document-history-preview').boundingBox())!
    const listBounds = (await history.locator('.pod-document-history-list').boundingBox())!
    expect(
      previewBounds.y + previewBounds.height <= listBounds.y + 1 ||
        listBounds.y + listBounds.height <= previewBounds.y + 1
    ).toBe(true)
    await page.screenshot({ path: info.outputPath('history-mobile.png') })
    await page.setViewportSize({ width: 1440, height: 900 })
    await expect.poll(async () => (await history.boundingBox())?.width ?? 0).toBeGreaterThanOrEqual(1000)
    const restore = async () => {
      await history.getByRole('button', { name: '恢复此版本', exact: true }).click()
      await page
        .getByRole('dialog', { name: '恢复此版本', exact: true })
        .getByRole('button', { name: '恢复此版本', exact: true })
        .click()
      await expect(history).toBeHidden()
    }
    const before = await request<{ page: { revision: number } }>(page, `/pages/${id}`)
    await restore()
    await saved(page, id, '')
    const restored = await request<{ page: { revision: number } }>(page, `/pages/${id}`)
    expect(restored.page.revision).toBeGreaterThan(before.page.revision)
    const resolved = await request<{ threads: { body: string; anchor_present: boolean; resolved_at: string }[] }>(
      page,
      `/pages/${id}/comments?status=resolved`
    )
    expect(resolved.threads[0]).toMatchObject({ body: 'Discussion stays resolved.', anchor_present: false })
    expect(resolved.threads[0]?.resolved_at).toBeTruthy()

    await openHistory()
    await history
      .locator('.pod-document-history-list')
      .getByRole('button', { name: /恢复前版本/ })
      .click()
    await expect(history.locator('.pod-document-history-preview .editor-content')).toHaveText(
      'Quoted paragraph after review'
    )
    await restore()
    await saved(page, id, 'Quoted paragraph after review')
    const final = await request<{ threads: { anchor_present: boolean; resolved_at: string }[] }>(
      page,
      `/pages/${id}/comments?status=resolved`
    )
    expect(final.threads[0]?.anchor_present).toBe(false)
    expect(final.threads[0]?.resolved_at).toBe(resolved.threads[0]?.resolved_at)
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('a rejoined document refreshes missed comments without a reload or losing its draft', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let socket: WebSocket | undefined
  page.on('websocket', connected => {
    if (new URL(connected.url()).pathname === '/pod/socket/websocket') socket = connected
  })
  const memberContext = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await memberContext.addCookies(state.member.cookies)
  const member = await memberContext.newPage()
  let id: string | undefined
  try {
    id = await create(page, 'Comments reconnect')
    const sharing = await request<{ sharing_version: string }>(page, `/pages/${id}/sharing`)
    await request(page, `/pages/${id}/sharing`, 'PUT', {
      sharing_version: sharing.sharing_version,
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'contribute' }
      ]
    })
    await commentButton(page).click()
    const draft = comments(page).getByRole('textbox', { name: '添加评论…', exact: true })
    await draft.fill('Reconnect discussion')
    await comments(page).getByRole('button', { name: '发送', exact: true }).click()
    await expect(comments(page).getByText('Reconnect discussion', { exact: true })).toBeVisible()
    await draft.fill('Keep this unsent comment')
    const documentStarted = await page.evaluate(() => performance.timeOrigin)

    await member.goto(state.base_url + pageRoute(id))
    await commentButton(member).click()
    const thread = comments(member).locator('.pod-comment-thread').filter({ hasText: 'Reconnect discussion' })
    await expect(thread).toBeVisible()
    expect(socket).toBeDefined()
    const disconnected = socket!.waitForEvent('close', { timeout: 10_000 })
    // Complete the real close handshake before disabling the network. Otherwise
    // Chromium keeps the socket in CLOSING while its handshake cannot reach the server.
    await closeRealtimeSocket(page)
    await disconnected
    await context.setOffline(true)

    await thread.getByRole('button', { name: '回复', exact: true }).click()
    await thread.getByRole('textbox', { name: '回复', exact: true }).fill('Reply sent while the owner was offline')
    await thread.getByRole('button', { name: '发送', exact: true }).click()
    await expect(thread.getByText('Reply sent while the owner was offline', { exact: true })).toBeVisible()
    await expect(comments(page).getByText('Reply sent while the owner was offline', { exact: true })).toHaveCount(0)

    await context.setOffline(false)
    await expect(comments(page).getByText('Reply sent while the owner was offline', { exact: true })).toBeVisible({
      timeout: 15_000
    })
    expect(await page.evaluate(() => performance.timeOrigin)).toBe(documentStarted)
    await expect(draft).toHaveValue('Keep this unsent comment')
  } finally {
    await context.setOffline(false)
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
    await memberContext.close()
  }
})

test('comment edits require reviewing a newer version before an old draft can overwrite it', async ({
  browser
}, info) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const second = await context.newPage()
  let id: string | undefined
  try {
    id = await create(page, 'Comment edit conflict')
    await commentButton(page).click()
    await comments(page).getByRole('textbox', { name: '添加评论…', exact: true }).fill('Original comment')
    await comments(page).getByRole('button', { name: '发送', exact: true }).click()
    const firstEntry = comments(page).locator('.pod-comment-entry').first()
    await expect(firstEntry.getByText('Original comment', { exact: true })).toBeVisible()
    await firstEntry.getByRole('button', { name: '更多操作', exact: true }).click()
    await page.getByRole('menuitem', { name: '编辑评论', exact: true }).click()
    const draft = firstEntry.getByRole('textbox', { name: '编辑评论', exact: true })
    await draft.fill('Draft from the first tab')

    await second.goto(state.base_url + pageRoute(id))
    await commentButton(second).click()
    const secondEntry = comments(second).locator('.pod-comment-entry').first()
    await secondEntry.getByRole('button', { name: '更多操作', exact: true }).click()
    await second.getByRole('menuitem', { name: '编辑评论', exact: true }).click()
    await secondEntry.getByRole('textbox', { name: '编辑评论', exact: true }).fill('Saved from the second tab')
    await secondEntry.getByRole('button', { name: '发送', exact: true }).click()
    await expect(secondEntry.getByText('Saved from the second tab', { exact: true })).toBeVisible()

    await expect(firstEntry.getByRole('region', { name: '最新评论', exact: true })).toContainText(
      'Saved from the second tab'
    )
    await expect(draft).toHaveValue('Draft from the first tab')
    await expect(draft).toHaveAttribute('aria-disabled', 'true')
    await expect(firstEntry.getByRole('button', { name: '发送', exact: true })).toBeDisabled()
    await page.screenshot({ path: info.outputPath('comment-edit-conflict.png') })
    await firstEntry.getByRole('button', { name: '已核对，继续编辑', exact: true }).click()
    await expect(draft).toHaveValue('Draft from the first tab')
    await expect(firstEntry.getByRole('button', { name: '发送', exact: true })).toBeEnabled()
    await firstEntry.getByRole('button', { name: '发送', exact: true }).click()
    await expect(firstEntry.getByText('Draft from the first tab', { exact: true })).toBeVisible()
    await expect(secondEntry.getByText('Draft from the first tab', { exact: true })).toBeVisible()
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})
