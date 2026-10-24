import { expect, test, type Page } from '@playwright/test'
import { createHash } from 'node:crypto'
import { readFile, readdir } from 'node:fs/promises'
import { join } from 'node:path'

async function publication(page: Page, mode: 'current' | 'changed' | 'denied') {
  const folder = join(import.meta.dir, 'garfish/published/dist')
  const files = await Promise.all(
    (await readdir(folder)).map(async name => {
      const bytes = await readFile(join(folder, name))
      return {
        path: `dist/${name}`,
        sha256: createHash('sha256').update(bytes).digest('hex'),
        content_type: name.endsWith('.html')
          ? 'text/html'
          : name.endsWith('.css')
            ? 'text/css'
            : 'application/javascript',
        bytes
      }
    })
  )
  let manifests = 0
  let changed = false
  await page.route('**/api/v2/pod/pages/publication-fixture/files**', async route => {
    const url = new URL(route.request().url())
    if (!url.pathname.endsWith('/content')) {
      manifests++
      const entries = files.map(({ bytes: _bytes, ...file }) => file)
      // A new publication removed a file after the first manifest was read.
      if (mode === 'changed' && manifests === 1) {
        entries.push({ path: 'dist/removed.js', sha256: 'old', content_type: 'application/javascript' })
      }
      return route.fulfill({ json: { page_id: 'publication-fixture', revision: manifests, files: entries } })
    }
    if (mode === 'denied') return route.fulfill({ status: 403, json: { error: 'forbidden' } })
    if (url.searchParams.get('path') === 'dist/removed.js') {
      changed = true
      return route.fulfill({ status: 409, json: { error: 'manifest_changed' } })
    }
    const file = files.find(file => file.path === url.searchParams.get('path'))
    if (!file) throw new Error(`Unexpected file request: ${url}`)
    return route.fulfill({ body: file.bytes, contentType: file.content_type })
  })
  return { manifests: () => manifests, changed: () => changed }
}

for (const mode of ['current', 'changed'] as const) {
  test(`actual CLI publication mounts imported image, CSS background and font (${mode})`, async ({ page }) => {
    const state = await publication(page, mode)
    const errors: string[] = []
    page.on('pageerror', error => errors.push(error.message))
    await page.goto('/integration/garfish/published/index.html')
    await expect(page.locator('#status')).toHaveText('ready')
    await expect
      .poll(() => page.getByAltText('Published logo').evaluate((image: HTMLImageElement) => image.naturalWidth))
      .toBe(32)
    expect(
      await page.locator('.published-background').evaluate(async element => {
        const value = getComputedStyle(element).backgroundImage
        const image = new Image()
        image.src = value.slice(5, -2)
        await image.decode()
        return image.naturalWidth
      })
    ).toBe(32)
    expect(
      await page.locator('.published-font').evaluate(async element => {
        const family = getComputedStyle(element).fontFamily
        const fonts = await document.fonts.load(`16px ${family}`)
        return fonts.length > 0 && fonts.every(font => font.status === 'loaded')
      })
    ).toBe(true)
    expect(state.manifests()).toBe(mode === 'changed' ? 2 : 1)
    expect(state.changed()).toBe(mode === 'changed')
    expect(errors).toEqual([])
  })
}

test('a denied publication remains denied instead of retrying it as a revision change', async ({ page }) => {
  const state = await publication(page, 'denied')
  await page.goto('/integration/garfish/published/index.html')
  await expect(page.locator('#status')).toHaveText('error:403')
  await expect(page.getByAltText('Published logo')).toHaveCount(0)
  expect(state.manifests()).toBe(1)
})
