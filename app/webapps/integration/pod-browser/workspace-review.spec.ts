import { readFileSync } from 'node:fs'
import { expect, test, type BrowserContext, type Page } from '@playwright/test'
import { pageRoute } from './routes'

const state = JSON.parse(readFileSync(process.env.POD_BROWSER_STATE_PATH!, 'utf8')) as {
  base_url: string
  report_id: string
  database_id: string
  table_id: string
  owner: { cookies: Parameters<BrowserContext['addCookies']>[0] }
}
const location = (id: string) => state.base_url + pageRoute(id)
async function request<T>(page: Page, path: string, method = 'GET', body?: unknown): Promise<T> {
  return page.evaluate(
    async ({ path, method, body }) => {
      const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content ?? ''
      const response = await fetch(`/.internal-apis/pod${path}`, {
        method,
        credentials: 'same-origin',
        headers: {
          accept: 'application/json',
          'content-type': 'application/json',
          'x-ankole-authentication': meta('ankole-authentication'),
          'x-ankole-pod': meta('ankole-pod'),
          'x-csrf-token': meta('csrf-token')
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) })
      })
      if (!response.ok) throw new Error(`${method} ${path}: ${response.status} ${await response.text()}`)
      return response.status === 204 ? null : response.json()
    },
    { path, method, body }
  )
}

for (const fixture of [
  { name: 'unsupported calendar', config: { type: 'calendar' }, removed: 'calendar' },
  { name: 'malformed grid fields', config: { type: 'grid', visible_fields: {} }, removed: 'visible_fields' }
]) {
  test(`a persisted ${fixture.name} inline view can be repaired without losing the document or source table`, async ({
    browser
  }) => {
    const context = await browser.newContext()
    await context.addCookies(state.owner.cookies)
    const page = await context.newPage()
    const errors: string[] = []
    page.on('pageerror', error => errors.push(error.message))
    let savedID: string | undefined
    try {
      await page.goto(location(state.report_id))
      const saved = await request<{ page: { id: string; revision: number } }>(page, '/pages', 'POST', {
        type: 'doc',
        title: `Inline recovery review: ${fixture.name}`
      })
      savedID = saved.page.id
      await request(page, `/pages/${savedID}/content`, 'PUT', {
        base_revision: saved.page.revision,
        xml: `<page><p>Before the view</p><embed ref="${state.database_id}" table="${state.table_id}" view="${JSON.stringify(fixture.config).replaceAll('"', '&quot;')}"/><p>After the view</p></page>`
      })
      await page.goto(location(savedID))
      await page.reload()
      const editor = page.locator('.editor-content')
      await expect(editor).toContainText('Before the view')
      await expect(editor).toContainText('After the view')
      const embed = editor.locator('.embed')
      await expect(embed.getByRole('alert')).toBeVisible()
      await editor.getByText('After the view', { exact: true }).click()
      await page.keyboard.press('End')
      await page.keyboard.insertText(' remains editable')
      await expect
        .poll(
          async () => (await request<{ content: { plain_text: string } }>(page, `/pages/${savedID}`)).content.plain_text
        )
        .toContain('After the view remains editable')
      await embed.getByRole('button', { name: '放弃视图更改', exact: true }).click()
      await expect(embed.locator('.pod-database-grid')).toBeVisible()
      await expect
        .poll(async () => (await request<{ content: { xml: string } }>(page, `/pages/${savedID}`)).content.xml)
        .not.toContain(fixture.removed)
      const content = (await request<{ content: { xml: string } }>(page, `/pages/${savedID}`)).content.xml
      expect(content).toContain(`ref="${state.database_id}"`)
      expect(content).toContain(`table="${state.table_id}"`)
      expect(content).toContain('Before the view')
      expect(content).toContain('After the view remains editable')
      await page.reload()
      await expect(page.locator('.editor-content .pod-database-grid')).toBeVisible()
      await expect(page.locator('.editor-content')).toContainText('After the view remains editable')
      expect(errors).toEqual([])
    } finally {
      try {
        if (savedID) await request(page, `/pages/${savedID}`, 'DELETE')
      } finally {
        await context.close()
      }
    }
  })
}
