import { readFileSync } from 'node:fs'
import { expect, test, type BrowserContext, type Page, type Request } from '@playwright/test'
import { pageRoute } from './routes'

type Identity = { cookies: Parameters<BrowserContext['addCookies']>[0] }
const state = JSON.parse(readFileSync(process.env.POD_BROWSER_STATE_PATH!, 'utf8')) as {
  base_url: string
  backend_report_id: string
  backend_applet_id: string
  backend_table_id: string
  backend_stock_field_id: string
  backend_record_id: string
  backend_publish_v2_files: unknown[]
  owner: Identity
  member: Identity
  viewer: Identity
}

async function request(page: Page, path: string, method = 'GET', body?: unknown, revision?: number) {
  return page.evaluate(
    async ({ path, method, body, revision }) => {
      const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content
      const response = await fetch(`/.internal-apis/pod${path}`, {
        method,
        credentials: 'same-origin',
        headers: {
          accept: 'application/json',
          'content-type': 'application/json',
          'x-csrf-token': meta('csrf-token') ?? '',
          'x-ankole-authentication': meta('ankole-authentication') ?? '',
          'x-ankole-pod': meta('ankole-pod') ?? '',
          ...(revision === undefined ? {} : { 'x-ankole-applet-revision': String(revision) })
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) })
      })
      return { status: response.status, body: response.status === 204 ? null : await response.json() }
    },
    { path, method, body, revision }
  )
}

test('shared sample reservations use the real backend, retain failed work, and never overdraw competing stock', async ({
  browser
}, testInfo) => {
  const contexts = await Promise.all(
    [state.owner, state.member, state.viewer].map(async identity => {
      const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
      await context.addCookies(identity.cookies)
      return context
    })
  )
  const [owner, member, viewer] = await Promise.all(contexts.map(context => context.newPage()))
  const errors: string[] = []
  for (const page of [owner, member, viewer]) page.on('pageerror', error => errors.push(error.message))
  const release = Promise.withResolvers<void>()
  try {
    await owner.goto(state.base_url + pageRoute(state.backend_report_id))
    const workspace = owner.getByRole('region', { name: 'Sample reservations', exact: true })
    const available = workspace.getByRole('status', { name: 'Available samples', exact: true })
    const quantity = workspace.getByRole('spinbutton', { name: 'Quantity', exact: true })
    const reserve = workspace.getByRole('button', { name: 'Reserve samples', exact: true })
    await expect(available).toHaveText('5')
    await quantity.focus()
    await expect(quantity).toBeFocused()
    await quantity.fill('2')

    // Delay only delivery of an actual committed server response. This proves
    // pending UX without replacing the backend or the durable write.
    const committed = Promise.withResolvers<void>()
    let delayed = false
    await owner.route(`**/pages/${state.backend_applet_id}/routes/reserve`, async route => {
      if (delayed || route.request().method() !== 'POST') return route.continue()
      delayed = true
      const response = await route.fetch()
      expect(response.status()).toBe(200)
      committed.resolve()
      await release.promise
      await route.fulfill({ response })
    })
    await quantity.press('Enter')
    await committed.promise
    await expect(quantity).not.toBeEditable()
    await expect(quantity).toBeFocused()
    await expect(workspace.getByRole('button', { name: 'Reserving…', exact: true })).toBeDisabled()
    await expect(workspace.getByRole('status', { name: 'Available samples', exact: true })).toHaveText('5')
    await expect(workspace.getByRole('status').filter({ hasText: 'Saving your reservation…' })).toBeVisible()
    await member.goto(state.base_url + pageRoute(state.backend_applet_id))
    await expect(member.getByRole('status', { name: 'Available samples', exact: true })).toHaveText('3')
    // Document typography must not change an embedded application's layout.
    for (const heading of [
      workspace.getByRole('heading', { name: 'Reserve a sample', exact: true }),
      member.getByRole('heading', { name: 'Reserve a sample', exact: true })
    ]) {
      await expect(heading).toHaveCSS('margin-top', '0px')
      await expect(heading).toHaveCSS('margin-bottom', '0px')
    }
    for (const [inline, fullPage] of [
      [workspace, member.getByRole('region', { name: 'Sample reservations', exact: true })],
      [
        workspace.getByRole('button', { name: 'Reserving…', exact: true }),
        member.getByRole('button', { name: 'Reserve samples', exact: true })
      ]
    ] as const) {
      for (const property of ['font-size', 'line-height', 'font-weight']) {
        const expected = await fullPage.evaluate(
          (el, property) => getComputedStyle(el).getPropertyValue(property),
          property
        )
        await expect(inline).toHaveCSS(property, expected)
      }
    }
    release.resolve()
    await expect(available).toHaveText('3')
    await expect(workspace.getByText('Reserved 2 samples.', { exact: true })).toBeVisible()

    await quantity.fill('9')
    await reserve.click()
    await expect(workspace.getByRole('alert')).toHaveText('Not enough samples. Choose a smaller quantity.')
    await expect(quantity).toHaveValue('9')
    await expect(available).toHaveText('3')
    await owner.screenshot({
      path: testInfo.outputPath('reservation-error-desktop.png'),
      fullPage: true,
      caret: 'initial'
    })
    await owner.reload()
    await expect(available).toHaveText('3')

    await viewer.goto(state.base_url + pageRoute(state.backend_applet_id))
    const viewerQuantity = viewer.getByRole('spinbutton', { name: 'Quantity', exact: true })
    await expect(viewer.getByRole('status', { name: 'Available samples', exact: true })).toHaveText('3')
    await viewerQuantity.fill('1')
    await viewer.getByRole('button', { name: 'Reserve samples', exact: true }).click()
    await expect(viewer.getByRole('alert')).toHaveText('You can view this inventory. Ask an editor to reserve samples.')
    await expect(viewerQuantity).toHaveValue('1')
    await expect(viewer.getByRole('status', { name: 'Available samples', exact: true })).toHaveText('3')

    await quantity.fill('2')
    await member.getByRole('spinbutton', { name: 'Quantity', exact: true }).fill('2')
    const responseFor = (page: Page) =>
      page.waitForResponse(
        response =>
          response.request().method() === 'POST' &&
          new URL(response.url()).pathname.endsWith(`/pages/${state.backend_applet_id}/routes/reserve`)
      )
    const ownerResponse = responseFor(owner),
      memberResponse = responseFor(member)
    await Promise.all([reserve.click(), member.getByRole('button', { name: 'Reserve samples', exact: true }).click()])
    const responses = await Promise.all([ownerResponse, memberResponse])
    expect(responses.map(response => response.status()).sort()).toEqual([200, 409])
    await expect(available).toHaveText('1')
    await expect(member.getByRole('status', { name: 'Available samples', exact: true })).toHaveText('1')
    const saved = await request(owner, `/tables/${state.backend_table_id}/query`, 'POST', {
      ids: [state.backend_record_id]
    })
    expect(saved.status).toBe(200)
    expect(saved.body.records[0].data[state.backend_stock_field_id]).toBe(1)

    const previous = await request(owner, `/pages/${state.backend_applet_id}`)
    expect(previous.status).toBe(200)
    const oldRevision = previous.body.page.revision
    const publication = await request(owner, `/pages/${state.backend_applet_id}/publish`, 'POST', {
      base_revision: oldRevision,
      files: state.backend_publish_v2_files
    })
    expect(publication.status).toBe(200)
    expect(publication.body.routes).toEqual(['GET /stock', 'POST /reserve'])
    const oldRequest = await request(
      owner,
      `/pages/${state.backend_applet_id}/routes/stock`,
      'GET',
      undefined,
      oldRevision
    )
    expect(oldRequest.status).toBe(409)
    expect(oldRequest.body.error.code).toBe('applet_revision_changed')
    await expect(workspace.getByText('Shared inventory · Updated sample reservations', { exact: true })).toBeVisible()
    await expect(available).toHaveText('1')

    await owner.screenshot({
      path: testInfo.outputPath('reservation-final-desktop.png'),
      fullPage: true,
      caret: 'initial'
    })
    await owner.setViewportSize({ width: 390, height: 844 })
    await available.scrollIntoViewIfNeeded()
    await expect(reserve).toBeVisible()
    expect(await owner.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await owner.screenshot({
      path: testInfo.outputPath('reservation-final-mobile.png'),
      fullPage: true,
      caret: 'initial'
    })
    expect(errors).toEqual([])
  } finally {
    release.resolve()
    await Promise.all(contexts.map(context => context.close()))
  }
})

test('an embedded Applet stays available after closing a responsive Page chat', async ({ browser }, testInfo) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(state.base_url + pageRoute(state.backend_report_id))
    const embedded = page.locator('.editor-content .embed').filter({
      has: page.getByRole('button', { name: 'Reserve samples', exact: true })
    })
    const available = embedded.getByRole('status', { name: 'Available samples', exact: true })
    await expect(available).toHaveText(/^\d+$/)
    const stock = await available.innerText()
    await page.getByRole('button', { name: '页面对话', exact: true }).click()
    await expect(page.getByRole('complementary', { name: '页面对话', exact: true })).toBeVisible()
    await page.setViewportSize({ width: 390, height: 844 })
    const chat = page.getByRole('dialog', { name: '页面对话', exact: true })
    await expect(chat).toBeVisible()
    // The modal correctly removes the background Applet from the accessible tree.
    await expect(embedded).toHaveCount(0)
    await chat.getByRole('button', { name: '关闭页面对话', exact: true }).click()
    await expect(chat).toBeHidden()
    await expect.poll(() => new URL(page.url()).searchParams.has('chat')).toBe(false)
    await available.scrollIntoViewIfNeeded()
    await expect(available).toHaveText(stock)
    await expect(available).toBeInViewport()
    await expect(embedded.getByRole('button', { name: 'Reserve samples', exact: true })).toBeVisible()
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await page.screenshot({ path: testInfo.outputPath('applet-after-mobile-chat-close.png'), caret: 'initial' })
  } finally {
    await context.close()
  }
})

test('stale Applet recovery cancels an older page read, supports retry, and releases reads when leaving', async ({
  browser
}, testInfo) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const control = await context.newPage()
  const page = await context.newPage()
  const errors: string[] = []
  page.on('pageerror', error => errors.push(error.message))
  // The revision header must recover the shared host even when live updates are unavailable.
  await page.routeWebSocket(/.*/, socket => socket.close())
  let id: string | undefined
  try {
    await control.goto(state.base_url + '/content/private')
    const created = await request(control, '/pages', 'POST', {
      type: 'applet',
      parent_id: state.backend_report_id,
      title: 'Revision recovery check'
    })
    expect(created.status).toBe(200)
    id = created.body.page.id
    const publish = () =>
      request(control, `/pages/${id}/publish`, 'POST', {
        base_revision: revision,
        files: state.backend_publish_v2_files
      })
    let revision = 0
    const initial = await publish()
    expect(initial.status).toBe(200)
    revision = initial.body.revision
    const stockRevisions: string[] = []
    const reserveRevisions: string[] = []
    page.on('request', outgoing => {
      if (new URL(outgoing.url()).pathname === `/.internal-apis/pod/pages/${id}/routes/stock`) {
        stockRevisions.push(outgoing.headers()['x-ankole-applet-revision'])
      }
      if (
        outgoing.method() === 'POST' &&
        new URL(outgoing.url()).pathname === `/.internal-apis/pod/pages/${id}/routes/reserve`
      ) {
        reserveRevisions.push(outgoing.headers()['x-ankole-applet-revision'])
      }
    })
    await page.goto(state.base_url + pageRoute(id!))
    const workspace = page.getByRole('region', { name: 'Sample reservations', exact: true })
    const available = workspace.getByRole('status', { name: 'Available samples', exact: true })
    await expect(available).toHaveText(/^\d+$/)
    const initialStock = await available.textContent()
    expect(stockRevisions.at(-1)).toBe(String(revision))

    for (const recovery of ['normal', 'retry', 'leave'] as const) {
      const oldReady = Promise.withResolvers<void>()
      const oldRelease = Promise.withResolvers<void>()
      const oldFinished = Promise.withResolvers<void>()
      const freshReady = Promise.withResolvers<void>()
      const freshRelease = Promise.withResolvers<void>()
      const freshFinished = Promise.withResolvers<void>()
      let oldRequest: Request | undefined
      let freshRequest: Request | undefined
      let reads = 0
      const before = revision
      const priorReserves = reserveRevisions.length
      const pageURL = (url: URL) => url.pathname === `/.internal-apis/pod/pages/${id}`
      await page.route(pageURL, async route => {
        if (route.request().method() !== 'GET') return route.continue()
        reads++
        const response = await route.fetch()
        expect(response.status()).toBe(200)
        const detail = await response.json()
        if (reads === 1) {
          oldRequest = route.request()
          expect(detail.page.revision).toBe(before)
          oldReady.resolve()
          await oldRelease.promise
          try {
            await route.fulfill({ response })
          } catch (error) {
            if (!oldRequest.failure()?.errorText.includes('ERR_ABORTED')) throw error
          } finally {
            oldFinished.resolve()
          }
        } else {
          expect(detail.page.revision).toBe(revision)
          if (reads === 2 && recovery === 'retry') {
            await route.fulfill({
              status: 503,
              contentType: 'application/json',
              body: JSON.stringify({
                error: { code: 'snapshot_read_unavailable', message: 'Snapshot read temporarily unavailable' }
              })
            })
          } else if (reads === 2 && recovery === 'leave') {
            freshRequest = route.request()
            freshReady.resolve()
            await freshRelease.promise
            try {
              await route.fulfill({ response })
            } catch (error) {
              if (!freshRequest.failure()?.errorText.includes('ERR_ABORTED')) throw error
            } finally {
              freshFinished.resolve()
            }
          } else await route.fulfill({ response })
        }
      })
      try {
        // Saving a title starts a genuine page-query refresh without advancing publication revision.
        const title = page.locator('textarea.pod-page-title')
        await title.fill(`Revision recovery check · ${recovery}`)
        await title.press('Enter')
        await oldReady.promise
        const published = await publish()
        expect(published.status).toBe(200)
        revision = published.body.revision
        expect(revision).toBe(before + 1)
        const staleResponse = page.waitForResponse(
          response =>
            response.request().method() === 'POST' &&
            new URL(response.url()).pathname === `/.internal-apis/pod/pages/${id}/routes/reserve`
        )
        await workspace.getByRole('button', { name: 'Reserve samples', exact: true }).click()
        const rejected = await staleResponse
        expect(rejected.status()).toBe(409)
        expect((await rejected.json()).error.code).toBe('applet_revision_changed')
        await testInfo.attach(`revision-race-${recovery}.json`, {
          contentType: 'application/json',
          body: JSON.stringify({
            before,
            current: revision,
            staleStatus: rejected.status(),
            oldReadCaptured: !!oldRequest
          })
        })
        // A new GET is required while the old response is still held. Reusing its promise strands the Applet.
        await expect.poll(() => reads, { timeout: 5000 }).toBeGreaterThanOrEqual(2)
        await expect.poll(() => oldRequest?.failure()?.errorText ?? '').toContain('ERR_ABORTED')
        oldRelease.resolve()
        await oldFinished.promise
        if (recovery === 'retry') {
          const failure = page
            .getByRole('alert')
            .filter({ hasText: 'Snapshot read temporarily unavailable' })
            .filter({ has: page.getByRole('button', { name: /重试|Retry/ }) })
          await expect(failure).toBeVisible()
          await failure.getByRole('button', { name: /重试|Retry/ }).click()
          await expect(failure).toHaveCount(0)
        } else if (recovery === 'leave') {
          await freshReady.promise
          await page.locator('a[href="/content/private"]').first().click()
          await expect(page).toHaveURL(/\/content\/private$/)
          await expect.poll(() => freshRequest?.failure()?.errorText ?? '').toContain('ERR_ABORTED')
          freshRelease.resolve()
          await freshFinished.promise
          await expect(workspace).toHaveCount(0)
          continue
        }
        await expect(available).toHaveText(initialStock!)
        await expect.poll(() => stockRevisions.at(-1)).toBe(String(revision))
      } finally {
        oldRelease.resolve()
        freshRelease.resolve()
        if (oldRequest) await oldFinished.promise
        if (freshRequest) await freshFinished.promise
        expect(reserveRevisions.slice(priorReserves)).toEqual([String(before)])
        await page.unroute(pageURL)
      }
    }
    expect(errors).toEqual([])
  } finally {
    if (id) await request(control, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})
