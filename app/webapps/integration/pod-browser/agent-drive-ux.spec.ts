import { expect, test } from '@playwright/test'
import { mkdir, writeFile } from 'node:fs/promises'
import { basename, join } from 'node:path'
import { state } from './fixtures'

test('drive uploads start from the picker and rename preserves the folder and bytes', async ({ browser }, testInfo) => {
  const context = await browser.newContext()
  await context.addCookies(state.site_admin.cookies)
  const page = await context.newPage()
  const directory = testInfo.outputPath(`drive-ux-${Date.now()}`)
  const folder = basename(directory)
  const bytes = 'Content kept through upload, rename, move and download.'
  await mkdir(directory, { recursive: true })
  await writeFile(join(directory, 'original.txt'), bytes)
  await writeFile(join(directory, 'occupied.txt'), 'An existing file must stay intact.')
  const drive = `${state.console_url}/drive?owner=${state.agent_uid}&data_tenant=${state.tenant_id}`
  try {
    const readinessResponse = page.waitForResponse(
      response => new URL(response.url()).pathname === '/api/v2/console-readiness'
    )
    await page.goto(drive)
    const readinessHTTP = await readinessResponse
    expect(readinessHTTP.ok()).toBe(true)
    expect((await readinessHTTP.json()).total_core_steps).toBe(4)
    const readiness = page.getByRole('button', { name: /^Ankole 使用准备：/ })
    await expect(readiness).toHaveAttribute('aria-expanded', 'false')
    await expect(page.getByRole('dialog')).toHaveCount(0)
    await readiness.click()
    await expect(page.getByRole('heading', { name: 'Ankole 使用准备', exact: true })).toBeVisible()
    await expect(page.getByRole('link', { name: /接入消息渠道/ })).toHaveCount(0)
    await page.keyboard.press('Escape')
    await expect(readiness).toHaveAttribute('aria-expanded', 'false')
    await page.getByRole('button', { name: '上传', exact: true }).click()
    const chosen = page.waitForEvent('filechooser')
    await page.getByRole('menuitem', { name: '上传文件夹', exact: true }).click()
    await (await chosen).setFiles(directory)
    await expect(page.getByRole('dialog')).toHaveCount(0)
    await expect(page.getByRole('button', { name: '上传', exact: true })).toBeEnabled()
    await page.getByRole('button', { name: folder, exact: true }).click()

    const original = page
      .getByRole('row')
      .filter({ has: page.getByRole('button', { name: 'original.txt', exact: true }) })
    await expect(original).toBeVisible()
    await original.getByRole('button', { name: '更多操作', exact: true }).click()
    await page.getByRole('menuitem', { name: '重命名', exact: true }).click()
    const name = page.getByRole('textbox', { name: '名称', exact: true })
    await expect(name).toHaveValue('original.txt')
    await name.fill('occupied.txt')
    const rejected = page.waitForResponse(
      response =>
        new URL(response.url()).pathname.startsWith(`/api/v2/drive/${state.tenant_id}/nodes/`) &&
        response.request().method() === 'PATCH'
    )
    await name.press('Enter')
    expect((await rejected).ok()).toBe(false)
    await expect(name).toHaveValue('occupied.txt')
    await name.fill('renamed.txt')
    const renamedResponse = page.waitForResponse(
      response =>
        new URL(response.url()).pathname.startsWith(`/api/v2/drive/${state.tenant_id}/nodes/`) &&
        response.request().method() === 'PATCH'
    )
    await name.press('Enter')
    const renamedHTTP = await renamedResponse
    expect(renamedHTTP.ok()).toBe(true)
    expect(renamedHTTP.request().postDataJSON().data).toEqual({
      name: 'renamed.txt'
    })
    await expect(name).toHaveCount(0)
    await page.reload()
    const renamed = page
      .getByRole('row')
      .filter({ has: page.getByRole('button', { name: 'renamed.txt', exact: true }) })
    await expect(renamed).toBeVisible()

    const downloaded = page.waitForEvent('download')
    await renamed.getByRole('button', { name: 'renamed.txt', exact: true }).click()
    const download = await downloaded
    expect(download.suggestedFilename()).toBe('renamed.txt')
    const chunks: Buffer[] = []
    for await (const chunk of (await download.createReadStream())!) chunks.push(Buffer.from(chunk))
    expect(Buffer.concat(chunks).toString()).toBe(bytes)

    await page.getByRole('button', { name: '新建文件夹', exact: true }).click()
    const createDialog = page.getByRole('dialog')
    await createDialog.getByRole('textbox', { name: '名称', exact: true }).fill('archive')
    const createdResponse = page.waitForResponse(
      response =>
        new URL(response.url()).pathname === `/api/v2/drive/${state.tenant_id}/nodes` &&
        response.request().method() === 'POST'
    )
    await createDialog.getByRole('button', { name: '保存', exact: true }).click()
    const createdHTTP = await createdResponse
    expect(createdHTTP.ok()).toBe(true)
    const archiveID = (await createdHTTP.json()).id
    await expect(createDialog).toHaveCount(0)

    await renamed.getByRole('button', { name: '更多操作', exact: true }).click()
    await page.getByRole('menuitem', { name: '移动', exact: true }).click()
    const dialog = page.getByRole('dialog')
    await dialog.getByRole('button', { name: state.agent_uid, exact: true }).click()
    await dialog.getByRole('button', { name: folder, exact: true }).click()
    await dialog.getByRole('button', { name: 'archive', exact: true }).click()
    const movedResponse = page.waitForResponse(
      response =>
        new URL(response.url()).pathname.startsWith(`/api/v2/drive/${state.tenant_id}/nodes/`) &&
        response.request().method() === 'PATCH'
    )
    await dialog.getByRole('button', { name: '移动到这里', exact: true }).click()
    const movedHTTP = await movedResponse
    expect(movedHTTP.ok()).toBe(true)
    expect(movedHTTP.request().postDataJSON().data).toEqual({ parent_id: archiveID })
    expect(new URL(movedHTTP.url()).pathname).toBe(new URL(renamedHTTP.url()).pathname)
    await expect(dialog).toHaveCount(0)
    await page.getByRole('button', { name: 'archive', exact: true }).click()
    await expect(page.getByRole('button', { name: 'renamed.txt', exact: true })).toBeVisible()
    await page.screenshot({ path: testInfo.outputPath('drive-after-move.png'), fullPage: true })

    await page.goto(drive)
    const uploadedFolder = page
      .getByRole('row')
      .filter({ has: page.getByRole('button', { name: folder, exact: true }) })
    await uploadedFolder.getByRole('button', { name: '更多操作', exact: true }).click()
    await page.getByRole('menuitem', { name: '删除', exact: true }).click()
    await page.getByRole('dialog').getByRole('button', { name: '删除', exact: true }).click()
    await expect(uploadedFolder).toHaveCount(0)
  } finally {
    await context.close()
  }
})
