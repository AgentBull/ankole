import { readFileSync } from 'node:fs'
import { state, request } from './fixtures'
import { expect, test } from '@playwright/test'
import { initSync as initPresentationWasm, PresentationEditor } from '@ankole/kernel/presentation-wasm'
import { pageRoute } from './routes'

const presentationWasm = new URL(
  '../../../kernel/dist/presentation-wasm/ankole_presentation_wasm_bg.wasm',
  import.meta.url
)

function buildPptxBuffer(slides: Array<{ title: string; subtitle?: string }>): Buffer {
  initPresentationWasm({ module: readFileSync(presentationWasm) })
  const editor = PresentationEditor.create_blank('Results')
  try {
    slides.forEach((slide, idx) => {
      if (idx > 0) editor.execute_command('slide.new', '{}')
      const info = JSON.parse(editor.execute_command('slide.inspect', '{}')) as { shapes: Array<{ id: number }> }
      editor.execute_command('text.set', JSON.stringify({ id: info.shapes[0].id, text: slide.title }))
      if (slide.subtitle && info.shapes[1]) {
        editor.execute_command('text.set', JSON.stringify({ id: info.shapes[1].id, text: slide.subtitle }))
      }
    })
    return Buffer.from(editor.export_pptx())
  } finally {
    editor.free()
  }
}

test('replacing a Markdown file clears the old section selection and anchors new comments to the new object', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto(pageRoute(state.report_id))
    id = (
      await request<{ page: { id: string } }>(page, '/pages', 'POST', { type: 'file', title: 'Versioned sections' })
    ).page.id
    await page.goto(pageRoute(id))
    const input = page.locator('input[type="file"]')
    await expect(input).toBeEnabled()
    await input.setInputFiles({
      name: 'notes.md',
      mimeType: 'text/markdown',
      buffer: Buffer.from('# Original\nOld content.\n')
    })
    await page.getByRole('button', { name: '# Original', exact: true }).click()
    const selection = page.getByTestId('file-comment-selection-bar')
    await expect(selection).toContainText('Old content.')
    await input.setInputFiles({
      name: 'notes.md',
      mimeType: 'text/markdown',
      buffer: Buffer.from('# Replacement\nNew content.\n')
    })
    await expect(page.getByRole('button', { name: '# Replacement', exact: true })).toBeVisible()
    await expect(selection).toHaveCount(0)
    await page.getByRole('button', { name: '# Replacement', exact: true }).click()
    await selection.getByRole('button', { name: '批注所选内容', exact: true }).click()
    const comments = page.getByRole('complementary', { name: '评论', exact: true })
    await comments.getByRole('textbox', { name: '添加评论…', exact: true }).fill('Review the new version.')
    await comments.getByRole('button', { name: '发送', exact: true }).click()
    await expect(comments.getByText('Review the new version.', { exact: true })).toBeVisible()
    const manifest = await request<{ files: { object_id: string }[] }>(page, `/pages/${id}/files`)
    const result = await request<{ threads: { anchor: { object_id: string; heading: string }; quote: string }[] }>(
      page,
      `/pages/${id}/comments`
    )
    expect(result.threads[0]).toMatchObject({
      anchor: { object_id: manifest.files[0].object_id, heading: 'Replacement' }
    })
    expect(result.threads[0].quote).toContain('New content.')
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('keyboard file selection keeps a failed upload, freezes pending work, and leaves download above the real preview', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 900, height: 800 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const started = Promise.withResolvers<void>(),
    gate = Promise.withResolvers<void>()
  let id: string | undefined
  try {
    await page.goto(pageRoute(state.report_id))
    id = (await request<{ page: { id: string } }>(page, '/pages', 'POST', { type: 'file', title: 'File toolbar' })).page
      .id
    await page.goto(pageRoute(id))
    const XLSX = await import('xlsx')
    const workbook = XLSX.utils.book_new()
    XLSX.utils.book_append_sheet(workbook, XLSX.utils.aoa_to_sheet([['Revenue'], [1234.5]]), 'Revenue')
    XLSX.utils.book_append_sheet(workbook, XLSX.utils.aoa_to_sheet([['Next quarter'], [28]]), 'Forecast')
    const file = {
      name: '季度复盘以及销售流水汇总报告.xls',
      mimeType: 'application/vnd.ms-excel',
      buffer: Buffer.from(XLSX.write(workbook, { type: 'array', bookType: 'xls' }))
    }
    let calls = 0
    await page.route(`**/api/v2/pod/pages/${id}/files`, async route => {
      if (route.request().method() !== 'POST') return route.continue()
      calls++
      if (calls === 1) return route.fulfill({ status: 503, json: { error: 'Upload temporarily unavailable' } })
      started.resolve()
      await gate.promise
      await route.continue()
    })
    const choose = page.getByRole('button', { name: '选择上传文件', exact: true })
    await expect(choose).toBeEnabled()
    await choose.focus()
    const chooser = page.waitForEvent('filechooser')
    await choose.press('Enter')
    await (await chooser).setFiles(file)
    const input = page.locator('input[type="file"]')
    await expect(page.getByRole('status').filter({ hasText: file.name })).toHaveText(file.name)
    await expect(page.getByRole('alert').getByText('Upload temporarily unavailable', { exact: true })).toBeVisible()
    await expect(page.getByRole('status').filter({ hasText: file.name })).toHaveText(file.name)
    await expect(input).toHaveValue('')
    await page.getByRole('alert').getByRole('button', { name: '重试', exact: true }).click()
    await started.promise
    await expect(input).toBeDisabled()
    await expect(page.getByRole('button', { name: '正在上传…', exact: true })).toBeDisabled()
    gate.resolve()
    const revenue = page.getByTitle(/工作表.*Revenue/)
    await expect(revenue.contentFrame().getByText('1234.5', { exact: true })).toBeVisible()
    await expect(input).toHaveValue('')
    const worksheets = page.getByRole('navigation', { name: '工作表', exact: true })
    await expect(worksheets.getByRole('button', { name: 'Revenue', exact: true })).toHaveAttribute(
      'aria-pressed',
      'true'
    )
    await worksheets.getByRole('button', { name: 'Forecast', exact: true }).click()
    await expect(worksheets.getByRole('button', { name: 'Forecast', exact: true })).toHaveAttribute(
      'aria-pressed',
      'true'
    )
    await expect(worksheets.getByRole('button', { name: 'Revenue', exact: true })).toHaveAttribute(
      'aria-pressed',
      'false'
    )
    await expect(
      page
        .getByTitle(/工作表.*Forecast/)
        .contentFrame()
        .getByText('Next quarter', { exact: true })
    ).toBeVisible()
    const download = page.getByRole('link', { name: '下载原文件', exact: true })
    const href = await download.getAttribute('href')
    const response = await page.request.get(href!)
    expect(response.ok()).toBe(true)
    expect(await response.body()).toEqual(file.buffer)
    for (const width of [900, 390]) {
      await page.setViewportSize({ width, height: 800 })
      const preview = await page.getByTitle(/工作表.*Forecast/).boundingBox()
      for (const action of [download, page.getByRole('button', { name: '选择替换文件', exact: true })]) {
        await expect(action).toBeInViewport({ ratio: 1 })
        const bounds = await action.boundingBox()
        expect(bounds!.x).toBeGreaterThanOrEqual(0)
        expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(width)
        expect(bounds!.y + bounds!.height).toBeLessThanOrEqual(preview!.y)
      }
    }
    const replacement = XLSX.utils.book_new()
    XLSX.utils.book_append_sheet(replacement, XLSX.utils.aoa_to_sheet([['Reduced revenue'], [19]]), 'Revenue')
    await page.getByLabel('选择替换文件', { exact: true }).setInputFiles({
      ...file,
      buffer: Buffer.from(XLSX.write(replacement, { type: 'array', bookType: 'xls' }))
    })
    await expect(worksheets.getByRole('button', { name: 'Forecast', exact: true })).toHaveCount(0)
    await expect(worksheets.getByRole('button', { name: 'Revenue', exact: true })).toHaveAttribute(
      'aria-pressed',
      'true'
    )
    await expect(revenue.contentFrame().getByText('Reduced revenue', { exact: true })).toBeVisible()
    await page.getByLabel('选择替换文件', { exact: true }).setInputFiles(file)
    await expect(worksheets.getByRole('button', { name: 'Revenue', exact: true })).toHaveAttribute(
      'aria-pressed',
      'true'
    )
    await expect(worksheets.getByRole('button', { name: 'Forecast', exact: true })).toHaveAttribute(
      'aria-pressed',
      'false'
    )
    await expect(revenue.contentFrame().getByText('1234.5', { exact: true })).toBeVisible()
    expect(calls).toBe(4)
  } finally {
    gate.resolve()
    await page.unrouteAll({ behavior: 'wait' })
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('presentation pages expose their selection while keeping file actions above the preview', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 390, height: 844 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto(pageRoute(state.report_id))
    id = (
      await request<{ page: { id: string } }>(page, '/pages', 'POST', { type: 'file', title: 'Presentation toolbar' })
    ).page.id
    await page.goto(pageRoute(id))
    const original = {
      name: 'Results.pptx',
      mimeType: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      buffer: buildPptxBuffer([
        { title: 'Quarterly results' },
        { title: 'Next quarter', subtitle: 'Launch the research service' }
      ])
    }
    await page.getByLabel('选择上传文件', { exact: true }).setInputFiles(original)
    const slides = page.getByRole('list', { name: '幻灯片列表', exact: true })
    await expect(slides.getByRole('button', { name: '第 1 页', exact: true })).toHaveAttribute('aria-current', 'step')
    await slides.getByRole('button', { name: '第 2 页', exact: true }).click()
    await expect(slides.getByRole('button', { name: '第 2 页', exact: true })).toHaveAttribute('aria-current', 'step')
    await expect(slides.getByRole('button', { name: '第 1 页', exact: true })).not.toHaveAttribute('aria-current')
    await expect(page.getByText('Next quarter', { exact: true })).toBeVisible()
    await expect(page.getByRole('link', { name: '下载', exact: true })).toBeInViewport({ ratio: 1 })
    await expect(page.getByRole('button', { name: '选择替换文件', exact: true })).toBeInViewport({ ratio: 1 })
    const bytes = buildPptxBuffer([{ title: 'Updated results' }])
    await page.getByLabel('选择替换文件', { exact: true }).setInputFiles({
      name: original.name,
      mimeType: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      buffer: bytes
    })
    await expect(slides.getByRole('button', { name: '第 1 页', exact: true })).toHaveAttribute('aria-current', 'step')
    await expect(slides.getByRole('button', { name: '第 2 页', exact: true })).toHaveCount(0)
    await expect(page.getByText('Updated results', { exact: true })).toBeVisible()
    const response = await page.request.get(
      (await page.getByRole('link', { name: '下载', exact: true }).getAttribute('href'))!
    )
    expect(response.ok()).toBe(true)
    initPresentationWasm({ module: readFileSync(presentationWasm) })
    const downloaded = PresentationEditor.open(new Uint8Array(await response.body()), '[]')
    try {
      const downloadedSlides = JSON.parse(downloaded.slides_info()) as Array<{ title: string }>
      expect(downloadedSlides).toHaveLength(1)
      expect(downloadedSlides[0].title).toBe('Updated results')
    } finally {
      downloaded.free()
    }
    await page.getByLabel('选择替换文件', { exact: true }).setInputFiles(original)
    await expect(slides.getByRole('button', { name: '第 1 页', exact: true })).toHaveAttribute('aria-current', 'step')
    await expect(slides.getByRole('button', { name: '第 2 页', exact: true })).not.toHaveAttribute('aria-current')
    await expect(page.getByText('Quarterly results', { exact: true })).toBeVisible()
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})
