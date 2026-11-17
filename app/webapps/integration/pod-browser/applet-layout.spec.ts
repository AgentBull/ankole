import { expect, test, type Page } from '@playwright/test'
import { state, request, createApplet, publishApplet } from './fixtures'
import { conversationRoute, pageRoute } from './routes'

async function viewportAndPortal(page: Page) {
  const frame = page.frameLocator('iframe')
  await frame.getByRole('button', { name: 'Viewport dashboard', exact: true }).click()
  await expect(frame.getByRole('heading', { name: 'Viewport dashboard', exact: true })).toBeVisible()
  const dimensions = async () => ({
    frame: await page.locator('iframe').evaluate(element => element.getBoundingClientRect().height),
    panel: await page.locator('.pod-page-scroll').evaluate(element => element.clientHeight),
    content: await frame
      .locator('.viewport-workspace')
      .evaluate(element => ({ height: element.getBoundingClientRect().height, viewport: innerHeight }))
  })
  await expect
    .poll(async () => {
      const value = await dimensions()
      return Math.abs(value.frame - value.panel)
    })
    .toBeLessThan(1)
  const first = await dimensions()
  expect(first.frame).toBeGreaterThan(300)
  expect(first.content.height).toBe(first.content.viewport + 32)
  await page.evaluate(
    () =>
      new Promise(resolve => {
        let frames = 0
        const next = () => {
          if (++frames === 12) resolve(null)
          else requestAnimationFrame(next)
        }
        requestAnimationFrame(next)
      })
  )
  expect((await dimensions()).frame).toBe(first.frame)
  await frame.getByRole('button', { name: 'Open portal', exact: true }).click()
  const portal = frame.getByRole('dialog', { name: 'Frame portal', exact: true })
  await expect(portal).toBeVisible()
  await expect(page.getByRole('dialog', { name: 'Frame portal', exact: true })).toHaveCount(0)
  expect(
    await portal.evaluate(element => {
      const rect = element.getBoundingClientRect()
      return (
        !element.closest('.ankole-applet') &&
        rect.top >= 0 &&
        rect.left >= 0 &&
        rect.bottom <= innerHeight &&
        rect.right <= innerWidth
      )
    })
  ).toBe(true)
  await portal.getByRole('button', { name: 'Close portal', exact: true }).click()
  await expect(portal).toBeHidden()
  await page.setViewportSize({ width: 1080, height: 700 })
  await expect
    .poll(async () => {
      const value = await dimensions()
      return Math.abs(value.frame - value.panel)
    })
    .toBeLessThan(1)
  expect((await dimensions()).frame).toBeLessThan(first.frame)
}

test('full-page and embedded applets give padded 100vh content and UIKit Portals one stable workspace viewport', async ({
  browser
}) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let documentID: string | undefined
  try {
    await page.goto(state.base_url + pageRoute(state.applet_id))
    await viewportAndPortal(page)
    // The Applet fills the Page body below the header, so the body neither repeats the title nor scrolls;
    // the Page's gutters pad the Applet's own document instead.
    await expect(page.locator('.pod-page-heading')).toHaveCount(0)
    const body = await page.locator('.pod-page-scroll').evaluate(element => {
      const panel = element.getBoundingClientRect()
      const frame = element.querySelector('iframe')!.getBoundingClientRect()
      return {
        overflow: element.scrollHeight - element.clientHeight,
        offset: Math.abs(frame.left - panel.left),
        width: Math.abs(frame.width - element.clientWidth)
      }
    })
    expect(body).toEqual({ overflow: 0, offset: 0, width: 0 })
    const html = page.frameLocator('iframe').locator('html')
    await expect(html).toHaveCSS('padding-top', '40px')
    await expect(html).toHaveCSS('padding-left', '68px')
    // The wheel moves the Applet even beside its content column.
    const panel = (await page.locator('.pod-page-scroll').boundingBox())!
    await page.mouse.move(panel.x + 12, panel.y + panel.height / 2)
    await page.mouse.wheel(0, 200)
    await expect
      .poll(() => page.locator('iframe').evaluate(frame => (frame as HTMLIFrameElement).contentWindow!.scrollY))
      .toBeGreaterThan(0)
    const created = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'doc',
      title: 'Embedded viewport acceptance',
      private_owner_uid: state.owner.uid
    })
    documentID = created.page.id
    await request(page, `/pages/${documentID}/content`, 'PUT', {
      base_revision: 0,
      xml: `<page><p>Embedded internal application.</p><embed ref="${state.applet_id}"/></page>`
    })
    await page.setViewportSize({ width: 1440, height: 900 })
    await page.goto(state.base_url + pageRoute(documentID))
    const embedded = page.frameLocator('iframe')
    await expect(embedded.getByRole('heading', { name: /Tracker v[12]/ })).toBeVisible()
    await expect(embedded.locator('.applet-page-title')).toHaveAttribute('data-embedded', 'true')
    const embed = () =>
      page.locator('iframe').evaluate(element => {
        const frame = element as HTMLIFrameElement
        return {
          height: frame.getBoundingClientRect().height,
          panel: document.querySelector('.pod-page-scroll')!.clientHeight,
          inner: frame.contentDocument!.documentElement.scrollHeight - frame.contentWindow!.innerHeight
        }
      })
    // A document gives the embedded Applet its content's height: no blank screen below it and no scrolling inside it.
    await expect
      .poll(async () => {
        const value = await embed()
        return value.height < value.panel - 100 && value.inner <= 1
      })
      .toBe(true)
    // A modal dialog gets the whole workspace viewport while it is open, then the embed fits its content again.
    await embedded.getByRole('button', { name: 'Open record portal', exact: true }).click()
    await expect(embedded.getByRole('dialog', { name: 'Record portal', exact: true })).toBeVisible()
    await expect
      .poll(async () => {
        const value = await embed()
        return Math.abs(value.height - value.panel)
      })
      .toBeLessThan(1)
    await embedded.getByRole('button', { name: 'Close record portal', exact: true }).click()
    await expect
      .poll(async () => {
        const value = await embed()
        return value.height < value.panel - 100
      })
      .toBe(true)
    // A layout sized from the viewport keeps the whole panel without growing or shrinking frame after frame.
    await viewportAndPortal(page)
    await expect(embedded.locator('html')).toHaveCSS('padding', '0px')
  } finally {
    if (documentID) await request(page, `/pages/${documentID}`, 'DELETE')
    await context.close()
  }
})

test('document embed parameters update the running Applet without losing its iframe or form state', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let documentID: string | undefined
  try {
    await page.goto(state.base_url + pageRoute(state.applet_id))
    const created = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'doc',
      title: 'Parameterized report',
      private_owner_uid: state.owner.uid,
      xml: `<page><p>Regional report</p><embed ref="${state.applet_id}" props='{"region":"华东"}' /></page>`
    })
    documentID = created.page.id
    await page.goto(state.base_url + pageRoute(documentID))
    const frame = page.frameLocator('iframe')
    await expect(frame.locator('[data-applet-props]')).toHaveText('{"region":"华东"}')
    const original = await page.locator('iframe').elementHandle()
    const originalContainer = await page.locator('.pod-inline-page').elementHandle()
    await frame.getByRole('textbox', { name: 'Draft evaluation', exact: true }).fill('Keep this unfinished edit')
    await frame.getByRole('button', { name: 'Local counter 0', exact: true }).click()

    await page.locator('.pod-inline-page').getByRole('button', { name: '视图', exact: true }).click()
    await page.getByRole('menuitem', { name: '嵌入参数（Props）', exact: true }).click()
    const dialog = page.getByRole('dialog', { name: '嵌入参数（Props）', exact: true })
    await dialog.getByRole('textbox', { name: '参数（JSON）', exact: true }).fill('{"region":"华南"}')
    await dialog.getByRole('button', { name: '保存', exact: true }).click()
    await expect(frame.locator('[data-applet-props]')).toHaveText('{"region":"华南"}')
    await expect(frame.getByRole('textbox', { name: 'Draft evaluation', exact: true })).toHaveValue(
      'Keep this unfinished edit'
    )
    await expect(frame.getByRole('button', { name: 'Local counter 1', exact: true })).toBeVisible()
    expect(await original!.evaluate(element => element.isConnected)).toBe(true)
    expect(await originalContainer!.evaluate(element => element.isConnected)).toBe(true)

    await expect
      .poll(async () => {
        const detail = await request<{ page: { revision: number }; content: { content: string } }>(
          page,
          `/pages/${documentID}`
        )
        return detail.content.content.includes('华南')
      })
      .toBe(true)
    const detail = await request<{ page: { revision: number }; content: { content: string } }>(
      page,
      `/pages/${documentID}`
    )
    await request(page, `/pages/${documentID}/content`, 'PUT', {
      base_revision: detail.page.revision,
      xml: detail.content.content.replace('华南', '华北')
    })
    await expect(frame.locator('[data-applet-props]')).toHaveText('{"region":"华北"}')
    await expect(frame.getByRole('textbox', { name: 'Draft evaluation', exact: true })).toHaveValue(
      'Keep this unfinished edit'
    )
    await expect(frame.getByRole('button', { name: 'Local counter 1', exact: true })).toBeVisible()
    expect(await original!.evaluate(element => element.isConnected)).toBe(true)
    expect(await originalContainer!.evaluate(element => element.isConnected)).toBe(true)
  } finally {
    if (documentID) await request(page, `/pages/${documentID}`, 'DELETE')
    await context.close()
  }
})

test('the Applet Page menu shows the running Applet on the whole screen and returns it to the workspace', async ({
  browser
}) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(state.base_url + pageRoute(state.applet_id))
    const frame = page.frameLocator('iframe')
    await frame.getByRole('button', { name: 'Viewport dashboard', exact: true }).click()
    const heading = frame.getByRole('heading', { name: 'Viewport dashboard', exact: true })
    await expect(heading).toBeVisible()
    const sizes = () =>
      page.evaluate(() => {
        const element = document.querySelector('iframe')!
        const rect = element.getBoundingClientRect()
        return {
          fullScreen: !!document.fullscreenElement?.contains(element),
          headerOnScreen: !!document.fullscreenElement?.querySelector('.pod-page-path'),
          width: rect.width,
          height: rect.height,
          panel: document.querySelector('.pod-page-scroll')!.clientHeight,
          frameViewport: element.contentWindow!.innerHeight
        }
      })

    await page.locator('.pod-page-actions').getByRole('button', { name: '更多操作', exact: true }).click()
    await page.getByRole('menuitem', { name: '全屏显示', exact: true }).click()
    await expect.poll(async () => (await sizes()).fullScreen).toBe(true)
    await expect
      .poll(async () => {
        const value = await sizes()
        return Math.abs(value.height - 900) + Math.abs(value.width - 1440) + Math.abs(value.frameViewport - 900)
      })
      .toBeLessThan(1)
    expect((await sizes()).headerOnScreen).toBe(false)
    await expect(heading).toBeVisible()
    await frame.getByRole('button', { name: 'Open portal', exact: true }).click()
    const portal = frame.getByRole('dialog', { name: 'Frame portal', exact: true })
    await expect(portal).toBeInViewport({ ratio: 1 })
    await portal.getByRole('button', { name: 'Close portal', exact: true }).click()
    await expect(portal).toBeHidden()

    await page.evaluate(() => document.exitFullscreen())
    await expect
      .poll(async () => {
        const value = await sizes()
        return !value.fullScreen && value.height < 900 && Math.abs(value.height - value.panel) < 1
      })
      .toBe(true)
    await expect(heading).toBeVisible()
  } finally {
    await context.close()
  }
})

test('an Applet Page renames its title in the header and links the conversation that produced it', async ({
  browser
}) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto(state.base_url + pageRoute(state.report_id))
    const created = await createApplet({
      parent_id: state.report_id,
      title: 'Applet from a conversation',
      saved_from_message_id: state.message_id
    })
    id = created.id
    await publishApplet(id, created.revision, state.publish_v1_files)
    await page.goto(state.base_url + pageRoute(id))
    const header = page.locator('.pod-page-path')
    const appletTitle = page.frameLocator('iframe').locator('.applet-page-title')
    await expect(appletTitle).toHaveText('Applet from a conversation')
    await expect(appletTitle).toHaveAttribute('data-embedded', 'false')
    await page.locator('.pod-page-actions').getByRole('button', { name: '更多操作', exact: true }).click()
    await page.getByRole('menuitem', { name: '重命名', exact: true }).click()
    const field = header.getByRole('textbox', { name: /^重命名 / })
    await expect(field).toBeFocused()
    await field.fill('Renamed conversation Applet')
    await field.press('Enter')
    await expect(field).toHaveCount(0)
    await expect(header.locator('[aria-current="page"]')).toHaveText('Renamed conversation Applet')
    // The running Applet receives the new title without reloading.
    await expect(appletTitle).toHaveText('Renamed conversation Applet')
    expect((await request<{ page: { title: string } }>(page, `/pages/${id}`)).page.title).toBe(
      'Renamed conversation Applet'
    )
    const source = header.getByRole('link', { name: /^来源对话：/ })
    await expect(source).toBeVisible()
    await expect(page.locator('.pod-page-origin')).toHaveCount(0)
    await source.click()
    await expect(page).toHaveURL(new RegExp(`${conversationRoute(state.conversation_id)}$`))
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})
