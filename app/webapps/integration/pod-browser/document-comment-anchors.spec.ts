import { expect, test, type Page, type WebSocket } from '@playwright/test'
import { closeRealtimeSocket, request, state } from './fixtures'
import { pageRoute } from './routes'

const editor = (page: Page) => page.locator('.pod-document .editor-content')
const comments = (page: Page) => page.getByRole('complementary', { name: '评论', exact: true })
const composer = (page: Page) => comments(page).getByRole('textbox', { name: '添加评论…', exact: true })
type Content = { content: { content: string; plain_text: string } }
type Threads = { threads: { id: string; body: string; quote: string; anchor_present: boolean }[] }

async function create(page: Page, title: string) {
  await page.goto(state.base_url + pageRoute(state.report_id))
  const { page: created } = await request<{ page: { id: string } }>(page, '/pages', 'POST', { type: 'doc', title })
  await page.goto(state.base_url + pageRoute(created.id))
  await expect(editor(page)).toBeVisible()
  return created.id
}

async function saved(page: Page, id: string, text: string) {
  await expect.poll(async () => (await request<Content>(page, `/pages/${id}`)).content.plain_text).toBe(text)
}

async function selectParagraph(page: Page, index: number, text: string) {
  await editor(page).locator(':scope > p').nth(index).click()
  await page.keyboard.press('Home')
  for (let i = 0; i < text.length; i++) await page.keyboard.press('Shift+ArrowRight')
  await expect.poll(() => page.evaluate(() => getSelection()?.toString())).toBe(text)
}

test('a failed title save does not prevent posting or relocating a confirmed body quote', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    id = await create(page, 'Comment with an unsaved title')
    await editor(page).locator('p').first().click()
    await page.keyboard.insertText('Quoted phrase')
    await saved(page, id, 'Quoted phrase')
    let failedSaves = 0
    await page.route(`**/api/v2/pod/pages/${id}`, route => {
      if (route.request().method() !== 'PATCH') return route.continue()
      failedSaves++
      return route.abort('failed')
    })
    const title = page.getByRole('textbox', { name: '页面标题', exact: true })
    await title.fill('Keep this unsaved title')
    await expect.poll(() => failedSaves).toBeGreaterThan(0)
    await selectParagraph(page, 0, 'Quoted phrase')
    await page.locator('.selection-toolbar').getByRole('button', { name: '评论', exact: true }).click()
    await composer(page).fill('Discuss the saved body.')
    await comments(page).getByRole('button', { name: '发送', exact: true }).click()
    const thread = comments(page).locator('.pod-comment-thread')
    await expect(thread.getByText('Discuss the saved body.', { exact: true })).toBeVisible()
    expect((await request<Threads>(page, `/pages/${id}/comments`)).threads[0]).toMatchObject({
      quote: 'Quoted phrase',
      anchor_present: true
    })

    await selectParagraph(page, 0, 'Quoted phrase')
    await page.keyboard.insertText('Replacement phrase')
    await saved(page, id, 'Replacement phrase')
    await expect(thread.getByText('原文已删除', { exact: true })).toBeVisible()
    await selectParagraph(page, 0, 'Replacement phrase')
    await comments(page).getByRole('button', { name: '重新定位到所选文字', exact: true }).click()
    await expect(comments(page).locator('.pod-comment-draft-quote blockquote')).toHaveText('Replacement phrase')
    await comments(page).getByRole('button', { name: '重新定位到所选文字', exact: true }).click()
    await expect(editor(page).locator('[data-comment-ids]')).toHaveText('Replacement phrase')
    await expect(thread.locator('.pod-comment-quote')).toHaveText('Quoted phrase')
    await expect(thread.getByText('原文已删除', { exact: true })).toHaveCount(0)
    expect((await request<Threads>(page, `/pages/${id}/comments`)).threads[0]).toMatchObject({
      quote: 'Quoted phrase',
      anchor_present: true
    })
    await expect(title).toHaveValue('Keep this unsaved title')
    expect((await request<{ page: { title: string } }>(page, `/pages/${id}`)).page.title).toBe(
      'Comment with an unsaved title'
    )
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('an offline body edit waits for confirmation without invalidating its selected quote', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let socket: WebSocket | undefined
  page.on('websocket', connected => {
    if (new URL(connected.url()).pathname === '/pod/socket/websocket') socket = connected
  })
  let id: string | undefined
  try {
    id = await create(page, 'Comment after body confirmation')
    await editor(page).locator('p').first().click()
    await page.keyboard.insertText('Quoted phrase')
    await saved(page, id, 'Quoted phrase')
    await selectParagraph(page, 0, 'Quoted phrase')
    await page.locator('.selection-toolbar').getByRole('button', { name: '评论', exact: true }).click()
    await composer(page).fill('Keep this selection while saving.')

    expect(socket).toBeDefined()
    const disconnected = socket!.waitForEvent('close', { timeout: 10_000 })
    await closeRealtimeSocket(page)
    await disconnected
    await context.setOffline(true)
    await editor(page).locator('p').first().click()
    await page.keyboard.press('End')
    await page.keyboard.insertText(' with a later edit')
    const send = comments(page).getByRole('button', { name: '发送', exact: true })
    await expect(send).toBeDisabled()
    await expect(comments(page).getByText('请等待当前编辑保存完成。', { exact: true })).toBeVisible()
    await expect(
      comments(page).getByText('正文已变化或选区需要重新确认。请重新选择引用文字后提交。', { exact: true })
    ).toHaveCount(0)
    await expect(composer(page)).toBeEditable()

    await context.setOffline(false)
    await expect(send).toBeEnabled({ timeout: 15_000 })
    await saved(page, id, 'Quoted phrase with a later edit')
    await send.click()
    await expect(
      comments(page).locator('.pod-comment-thread').getByText('Keep this selection while saving.', { exact: true })
    ).toBeVisible()
    expect((await request<Threads>(page, `/pages/${id}/comments`)).threads[0]).toMatchObject({
      quote: 'Quoted phrase',
      anchor_present: true
    })
  } finally {
    await context.setOffline(false)
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('a quoted block keeps its discussion when dragged into children or columns and undone', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    id = await create(page, 'Dragged comment anchor')
    await editor(page).locator('p').first().click()
    for (const [index, text] of ['Parent', 'Between', 'Quoted block', 'After'].entries()) {
      if (index) await page.keyboard.press('Enter')
      await page.keyboard.insertText(text)
    }
    await saved(page, id, 'Parent\nBetween\nQuoted block\nAfter')
    await selectParagraph(page, 2, 'Quoted block')
    await page.locator('.selection-toolbar').getByRole('button', { name: '评论', exact: true }).click()
    await composer(page).fill('Keep this discussion with its block.')
    await comments(page).getByRole('button', { name: '发送', exact: true }).click()
    await expect(editor(page).locator('[data-comment-ids]')).toHaveText('Quoted block')
    const thread = (await request<Threads>(page, `/pages/${id}/comments`)).threads[0]!
    await comments(page).getByRole('button', { name: '关闭', exact: true }).click()

    for (const side of [false, true]) {
      const paragraphs = editor(page).locator(':scope > p')
      await paragraphs.nth(2).hover()
      const grip = (await page.getByRole('button', { name: 'Block 菜单', exact: true }).boundingBox())!
      const target = (await paragraphs.first().boundingBox())!
      const x = side ? target.x + target.width - 2 : target.x + 40
      const y = side ? target.y + target.height / 2 : target.y + target.height - 2
      await page.mouse.move(grip.x + grip.width / 2, grip.y + grip.height / 2)
      await page.mouse.down()
      await page.mouse.move(x, y, { steps: 16 })
      await page.mouse.move(x + 1, y)
      await expect(page.locator('.drag-line')).toHaveCSS('opacity', '1')
      await page.mouse.up()
      if (side) await expect(editor(page).locator('.editor-column')).toHaveText(['Parent', 'Quoted block'])
      else await expect(editor(page).locator('.block-group > p')).toHaveText(['Parent', 'Quoted block'])
      await saved(page, id, 'Parent\nQuoted block\nBetween\nAfter')
      await expect(editor(page).locator('[data-comment-ids]')).toHaveAttribute('data-comment-ids', thread.id)
      expect((await request<Threads>(page, `/pages/${id}/comments`)).threads[0]).toMatchObject({
        id: thread.id,
        quote: 'Quoted block',
        anchor_present: true
      })
      await page.keyboard.press('ControlOrMeta+z')
      await expect(paragraphs).toHaveText(['Parent', 'Between', 'Quoted block', 'After'])
      await saved(page, id, 'Parent\nBetween\nQuoted block\nAfter')
      await expect(editor(page).locator('[data-comment-ids]')).toHaveAttribute('data-comment-ids', thread.id)
    }
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('a pending selection follows local and remote edits, but deleted source requires reselection without losing the draft', async ({
  browser
}, info) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const peer = await context.newPage()
  let id: string | undefined
  try {
    id = await create(page, 'Pending comment anchor')
    await editor(page).locator('p').first().click()
    for (const [index, text] of ['Before', 'Selected phrase', 'After'].entries()) {
      if (index) await page.keyboard.press('Enter')
      await page.keyboard.insertText(text)
    }
    await saved(page, id, 'Before\nSelected phrase\nAfter')
    await peer.goto(state.base_url + pageRoute(id))
    await expect(editor(peer).locator('p')).toHaveText(['Before', 'Selected phrase', 'After'])

    await selectParagraph(page, 1, 'Selected phrase')
    await page.locator('.selection-toolbar').getByRole('button', { name: '评论', exact: true }).click()
    await composer(page).fill('Please clarify this exact phrase.')
    await editor(page).locator('p').first().click()
    await page.keyboard.press('Home')
    await page.keyboard.insertText('Local ')
    await expect(editor(peer).locator('p').first()).toHaveText('Local Before')
    await editor(peer).locator('p').first().click()
    await peer.keyboard.press('Home')
    await peer.keyboard.insertText('Remote ')
    await expect(editor(page).locator('p').first()).toHaveText('Remote Local Before')
    await saved(page, id, 'Remote Local Before\nSelected phrase\nAfter')
    await comments(page).getByRole('button', { name: '发送', exact: true }).click()
    await expect(
      comments(page).locator('.pod-comment-thread').getByText('Please clarify this exact phrase.', { exact: true })
    ).toBeVisible()
    const first = (await request<Threads>(page, `/pages/${id}/comments`)).threads[0]!
    expect(first).toMatchObject({ quote: 'Selected phrase', anchor_present: true })
    await expect(editor(page).locator('[data-comment-ids]')).toHaveText('Selected phrase')

    await selectParagraph(page, 2, 'After')
    await page.locator('.selection-toolbar').getByRole('button', { name: '评论', exact: true }).click()
    await expect(comments(page).locator('.pod-comment-draft-quote blockquote')).toHaveText('After')
    await composer(page).fill('Keep this draft until I choose its source again.')
    await selectParagraph(peer, 2, 'After')
    await peer.keyboard.press('Backspace')
    await peer.keyboard.insertText('Replacement')
    await expect(editor(page).locator('p').last()).toHaveText('Replacement')
    await expect(
      comments(page).getByText('正文已变化或选区需要重新确认。请重新选择引用文字后提交。', { exact: true })
    ).toBeVisible()
    await expect(composer(page)).toHaveValue('Keep this draft until I choose its source again.')
    await expect(composer(page)).toBeEditable()
    await expect(comments(page).getByRole('button', { name: '发送', exact: true })).toBeDisabled()
    expect((await request<Threads>(page, `/pages/${id}/comments`)).threads).toHaveLength(1)
    await page.screenshot({ path: info.outputPath('comment-draft-source-deleted.png') })

    await selectParagraph(page, 2, 'Replacement')
    await page.locator('.selection-toolbar').getByRole('button', { name: '评论', exact: true }).click()
    await expect(composer(page)).toHaveValue('Keep this draft until I choose its source again.')
    await comments(page).getByRole('button', { name: '发送', exact: true }).click()
    await expect(
      comments(page)
        .locator('.pod-comment-thread')
        .getByText('Keep this draft until I choose its source again.', { exact: true })
    ).toBeVisible()
    const second = (await request<Threads>(page, `/pages/${id}/comments`)).threads.find(
      thread => thread.id !== first.id
    )
    expect(second).toMatchObject({ quote: 'Replacement', anchor_present: true })
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('a whole code block cut and paste moves its discussion through the real keyboard clipboard and OT commit', async ({
  browser
}, info) => {
  const context = await browser.newContext({
    permissions: ['clipboard-read', 'clipboard-write'],
    viewport: { width: 1440, height: 900 }
  })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    id = await create(page, 'Move code discussion')
    await editor(page).locator('p').first().click()
    await page.keyboard.insertText('Destination')
    await page.keyboard.press('Enter')
    await page.keyboard.type('```ts')
    await page.keyboard.press('Enter')
    await page.keyboard.insertText('a = 1')
    await page.keyboard.press('Enter')
    await page.keyboard.insertText('b = 2')
    await expect(editor(page).locator('pre')).toHaveText('a = 1\nb = 2', { useInnerText: true })
    await page.keyboard.press('Home')
    for (let i = 0; i < 5; i++) await page.keyboard.press('Shift+ArrowRight')
    await expect.poll(() => page.evaluate(() => getSelection()?.toString())).toBe('b = 2')
    await page.locator('.selection-toolbar').getByRole('button', { name: '评论', exact: true }).click()
    await composer(page).fill('Explain this code line.')
    await comments(page).getByRole('button', { name: '发送', exact: true }).click()
    await expect(editor(page).locator('[data-comment-ids]')).toHaveText('b = 2')
    const thread = (await request<Threads>(page, `/pages/${id}/comments`)).threads[0]!
    await comments(page).getByRole('button', { name: '关闭', exact: true }).click()

    await editor(page).locator('pre').click()
    await page.keyboard.press('ArrowRight')
    await page.keyboard.press('Escape')
    await expect(editor(page).locator('.editor-code-block')).toHaveClass(/editor-selected-block/)
    await page.keyboard.press('ControlOrMeta+x')
    await expect(editor(page).locator('pre')).toHaveCount(0)
    await editor(page).locator('p').first().click()
    await page.keyboard.press('Home')
    await page.keyboard.press('ControlOrMeta+v')
    await expect(editor(page).locator('pre')).toHaveText('a = 1\nb = 2', { useInnerText: true })
    await expect(editor(page).locator('[data-comment-ids]')).toHaveAttribute('data-comment-ids', thread.id)
    await expect
      .poll(async () => {
        const content = (await request<Content>(page, `/pages/${id}`)).content
        return (
          content.content.includes(`<comment ids="${thread.id}">b = 2</comment>`) &&
          content.plain_text.indexOf('b = 2') < content.plain_text.indexOf('Destination')
        )
      })
      .toBe(true)
    await editor(page).locator('[data-comment-ids]').click()
    await expect(comments(page).getByText('Explain this code line.', { exact: true })).toBeVisible()
    await expect(comments(page).getByText('原文已删除', { exact: true })).toHaveCount(0)
    await page.reload()
    await expect(editor(page).locator('[data-comment-ids]')).toHaveAttribute('data-comment-ids', thread.id)
    await page.screenshot({ path: info.outputPath('code-comment-after-move.png') })
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})
