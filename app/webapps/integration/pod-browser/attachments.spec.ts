import { readFileSync } from 'node:fs'
import { expect, test, type BrowserContext, type Page, type Request } from '@playwright/test'
import { conversationRoute, pageRoute } from './routes'
import type { ConversationDetail } from '../../common/api/generated/types.gen'

const state = JSON.parse(readFileSync(process.env.POD_BROWSER_STATE_PATH!, 'utf8')) as {
  base_url: string
  report_id: string
  owner: { cookies: Parameters<BrowserContext['addCookies']>[0] }
}
const imageBytes = readFileSync(
  new URL('../../../control_plane/test/fixtures/sessions/rgba.png', import.meta.url)
).toString('base64')

function fileLabel(action: string, name: string): RegExp {
  const escape = (value: string) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const file = escape(name)
  return new RegExp(`^${escape(action)} (?:${file}|[\u2066-\u2068]${file}\u2069)$`)
}

async function request(page: Page, path: string, method = 'GET', body?: unknown): Promise<ConversationDetail> {
  return page.evaluate(
    async ({ path, method, body }) => {
      const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content ?? ''
      const response = await fetch(`/.internal-apis/pod${path}`, {
        method,
        credentials: 'same-origin',
        headers: {
          accept: 'application/json',
          'content-type': 'application/json',
          'x-ankole-authentication': meta('ankole-authentication'),
          'x-ankole-pod': meta('ankole-pod'),
          'x-csrf-token': meta('csrf-token')
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) })
      })
      if (!response.ok) throw new Error(`Attachment test ${method} ${path}: ${response.status}`)
      return response.status === 204 ? null : response.json()
    },
    { path, method, body }
  )
}

async function removeConversation(page: Page, id: string | undefined) {
  if (!id) return
  let detail = await request(page, `/conversations/${id}`)
  for (const input of detail.pendingInputs) {
    detail = await request(page, `/conversations/${id}/queue`, 'POST', {
      action: 'remove',
      messageID: input.messageID,
      expectedVersion: detail.queueVersion
    })
  }
  await request(page, `/conversations/${id}`, 'DELETE')
}

function uploadID(request: Request) {
  return request
    .postDataBuffer()
    ?.toString()
    .match(/name="fileID"\r\n\r\n([^\r]+)/)?.[1]
}

test('file preparation and an uncertain send retain stable identities through panel close, retry and refresh', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const gate = Promise.withResolvers<void>()
  const started = Promise.withResolvers<void>()
  const uploadIDs: (string | undefined)[] = []
  const messageIDs: string[] = []
  let id: string | undefined
  try {
    await page.goto(pageRoute(state.report_id))
    await page.getByRole('button', { name: '页面对话', exact: true }).click()
    const panel = page.getByRole('complementary', { name: '页面对话', exact: true })
    await panel.getByRole('button', { name: '新对话', exact: true }).click()
    const composer = panel.locator('.pod-chat-composer')
    await page.route('**/.internal-apis/pod/attachments', async route => {
      uploadIDs.push(uploadID(route.request()))
      if (uploadIDs.length === 1)
        return route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: { code: 'upload_unavailable', message: 'Upload unavailable' } })
        })
      started.resolve()
      await gate.promise
      await route.continue()
    })
    const choose = page.waitForEvent('filechooser')
    await composer.getByRole('button', { name: '添加文件', exact: true }).click()
    await (
      await choose
    ).setFiles({ name: '季度说明.txt', mimeType: 'text/plain', buffer: Buffer.from('Original Human file contents') })
    await expect(composer.getByRole('alert')).toHaveText('上传失败，请重试')
    await composer.getByRole('button', { name: fileLabel('重试上传', '季度说明.txt') }).click()
    await started.promise
    await panel.getByRole('button', { name: '关闭页面对话', exact: true }).click()
    gate.resolve()
    await page.getByRole('button', { name: '页面对话', exact: true }).click()
    await expect(composer.getByRole('status')).toHaveText('已就绪')
    expect(uploadIDs[0]).toBeTruthy()
    expect(uploadIDs[1]).toBe(uploadIDs[0])
    await composer.getByRole('textbox', { name: '消息', exact: true }).fill('请读取上传的说明')
    await page.route('**/.internal-apis/pod/conversations', async route => {
      if (route.request().method() !== 'POST') return route.continue()
      const body = route.request().postDataJSON()
      messageIDs.push(body.messageID)
      const response = await route.fetch()
      id = (await response.json()).conversation.id
      if (messageIDs.length === 1)
        return route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: { code: 'message_unavailable', message: 'Message unavailable' } })
        })
      await route.fulfill({ response })
    })
    await composer.getByRole('button', { name: '发送消息', exact: true }).click()
    await expect(panel.getByRole('button', { name: '重试发送', exact: true })).toBeVisible()
    await expect(composer.getByRole('link', { name: fileLabel('下载', '季度说明.txt') })).toBeVisible()
    await panel.getByRole('button', { name: '重试发送', exact: true }).click()
    await expect.poll(() => messageIDs.length).toBe(2)
    expect(messageIDs[1]).toBe(messageIDs[0])
    await expect(composer.getByRole('link', { name: fileLabel('下载', '季度说明.txt') })).toHaveCount(0)
    await page.goto(conversationRoute(id!))
    await page.reload()
    const download = page.getByRole('link', { name: fileLabel('下载', '季度说明.txt') })
    await expect(download).toHaveCount(1)
    const href = (await download.getAttribute('href'))!
    const contents = await page.evaluate(async href => (await fetch(href, { credentials: 'same-origin' })).text(), href)
    expect(contents).toBe('Original Human file contents')
    const detail = await request(page, `/conversations/${id}`)
    expect(detail.messages.filter(message => message.id === messageIDs[0])).toHaveLength(1)
    expect(detail.messages.find(message => message.id === messageIDs[0])!.attachments).toHaveLength(1)
  } finally {
    gate.resolve()
    await page.unrouteAll({ behavior: 'wait' })
    await removeConversation(page, id)
    page.on('dialog', dialog => dialog.accept())
    await context.close()
  }
})

test('paste previews a real image, removal clears it, and dropping a file sends an attachment-only message', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 390, height: 844 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto('/')
    const composer = page.locator('.pod-chat-composer')
    await expect(composer.getByRole('textbox', { name: '消息', exact: true })).toBeVisible()
    await composer.evaluate((element, base64) => {
      const bytes = Uint8Array.from(atob(base64), value => value.charCodeAt(0))
      const transfer = new DataTransfer()
      transfer.items.add(new File([bytes], 'pasted.png', { type: 'image/png' }))
      element.dispatchEvent(new ClipboardEvent('paste', { clipboardData: transfer, bubbles: true, cancelable: true }))
    }, imageBytes)
    const image = composer.getByRole('img', { name: 'pasted.png', exact: true })
    await expect(image).toBeVisible()
    await expect.poll(() => image.evaluate(image => (image as HTMLImageElement).naturalWidth)).toBeGreaterThan(0)
    await expect(composer.getByRole('status')).toHaveText('已就绪')
    await composer.getByRole('button', { name: fileLabel('移除', 'pasted.png') }).click()
    await expect(image).toHaveCount(0)
    await expect(composer.getByRole('button', { name: '发送消息', exact: true })).toBeDisabled()
    await composer.evaluate(element => {
      const transfer = new DataTransfer()
      transfer.items.add(new File(['Dropped file body'], 'dropped.txt', { type: 'text/plain' }))
      element.dispatchEvent(new DragEvent('drop', { dataTransfer: transfer, bubbles: true, cancelable: true }))
    })
    await expect(composer.getByRole('status')).toHaveText('已就绪')
    const sent = page.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === '/.internal-apis/pod/conversations'
    )
    await composer.getByRole('button', { name: '发送消息', exact: true }).click()
    const detail = await (await sent).json()
    id = detail.conversation.id
    expect(detail.conversation.title).toBe('dropped.txt')
    expect(detail.messages[0].text).toBe('')
    expect(detail.messages[0].attachments).toHaveLength(1)
    await expect(composer.getByRole('link', { name: fileLabel('下载', 'dropped.txt') })).toHaveCount(0)
    await expect(page).toHaveURL(url => url.pathname === conversationRoute(id!))
    await page.reload()
    const download = page.getByRole('link', { name: fileLabel('下载', 'dropped.txt') })
    await expect(download).toHaveCount(1)
    expect(await page.evaluate(async href => (await fetch(href!)).text(), await download.getAttribute('href'))).toBe(
      'Dropped file body'
    )
    const bounds = await download.boundingBox()
    expect(bounds!.x).toBeGreaterThanOrEqual(0)
    expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(390)
  } finally {
    await removeConversation(page, id)
    page.on('dialog', dialog => dialog.accept())
    await context.close()
  }
})
