import { fileURLToPath } from 'node:url'
import { expect, test, type Page } from '@playwright/test'
import { state, request } from './fixtures'
import { pageRoute } from './routes'

const fixture = (name: string) =>
  fileURLToPath(new URL(`../../../../libs/ankole-editor/public/${name}`, import.meta.url))

async function insertBlock(page: Page, query: string, title: string) {
  const editor = page.locator('.pod-document .editor-content')
  await editor.focus()
  await page.keyboard.press('ControlOrMeta+End')
  await page.keyboard.press('Enter')
  await page.keyboard.insertText(`/${query}`)
  await page.getByRole('option', { name: title, exact: true }).click()
  return editor.locator('.resource-block').last()
}

test('document file and media blocks upload real assets, switch views, and survive a reload', async ({
  browser
}, info) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const errors: string[] = []
  page.on('pageerror', error => errors.push(error.message))
  let id: string | undefined
  try {
    await page.goto(state.base_url + pageRoute(state.report_id))
    await page.locator('.pod-sidebar-top').getByRole('button', { name: '新建页面', exact: true }).click()
    const created = page.waitForResponse(
      response => response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/pages'
    )
    await page.getByRole('menuitem', { name: '文档', exact: true }).click()
    const response = await created
    expect(response.status()).toBe(201)
    id = ((await response.json()) as { page: { id: string } }).page.id
    await expect(page).toHaveURL(state.base_url + pageRoute(id))
    const title = page.getByRole('textbox', { name: '页面标题', exact: true })
    await title.fill('Resource blocks acceptance')
    await title.press('Enter')
    await page.keyboard.type('# Section')
    const editor = page.locator('.pod-document .editor-content')
    await expect(editor.locator('h1')).toHaveText('Section')
    const titleSize = await title.evaluate(element => parseFloat(getComputedStyle(element).fontSize))
    expect(await editor.locator('h1').evaluate(element => parseFloat(getComputedStyle(element).fontSize))).toBeLessThan(
      titleSize
    )

    await editor.focus()
    await page.keyboard.press('ControlOrMeta+End')
    await page.keyboard.press('Enter')
    await page.keyboard.insertText('/attachment')
    await page.getByRole('option', { name: '文件', exact: true }).click()
    const uploadDialog = page.getByRole('dialog', { name: '文件', exact: true })
    await expect(uploadDialog).toBeVisible()
    const uploadedFilePage = page.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/file-pages'
    )
    await uploadDialog
      .locator('input[type="file"]')
      .setInputFiles({ name: 'notes.txt', mimeType: 'text/plain', buffer: Buffer.from('Resource upload contents') })
    expect((await uploadedFilePage).ok()).toBe(true)
    await expect(uploadDialog).toHaveCount(0)
    await expect(page.getByRole('main').getByRole('link', { name: /notes\.txt/ })).toBeVisible()

    const picture = await insertBlock(page, 'img', '媒体')
    await picture.locator('input[type="file"]').setInputFiles(fixture('resource-image.png'))
    await expect
      .poll(() => picture.locator('img').evaluate(image => (image as HTMLImageElement).naturalWidth))
      .toBe(160)
    for (const [name, view] of [
      ['链接视图', 'link'],
      ['卡片视图', 'card'],
      ['预览视图', 'preview']
    ]) {
      await picture.getByRole('button', { name: '视图', exact: true }).click()
      await page.getByRole('menuitem', { name: name!, exact: true }).click()
      await expect(picture).toHaveAttribute('data-view', view!)
    }
    const movie = await insertBlock(page, 'video', '媒体')
    await movie.locator('input[type="file"]').setInputFiles(fixture('resource-video.mp4'))
    await expect
      .poll(() => movie.locator('video').evaluate(video => (video as HTMLVideoElement).readyState))
      .toBeGreaterThanOrEqual(1)
    await expect(page.locator('[data-sync-status="saved"]')).toBeVisible()
    await page.reload()
    await expect(editor.locator('.resource-block')).toHaveCount(2)
    await expect(page.getByRole('main').getByRole('link', { name: /notes\.txt/ })).toBeVisible()
    await expect
      .poll(() =>
        editor
          .locator('.resource-media[src*="resource-image.png"]')
          .evaluate(image => (image as HTMLImageElement).naturalWidth)
      )
      .toBe(160)
    await expect
      .poll(() => editor.locator('video').evaluate(video => (video as HTMLVideoElement).readyState))
      .toBeGreaterThanOrEqual(1)
    await page.screenshot({ path: info.outputPath('document-resources.png'), fullPage: true })
    expect(errors).toEqual([])
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})
