import { state, request as podRequest } from './fixtures'
import { readFileSync } from 'node:fs'
import { expect, test, type Page } from '@playwright/test'
import { uuidV4 } from '@agentbull/active-support'
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
  for (const input of detail.pendingQueues.flatMap(queue => queue.inputs)) {
    detail = await request(page, `/conversations/${id}/queue`, 'POST', {
      action: 'retract',
      messageID: input.messageID,
      agentUID: input.agentUID,
      expectedVersion: detail.pendingQueues.find(queue => queue.agentUID === input.agentUID)!.queueVersion
    })
  }
}

const defaultFiles = [
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
]

async function createChat(page: Page, files = defaultFiles) {
  await page.goto('/')
  const group = await request(page, '/conversations', 'POST', {
    conversationID: uuidV4(),
    messageID: uuidV4(),
    roomMode: 'group',
    agentUIDs: [state.agent_uid],
    participantUIDs: [state.member.uid],
    text: 'Attachment preview browser fixture'
  })
  await page.goto(conversationRoute(group.conversation.id))
  const composer = page.locator('.pod-chat-composer')
  const choose = page.waitForEvent('filechooser')
  await composer.getByRole('button', { name: '添加文件', exact: true }).click()
  await (await choose).setFiles(files)
  await expect(composer.getByRole('status')).toHaveText(files.map(() => '已就绪'))
  await composer.getByRole('textbox', { name: '消息', exact: true }).fill('Attachment preview browser fixture')
  const sent = page.waitForResponse(
    response =>
      response.request().method() === 'POST' &&
      new URL(response.url()).pathname === `/api/v2/pod/conversations/${group.conversation.id}/messages`
  )
  await composer.getByRole('button', { name: '发送消息', exact: true }).click()
  const detail = (await (await sent).json()) as ConversationDetail
  await page.goto(conversationRoute(detail.conversation.id))
  return detail.conversation.id
}

test('real frozen attachments preview in the room sidebar with bounded text, escaped markup, focus and Escape', async ({
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
    // Keep the real HTTP adapter: the first read requests a missing attachment position.
    await page.route('**/api/v2/pod/conversations/*/attachments/**', async route => {
      const url = new URL(route.request().url())
      if (url.searchParams.get('position') === String(attachment.position) && reads++ === 0) {
        url.searchParams.set('position', '999')
        return route.continue({ url: url.toString() })
      }
      return route.continue()
    })
    const read = page.waitForRequest(
      request =>
        request.url().includes('/attachments/') &&
        new URL(request.url()).searchParams.get('position') === String(attachment.position)
    )
    const rejected = page.waitForResponse(
      response => response.url().includes('/attachments/') && response.status() === 404
    )
    await trigger.click()
    const previewRequest = await read
    expect(new URL(previewRequest.url()).searchParams.get('authentication_ref')).toBe(expectedIdentity)
    expect(previewRequest.headers()['x-ankole-authentication']).toBe(expectedIdentity)
    const dialog = page.getByRole('complementary', { name: 'preview-note.txt', exact: true })
    await expect(dialog.locator('.pod-chat-file-panel-body')).toBeFocused()
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
    // The sidebar is not modal: Tab leaves it for the rest of the room, and Escape closes it from inside.
    await dialog.locator('.pod-chat-file-panel-body').focus()
    await page.keyboard.press('Escape')
    await expect(dialog).toHaveCount(0)
    await expect(trigger).toBeFocused()
    await expect(composer).toHaveValue('Unsent continuation')
    await expect(page).toHaveURL(state.base_url + conversationRoute(id))

    await page.getByRole('button', { name: fileLabel('预览', 'preview-markup.html') }).click()
    const markup = page.getByRole('complementary', { name: 'preview-markup.html', exact: true })
    await expect(markup.locator('pre')).toHaveText('<script>window.previewExecuted = true</script>')
    expect(await page.evaluate(() => 'previewExecuted' in window)).toBe(false)
    await page.keyboard.press('Escape')

    const imageTrigger = page.getByRole('button', { name: fileLabel('预览', 'preview-image.png') })
    await imageTrigger.click()
    const imageDialog = page.getByRole('complementary', { name: 'preview-image.png', exact: true })
    const image = imageDialog.getByRole('img', { name: 'preview-image.png', exact: true })
    await expect.poll(() => image.evaluate(element => (element as HTMLImageElement).naturalWidth)).toBeGreaterThan(0)
    const blob = (await image.getAttribute('src'))!
    expect(blob).toMatch(/^blob:/)
    const viewport = imageDialog.getByRole('region', { name: 'preview-image.png', exact: true })
    await imageDialog.getByRole('button', { name: '放大', exact: true }).click()
    await expect(imageDialog.getByRole('toolbar')).toContainText('150%')
    expect(await viewport.evaluate(element => element.scrollWidth > element.clientWidth)).toBe(true)
    await viewport.focus()
    await viewport.press('+')
    await expect(imageDialog.getByRole('toolbar')).toContainText('200%')
    const box = (await viewport.boundingBox())!
    const imageStart = (await image.boundingBox())!
    await page.mouse.move(box.x + box.width * 0.7, box.y + box.height / 2)
    await page.mouse.down()
    await page.mouse.move(box.x + box.width * 0.3, box.y + box.height / 2, { steps: 5 })
    await page.mouse.up()
    await expect.poll(async () => (await image.boundingBox())!.x).toBeLessThan(imageStart.x - box.width * 0.3)
    await viewport.press('0')
    await expect(imageDialog.getByRole('toolbar')).toContainText('100%')
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

test('a wide room narrows its chat to a 300px column beside the file sidebar and restores it on close', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1440, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    id = await createChat(page, [defaultFiles[0]!])
    const body = page.locator('.pod-chat-room-body')
    const chat = body.locator('> .pod-chat-room-main')
    const roomWidth = (await body.boundingBox())!.width
    expect((await chat.boundingBox())!.width).toBeCloseTo(roomWidth, 0)
    const trigger = page.getByRole('button', { name: fileLabel('预览', 'preview-note.txt') })
    await trigger.click()
    const panel = page.getByRole('complementary', { name: 'preview-note.txt', exact: true })
    await expect(panel.locator('pre')).toContainText('Preview prefix')
    await expect.poll(async () => Math.round((await chat.boundingBox())!.width)).toBe(300)
    await expect.poll(async () => Math.round((await panel.boundingBox())!.width)).toBe(Math.round(roomWidth - 300))
    await panel.getByRole('button', { name: '关闭', exact: true }).click()
    await expect(panel).toHaveCount(0)
    await expect.poll(async () => Math.round((await chat.boundingBox())!.width)).toBe(Math.round(roomWidth))
  } finally {
    if (id) {
      await clearPending(page, id)
      await request(page, `/conversations/${id}`, 'DELETE')
    }
    page.on('dialog', dialog => dialog.accept())
    await context.close()
  }
})

test('frozen CSV and Markdown attachments preview as a UTF-8 table and as rendered Markdown', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 900, height: 800 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    // An empty browser type reaches the control plane as `application/octet-stream`, so the file name decides.
    id = await createChat(page, [
      { name: 'quotes.csv', mimeType: '', buffer: Buffer.from('名称,涨跌幅\n贵州茅台,"1,2%"\n宁德时代,-0.5%\n') },
      {
        name: 'review.md',
        mimeType: 'text/markdown',
        buffer: Buffer.from('# 季度复盘\n\n- **营收**增长\n\n| 指标 | 数值 |\n| --- | --- |\n| 毛利率 | 52% |\n')
      }
    ])
    const tableTrigger = page.getByRole('button', { name: fileLabel('预览', 'quotes.csv') })
    await tableTrigger.click()
    const table = page.getByRole('complementary', { name: 'quotes.csv', exact: true })
    await expect(table.getByRole('columnheader', { name: '涨跌幅', exact: true })).toBeVisible()
    await expect(table.getByRole('cell', { name: '贵州茅台', exact: true })).toBeVisible()
    await expect(table.getByRole('cell', { name: '1,2%', exact: true })).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(table).toHaveCount(0)
    await expect(tableTrigger).toBeFocused()

    await page.getByRole('button', { name: fileLabel('预览', 'review.md') }).click()
    const markdown = page.getByRole('complementary', { name: 'review.md', exact: true })
    await expect(markdown.getByRole('heading', { level: 1, name: '季度复盘', exact: true })).toBeVisible()
    await expect(markdown.locator('strong')).toHaveText('营收')
    await expect(markdown.getByRole('cell', { name: '52%', exact: true })).toBeVisible()
    await expect(markdown.locator('pre')).toHaveCount(0)
    await page.keyboard.press('Escape')
    await expect(markdown).toHaveCount(0)
  } finally {
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
    const matches = (url: string) =>
      url.includes('/attachments/') && new URL(url).searchParams.get('position') === String(attachment.position)
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
    const dialog = page.getByRole('complementary', { name: 'preview-note.txt', exact: true })
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
    await expect(page).toHaveURL(`${state.base_url}/`)
    await expect(trigger).toHaveCount(0)
    await expect(page.getByRole('textbox', { name: '消息', exact: true })).toHaveValue('')
    await expect(page.getByRole('button', { name: '发送消息', exact: true })).toBeDisabled()
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

test('local text, image, and unsupported-file previews keep unsent text and selected files in the composer', async ({
  browser
}) => {
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
      { name: 'local-image.png', mimeType: 'image/png', buffer: png },
      { name: 'local-bundle.zip', mimeType: 'application/zip', buffer: Buffer.from('PK\u0005\u0006') }
    ])
    await expect(composer.getByRole('status')).toHaveText(['已就绪', '已就绪', '已就绪'])
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
    const bundleTrigger = composer.getByRole('button', { name: fileLabel('预览', 'local-bundle.zip') })
    await bundleTrigger.click()
    const bundle = page.getByRole('dialog', { name: 'local-bundle.zip', exact: true })
    await expect(bundle.getByText('无法在此预览该文件。可在新标签页打开或下载原文件。', { exact: true })).toBeVisible()
    await expect(bundle.getByRole('link', { name: '下载原文件', exact: true })).toHaveAttribute(
      'download',
      'local-bundle.zip'
    )
    await page.keyboard.press('Escape')
    await expect(bundle).toHaveCount(0)
    await expect(bundleTrigger).toBeFocused()
    await expect(message).toHaveValue('Keep my unsent draft')
    await expect(composer.getByRole('button', { name: fileLabel('预览', 'local-note.txt') })).toBeVisible()
    await expect(composer.getByRole('button', { name: fileLabel('预览', 'local-image.png') })).toBeVisible()
    await composer.getByRole('button', { name: fileLabel('移除', 'local-note.txt') }).click()
    await composer.getByRole('button', { name: fileLabel('移除', 'local-image.png') }).click()
    await composer.getByRole('button', { name: fileLabel('移除', 'local-bundle.zip') }).click()
    await message.clear()
  } finally {
    page.on('dialog', dialog => dialog.accept())
    await context.close()
  }
})

test('a PDF draft shows its upload progress and its size, and opens in the viewer', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 900, height: 800 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  // pdf.js rebuilds the cross-reference table that this one-page file leaves out.
  const pdf = Buffer.from(
    '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n' +
      '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n'
  )
  try {
    await page.goto('/')
    const composer = page.locator('.pod-chat-composer')
    let release!: () => void
    const held = new Promise<void>(resolve => {
      release = resolve
    })
    // Keep the real upload adapter and hold its request so the uploading state stays on screen.
    await page.route('**/api/v2/pod/attachments', async route => {
      await held
      await route.continue()
    })
    const choose = page.waitForEvent('filechooser')
    await composer.getByRole('button', { name: '添加文件', exact: true }).click()
    await (await choose).setFiles([{ name: 'first-page.pdf', mimeType: 'application/pdf', buffer: pdf }])
    const remove = composer.getByRole('button', { name: fileLabel('移除', 'first-page.pdf') })
    await expect(composer.getByRole('status')).toHaveText('正在上传')
    await expect(remove.getByRole('progressbar', { includeHidden: true })).toBeVisible()
    release()
    await expect(composer.getByRole('status')).toHaveText('已就绪')
    await expect(remove.getByRole('progressbar', { includeHidden: true })).toHaveCount(0)
    await expect(composer.getByText(`${pdf.byteLength} B`)).toBeVisible()
    // The card marks the file by its extension, and the preview dialog draws it in the PDF viewer.
    await expect(
      composer.getByRole('button', { name: fileLabel('预览', 'first-page.pdf') }).locator('img')
    ).toHaveCount(0)
    await composer.getByRole('button', { name: fileLabel('预览', 'first-page.pdf') }).click()
    const dialog = page.getByRole('dialog')
    await expect(dialog.getByText('1 / 1')).toBeVisible()
    await expect(dialog.locator('.pdfViewer canvas')).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(dialog).toHaveCount(0)
    await remove.click()
  } finally {
    await page.unrouteAll({ behavior: 'wait' })
    await context.close()
  }
})
