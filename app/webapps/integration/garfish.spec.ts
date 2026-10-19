import { expect, test as base, type Page } from '@playwright/test'

const test = base.extend<{ uncaughtErrors: void }>({
  uncaughtErrors: [
    async ({ page }, use) => {
      const errors: string[] = []
      page.on('pageerror', error => errors.push(error.message))
      await use()
      expect(errors).toEqual([])
    },
    { auto: true }
  ]
})

const slot = (page: Page, location = 'main') => page.locator(`.applet-slot[data-location="${location}"]`)
const telemetry = (page: Page, instance: string, kind: string) =>
  page
    .locator('html')
    .getAttribute(`data-${kind}-${instance}`)
    .then(value => Number(value ?? 0))

test.beforeEach(async ({ page }) => {
  await page.goto('/integration/garfish/index.html')
  await expect(page.getByRole('heading', { name: 'Pod page' })).toBeVisible()
})

test('CommonJS provider shares React and uikit with the Vite host', async ({ page }) => {
  await page.getByRole('button', { name: 'Mount applet', exact: true }).click()
  const main = slot(page)
  await expect(main.locator('.shared-modules')).toHaveText('shared')
  await main.getByRole('button', { name: 'Increment' }).click()
  await expect(main.locator('.applet-count')).toHaveText('1')
  await expect(main.getByRole('button', { name: 'Increment' })).toHaveAttribute('data-slot', 'button')
})

test('compiled Tailwind CSS is scoped while Pod design variables reach the applet', async ({ page }) => {
  const hostStyle = () =>
    page.locator('[data-check="host-style"]').evaluate(element => {
      const style = getComputedStyle(element)
      return {
        fontSize: style.fontSize,
        color: style.color,
        background: getComputedStyle(document.body).backgroundColor
      }
    })
  const before = await hostStyle()
  await page.getByRole('button', { name: 'Mount applet', exact: true }).click()
  await expect(slot(page).locator('.applet-detail')).toHaveText('revision-1')
  const styles = await slot(page)
    .locator('.ankole-applet-box')
    .evaluate(element => {
      const style = getComputedStyle(element)
      return { padding: style.padding, gap: style.gap, display: style.display, radius: style.borderRadius }
    })
  expect(styles).toEqual({ padding: '16px', gap: '8px', display: 'grid', radius: '8px' })
  expect(
    await slot(page)
      .locator('.applet-title')
      .evaluate(element => getComputedStyle(element).color)
  ).toBe(await page.locator('.pod-title').evaluate(element => getComputedStyle(element).color))
  expect(await hostStyle()).toEqual(before)
  expect(
    await slot(page)
      .locator('style')
      .evaluateAll(styles => styles.some(style => style.textContent?.includes('garfish_app_for_')))
  ).toBe(true)
})

test('two revisions isolate state, globals, and conflicting styles', async ({ page }) => {
  await page.getByRole('button', { name: 'Mount applet', exact: true }).click()
  await page.getByRole('button', { name: 'Mount second instance' }).click()
  const main = slot(page)
  const second = slot(page, 'second')
  await expect(main.locator('.applet-detail')).toHaveText('revision-1')
  await expect(second.locator('.applet-detail')).toHaveText('revision-2')
  await main.getByRole('button', { name: 'Increment' }).click()
  await expect(main.locator('.applet-count')).toHaveText('1')
  await expect(second.locator('.applet-count')).toHaveText('0')
  for (const current of [main, second]) {
    await current.getByRole('button', { name: 'Read global' }).click()
    await expect(current.locator('.applet-global')).toHaveText((await current.getAttribute('data-instance'))!)
  }
  await expect(main.locator('.applet-title')).toHaveCSS('font-size', '16px')
  await expect(second.locator('.applet-title')).toHaveCSS('font-size', '24px')
  expect(await page.evaluate(() => Reflect.get(window, '__appletInstance'))).toBeUndefined()
})

test('updating a revision cleans sandbox timers, listeners, DOM, and style nodes', async ({ page }) => {
  await page.getByRole('button', { name: 'Mount applet', exact: true }).click()
  const main = slot(page)
  await expect(main.locator('.applet-detail')).toHaveText('revision-1')
  const old = (await main.getAttribute('data-instance'))!
  await expect.poll(() => telemetry(page, old, 'ticks')).toBeGreaterThan(0)
  await page.evaluate(() => window.dispatchEvent(new Event('applet-probe')))
  expect(await telemetry(page, old, 'events')).toBe(1)
  await expect(page.locator(`[data-effect-owner="${old}"]`)).toHaveCount(2)

  await page.getByRole('button', { name: 'Update main' }).click()
  await expect(main.locator('.applet-detail')).toHaveText('revision-2')
  expect(await main.getAttribute('data-instance')).not.toBe(old)
  await expect(page.locator(`[data-effect-owner="${old}"]`)).toHaveCount(0)
  const stopped = await telemetry(page, old, 'ticks')
  await page.evaluate(() => window.dispatchEvent(new Event('applet-probe')))
  expect(await telemetry(page, old, 'events')).toBe(1)
  // More than two interval periods distinguishes cancellation from a tick between assertions.
  await page.waitForTimeout(350)
  expect(await telemetry(page, old, 'ticks')).toBe(stopped)
  await main.getByRole('button', { name: 'Unmount', exact: true }).click()
  await expect(page.locator('[id^="garfish_app_for_"]')).toHaveCount(0)
  await expect(page.locator('[data-effect-owner]')).toHaveCount(0)
})

test('render and load failures stay inside their own containers', async ({ page }) => {
  await page.route('**/dist/missing/applet.html', route => route.fulfill({ status: 404, body: 'missing applet' }))
  await page.getByRole('button', { name: 'Mount applet', exact: true }).click()
  await page.getByRole('button', { name: 'Mount broken applet' }).click()
  await expect(slot(page, 'broken').getByRole('alert')).toHaveText('Applet failed')
  await page.getByRole('button', { name: 'Mount missing applet' }).click()
  await expect(slot(page, 'missing').getByRole('alert')).toBeVisible()
  await slot(page).getByRole('button', { name: 'Increment' }).click()
  await expect(slot(page).locator('.applet-count')).toHaveText('1')
  await expect(page.getByRole('heading', { name: 'Pod page' })).toBeVisible()
})

test('unmounting during load prevents a late applet from mounting', async ({ page }) => {
  let release!: () => void
  let received!: () => void
  const requestReceived = new Promise<void>(resolve => {
    received = resolve
  })
  const released = new Promise<void>(resolve => {
    release = resolve
  })
  await page.route('**/dist/revision-1/applet.html', async route => {
    received()
    await released
    await route.continue()
  })
  await page.getByRole('button', { name: 'Mount applet', exact: true }).click()
  await requestReceived
  await slot(page).getByRole('button', { name: 'Unmount', exact: true }).click()
  release()
  await page.waitForResponse('**/dist/revision-1/applet.html')
  await page.getByRole('button', { name: 'Mount second instance' }).click()
  await expect(slot(page, 'second').locator('.applet-detail')).toHaveText('revision-2')
  await expect(slot(page)).toHaveCount(0)
  await expect(page.locator('[id^="garfish_app_for_"]')).toHaveCount(1)
})
