import { state, request as podRequest } from './fixtures'
import { readFileSync } from 'node:fs'
import { expect, test, type Page } from '@playwright/test'
import type { ConversationDetail } from '../../pod/api'
import { conversationRoute } from './routes'

const png = readFileSync(new URL('../../../control_plane/test/fixtures/sessions/rgba.png', import.meta.url))

function fileLabel(action: string, name: string) {
  const file = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(`^${action} (?:${file}|[\u2066-\u2068]${file}\u2069)$`)
}

async function request<T = ConversationDetail>(page: Page, path: string, method = 'GET', body?: unknown): Promise<T> {
  return podRequest(page, path, method, body)
}

async function clearPending(page: Page, id: string) {
  let detail = await request(page, `/conversations/${id}`)
  for (const input of detail.pendingInputs) {
    detail = await request(page, `/conversations/${id}/queue`, 'POST', {
      action: 'remove',
      messageID: input.messageID,
      expectedVersion: detail.queueVersion
    })
  }
}

async function createChat(page: Page) {
  await page.goto('/')
  const composer = page.locator('.pod-chat-composer')
  const choose = page.waitForEvent('filechooser')
  await composer.getByRole('button', { name: '添加文件', exact: true }).click()
  await (
    await choose
  ).setFiles([
    {
      name: 'preview-note.txt',
      mimeType: 'text/plain',
      buffer: Buffer.from(`Preview prefix\n${'x'.repeat(200_000)}\nUNREAD TAIL`)
    },
    { name: 'preview-image.png', mimeType: 'image/png', buffer: png },
    {
      name: 'preview-markup.html',
      mimeType: 'text/html',
      buffer: Buffer.from('<script>window.previewExecuted = true</script>')
    }
  ])
  await expect(composer.getByRole('status')).toHaveText(['已就绪', '已就绪', '已就绪'])
  await composer.getByRole('textbox', { name: '消息', exact: true }).fill('Attachment preview browser fixture')
  const sent = page.waitForResponse(
    response =>
      response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/conversations'
  )
  await composer.getByRole('button', { name: '发送消息', exact: true }).click()
  const detail = (await (await sent).json()) as ConversationDetail
  await page.goto(conversationRoute(detail.conversation.id))
  return detail.conversation.id
}

test('real frozen attachments preview in the same chat with bounded text, escaped markup, focus and Escape', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 900, height: 800 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    id = await createChat(page)
    const composer = page.locator('.pod-chat-composer').getByRole('textbox', { name: '消息', exact: true })
    await composer.fill('Unsent continuation')
    const attachment = (await request(page, `/conversations/${id}`)).messages
      .flatMap(message => message.attachments)
      .find(attachment => attachment.name === 'preview-note.txt')!
    const trigger = page.getByRole('button', { name: fileLabel('预览', 'preview-note.txt') })
    const expectedIdentity = await page.locator('meta[name="ankole-authentication"]').getAttribute('content')
    let reads = 0
    // Keep the real HTTP adapter: the first read reaches the server with a missing path.
    await page.route('**/api/v2/pod/conversations/*/attachments/**', async route => {
      const url = new URL(route.request().url())
      if (url.searchParams.get('path') === attachment.path && reads++ === 0) {
        url.searchParams.set('path', 'missing-preview-file.txt')
        return route.continue({ url: url.toString() })
      }
      return route.continue()
    })
    const read = page.waitForRequest(request => new URL(request.url()).searchParams.get('path') === attachment.path)
    const rejected = page.waitForResponse(
      response => response.url().includes('/attachments/') && response.status() === 404
    )
    await trigger.click()
    const previewRequest = await read
    expect(new URL(previewRequest.url()).searchParams.get('authentication_ref')).toBe(expectedIdentity)
    expect(previewRequest.headers()['x-ankole-authentication']).toBe(expectedIdentity)
    const dialog = page.getByRole('dialog', { name: 'preview-note.txt', exact: true })
    await expect(dialog.locator('.pod-dialog-body')).toBeFocused()
    expect((await rejected).status()).toBe(404)
    await expect(dialog.getByRole('alert')).toBeVisible()
    await dialog.getByRole('button', { name: '重试', exact: true }).click()
    await expect(dialog.locator('pre')).toContainText('Preview prefix')
    await expect(dialog.getByRole('status')).toHaveText('仅预览文件开头。下载原文件以查看全部内容。')
    expect(await dialog.locator('pre').textContent()).not.toContain('UNREAD TAIL')
    expect((await dialog.locator('pre').textContent())!.length).toBeLessThanOrEqual(64 * 1024)
    const retryFocus = await dialog.evaluate(element => ({
      withinDialog: element.contains(document.activeElement),
      tag: document.activeElement?.tagName,
      role: document.activeElement?.getAttribute('role'),
      label: document.activeElement?.getAttribute('aria-label'),
      text: document.activeElement?.textContent?.slice(0, 80)
    }))
    await test.info().attach('attachment-preview-retry-focus', {
      body: JSON.stringify(retryFocus),
      contentType: 'application/json'
    })
    expect(retryFocus.withinDialog).toBe(true)
    await expect(dialog.getByRole('link', { name: '下载原文件', exact: true })).toBeInViewport()
    await expect(dialog.getByRole('link', { name: '在新标签页打开', exact: true })).toHaveAttribute('target', '_blank')
    for (let tab = 0; tab < 6; tab++) {
      await page.keyboard.press('Tab')
      const tabFocus = await dialog.evaluate(element => ({
        withinDialog: element.contains(document.activeElement),
        tag: document.activeElement?.tagName,
        role: document.activeElement?.getAttribute('role'),
        label: document.activeElement?.getAttribute('aria-label'),
        focusGuard: document.activeElement?.getAttribute('data-base-ui-focus-guard'),
        guardType: document.activeElement?.getAttribute('data-type')
      }))
      if (!tabFocus.withinDialog) {
        await test.info().attach('attachment-preview-tab-focus', {
          body: JSON.stringify(tabFocus),
          contentType: 'application/json'
        })
      }
      // Base UI moves its inside focus guard back to content on the next animation frame.
      if (!tabFocus.withinDialog) {
        expect(tabFocus.focusGuard).not.toBeNull()
        expect(tabFocus.guardType).toBe('inside')
      }
      await expect.poll(() => dialog.evaluate(element => element.contains(document.activeElement))).toBe(true)
    }
    await page.keyboard.press('Escape')
    await expect(dialog).toHaveCount(0)
    await expect(trigger).toBeFocused()
    await expect(composer).toHaveValue('Unsent continuation')
    await expect(page).toHaveURL(state.base_url + conversationRoute(id))

    await page.getByRole('button', { name: fileLabel('预览', 'preview-markup.html') }).click()
    const markup = page.getByRole('dialog', { name: 'preview-markup.html', exact: true })
    await expect(markup.locator('pre')).toHaveText('<script>window.previewExecuted = true</script>')
    expect(await page.evaluate(() => 'previewExecuted' in window)).toBe(false)
    await page.keyboard.press('Escape')

    const imageTrigger = page.getByRole('button', { name: fileLabel('预览', 'preview-image.png') })
    await imageTrigger.click()
    const imageDialog = page.getByRole('dialog', { name: 'preview-image.png', exact: true })
    const image = imageDialog.getByRole('img', { name: 'preview-image.png', exact: true })
    await expect.poll(() => image.evaluate(element => (element as HTMLImageElement).naturalWidth)).toBeGreaterThan(0)
    const blob = (await image.getAttribute('src'))!
    expect(blob).toMatch(/^blob:/)
    await page.keyboard.press('Escape')
    await expect(imageDialog).toHaveCount(0)
    await expect(imageTrigger).toBeFocused()
    expect(
      await page.evaluate(
        async url =>
          fetch(url).then(
            () => true,
            () => false
          ),
        blob
      )
    ).toBe(false)
    await composer.clear()
  } finally {
    await page.unrouteAll({ behavior: 'wait' })
    if (id) {
      await clearPending(page, id)
      await request(page, `/conversations/${id}`, 'DELETE')
    }
    page.on('dialog', dialog => dialog.accept())
    await context.close()
  }
})

test('closing a pending preview aborts its request, and removing its owning message releases it before deletion', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const gate = Promise.withResolvers<void>()
  const started = Promise.withResolvers<void>()
  let failed = 0
  let id: string | undefined
  try {
    id = await createChat(page)
    const attachment = (await request(page, `/conversations/${id}`)).messages
      .flatMap(message => message.attachments)
      .find(attachment => attachment.name === 'preview-note.txt')!
    expect(attachment).toBeTruthy()
    const matches = (url: string) => new URL(url).searchParams.get('path') === attachment.path
    page.on('requestfailed', request => {
      if (matches(request.url())) failed++
    })
    await page.route('**/api/v2/pod/conversations/*/attachments/**', async route => {
      if (!matches(route.request().url())) return route.continue()
      started.resolve()
      await gate.promise
      await route.continue().catch(() => undefined)
    })
    const trigger = page.getByRole('button', { name: fileLabel('预览', 'preview-note.txt') })
    await trigger.click()
    await started.promise
    const dialog = page.getByRole('dialog', { name: 'preview-note.txt', exact: true })
    await expect(dialog.getByRole('status')).toHaveText('正在加载文件…')
    await page.keyboard.press('Escape')
    await expect(dialog).toHaveCount(0)
    await expect(trigger).toBeFocused()
    gate.resolve()
    await page.unrouteAll({ behavior: 'wait' })
    await expect.poll(() => failed).toBe(1)
    await trigger.click()
    await expect(dialog.locator('pre')).toContainText('Preview prefix')
    await clearPending(page, id)
    await expect(dialog).toHaveCount(0)
    await request(page, `/conversations/${id}`, 'DELETE')
    id = undefined
    await expect(dialog).toHaveCount(0)
    await expect(page.getByRole('button', { name: '发送消息', exact: true })).toHaveCount(0)
  } finally {
    gate.resolve()
    await page.unrouteAll({ behavior: 'wait' })
    if (id) {
      await clearPending(page, id)
      await request(page, `/conversations/${id}`, 'DELETE')
    }
    await context.close()
  }
})

test('local text and image previews keep unsent text and selected files in the composer', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 390, height: 844 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto('/')
    const composer = page.locator('.pod-chat-composer')
    const message = composer.getByRole('textbox', { name: '消息', exact: true })
    await message.fill('Keep my unsent draft')
    const choose = page.waitForEvent('filechooser')
    await composer.getByRole('button', { name: '添加文件', exact: true }).click()
    await (
      await choose
    ).setFiles([
      { name: 'local-note.txt', mimeType: 'text/plain', buffer: Buffer.from('Local draft attachment') },
      { name: 'local-image.png', mimeType: 'image/png', buffer: png }
    ])
    await expect(composer.getByRole('status')).toHaveText(['已就绪', '已就绪'])
    const textTrigger = composer.getByRole('button', { name: fileLabel('预览', 'local-note.txt') })
    await textTrigger.click()
    const text = page.getByRole('dialog', { name: 'local-note.txt', exact: true })
    await expect(text.locator('pre')).toHaveText('Local draft attachment')
    await expect(text).toBeInViewport({ ratio: 1 })
    await expect(text.getByRole('link', { name: '下载原文件', exact: true })).toBeInViewport()
    await page.keyboard.press('Escape')
    await expect(text).toHaveCount(0)
    await expect(textTrigger).toBeFocused()
    await composer.getByRole('button', { name: fileLabel('预览', 'local-image.png') }).click()
    const image = page.getByRole('dialog', { name: 'local-image.png', exact: true })
    await expect
      .poll(() =>
        image
          .getByRole('img', { name: 'local-image.png', exact: true })
          .evaluate(element => (element as HTMLImageElement).naturalWidth)
      )
      .toBeGreaterThan(0)
    await page.keyboard.press('Escape')
    await expect(image).toHaveCount(0)
    await expect(message).toHaveValue('Keep my unsent draft')
    await expect(composer.getByRole('link', { name: fileLabel('下载', 'local-note.txt') })).toBeVisible()
    await expect(composer.getByRole('link', { name: fileLabel('下载', 'local-image.png') })).toBeVisible()
    await composer.getByRole('button', { name: fileLabel('移除', 'local-note.txt') }).click()
    await composer.getByRole('button', { name: fileLabel('移除', 'local-image.png') }).click()
    await message.clear()
  } finally {
    page.on('dialog', dialog => dialog.accept())
    await context.close()
  }
})
