import { expect, test, type Page } from '@playwright/test'
import { request, state } from './fixtures'
import { pageRoute } from './routes'

const editor = (page: Page) => page.locator('.pod-document .editor-content')
const comments = (page: Page) => page.getByRole('complementary', { name: '评论', exact: true })
const trigger = (page: Page) => page.locator('.pod-page-header').getByRole('button', { name: '评论', exact: true })

async function create(page: Page, title: string) {
  await page.goto(state.base_url + pageRoute(state.report_id))
  const result = await request<{ page: { id: string } }>(page, '/pages', 'POST', { type: 'doc', title })
  await page.goto(state.base_url + pageRoute(result.page.id))
  await expect(editor(page)).toBeVisible()
  return result.page.id
}

async function selectParagraph(page: Page, text: string) {
  await editor(page).locator('p').first().click()
  await page.keyboard.press('ControlOrMeta+Home')
  for (let index = 0; index < text.length; index++) await page.keyboard.press('Shift+ArrowRight')
  await expect.poll(() => page.evaluate(() => getSelection()?.toString())).toBe(text)
}

async function addComment(page: Page, body: string) {
  await comments(page).getByRole('textbox', { name: '添加评论…', exact: true }).fill(body)
  await comments(page).getByRole('button', { name: '发送', exact: true }).click()
  await expect(comments(page).locator('.pod-comment-thread').getByText(body, { exact: true })).toBeVisible()
}

test('Mermaid source comments keep their anchor through editing and reload', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto(state.base_url + pageRoute(state.report_id))
    const created = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'doc',
      title: 'Mermaid comment',
      xml: '<page><mermaid>graph TD\n  A[Alpha] --&gt; B[Beta]</mermaid></page>'
    })
    id = created.page.id
    await page.goto(state.base_url + pageRoute(id))
    await editor(page).locator('.mermaid-pre').click()
    await page.keyboard.press('ControlOrMeta+Home')
    for (let index = 0; index < 14; index++) await page.keyboard.press('ArrowRight')
    for (let index = 0; index < 5; index++) await page.keyboard.press('Shift+ArrowRight')
    await expect.poll(() => page.evaluate(() => getSelection()?.toString())).toBe('Alpha')
    await page.locator('.selection-toolbar').getByRole('button', { name: '评论', exact: true }).click()
    await addComment(page, 'Keep the Alpha node')
    const readThreads = () =>
      request<{ threads: { quote: string; anchor_present: boolean }[] }>(page, `/pages/${id}/comments`)
    await expect
      .poll(async () => (await readThreads()).threads[0])
      .toMatchObject({ quote: 'Alpha', anchor_present: true })
    await trigger(page).click()
    await editor(page)
      .locator('.mermaid-pre')
      .evaluate(element => {
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT)
        let text: Node | null = null
        for (let node = walker.nextNode(); node; node = walker.nextNode()) text = node
        if (!text) throw new Error('The Mermaid source has no text')
        element.closest<HTMLElement>('[contenteditable="true"]')?.focus()
        const range = document.createRange()
        range.setStart(text, text.textContent!.length)
        range.collapse(true)
        getSelection()!.removeAllRanges()
        getSelection()!.addRange(range)
        document.dispatchEvent(new Event('selectionchange'))
      })
    await page.keyboard.insertText('\n  B --> C[Gamma]')
    await expect(editor(page).locator('.mermaid-pre')).toContainText('Gamma')
    await expect
      .poll(async () => (await request<{ content: { content: string } }>(page, `/pages/${id}`)).content.content)
      .toContain('Gamma')
    await page.reload()
    await expect(editor(page).locator('.mermaid-pre')).toContainText('Alpha')
    expect((await readThreads()).threads[0]).toMatchObject({ quote: 'Alpha', anchor_present: true })
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('returning readers discover replies on old threads, share a direct link, and persist explicit read state', async ({
  browser
}, info) => {
  const ownerContext = await browser.newContext({
    permissions: ['clipboard-read', 'clipboard-write'],
    viewport: { width: 1440, height: 900 }
  })
  await ownerContext.addCookies(state.owner.cookies)
  const owner = await ownerContext.newPage()
  const memberContext = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await memberContext.addCookies(state.member.cookies)
  const member = await memberContext.newPage()
  let id: string | undefined
  try {
    id = await create(owner, 'Comment activity and links')
    await trigger(owner).click()
    await addComment(owner, 'The oldest discussion')
    const { threads } = await request<{ threads: { id: string }[] }>(owner, `/pages/${id}/comments`)
    const threadID = threads[0]!.id
    // Fill a complete page through the real public comment API. The reply below must bring
    // this oldest discussion back into the first page the returning reader actually sees.
    for (let index = 0; index < 26; index++) {
      await request(owner, `/pages/${id}/comments`, 'POST', { body: `Later discussion ${index}` })
    }
    const direct = await ownerContext.newPage()
    const cursors: string[] = []
    direct.on('request', request => {
      const url = new URL(request.url())
      if (url.pathname.endsWith(`/pages/${id}/comments`) && url.searchParams.has('cursor')) {
        cursors.push(url.searchParams.get('cursor')!)
      }
    })
    await direct.goto(`${state.base_url}${pageRoute(id)}?commentId=${threadID}`)
    await expect(comments(direct).locator(`[data-thread-id="${threadID}"]`)).toBeVisible()
    expect(cursors).toEqual([])
    await direct.close()
    const sharing = await request<{ sharing_version: string }>(owner, `/pages/${id}/sharing`)
    await request(owner, `/pages/${id}/sharing`, 'PUT', {
      sharing_version: sharing.sharing_version,
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'contribute' }
      ]
    })
    await owner.goto(state.base_url + pageRoute(state.report_id))
    await member.goto(`${state.base_url}${pageRoute(id)}?commentId=${threadID}`)
    const memberThread = comments(member).locator(`[data-thread-id="${threadID}"]`)
    await expect(memberThread).toBeVisible()
    await memberThread.getByRole('button', { name: '回复', exact: true }).click()
    await memberThread
      .getByRole('textbox', { name: '回复', exact: true })
      .fill('Answer delivered while the owner was away')
    await memberThread.getByRole('button', { name: '发送', exact: true }).click()
    await expect(memberThread.getByText('Answer delivered while the owner was away', { exact: true })).toBeVisible()

    await owner.goto(state.base_url + pageRoute(id))
    await expect(trigger(owner).getByLabel('未读评论', { exact: true })).toHaveText('1')
    await trigger(owner).click()
    const thread = comments(owner).locator('.pod-comment-thread').first()
    await expect(thread).toHaveAttribute('data-thread-id', threadID)
    await expect(thread.getByText('Answer delivered while the owner was away', { exact: true })).toBeVisible()
    await thread.locator('.pod-comment-entry').first().getByRole('button', { name: '更多操作', exact: true }).click()
    await owner.getByRole('menuitem', { name: '复制评论链接', exact: true }).click()
    await expect.poll(() => owner.evaluate(() => navigator.clipboard.readText())).toContain(`commentId=${threadID}`)
    const link = await owner.evaluate(() => navigator.clipboard.readText())
    await owner.goto(link)
    await expect(comments(owner).locator(`[data-thread-id="${threadID}"]`)).toHaveAttribute('data-focused', 'true')
    await comments(owner).getByRole('button', { name: '全部标为已读', exact: true }).click()
    await expect(trigger(owner).getByLabel('未读评论', { exact: true })).toHaveCount(0)
    await owner.reload()
    await expect(comments(owner).locator(`[data-thread-id="${threadID}"]`)).toBeVisible()
    await expect(trigger(owner).getByLabel('未读评论', { exact: true })).toHaveCount(0)
    await owner.screenshot({ path: info.outputPath('comments-read-link.png') })
  } finally {
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await ownerContext.close()
    await memberContext.close()
  }
})

test('overlapping discussions stay selectable, resolved highlights retire, and mobile readers can locate and reanchor', async ({
  browser
}, info) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    id = await create(page, 'Comment locations')
    await editor(page).locator('p').first().click()
    await page.keyboard.insertText('Review this paragraph')
    await expect
      .poll(async () => (await request<{ content: { plain_text: string } }>(page, `/pages/${id}`)).content.plain_text)
      .toBe('Review this paragraph')
    for (const body of ['First concern', 'Second concern']) {
      await selectParagraph(page, 'Review this paragraph')
      await page.locator('.selection-toolbar').getByRole('button', { name: '评论', exact: true }).click()
      await addComment(page, body)
      await comments(page).getByRole('button', { name: '关闭', exact: true }).click()
    }
    const { threads } = await request<{ threads: { id: string; body: string }[] }>(page, `/pages/${id}/comments`)
    const firstID = threads.find(thread => thread.body === 'First concern')!.id
    const secondID = threads.find(thread => thread.body === 'Second concern')!.id
    await editor(page).locator('[data-comment-ids]').first().click()
    await expect(comments(page).getByText('此处的评论 · 2', { exact: true })).toBeVisible()
    await expect(comments(page).locator('.pod-comment-thread')).toHaveCount(2)
    await comments(page)
      .locator(`[data-thread-id="${firstID}"]`)
      .getByRole('button', { name: '解决', exact: true })
      .click()
    await expect(editor(page).locator('[data-comment-ids]')).toHaveAttribute('data-comment-ids', secondID)
    await comments(page).getByRole('button', { name: '关闭', exact: true }).click()
    await editor(page).locator('[data-comment-ids]').click()
    await expect(comments(page).locator(`[data-thread-id="${secondID}"]`)).toHaveAttribute('data-focused', 'true')
    await comments(page).getByRole('button', { name: '关闭', exact: true }).click()

    await page.setViewportSize({ width: 375, height: 812 })
    await editor(page).locator('[data-comment-ids]').click()
    const mobile = page.getByRole('dialog', { name: '评论', exact: true })
    const thread = mobile.locator(`[data-thread-id="${secondID}"]`)
    await expect(thread).toBeVisible()
    await thread.getByRole('button', { name: 'Review this paragraph', exact: true }).click()
    await expect(mobile).toHaveCount(0)
    await expect(editor(page)).toBeFocused()
    await expect.poll(() => page.evaluate(() => getSelection()?.toString())).toBe('Review this paragraph')
    await page.getByRole('button', { name: '返回评论', exact: true }).click()
    await expect(thread).toHaveAttribute('data-focused', 'true')
    await thread.getByRole('button', { name: 'Review this paragraph', exact: true }).click()
    await expect(mobile).toHaveCount(0)
    await expect(editor(page)).toBeFocused()
    await expect.poll(() => page.evaluate(() => getSelection()?.toString())).toBe('Review this paragraph')
    await page.keyboard.press('Backspace')
    await page.keyboard.insertText('Replacement passage')
    await expect
      .poll(async () => (await request<{ content: { plain_text: string } }>(page, `/pages/${id}`)).content.plain_text)
      .toBe('Replacement passage')
    await page.getByRole('button', { name: '返回评论', exact: true }).click()
    await expect(thread.getByText('原文已删除', { exact: true })).toBeVisible()
    await thread.getByRole('button', { name: '重新定位到所选文字', exact: true }).click()
    await expect(mobile).toHaveCount(0)
    await selectParagraph(page, 'Replacement passage')
    await page.locator('.selection-toolbar').getByRole('button', { name: '评论', exact: true }).click()
    await expect(thread).toHaveAttribute('data-focused', 'true')
    await thread.getByRole('button', { name: '重新定位到所选文字', exact: true }).click()
    await expect(thread.getByText('原文已删除', { exact: true })).toHaveCount(0)
    await page.screenshot({ path: info.outputPath('comments-mobile-reanchored.png') })
    await thread.getByRole('button', { name: '解决', exact: true }).click()
    await mobile.getByRole('button', { name: '关闭', exact: true }).click()
    await expect(editor(page).locator('[data-comment-ids]')).toHaveCount(0)
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})
