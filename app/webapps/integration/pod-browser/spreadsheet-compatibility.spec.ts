import { expect, test, type Page } from '@playwright/test'
import { strFromU8, strToU8, unzipSync, zipSync } from 'fflate'
import * as XLSX from 'xlsx'
import { request, state } from './fixtures'
import { pageRoute } from './routes'

function purchaseWorkbook() {
  const workbook = XLSX.utils.book_new()
  const sheet = XLSX.utils.aoa_to_sheet([
    ['采购单号', '供应商', '数量', '含税单价', '金额'],
    ['PO-20261102-001', '华东包装材料', 12, 18.5, { t: 'n', f: 'C2*D2', v: 222 }],
    ['PO-20261102-002', '华南仓储设备', 8, 25, { t: 'n', f: 'C3*D3', v: 200 }]
  ])
  XLSX.utils.book_append_sheet(workbook, sheet, '采购台账')
  return workbook
}

async function filePage(page: Page) {
  const joined = new Set<string>()
  page.on('websocket', socket => {
    socket.on('framereceived', frame => {
      const [, , topic, event, payload] = JSON.parse(String(frame.payload))
      if (event === 'phx_reply' && payload.status === 'ok') joined.add(topic)
    })
  })
  await page.goto(pageRoute(state.report_id))
  const { page: created } = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
    type: 'file',
    title: '兼容性采购样本',
    parent_id: state.report_id
  })
  await page.goto(pageRoute(created.id))
  // Upload after the existing file channel has joined, so changing its workbook type is exercised.
  await expect.poll(() => joined.has(`page:${created.id}`)).toBe(true)
  return created.id
}

async function upload(page: Page, id: string, name: string, bytes: Uint8Array) {
  const response = () =>
    page.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === `/api/v2/pod/pages/${id}/files`
    )
  const uploaded = response()
  await page
    .locator('input[type="file"]')
    .setInputFiles({ name, mimeType: 'application/octet-stream', buffer: Buffer.from(bytes) })
  let result = await uploaded
  // A download may have compacted the previous object after the form read its manifest.
  if (result.status() === 409) {
    const retried = response()
    await page.getByRole('alert').getByRole('button', { name: '重试', exact: true }).click()
    result = await retried
  }
  expect(result.status()).toBe(200)
  // The upload renames the Page after the file, so its canonical address carries the new title.
  await expect(page).toHaveURL(state.base_url + pageRoute(id, undefined, name))
  const manifest = await request<{ files: { path: string; size: number }[] }>(page, `/pages/${id}/files`)
  expect(manifest.files).toHaveLength(1)
  expect(manifest.files[0].size).toBe(bytes.byteLength)
  const storedName = manifest.files[0].path.split('/').at(-1)!
  await expect(page.getByTitle(storedName, { exact: true }).and(page.locator('main span'))).toBeVisible()
  await expect(page.getByRole('button', { name: '选择替换文件', exact: true })).toBeEnabled()
}

test('a workbook uploaded into an open file page saves edits and follows replacement without reloading', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    id = await filePage(page)
    const workbook = purchaseWorkbook()
    await upload(
      page,
      id,
      '采购上传编辑.xlsx',
      new Uint8Array(XLSX.write(workbook, { type: 'array', bookType: 'xlsx' }))
    )
    await expect(page.getByRole('grid')).toBeVisible()
    const bounds = (await page.getByRole('grid').boundingBox())!
    await page.mouse.click(bounds.x + 48 + 3 * 64 + 16, bounds.y + 24 + 4 * 20 + 8)
    await page.keyboard.insertText('上传后直接保存')
    await page.keyboard.press('Enter')
    await expect(page.getByRole('status').filter({ hasText: '所有更改已保存' })).toBeVisible()
    const latest = await page.request.get(
      (await page.getByRole('link', { name: '下载', exact: true }).getAttribute('href'))!
    )
    expect(XLSX.read(await latest.body()).Sheets['采购台账'].D5.v).toBe('上传后直接保存')

    workbook.Sheets['采购台账'].A1 = { t: 's', v: '替换后的采购台账' }
    const reloaded = page.waitForResponse(
      response =>
        response.request().method() === 'GET' && new URL(response.url()).pathname === `/api/v2/pod/pages/${id}/office`
    )
    await upload(
      page,
      id,
      '采购上传编辑.xlsx',
      new Uint8Array(XLSX.write(workbook, { type: 'array', bookType: 'xlsx' }))
    )
    expect((await reloaded).ok()).toBe(true)
    await expect(page.getByRole('textbox', { name: '单元格内容', exact: true })).toBeEditable()
    const replacedBounds = (await page.getByRole('grid').boundingBox())!
    await page.mouse.click(replacedBounds.x + 64, replacedBounds.y + 32)
    await expect(page.getByRole('textbox', { name: '单元格内容', exact: true })).toHaveValue('替换后的采购台账')

    const legacy = new Uint8Array(XLSX.write(workbook, { type: 'array', bookType: 'xls' }))
    await upload(page, id, '采购上传编辑.xls', legacy)
    await expect(page.getByRole('grid')).toHaveCount(0)
    await expect(
      page
        .getByTitle(/工作表.*采购台账/)
        .contentFrame()
        .getByText('替换后的采购台账', { exact: true })
    ).toBeVisible()
    const response = await page.request.get(
      (await page.getByRole('link', { name: '下载原文件', exact: true }).getAttribute('href'))!
    )
    expect(await response.body()).toEqual(Buffer.from(legacy))
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('unsupported-object warnings and the editing size boundary use the uploaded workbook', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    id = await filePage(page)
    const normal = new Uint8Array(XLSX.write(purchaseWorkbook(), { type: 'array', bookType: 'xlsx' }))
    const parts = unzipSync(normal)
    // This minimal part tests feature detection; it does not claim to model a usable Excel slicer.
    parts['[Content_Types].xml'] = strToU8(
      strFromU8(parts['[Content_Types].xml']).replace(
        '</Types>',
        '<Override PartName="/xl/slicers/slicer1.xml" ContentType="application/vnd.ms-excel.slicer+xml"/></Types>'
      )
    )
    parts['xl/slicers/slicer1.xml'] = strToU8(
      '<slicers xmlns="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main"/>'
    )
    await upload(page, id, '采购台账-对象检测.xlsx', zipSync(parts))
    await expect(page.getByRole('grid')).toBeVisible()
    await expect(page.getByRole('alert').getByText('部分工作簿对象无法保存', { exact: true })).toBeVisible()
    await expect(page.getByRole('alert')).toContainText('版本历史会保留原始文件')
    await page.getByRole('alert').getByRole('button', { name: '关闭', exact: true }).click()
    await expect(page.getByText('部分工作簿对象无法保存', { exact: true })).toHaveCount(0)

    const large = unzipSync(normal)
    large['customXml/size-boundary.bin'] = new Uint8Array(20 * 1024 * 1024)
    const bytes = Buffer.from(zipSync(large, { level: 0 }))
    expect(bytes.byteLength).toBeGreaterThan(20 * 1024 * 1024)
    await upload(page, id, '采购台账-大小边界.xlsx', bytes)
    await expect(
      page.getByText('该工作簿超过了本空间的在线编辑大小上限，请下载后查看或编辑。', { exact: true })
    ).toBeVisible()
    await expect(page.getByRole('grid')).toHaveCount(0)
    const link = page.getByRole('link', { name: '下载', exact: true })
    await expect(link).toBeVisible()
    const response = await page.request.get((await link.getAttribute('href'))!)
    expect(response.ok()).toBe(true)
    expect((await response.body()).equals(bytes)).toBe(true)
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('legacy xls, xlsb, ods, csv and tsv uploads remain read-only previews', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    id = await filePage(page)
    const workbook = purchaseWorkbook()
    for (const kind of ['xls', 'xlsb', 'ods', 'csv', 'tsv'] as const) {
      const bytes =
        kind === 'tsv'
          ? Buffer.from(XLSX.utils.sheet_to_csv(workbook.Sheets['采购台账'], { FS: '\t' }))
          : Buffer.from(XLSX.write(workbook, { type: 'array', bookType: kind }))
      await upload(page, id, `采购台账.${kind}`, bytes)
      if (kind === 'csv' || kind === 'tsv') {
        await expect(page.getByRole('cell', { name: '华东包装材料', exact: true })).toBeVisible()
      } else {
        await expect(
          page
            .getByTitle(/工作表.*采购台账/)
            .contentFrame()
            .getByText('华东包装材料', { exact: true })
        ).toBeVisible()
      }
      await expect(page.getByRole('grid')).toHaveCount(0)
      await expect(page.getByRole('button', { name: '加粗', exact: true })).toHaveCount(0)
      const href = await page.getByRole('link', { name: '下载原文件', exact: true }).getAttribute('href')
      const response = await page.request.get(href!)
      expect(response.ok()).toBe(true)
      expect(await response.body()).toEqual(bytes)
    }
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})
