import { readFileSync } from 'node:fs'
import { expect, test } from '@playwright/test'
import { initSync as initPresentationWasm, PresentationEditor } from '@ankole/kernel/presentation-wasm'
import { initSync as initWordWasm, WordEditor } from '@ankole/kernel/word-wasm'
import { request, state } from './fixtures'
import { pageRoute } from './routes'

const wordWasm = new URL('../../../kernel/dist/word-wasm/ankole_word_wasm_bg.wasm', import.meta.url)
const presentationWasm = new URL(
  '../../../kernel/dist/presentation-wasm/ankole_presentation_wasm_bg.wasm',
  import.meta.url
)

test('a Word page saves on navigation, exports PDF, keeps versions, and converts the latest text', async ({
  browser
}) => {
  const ownerContext = await browser.newContext({
    baseURL: state.base_url,
    viewport: { width: 1280, height: 900 },
    acceptDownloads: true
  })
  await ownerContext.addCookies(state.owner.cookies)
  const owner = await ownerContext.newPage()
  let wordId: string | undefined
  let convertedDocId: string | undefined
  try {
    await owner.goto(pageRoute(state.report_id))
    const report = owner.locator('.pod-tree-row', { has: owner.locator(`a[href="${pageRoute(state.report_id)}"]`) })
    await report.hover()
    await report.getByRole('button', { name: '新建页面', exact: true }).click()
    const created = owner.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/office-pages'
    )
    await owner.getByRole('menuitem', { name: 'Word 文档', exact: true }).click()
    const createRes = await created
    expect(createRes.status()).toBe(201)
    wordId = ((await createRes.json()) as { page: { id: string } }).page.id
    await expect(owner).toHaveURL(state.base_url + pageRoute(wordId, undefined, 'Untitled.docx'))
    await expect(owner.getByRole('button', { name: '转为在线文档', exact: true })).toBeEnabled()

    // Leave immediately after editing so the next page waits for the pending Word draft.
    const input = owner.getByRole('textbox', { name: '文档文本输入', exact: true })
    await input.focus()
    await owner.keyboard.type('Launch Readiness Memo')
    await owner.keyboard.press('Enter')
    await owner.keyboard.type('All launch gates passed.')
    await report.locator(`a[href="${pageRoute(state.report_id)}"]`).click()
    await expect(owner).toHaveURL(state.base_url + pageRoute(state.report_id))
    await owner.goBack()
    await expect(owner).toHaveURL(state.base_url + pageRoute(wordId, undefined, 'Untitled.docx'))
    await expect(owner.getByRole('status').filter({ hasText: '所有更改已保存' })).toBeVisible()

    // Live download omits sha256 so uncompacted edits are materialized into the downloaded .docx.
    const download = owner.getByRole('link', { name: '下载', exact: true })
    const href = (await download.getAttribute('href'))!
    expect(new URL(href, state.base_url).searchParams.has('sha256')).toBe(false)
    const fileRes = await owner.request.get(href)
    expect(fileRes.ok()).toBe(true)
    initWordWasm({ module: readFileSync(wordWasm) })
    const doc = WordEditor.open(new Uint8Array(await fileRes.body()), '[]')
    try {
      const matches = JSON.parse(doc.find('Launch Readiness Memo', false)) as Array<{ snippet?: string }>
      expect(matches.length).toBeGreaterThan(0)
      expect(JSON.parse(doc.find('All launch gates passed.', false))).toHaveLength(1)
    } finally {
      doc.free()
    }

    // Export PDF from the browser Worker.
    const pdfDownload = owner.waitForEvent('download')
    await owner.getByRole('button', { name: '导出 PDF', exact: true }).click()
    const downloadedPdf = await pdfDownload
    expect(downloadedPdf.suggestedFilename()).toMatch(/\.pdf$/i)

    // Version history records the initial creation version.
    await owner.getByRole('button', { name: '版本历史', exact: true }).click()
    const versions = owner.getByRole('list', { name: '版本', exact: true })
    await expect(versions.getByRole('listitem')).toHaveCount(1)
    await expect(versions.getByText('创建', { exact: true })).toBeVisible()
    await owner.keyboard.press('Escape')

    // Conversion waits for text the Word editor has not yet sent.
    const converted = owner.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/v2/pod/pages/${wordId}/convert-to-document`
    )
    await input.focus()
    await owner.keyboard.insertText('Last-minute approval')
    await owner.getByRole('button', { name: '转为在线文档', exact: true }).click()
    const convertRes = await converted
    expect(convertRes.status()).toBe(201)
    convertedDocId = ((await convertRes.json()) as { page: { id: string } }).page.id
    await expect(owner.locator('.editor-content')).toContainText('Launch Readiness Memo')
    await expect(owner.locator('.editor-content')).toContainText('All launch gates passed.')
    await expect(owner.locator('.editor-content')).toContainText('Last-minute approval')
  } finally {
    if (convertedDocId) await request(owner, `/pages/${convertedDocId}`, 'DELETE')
    if (wordId) await request(owner, `/pages/${wordId}`, 'DELETE')
    await ownerContext.close()
  }
})

test('a read-only Word viewer can convert the shared file into their Private pages', async ({ browser }) => {
  const ownerContext = await browser.newContext({ baseURL: state.base_url })
  const viewerContext = await browser.newContext({ baseURL: state.base_url })
  await ownerContext.addCookies(state.owner.cookies)
  await viewerContext.addCookies(state.viewer.cookies)
  const owner = await ownerContext.newPage()
  const viewer = await viewerContext.newPage()
  let wordID: string | undefined
  let convertedID: string | undefined
  try {
    await owner.goto(pageRoute(state.report_id))
    const { page } = await request<{ page: { id: string } }>(owner, '/office-pages', 'POST', {
      format: 'word',
      title: 'Read-only conversion',
      parent_id: state.report_id
    })
    wordID = page.id
    await viewer.goto(pageRoute(wordID))
    await expect(viewer.getByRole('textbox', { name: '文档文本输入', exact: true })).toHaveAttribute('readonly', '')
    const converted = viewer.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/v2/pod/pages/${wordID}/convert-to-document`
    )
    await viewer.getByRole('button', { name: '转为在线文档', exact: true }).click()
    const response = await converted
    expect(response.status()).toBe(201)
    const { page: document } = (await response.json()) as { page: { id: string; private_owner_uid: string } }
    convertedID = document.id
    expect(document.private_owner_uid).toBe(state.viewer.uid)
  } finally {
    if (convertedID) await request(viewer, `/pages/${convertedID}`, 'DELETE')
    if (wordID) await request(owner, `/pages/${wordID}`, 'DELETE')
    await viewerContext.close()
    await ownerContext.close()
  }
})

test('a Presentation page creates from menu, adds slides and notes, exports PDF, and downloads the updated deck', async ({
  browser
}) => {
  const ownerContext = await browser.newContext({
    baseURL: state.base_url,
    viewport: { width: 1280, height: 900 },
    acceptDownloads: true
  })
  await ownerContext.addCookies(state.owner.cookies)
  const owner = await ownerContext.newPage()
  let presId: string | undefined
  try {
    await owner.goto(pageRoute(state.report_id))
    const report = owner.locator('.pod-tree-row', { has: owner.locator(`a[href="${pageRoute(state.report_id)}"]`) })
    await report.hover()
    await report.getByRole('button', { name: '新建页面', exact: true }).click()
    const created = owner.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/office-pages'
    )
    await owner.getByRole('menuitem', { name: '演示文稿', exact: true }).click()
    const createRes = await created
    expect(createRes.status()).toBe(201)
    presId = ((await createRes.json()) as { page: { id: string } }).page.id
    await expect(owner).toHaveURL(state.base_url + pageRoute(presId, undefined, 'Untitled.pptx'))
    await expect(owner.getByRole('img', { name: '第 1 张幻灯片画布', exact: true })).toBeVisible()

    // Add a second slide and record speaker notes on it.
    await owner.getByRole('button', { name: '新建幻灯片', exact: true }).click()
    const slides = owner.getByRole('list', { name: '幻灯片列表', exact: true })
    await expect(slides.getByRole('button', { name: '第 2 页', exact: true })).toHaveAttribute('aria-current', 'step')

    await owner.getByRole('button', { name: '切换演讲者备注', exact: true }).click()
    const notes = owner.getByRole('textbox', { name: '演讲者备注', exact: true })
    await expect(owner.getByRole('status').filter({ hasText: '所有更改已保存' })).toBeVisible()
    const beforeNotes = await request<{ revision: number }>(owner, `/pages/${presId}/office`)
    await notes.focus()
    await notes.evaluate(node => {
      const textarea = node as HTMLTextAreaElement
      textarea.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }))
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set?.call(textarea, '未確定')
      textarea.dispatchEvent(new InputEvent('input', { bubbles: true, isComposing: true, data: '未確定' }))
    })
    await expect(notes).toHaveValue('未確定')
    // A composition that outlasts the autosave delay still leaves the shared slide untouched.
    await owner.waitForTimeout(2_100)
    expect((await request<{ revision: number }>(owner, `/pages/${presId}/office`)).revision).toBe(beforeNotes.revision)
    await notes.evaluate(node => {
      const textarea = node as HTMLTextAreaElement
      const text = 'Emphasize Ｑ４ margin expansion.'
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set?.call(textarea, text)
      textarea.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: text }))
      textarea.blur()
    })
    await expect
      .poll(async () => (await request<{ revision: number }>(owner, `/pages/${presId}/office`)).revision)
      .toBeGreaterThan(beforeNotes.revision)

    const search = new URL(pageRoute(presId), state.base_url)
    search.searchParams.set('at', 'page:2')
    search.searchParams.set('find', 'q4')
    await owner.goto(search.href)
    await expect(notes).toHaveValue('Emphasize Ｑ４ margin expansion.')

    // Export PDF from the browser Worker.
    const pdfDownload = owner.waitForEvent('download')
    await owner.getByRole('button', { name: '导出 PDF', exact: true }).click()
    const downloadedPdf = await pdfDownload
    expect(downloadedPdf.suggestedFilename()).toMatch(/\.pdf$/i)

    // Verify live .pptx download contains both slides and the speaker notes.
    const href = (await owner.getByRole('link', { name: '下载', exact: true }).getAttribute('href'))!
    const fileRes = await owner.request.get(href)
    expect(fileRes.ok()).toBe(true)
    initPresentationWasm({ module: readFileSync(presentationWasm) })
    const deck = PresentationEditor.open(new Uint8Array(await fileRes.body()), '[]')
    try {
      const slideList = JSON.parse(deck.slides_info()) as Array<{ notes: string }>
      expect(slideList).toHaveLength(2)
      expect(slideList[1].notes).toBe('Emphasize Ｑ４ margin expansion.')
    } finally {
      deck.free()
    }
  } finally {
    if (presId) await request(owner, `/pages/${presId}`, 'DELETE')
    await ownerContext.close()
  }
})

test('an extensionless PPTX file opens read-only and copies a partial text selection', async ({ browser }) => {
  initPresentationWasm({ module: readFileSync(presentationWasm) })
  const deck = PresentationEditor.create_blank('Read only')
  const file = (() => {
    try {
      deck.execute_command(
        'insert.textBox',
        JSON.stringify({ rect: [60, 400, 380, 60], text: 'Select just this word' })
      )
      deck.key_event('Enter', '{}')
      deck.execute_command('text.select', JSON.stringify({ anchor: [0, 0], caret: [0, 6] }))
      const {
        text_quads: [quad]
      } = JSON.parse(deck.selection_info()) as { text_quads: [number, number][][] }
      const [width, height] = deck.slide_pixel_size(1)
      const [x, y] = quad.reduce(([x, y], [px, py]) => [x + px / 4, y + py / 4], [0, 0])
      const endX = Math.max(...quad.map(([px]) => px)) - 1
      return { x: x / width, y: y / height, endX: endX / width, bytes: Buffer.from(deck.export_pptx()) }
    } finally {
      deck.free()
    }
  })()
  const context = await browser.newContext({
    baseURL: state.base_url,
    permissions: ['clipboard-read', 'clipboard-write']
  })
  await context.addCookies(state.owner.cookies)
  const owner = await context.newPage()
  let pageId: string | undefined
  try {
    await owner.goto(pageRoute(state.report_id))
    const { page } = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      type: 'file',
      title: 'Extensionless presentation',
      parent_id: state.report_id
    })
    pageId = page.id
    await owner.goto(pageRoute(pageId))
    await owner.locator('input[type="file"]').setInputFiles({
      name: 'Extensionless presentation',
      mimeType: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      buffer: file.bytes
    })
    const workspace = owner.locator('[data-office-workspace]')
    const canvas = workspace.getByRole('img', { name: '第 1 张幻灯片画布', exact: true })
    await expect(canvas).toBeVisible()
    const box = (await canvas.boundingBox())!
    const y = box.y + file.y * box.height
    await owner.mouse.move(box.x + file.x * box.width, y)
    await owner.mouse.down()
    await owner.mouse.move(box.x + file.endX * box.width, y, { steps: 4 })
    await owner.mouse.up()
    await expect(workspace.locator('svg polygon')).not.toHaveCount(0)
    await workspace.getByRole('button', { name: '复制', exact: true }).click()
    await expect.poll(() => owner.evaluate(() => navigator.clipboard.readText())).toBe('ect')
  } finally {
    if (pageId) await request(owner, `/pages/${pageId}`, 'DELETE')
    await context.close()
  }
})
