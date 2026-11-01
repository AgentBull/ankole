import { expect, test } from '@playwright/test'
import type { ListDriveNodesResponse } from '../console/api/v2/generated/types.gen'

// This HTTP fixture stores the bytes that the page sends as multipart data.
// Controller tests cover the same operations through the real Files owner.
test('an operator uploads, renames, downloads, and deletes a Drive file', async ({ page }, testInfo) => {
  const tenantID = '019a2ee2-45d1-7cb5-b54d-d62a7d0f6b86'
  const rootID = '019a2ee2-45d1-7cb5-b54d-d62a7d0f6b87'
  const fileID = '019a2ee2-45d1-7cb5-b54d-d62a7d0f6b88'
  const nodes = new Map<string, ListDriveNodesResponse['nodes'][number]>()
  const bytes = new Map<string, Buffer>()
  const base = `/api/v2/drive/${tenantID}`
  await page.addInitScript(id => sessionStorage.setItem('ankole.console.data-tenant:anonymous', id), tenantID)
  await page.route(
    url => url.pathname.startsWith('/api/'),
    async route => {
      const request = route.request()
      const url = new URL(request.url())
      const path = url.pathname
      expect(request.headers()['x-ankole-tenant']).toBe(tenantID)
      if (path === `${base}/uploads` && request.method() === 'POST') {
        const form = await new Response(new Uint8Array(request.postDataBuffer()!).buffer, {
          headers: request.headers()
        }).formData()
        const file = form.get('file') as File
        expect(form.get('parent_id')).toBe(rootID)
        bytes.set(fileID, Buffer.from(await file.arrayBuffer()))
        nodes.set(fileID, {
          id: fileID,
          parent_id: rootID,
          name: String(form.get('name')),
          kind: 'file',
          size: file.size,
          content_type: 'text/plain',
          object_id: '019a2ee2-45d1-7cb5-b54d-d62a7d0f6b89',
          updated_at: '2026-10-30T00:00:00Z'
        })
        return route.fulfill({ json: { id: fileID } })
      }
      if (path === `${base}/nodes/${fileID}/content`) {
        const body = bytes.get(fileID)
        return body ? route.fulfill({ body, contentType: 'text/plain' }) : route.fulfill({ status: 404 })
      }
      if (path === `${base}/nodes/${fileID}` && request.method() === 'PATCH') {
        const data = request.postDataJSON().data
        expect(data).toEqual({ name: 'renamed.txt' })
        nodes.get(fileID)!.name = data.name
        return route.fulfill({ json: { id: fileID } })
      }
      if (path === `${base}/nodes/${fileID}` && request.method() === 'DELETE') {
        nodes.delete(fileID)
        return route.fulfill({ json: { id: fileID } })
      }
      if (path === `${base}/nodes`) {
        expect(url.searchParams.get('parent_id')).toBe(rootID)
        return route.fulfill({
          json: {
            nodes: Array.from(nodes.values()),
            ancestors: [{ id: rootID, name: 'Agent private drive' }],
            next_after: null
          }
        })
      }
      return route.fulfill({ status: 404 })
    }
  )
  await page.goto(`/drive?node=${rootID}`)
  await page.getByRole('button', { name: 'Upload', exact: true }).click()
  const chosen = page.waitForEvent('filechooser')
  await page.getByRole('menuitem', { name: 'Upload files', exact: true }).click()
  await (
    await chosen
  ).setFiles({
    name: 'original.txt',
    mimeType: 'text/plain',
    buffer: Buffer.from('fixture bytes from the operator')
  })
  await expect(page.getByRole('dialog')).toHaveCount(0)
  const original = page.getByRole('row').filter({ hasText: 'original.txt' })
  await expect(original).toBeVisible()
  await original.getByRole('button', { name: 'More actions', exact: true }).click()
  await page.getByRole('menuitem', { name: 'Rename', exact: true }).click()
  await page.getByRole('textbox', { name: 'Name', exact: true }).fill('renamed.txt')
  await page.getByRole('textbox', { name: 'Name', exact: true }).press('Enter')
  await expect(original).toHaveCount(0)
  const renamed = page.getByRole('row').filter({ hasText: 'renamed.txt' })
  await expect(renamed).toBeVisible()
  const downloaded = page.waitForEvent('download')
  await renamed.getByRole('button', { name: 'renamed.txt', exact: true }).click()
  const download = await downloaded
  expect(download.suggestedFilename()).toBe('renamed.txt')
  const stream = await download.createReadStream()
  const chunks: Buffer[] = []
  for await (const chunk of stream!) chunks.push(Buffer.from(chunk))
  expect(Buffer.concat(chunks).toString()).toBe('fixture bytes from the operator')
  await page.screenshot({ path: testInfo.outputPath('drive-desktop.png'), fullPage: true })
  await page.setViewportSize({ width: 390, height: 640 })
  await expect(renamed).toBeVisible()
  await page.screenshot({ path: testInfo.outputPath('drive-mobile.png'), fullPage: true })
  await renamed.getByRole('button', { name: 'More actions', exact: true }).click()
  await page.getByRole('menuitem', { name: 'Delete', exact: true }).click()
  await page.getByRole('dialog').getByRole('button', { name: 'Delete', exact: true }).click()
  await expect(renamed).toHaveCount(0)
})
