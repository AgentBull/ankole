import { expect, test, type Page } from '@playwright/test'

test.setTimeout(90_000)

// Browser unit coverage: hold the engine boundary while the real React view scrolls and changes generations.
test.beforeEach(async ({ page }) => {
  await page.route('**/fonts/office/manifest.json', route =>
    route.fulfill({
      json: { fonts: [{ family: 'Carlito', file: 'Carlito-Regular.ttf' }] }
    })
  )
  await page.route('**/fonts/office/Carlito-Regular.ttf', route => route.fulfill({ body: 'unit-font' }))
  await page.goto('/integration/word-rendering/index.html')
  await expect(page.getByRole('status', { name: 'Pending renders' })).toContainText('1:1:1.3333')
})

test('a page still visible after scrolling receives its in-flight bitmap', async ({ page }) => {
  await scroll(page, 600)
  await page.getByRole('button', { name: 'Release next render' }).click()
  await expect.poll(() => pixel(page, 1)).toEqual([40, 67, 1, 255])
  expect(await requestCount(page, '1:1:1.3333')).toBe(1)
})

test('an offscreen completion is cached for scrolling back without another render', async ({ page }) => {
  await scroll(page, 2700)
  await expect(page.getByRole('group', { name: 'Page 2 of 8', exact: true }).locator('canvas')).toHaveCount(0)
  await page.getByRole('button', { name: 'Release next render' }).click()
  await expect(page.getByRole('status', { name: 'Pending renders' })).toBeEmpty()
  await scroll(page, 0)
  await expect.poll(() => pixel(page, 1)).toEqual([40, 67, 1, 255])
  expect(await requestCount(page, '1:1:1.3333')).toBe(1)
})

test('a version change discards the old completion before the replacement render finishes', async ({ page }) => {
  await page.getByRole('button', { name: 'Change document version' }).click()
  await page.getByRole('button', { name: 'Release next render' }).click()
  await expect.poll(() => requestCount(page, '1:1:1.3333')).toBe(2)
  expect(await pixel(page, 1)).toEqual([0, 0, 0, 0])
  await page.getByRole('button', { name: 'Release next render' }).click()
  await expect.poll(() => pixel(page, 1)).toEqual([40, 67, 1, 255])
})

test('zooming discards an old-scale completion before the replacement render finishes', async ({ page }) => {
  await page.getByRole('button', { name: 'Zoom in', exact: true }).click()
  await page.getByRole('button', { name: 'Release next render' }).click()
  await expect(page.getByRole('status', { name: 'Pending renders' })).toContainText('1:1:1.5333')
  expect(await pixel(page, 1)).toEqual([0, 0, 0, 0])
  await page.getByRole('button', { name: 'Release next render' }).click()
  await expect.poll(() => pixel(page, 1)).toEqual([40, 77, 1, 255])
})

test('switching documents rejects a pending result from the earlier session', async ({ page }) => {
  await page.getByRole('button', { name: 'Change document', exact: true }).click()
  await expect(page.getByRole('status', { name: 'Pending renders' })).toContainText('2:1:1.3333')
  await page.getByRole('button', { name: 'Release next render' }).click()
  expect(await pixel(page, 1)).toEqual([0, 0, 0, 0])
  await page.getByRole('button', { name: 'Release next render' }).click()
  await expect.poll(() => pixel(page, 1)).toEqual([80, 67, 1, 255])
})

test('unmounting discards a pending bitmap and a later mount renders it again', async ({ page }) => {
  await page.getByRole('button', { name: 'Toggle view' }).click()
  await page.getByRole('button', { name: 'Release next render' }).click()
  await expect(page.getByRole('status', { name: 'Pending renders' })).toBeEmpty()
  await page.getByRole('button', { name: 'Toggle view' }).click()
  await expect.poll(() => requestCount(page, '1:1:1.3333')).toBe(2)
  expect(await pixel(page, 1)).toEqual([0, 0, 0, 0])
  await page.getByRole('button', { name: 'Release next render' }).click()
  await expect.poll(() => pixel(page, 1)).toEqual([40, 67, 1, 255])
})

async function scroll(page: Page, top: number) {
  await page.getByRole('region', { name: 'Document pages' }).evaluate((element, scrollTop) => {
    element.scrollTop = scrollTop
    element.dispatchEvent(new Event('scroll'))
  }, top)
}

async function pixel(page: Page, index: number) {
  return page
    .getByRole('group', { name: `Page ${index + 1} of 8`, exact: true })
    .locator('canvas')
    .evaluate(canvas => {
      if (!(canvas instanceof HTMLCanvasElement)) throw new Error('Expected a page canvas')
      return Array.from(canvas.getContext('2d')!.getImageData(0, 0, 1, 1).data)
    })
}

async function requestCount(page: Page, request: string) {
  return (await page.getByRole('status', { name: 'Render requests' }).textContent())!
    .split(',')
    .filter(item => item === request).length
}
