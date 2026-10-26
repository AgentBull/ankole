import { state, requestWithSharingVersion as request } from './fixtures'
import { pageRoute } from './routes'
import { expect, test, type Page } from '@playwright/test'

const location = (id: string) => `${state.base_url}${pageRoute(id)}`
type Manifest = { revision: number; files: { path: string; sha256: string }[] }

async function expectAppletStyles(page: Page) {
  const shell = page.frameLocator('iframe').locator('.applet-shell')
  await expect(shell).toHaveCSS('display', 'grid')
  await expect(shell).toHaveCSS('padding', '16px')
  await expect(shell).toHaveCSS('gap', '8px')
  const actions = shell.locator('.applet-actions')
  await expect(actions).toHaveCSS('display', 'flex')
  await expect(actions).toHaveCSS('gap', '12px')
  await expect(actions.getByRole('button')).toHaveCount(5)
  await expect
    .poll(() =>
      actions.evaluate(element => {
        const [first, second] = element.querySelectorAll('button')
        return first && second ? second.getBoundingClientRect().left - first.getBoundingClientRect().right : null
      })
    )
    .toBeCloseTo(12, 1)
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

test('a temporary token failure still restores workspace updates after the Page connects', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const control = await context.newPage()
  const joined = joinedTopics(page)
  let failToken = true
  let createdID: string | undefined
  try {
    await page.route('**/api/v2/pod/realtime-token', route => {
      if (!failToken) return route.continue()
      failToken = false
      return route.fulfill({
        status: 503,
        contentType: 'application/json',
        body: JSON.stringify({ error: 'Temporary connection failure' })
      })
    })
    await page.goto(location(state.applet_id))
    await expect(page.frameLocator('iframe').getByRole('heading', { name: /Tracker v[12]/ })).toBeVisible()
    await expect.poll(() => joined.includes(`page:${state.applet_id}`)).toBe(true)
    const branch = page.getByRole('button', { name: 'Browser report', exact: true })
    if ((await branch.getAttribute('aria-expanded')) !== 'true') await branch.click()
    await expect(page.getByRole('link', { name: 'Browser tracker', exact: true })).toBeVisible()
    await control.goto(location(state.report_id))
    const title = `Recovered workspace item ${Date.now()}`
    const created = await request<{ page: { id: string } }>(control, '/pages', 'POST', {
      type: 'doc',
      title,
      parent_id: state.report_id
    })
    createdID = created.page.id
    await expect(page.getByRole('link', { name: title, exact: true })).toBeVisible({ timeout: 10_000 })
    await expect.poll(() => joined.includes('content')).toBe(true)
  } finally {
    if (createdID) await request(control, `/pages/${createdID}`, 'DELETE')
    await context.close()
  }
})

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
    await page.route(`**/api/v2/pod/pages/${saved.id}/files`, async route => {
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
    await page.route('**/api/v2/pod/realtime-token', route => {
      if (!failToken) return route.continue()
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
    failToken = false
    await warning.getByRole('button', { name: '重试', exact: true }).click()
    await expect.poll(() => joined.includes(`page:${saved.id}`)).toBe(true)
    await expect.poll(() => joined.includes('content'), { timeout: 10_000 }).toBe(true)
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
    await page.route(`**/pod/applet-frame/*/${id}/*/main.js`, async route => {
      if (!failResource || !new URL(route.request().url()).pathname.endsWith('/main.js')) {
        return route.continue()
      }
      failResource = false
      resourceStarted.resolve()
      await resourceGate.promise
      await route.fulfill({ status: 503, body: 'Temporary Applet asset failure' })
    })
    await page.route('**/api/v2/pod/realtime-token', route => {
      if (!failToken) return route.continue()
      return route.fulfill({
        status: 503,
        contentType: 'application/json',
        body: JSON.stringify({ error: 'Temporary connection failure' })
      })
    })
    const joined = joinedTopics(page)
    await page.goto(location(id))
    await resourceStarted.promise
    await expect(page.getByText('正在加载小应用…', { exact: true })).toBeVisible()
    resourceGate.resolve()
    await expect(page.getByRole('button', { name: '重新加载小应用', exact: true })).toBeVisible()
    await expect(page.getByText('正在加载小应用…', { exact: true })).toHaveCount(0)
    await page.getByRole('button', { name: '重新加载小应用', exact: true }).click()
    await expect(page.frameLocator('iframe').getByRole('heading', { name: 'Tracker v1', exact: true })).toBeVisible()
    await expectAppletStyles(page)
    const warning = page.getByRole('alert').filter({ hasText: '实时连接暂时不可用' })
    await expect(warning).toBeVisible()
    failToken = false
    await warning.getByRole('button', { name: '重试', exact: true }).click()
    await expect.poll(() => joined.includes(`page:${id}`)).toBe(true)
    await expect.poll(() => joined.includes('content'), { timeout: 10_000 }).toBe(true)
    await expect(warning).toHaveCount(0)
    const manifest = await request<Manifest>(page, `/pages/${id}/files`)
    await request(page, `/pages/${id}/publish`, 'POST', {
      base_revision: manifest.revision,
      files: state.publish_v2_files
    })
    await expect(page.frameLocator('iframe').getByRole('heading', { name: 'Tracker v2', exact: true })).toBeVisible()
    await expect(
      page.frameLocator('iframe').getByRole('button', { name: 'Local counter 0', exact: true })
    ).toBeVisible()
    await expectAppletStyles(page)
    await viewer.goto(location(id))
    await expect(viewer.frameLocator('iframe').getByRole('heading', { name: 'Tracker v2', exact: true })).toBeVisible()
    await request(page, `/pages/${id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [{ principal_uid: state.owner.uid, role: 'manage' }]
    })
    await expect(viewer.getByRole('alert')).toContainText('没有权限')
    await expect(viewer.frameLocator('iframe').getByRole('heading', { name: 'Tracker v2', exact: true })).toHaveCount(0)
    await expect(viewer.getByRole('button', { name: '重新加载小应用', exact: true })).toHaveCount(0)
    await expect(viewer.getByRole('button', { name: '重试', exact: true })).toHaveCount(0)
  } finally {
    resourceGate.resolve()
    await context.close()
    await viewerContext.close()
  }
})

test('a caught React.lazy chunk failure refreshes its stale publication without replaying the action', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const control = await context.newPage(),
    page = await context.newPage()
  await page.routeWebSocket('**/pod/socket/websocket*', socket => socket.close())
  try {
    const id = state.runtime_test_applet_id
    await control.goto(location(state.report_id))
    const detail = await request<{ page: { revision: number } }>(control, `/pages/${id}`)
    await page.goto(location(id))
    const frame = page.frameLocator('iframe')
    await expect(frame.getByRole('heading', { name: /Tracker v[12]/ })).toBeVisible()
    const previous = await page.locator('iframe').getAttribute('src')
    if (!previous) throw new Error('The published applet must have a frame URL')
    await frame.getByRole('button', { name: 'Local counter 0', exact: true }).click()
    await expect(frame.getByRole('button', { name: 'Local counter 1', exact: true })).toBeVisible()
    const publication = await request<{ revision: number }>(control, `/pages/${id}/publish`, 'POST', {
      base_revision: detail.page.revision,
      files: state.publish_v2_files
    })
    await expect(page.locator('iframe')).toHaveAttribute('src', previous)
    const staleChunk = page.waitForResponse(
      response => {
        const url = new URL(response.url())
        return (
          url.pathname.startsWith(new URL(previous, state.base_url).pathname.replace(/index.html$/, '')) &&
          /\/chunks\/lazy-details-[^/]+\.js$/.test(url.pathname)
        )
      },
      { timeout: 10_000 }
    )
    await frame.getByRole('button', { name: 'Load lazy details', exact: true }).click()
    expect((await staleChunk).status()).toBe(409)
    await expect(page.locator('iframe')).toHaveAttribute(
      'src',
      previous.replace(`/${detail.page.revision}/index.html`, `/${publication.revision}/index.html`)
    )
    await expect(frame.getByRole('button', { name: 'Local counter 0', exact: true })).toBeVisible()
    await expect(frame.locator('.applet-lazy-details')).toHaveCount(0)
    await frame.getByRole('button', { name: 'Load lazy details', exact: true }).click()
    await expect(frame.locator('.applet-lazy-details')).toHaveText('Lazy details loaded')
    const freshFrame = await page.locator('iframe').getAttribute('src')
    const revalidation = page.waitForResponse(response => response.url() === new URL(freshFrame!, state.base_url).href)
    await frame.getByRole('button', { name: 'Render error', exact: true }).click()
    expect((await revalidation).status()).toBe(200)
    const reload = page.getByRole('button', { name: '重新加载小应用', exact: true })
    await expect(reload).toHaveCount(1)
    await expect(reload).toBeVisible()
    await expect(frame.getByRole('button')).toHaveCount(0)
    expect(
      await reload.evaluate(button => {
        const rect = button.getBoundingClientRect()
        const viewport = button.closest('.pod-page-scroll')!.getBoundingClientRect()
        return rect.top >= viewport.top && rect.bottom <= viewport.bottom
      })
    ).toBe(true)
    await reload.click()
    await expect(frame.getByRole('button', { name: 'Local counter 0', exact: true })).toBeVisible()
    await expect(reload).toHaveCount(0)
    await expect(page.getByRole('alert').filter({ hasText: 'Fixture rendering failed' })).toHaveCount(0)
    await expect(page.locator('iframe')).toHaveAttribute('src', freshFrame!)
  } finally {
    await context.close()
  }
})
