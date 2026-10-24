import { expect, test } from '@playwright/test'

// This HTTP fixture stores the bytes that the page sends as multipart data.
// The controller tests cover the same operations through the real Files owner.
test('an operator uploads, renames, downloads, and deletes an Agent file', async ({ page }) => {
  const bytes = new Map<string, Buffer>()
  await page.route(
    url => url.pathname.startsWith('/api/'),
    async route => {
      const request = route.request()
      const url = new URL(request.url())
      const path = url.pathname
      if (path === '/api/v2/agents/agent-one') {
        return route.fulfill({
          json: { data: { id: 'agent-one', type: 'agent', attributes: { display_name: 'Files Agent' } } }
        })
      }
      if (path === '/api/v2/agents/agent-one/files' && request.method() === 'POST') {
        const form = await new Response(new Uint8Array(request.postDataBuffer()!).buffer, {
          headers: request.headers()
        }).formData()
        const file = form.get('file') as File
        bytes.set(String(form.get('path')), Buffer.from(await file.arrayBuffer()))
        return route.fulfill({ json: { uploaded_file: { path: form.get('path') } } })
      }
      if (path === '/api/v2/agents/agent-one/files/content') {
        const body = bytes.get(url.searchParams.get('path')!)
        return body ? route.fulfill({ body, contentType: 'text/plain' }) : route.fulfill({ status: 404 })
      }
      if (path === '/api/v2/agents/agent-one/file-moves') {
        const { from_path, to_path } = request.postDataJSON().data
        const content = bytes.get(from_path)
        if (!content || bytes.has(to_path)) {
          return route.fulfill({ status: 409, json: { errors: [{ detail: 'Choose another path' }] } })
        }
        bytes.delete(from_path)
        bytes.set(to_path, content)
        return route.fulfill({ json: { moved_files: 1 } })
      }
      if (path === '/api/v2/agents/agent-one/files') {
        if (request.method() === 'DELETE') {
          const deleted = bytes.delete(url.searchParams.get('path')!)
          return route.fulfill({ json: { deleted_files: deleted ? 1 : 0 } })
        }
        return route.fulfill({
          json: {
            file_listing: {
              path: '',
              folders: [],
              truncated: false,
              files: Array.from(bytes, ([path, content]) => ({
                path,
                size: content.length,
                content_type: 'text/plain',
                source: 'console',
                updated_at: '2026-10-23T00:00:00Z',
                conversation_id: null,
                message_id: null
              }))
            }
          }
        })
      }
      return route.fulfill({ status: 404 })
    }
  )
  await page.goto('/files/agent-one')
  await page.getByRole('button', { name: 'Upload', exact: true }).click()
  await page.getByLabel('Upload', { exact: true }).setInputFiles({
    name: 'original.txt',
    mimeType: 'text/plain',
    buffer: Buffer.from('fixture bytes from the operator')
  })
  await page.getByRole('dialog').locator('button[type=submit]').click()
  const original = page.getByRole('row').filter({ hasText: 'original.txt' })
  await expect(original).toBeVisible()
  await original.getByRole('button', { name: 'More actions', exact: true }).click()
  await page.getByRole('menuitem', { name: 'Move or rename', exact: true }).click()
  await page.getByRole('dialog').getByRole('textbox').fill('renamed.txt')
  await page.getByRole('dialog').getByRole('button', { name: 'Move or rename', exact: true }).click()
  await expect(original).toHaveCount(0)
  const renamed = page.getByRole('row').filter({ hasText: 'renamed.txt' })
  await expect(renamed).toBeVisible()
  await renamed.getByRole('button', { name: 'More actions', exact: true }).click()
  const downloaded = page.waitForEvent('download')
  await page.getByRole('menuitem', { name: 'Download', exact: true }).click()
  const download = await downloaded
  expect(download.suggestedFilename()).toBe('renamed.txt')
  const stream = await download.createReadStream()
  const chunks: Buffer[] = []
  for await (const chunk of stream!) chunks.push(Buffer.from(chunk))
  expect(Buffer.concat(chunks).toString()).toBe('fixture bytes from the operator')
  await renamed.getByRole('button', { name: 'More actions', exact: true }).click()
  await page.getByRole('menuitem', { name: 'Delete', exact: true }).click()
  await page.getByRole('dialog').getByRole('button', { name: 'Delete', exact: true }).click()
  await expect(renamed).toHaveCount(0)
})
