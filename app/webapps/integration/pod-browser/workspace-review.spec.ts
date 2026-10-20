import { state, request } from './fixtures'
import { expect, test } from '@playwright/test'
import { pageRoute } from './routes'

const location = (id: string) => state.base_url + pageRoute(id)

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
