import { readFileSync } from 'node:fs'
import { expect, test, type Page } from '@playwright/test'
import { initSync, Spreadsheet } from '@ankole/kernel/spreadsheet-wasm'
import { request, state } from './fixtures'
import { pageRoute } from './routes'

const wasm = new URL('../../../kernel/dist/spreadsheet-wasm/ankole_spreadsheet_wasm_bg.wasm', import.meta.url)

/** Clicks a cell of a blank sheet: its default rows and columns sit after the 48 × 24 px headers. */
async function clickCell(page: Page, row: number, col: number) {
  const grid = page.getByRole('grid')
  const bounds = (await grid.boundingBox())!
  await page.mouse.click(bounds.x + 48 + col * 64 + 16, bounds.y + 24 + row * 20 + 8)
}

/** The value that the active cell paints, without the bidirectional isolates around message placeholders. */
const activeCell = (page: Page) =>
  expect.poll(async () =>
    (await page.getByRole('status', { name: '当前单元格', exact: true }).textContent())?.replace(/[\u2068\u2069]/g, '')
  )
const sheetGrid = (page: Page) => page.getByRole('grid', { name: /工作表.*Sheet1/ })

test('a spreadsheet page edits cells, collaborates live, keeps versions, and downloads the latest workbook', async ({
  browser
}) => {
  const ownerContext = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1280, height: 900 } })
  const memberContext = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1280, height: 900 } })
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const owner = await ownerContext.newPage()
  const member = await memberContext.newPage()
  let id: string | undefined
  try {
    await owner.goto(pageRoute(state.report_id))
    const report = owner.locator('.pod-tree-row', { has: owner.locator(`a[href="${pageRoute(state.report_id)}"]`) })
    await report.hover()
    await report.getByRole('button', { name: '新建页面', exact: true }).click()
    const created = owner.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/spreadsheet-pages'
    )
    await owner.getByRole('menuitem', { name: '电子表格', exact: true }).click()
    const response = await created
    expect(response.status()).toBe(201)
    id = ((await response.json()) as { page: { id: string } }).page.id
    await expect(owner).toHaveURL(state.base_url + pageRoute(id, undefined, 'Untitled.xlsx'))
    await expect(sheetGrid(owner)).toBeVisible()

    await clickCell(owner, 0, 0)
    await owner.keyboard.type('12')
    await owner.keyboard.press('Enter')
    await owner.keyboard.type('=A1*2')
    await owner.keyboard.press('Enter')
    await owner.keyboard.press('ArrowUp')
    await activeCell(owner).toBe('A2：24')
    await expect(owner.getByRole('textbox', { name: '单元格内容', exact: true })).toHaveValue('=A1*2')
    await expect(owner.getByRole('status').filter({ hasText: '所有更改已保存' })).toBeVisible()

    await member.goto(pageRoute(id))
    await expect(sheetGrid(member)).toBeVisible()
    await clickCell(member, 1, 0)
    await activeCell(member).toBe('A2：24')
    await expect(member.getByTitle('Browser owner', { exact: true })).toBeVisible()
    await expect(owner.getByTitle('Browser member', { exact: true })).toBeVisible()

    // The owner inserts a row above A1; the member's formula moves to A3 with its reference.
    await clickCell(owner, 0, 0)
    await owner.getByRole('button', { name: '行和列', exact: true }).click()
    await owner.getByRole('menuitem', { name: '在上方插入行', exact: true }).click()
    await activeCell(member).toBe('A3：24')
    await expect(member.getByRole('textbox', { name: '单元格内容', exact: true })).toHaveValue('=A2*2')
    await expect(owner.getByRole('status').filter({ hasText: '所有更改已保存' })).toBeVisible()

    // The download carries no digest, so the server writes the pending edits into the file first.
    const download = owner.getByRole('link', { name: '下载', exact: true })
    const href = (await download.getAttribute('href'))!
    expect(new URL(href, state.base_url).searchParams.has('sha256')).toBe(false)
    const file = await owner.request.get(href)
    expect(file.ok()).toBe(true)
    initSync({ module: readFileSync(wasm) })
    const workbook = Spreadsheet.open(new Uint8Array(await file.body()), '[]')
    try {
      expect(workbook.cell_input(1, 'A2')).toBe('12')
      expect(workbook.cell_input(1, 'A3')).toBe('=A2*2')
      expect(JSON.parse(workbook.viewport(1, 2, 0, 2, 0)).cells[0].text).toBe('24')
    } finally {
      workbook.free()
    }

    // The page history records the blank workbook; compaction within the checkpoint interval adds no version.
    await owner.getByRole('button', { name: '版本历史', exact: true }).click()
    const versions = owner.getByRole('list', { name: '版本', exact: true })
    await expect(versions.getByRole('listitem')).toHaveCount(1)
    await expect(versions.getByText('创建', { exact: true })).toBeVisible()
    await expect(versions.getByText(/Browser owner/)).toBeVisible()
    await expect(versions.getByRole('button', { name: '恢复', exact: true })).toBeVisible()
  } finally {
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await ownerContext.close()
    await memberContext.close()
  }
})
