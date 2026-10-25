import { expect, test, type Page } from '@playwright/test'
import { state, request } from './fixtures'
import { pageRoute } from './routes'

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
    await viewportAndPortal(page)
  } finally {
    if (documentID) await request(page, `/pages/${documentID}`, 'DELETE')
    await context.close()
  }
})
