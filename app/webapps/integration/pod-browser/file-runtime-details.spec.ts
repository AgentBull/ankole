import { pageRoute } from './routes'
import { readFileSync } from 'node:fs'
import { expect, test, type BrowserContext, type Page } from '@playwright/test'

const state = JSON.parse(readFileSync(process.env.POD_BROWSER_STATE_PATH!, 'utf8')) as {
  base_url: string
  tenant_id: string
  report_id: string
  runtime_test_applet_id: string
  publish_v2_files: unknown[]
  owner: { uid: string; cookies: Parameters<BrowserContext['addCookies']>[0] }
  viewer: { cookies: Parameters<BrowserContext['addCookies']>[0] }
}
const location = (id: string) => `${state.base_url}${pageRoute(id)}`
type Manifest = { revision: number; files: { path: string; sha256: string }[] }

async function expectAppletStyles(page: Page) {
  const shell = page.locator('.applet-shell')
  await expect(shell).toHaveCSS('display', 'grid')
  await expect(shell).toHaveCSS('padding', '16px')
  await expect(shell).toHaveCSS('gap', '8px')
  const actions = shell.locator('.applet-actions')
  await expect(actions).toHaveCSS('display', 'flex')
  await expect(actions).toHaveCSS('gap', '12px')
  await expect(actions.getByRole('button')).toHaveCount(2)
  await expect
    .poll(() =>
      actions.evaluate(element => {
        const [first, second] = element.querySelectorAll('button')
        return first && second ? second.getBoundingClientRect().left - first.getBoundingClientRect().right : null
      })
    )
    .toBeCloseTo(12, 1)
}

async function request<T>(page: Page, path: string, method = 'GET', body?: unknown): Promise<T> {
  if (method === 'PUT' && path.endsWith('/sharing')) {
    const baseline = await request<{ sharing_version: string }>(page, path)
    body = { ...(body as Record<string, unknown>), sharing_version: baseline.sharing_version }
  }
  return page.evaluate(
    async ({ path, method, body }) => {
      const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content
      const authentication = meta('ankole-authentication'),
        tenant = meta('ankole-pod'),
        csrf = meta('csrf-token')
      const response = await fetch(`/.internal-apis/pod${path}`, {
        method,
        credentials: 'same-origin',
        headers: {
          accept: 'application/json',
          'content-type': 'application/json',
          ...(authentication ? { 'x-ankole-authentication': authentication } : {}),
          ...(tenant ? { 'x-ankole-pod': tenant } : {}),
          ...(csrf ? { 'x-csrf-token': csrf } : {})
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) })
      })
      if (!response.ok) throw new Error(`Pod ${method} ${path}: ${response.status} ${await response.text()}`)
      return response.status === 204 ? null : response.json()
    },
    { path, method, body }
  )
}

function joinedTopics(page: Page) {
  const topics: string[] = []
  page.on('websocket', socket =>
    socket.on('framereceived', frame => {
      try {
        const message = JSON.parse(String(frame.payload)) as unknown[]
        if (message[3] === 'phx_reply' && (message[4] as { status?: string })?.status === 'ok') {
          topics.push(String(message[2]))
        }
      } catch {
        /* Binary frames are not channel acknowledgements. */
      }
    })
  )
  return topics
}

const pixel = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jB1kAAAAASUVORK5CYII=',
  'base64'
)
const image = (name: string) => ({ name, mimeType: 'image/png', buffer: pixel })

test('file uploads retain a failed selection, freeze pending work, resolve real revision conflicts, and recover live updates', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const releases: (() => void)[] = []
  try {
    await page.goto(location(state.report_id))
    const { page: saved } = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'file',
      title: 'Upload recovery'
    })
    await page.goto(location(saved.id))
    const firstStarted = Promise.withResolvers<void>(),
      firstGate = Promise.withResolvers<void>()
    const conflictStarted = Promise.withResolvers<void>(),
      conflictGate = Promise.withResolvers<void>()
    releases.push(
      () => firstGate.resolve(),
      () => conflictGate.resolve()
    )
    let uploads = 0
    await page.route(`**/.internal-apis/pod/pages/${saved.id}/files`, async route => {
      if (route.request().method() !== 'POST') return route.continue()
      uploads++
      if (uploads === 1) {
        return route.fulfill({
          status: 503,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'Upload temporarily unavailable' })
        })
      }
      if (uploads === 2) {
        firstStarted.resolve()
        await firstGate.promise
      }
      if (uploads === 4) {
        conflictStarted.resolve()
        await conflictGate.promise
      }
      await route.continue()
    })
    const input = page.locator('input[type="file"]')
    await input.setInputFiles(image('sample.png'))
    await page.getByRole('button', { name: '上传文件', exact: true }).click()
    await expect(page.getByText('Upload temporarily unavailable', { exact: true })).toBeVisible()
    expect(await input.evaluate((element: HTMLInputElement) => element.files?.[0]?.name)).toBe('sample.png')
    await page.getByRole('button', { name: '上传文件', exact: true }).click()
    await firstStarted.promise
    await expect(input).toBeDisabled()
    await expect(page.getByRole('button', { name: '正在上传…', exact: true })).toBeDisabled()
    await input.locator('xpath=ancestor::form').dispatchEvent('submit')
    expect(uploads).toBe(2)
    firstGate.resolve()
    await expect(page.getByRole('img', { name: 'sample.png', exact: true })).toBeVisible()
    await expect(input).toHaveValue('')
    expect((await request<Manifest>(page, `/pages/${saved.id}/files`)).revision).toBe(1)
    await input.setInputFiles(image('sample.png'))
    await page.getByRole('button', { name: '替换文件', exact: true }).click()
    await expect(input).toHaveValue('')
    expect((await request<Manifest>(page, `/pages/${saved.id}/files`)).revision).toBe(2)

    const other = await context.newPage()
    await other.goto(location(saved.id))
    await expect(other.getByRole('img', { name: 'sample.png', exact: true })).toBeVisible()
    await input.setInputFiles(image('pending.png'))
    await page.getByRole('button', { name: '替换文件', exact: true }).click()
    await conflictStarted.promise
    await other.getByLabel('选择替换文件', { exact: true }).setInputFiles(image('remote.png'))
    await other.getByRole('button', { name: '替换文件', exact: true }).click()
    await expect(other.getByRole('img', { name: 'remote.png', exact: true })).toBeVisible()
    conflictGate.resolve()
    await expect(page.getByRole('alert')).toBeVisible()
    await expect(input).toBeEnabled()
    expect(await input.evaluate((element: HTMLInputElement) => element.files?.[0]?.name)).toBe('pending.png')
    await expect(page.getByRole('img', { name: 'remote.png', exact: true })).toBeVisible()
    await page.getByRole('button', { name: '替换文件', exact: true }).click()
    await expect(page.getByRole('img', { name: 'pending.png', exact: true })).toBeVisible()
    await expect(input).toHaveValue('')
    expect((await request<Manifest>(page, `/pages/${saved.id}/files`)).revision).toBe(4)

    let failToken = true
    await page.route('**/.internal-apis/pod/realtime-token', route => {
      if (!failToken) return route.continue()
      failToken = false
      return route.fulfill({
        status: 503,
        contentType: 'application/json',
        body: JSON.stringify({ error: 'Temporary connection failure' })
      })
    })
    const joined = joinedTopics(page)
    await page.reload()
    const warning = page.getByRole('alert').filter({ hasText: '实时连接暂时不可用' })
    await expect(warning).toBeVisible()
    await expect(page.getByRole('img', { name: 'pending.png', exact: true })).toBeVisible()
    await warning.getByRole('button', { name: '重试', exact: true }).click()
    await expect.poll(() => joined.includes(`page:${saved.id}`)).toBe(true)
    await expect(warning).toHaveCount(0)
    const download = await page.getByRole('link', { name: '下载原文件', exact: true }).getAttribute('href')
    expect(download).toBeTruthy()
    const response = await page.request.get(download!)
    expect(response.ok()).toBe(true)
    expect(await response.body()).toEqual(pixel)
  } finally {
    for (const release of releases) release()
    await context.close()
  }
})

test('Applet loading and live connections recover independently, then real access revocation removes retry actions', async ({
  browser
}) => {
  const context = await browser.newContext(),
    viewerContext = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  await viewerContext.addCookies(state.viewer.cookies)
  const page = await context.newPage(),
    viewer = await viewerContext.newPage()
  const resourceStarted = Promise.withResolvers<void>(),
    resourceGate = Promise.withResolvers<void>()
  try {
    const id = state.runtime_test_applet_id
    if (!id) throw new Error('The real fixture must seed a dedicated runtime recovery Applet')
    let failResource = true,
      failToken = true
    await page.route(`**/.internal-apis/pod/pages/${id}/files/content?**`, async route => {
      if (!failResource || new URL(route.request().url()).searchParams.get('path') !== 'dist/applet.js') {
        return route.continue()
      }
      failResource = false
      resourceStarted.resolve()
      await resourceGate.promise
      await route.fulfill({ status: 503, body: 'Temporary Applet asset failure' })
    })
    await page.route('**/.internal-apis/pod/realtime-token', route => {
      if (!failToken) return route.continue()
      failToken = false
      return route.fulfill({
        status: 503,
        contentType: 'application/json',
        body: JSON.stringify({ error: 'Temporary connection failure' })
      })
    })
    const joined = joinedTopics(page)
    await page.goto(location(id))
    await resourceStarted.promise
    await expect(page.getByText('正在加载小程序…', { exact: true })).toBeVisible()
    resourceGate.resolve()
    await expect(page.getByRole('button', { name: '重新加载小程序', exact: true })).toBeVisible()
    await expect(page.getByText('正在加载小程序…', { exact: true })).toHaveCount(0)
    await page.getByRole('button', { name: '重新加载小程序', exact: true }).click()
    await expect(page.getByRole('heading', { name: 'Tracker v1', exact: true })).toBeVisible()
    await expectAppletStyles(page)
    const warning = page.getByRole('alert').filter({ hasText: '实时连接暂时不可用' })
    await expect(warning).toBeVisible()
    await warning.getByRole('button', { name: '重试', exact: true }).click()
    await expect.poll(() => joined.includes(`page:${id}`)).toBe(true)
    await expect(warning).toHaveCount(0)
    const manifest = await request<Manifest>(page, `/pages/${id}/files`)
    await request(page, `/pages/${id}/publish`, 'POST', {
      base_revision: manifest.revision,
      files: state.publish_v2_files
    })
    await expect(page.getByRole('heading', { name: 'Tracker v2', exact: true })).toBeVisible()
    await expect(page.getByRole('button', { name: 'Local counter 0', exact: true })).toBeVisible()
    await expectAppletStyles(page)
    await viewer.goto(location(id))
    await expect(viewer.getByRole('heading', { name: 'Tracker v2', exact: true })).toBeVisible()
    await request(page, `/pages/${id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [{ principal_uid: state.owner.uid, role: 'manage' }]
    })
    await expect(viewer.getByRole('alert')).toContainText('没有权限')
    await expect(viewer.getByRole('heading', { name: 'Tracker v2', exact: true })).toHaveCount(0)
    await expect(viewer.getByRole('button', { name: '重新加载小程序', exact: true })).toHaveCount(0)
    await expect(viewer.getByRole('button', { name: '重试', exact: true })).toHaveCount(0)
  } finally {
    resourceGate.resolve()
    await context.close()
    await viewerContext.close()
  }
})
