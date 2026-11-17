import { expect, test } from '@playwright/test'

test('HTML preview anchors scroll their own document without loading the Pod shell', async ({ page }) => {
  await page.goto('/integration/html-file-preview/index.html')
  const preview = page.frameLocator('iframe')
  const source = preview.getByRole('link', { name: 'Source section', exact: true })
  await expect(source).toBeVisible()
  const hostURL = page.url()
  const documentRequests: string[] = []
  page.on('request', request => {
    if (request.isNavigationRequest()) documentRequests.push(request.url())
  })

  const documentState = () =>
    preview.locator('body').evaluate(() => {
      const target = document.querySelector(':target')
      return {
        url: location.href,
        scroll: window.scrollY,
        target: target?.id ?? null,
        targetTop: target?.getBoundingClientRect().top ?? null
      }
    })

  await source.click()
  await expect.poll(documentState).toMatchObject({
    url: 'about:srcdoc#applet-source-link',
    target: 'applet-source-link',
    targetTop: 0
  })
  expect((await documentState()).scroll).toBeGreaterThan(0)
  await preview.locator('body').evaluate(() => window.scrollTo(0, 0))
  await source.click()
  await expect.poll(() => documentState().then(state => state.targetTop)).toBe(0)

  const chinese = preview.getByRole('link', { name: 'Chinese section', exact: true })
  await chinese.focus()
  await page.keyboard.press('Enter')
  await expect.poll(documentState).toMatchObject({
    url: 'about:srcdoc#%E4%B8%AD%E6%96%87',
    target: '中文',
    targetTop: 0
  })

  await preview.getByRole('link', { name: 'Back to top', exact: true }).click()
  await expect.poll(() => documentState().then(state => state.scroll)).toBe(0)
  await expect(preview.getByRole('heading', { name: 'Interactive report', exact: true })).toBeVisible()
  expect(page.url()).toBe(hostURL)
  expect(documentRequests).toEqual([])
  expect(await page.locator('iframe').evaluate(frame => (frame as HTMLIFrameElement).contentDocument)).toBeNull()
})

test('HTML preview keeps report-owned click handlers and opens external links in a new tab', async ({ page }) => {
  await page.goto('/integration/html-file-preview/index.html')
  const preview = page.frameLocator('iframe')
  await preview.getByRole('link', { name: 'Custom action', exact: true }).click()
  await expect(preview.locator('#custom-status')).toHaveText('Handled by report')
  expect(await preview.locator('body').evaluate(() => location.href)).toBe('about:srcdoc')

  const popupPromise = page.waitForEvent('popup')
  await preview.getByRole('link', { name: 'External report', exact: true }).click()
  const popup = await popupPromise
  expect(popup.url()).toBe(`${page.url()}?external`)
  await popup.close()
  await expect(preview.getByRole('heading', { name: 'Interactive report', exact: true })).toBeVisible()
})
