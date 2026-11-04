import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { expect, test, type Page } from '@playwright/test'
import * as XLSX from 'xlsx'
import { request, state } from './fixtures'
import { pageRoute } from './routes'

type Case = {
  file: string
  sheet: string
  cell: string
  before: number | string
  input: number | string
  expected: { cell: string; before: number | string; after: number | string }
  restore_value: number | string
  baseline_totals: { cell: string; label: string; expected: number | string }[]
}

const corpus = new URL('../../../kernel/test/fixtures/spreadsheet/corpus/', import.meta.url)
const cases = JSON.parse(readFileSync(new URL('roundtrip_cases.json', corpus), 'utf8')) as Case[]
const formula = (page: Page) => page.getByRole('textbox', { name: '单元格内容', exact: true })
const saved = (page: Page) => expect(page.getByRole('status').filter({ hasText: '所有更改已保存' })).toBeVisible()

async function filePage(page: Page) {
  await page.goto(pageRoute(state.report_id))
  const { page: created } = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
    type: 'file',
    title: '业务语料回归',
    parent_id: state.report_id
  })
  const joined = new Set<string>()
  page.on('websocket', socket =>
    socket.on('framereceived', frame => {
      const message = JSON.parse(String(frame.payload)) as [unknown, unknown, string, string, { status?: string }]
      if (message[3] === 'phx_reply' && message[4]?.status === 'ok') joined.add(message[2])
    })
  )
  await page.goto(pageRoute(created.id))
  await expect.poll(() => joined.has(`page:${created.id}`)).toBe(true)
  return created.id
}

async function upload(page: Page, id: string, path: string) {
  const uploaded = page.waitForResponse(
    response =>
      response.request().method() === 'POST' && new URL(response.url()).pathname === `/api/v2/pod/pages/${id}/files`
  )
  await page.locator('input[type="file"]').setInputFiles(path)
  expect((await uploaded).status()).toBe(200)
  await expect(page.getByRole('grid')).toBeVisible()
}

// Keyboard navigation follows the real grid and does not assume imported row or column sizes.
async function selectCell(page: Page, sheet: string, address: string) {
  const tabs = page.getByRole('navigation', { name: '工作表', exact: true })
  await tabs.getByRole('button', { name: sheet, exact: true }).click()
  const editor = page.locator('textarea[aria-label^="编辑单元格"]')
  await editor.focus()
  await editor.press('Control+Home')
  const { r, c } = XLSX.utils.decode_cell(address)
  for (let row = 0; row < r; row++) await editor.press('ArrowDown')
  for (let col = 0; col < c; col++) await editor.press('ArrowRight')
  await expect(editor).toHaveAttribute('aria-label', new RegExp(`编辑单元格.*${address}`))
}

async function download(page: Page) {
  await saved(page)
  const href = (await page.getByRole('link', { name: '下载', exact: true }).getAttribute('href'))!
  expect(new URL(href, state.base_url).searchParams.has('sha256')).toBe(false)
  const response = await page.request.get(href)
  expect(response.ok()).toBe(true)
  return response.body()
}

function equals(actual: unknown, expected: number | string) {
  if (typeof expected === 'number') {
    expect(typeof actual).toBe('number')
    expect(
      Math.abs((actual as number) - expected),
      `stored ${String(actual)}, expected ${expected}`
    ).toBeLessThanOrEqual(Math.abs(expected) < 1 ? 1e-7 : 1e-5)
  } else expect(actual).toBe(expected)
}

for (const sample of cases) {
  test(`business corpus ${sample.file} uploads, edits, downloads and restores its reconciled totals`, async ({
    browser
  }, testInfo) => {
    const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1440, height: 1000 } })
    await context.addCookies(state.owner.cookies)
    const page = await context.newPage()
    let id: string | undefined
    try {
      id = await filePage(page)
      await upload(page, id, fileURLToPath(new URL(sample.file, corpus)))
      await selectCell(page, sample.sheet, sample.cell)
      await expect(formula(page)).toHaveValue(String(sample.before))
      await formula(page).fill(String(sample.input))
      await formula(page).press('Enter')
      await saved(page)
      // SheetJS reads stored cached results without recalculating them, independently of GridCraft.
      const edited = XLSX.read(await download(page), { type: 'buffer' })
      equals(edited.Sheets[sample.sheet]![sample.cell]?.v, sample.input)
      equals(edited.Sheets[sample.sheet]![sample.expected.cell]?.v, sample.expected.after)
      expect(edited.Sheets[sample.sheet]![sample.expected.cell]?.f).toBeTruthy()

      await selectCell(page, sample.sheet, sample.cell)
      await formula(page).fill(String(sample.restore_value))
      await formula(page).press('Enter')
      const restored = XLSX.read(await download(page), { type: 'buffer' })
      equals(restored.Sheets[sample.sheet]![sample.expected.cell]?.v, sample.expected.before)
      for (const total of sample.baseline_totals) {
        const [sheet, cell] = total.cell.split('!')
        equals(restored.Sheets[sheet!]![cell!]?.v, total.expected)
      }
    } catch (error) {
      await testInfo.attach('failure-before-cleanup', { body: await page.screenshot(), contentType: 'image/png' })
      throw error
    } finally {
      if (id) await request(page, `/pages/${id}`, 'DELETE')
      await context.close()
    }
  })
}
