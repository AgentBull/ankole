import { readFileSync } from 'node:fs'
import { expect, test } from '@playwright/test'
import { request, state } from './fixtures'
import { pageRoute } from './routes'

test('history identifies old content, icons, and references and compares it with the current document', async ({
  browser
}, info) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const created: string[] = []
  try {
    await page.goto(state.base_url + pageRoute(state.report_id))
    const reference = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'doc',
      title: 'Budget reference'
    })
    created.push(reference.page.id)
    const createdDocument = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'doc',
      title: 'History product review',
      icon: '🧭',
      xml: `<page><p>Original conclusion</p><p><mention page="${reference.page.id}"/></p><p><a href="ankole:page/${reference.page.id}">Budget details</a></p></page>`
    })
    const id = createdDocument.page.id
    created.push(id)
    await page.goto(state.base_url + pageRoute(id))
    const editor = page.locator('.pod-document .editor-content')
    await editor.locator('p').first().click()
    await page.keyboard.press('ControlOrMeta+Home')
    await page.keyboard.insertText('Reviewed: ')
    await expect
      .poll(async () => (await request<{ content: { plain_text: string } }>(page, `/pages/${id}`)).content.plain_text)
      .toContain('Reviewed: Original conclusion')
    await request(page, `/pages/${id}`, 'PATCH', { icon: '🚀' })
    await expect(page.getByRole('button', { name: '更改图标', exact: true })).toHaveText('🚀')

    await page.locator('.pod-page-header').getByRole('button', { name: '更多操作', exact: true }).click()
    await page.getByRole('menuitem', { name: '版本历史', exact: true }).click()
    const history = page.getByRole('dialog', { name: '版本历史', exact: true })
    await history
      .locator('.pod-document-history-list')
      .getByRole('button', { name: /创建文档/ })
      .click()
    const preview = history.getByRole('region', { name: '版本预览', exact: true })
    await expect(preview.locator('.pod-page-icon:not(.pod-mention-page-icon)')).toHaveText('🧭')
    await expect(preview.locator('.editor-content')).toContainText('Original conclusion')
    const link = preview.getByRole('link', { name: 'Budget reference', exact: true })
    await expect(link).toBeVisible()
    await expect(link).toHaveAttribute('href', state.base_url + pageRoute(reference.page.id))
    const openingReference = context.waitForEvent('page')
    await preview.getByRole('link', { name: 'Budget details', exact: true }).click()
    const referencePage = await openingReference
    await expect(referencePage).toHaveURL(state.base_url + pageRoute(reference.page.id))
    await referencePage.close()
    await expect(preview.getByText(/内容修改于/)).toBeVisible()
    await expect(preview.getByText(/快照保存于/)).toBeVisible()

    await history.getByRole('button', { name: '与当前版本比较', exact: true }).click()
    await expect(preview.locator('[data-change="removed"]')).toContainText('Original conclusion')
    await expect(preview.locator('[data-change="added"]')).toContainText('Reviewed: Original conclusion')
    await expect(preview.locator('.pod-page-icon:not(.pod-mention-page-icon)')).toHaveText(['🧭', '🧭', '🚀'])
    await page.screenshot({ path: info.outputPath('history-comparison.png') })
    await page.setViewportSize({ width: 375, height: 812 })
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await expect(history.getByRole('button', { name: '与当前版本比较', exact: true })).toBeVisible()
    await page.screenshot({ path: info.outputPath('history-comparison-mobile.png') })

    const downloading = page.waitForEvent('download')
    await history.getByRole('button', { name: '导出此版本', exact: true }).click()
    const download = await downloading
    const markdown = readFileSync((await download.path())!, 'utf8')
    expect(markdown).toContain('Original conclusion')
    expect(markdown).not.toContain('Reviewed:')
    expect(markdown).toContain(`[Budget reference](${state.base_url + pageRoute(reference.page.id)})`)

    await page.route(`**/api/v2/pod/pages/${reference.page.id}`, route => route.abort('failed'))
    await page.reload()
    await page.locator('.pod-page-header').getByRole('button', { name: '更多操作', exact: true }).click()
    await page.getByRole('menuitem', { name: '版本历史', exact: true }).click()
    await history
      .locator('.pod-document-history-list')
      .getByRole('button', { name: /创建文档/ })
      .click()
    await history.getByRole('button', { name: '与当前版本比较', exact: true }).click()
    await expect(preview.locator('[data-change="removed"]')).toContainText('Original conclusion')
    await expect(preview.locator('[data-change="added"]')).toContainText('Reviewed: Original conclusion')
    await page.unroute(`**/api/v2/pod/pages/${reference.page.id}`)
  } finally {
    for (const id of created.reverse()) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('restore refreshes its fence before confirmation and rejects edits made after confirmation', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto(state.base_url + pageRoute(state.report_id))
    const created = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'doc',
      title: 'Restore fence',
      xml: '<page><p>Original</p></page>'
    })
    id = created.page.id
    await page.goto(state.base_url + pageRoute(id))
    const openHistory = async () => {
      await page.locator('.pod-page-header').getByRole('button', { name: '更多操作', exact: true }).click()
      await page.getByRole('menuitem', { name: '版本历史', exact: true }).click()
      const history = page.getByRole('dialog', { name: '版本历史', exact: true })
      await history
        .locator('.pod-document-history-list')
        .getByRole('button', { name: /创建文档/ })
        .click()
      return history
    }
    let history = await openHistory()
    // This commit happens while the history list is already open.
    await request(page, `/pages/${id}`, 'PATCH', { title: 'Remote title', expected_title: 'Restore fence' })
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true, includeHidden: true })).toHaveValue(
      'Remote title'
    )
    await history.getByRole('button', { name: '恢复此版本', exact: true }).click()
    let confirmation = page.getByRole('dialog', { name: '恢复此版本', exact: true })
    const restored = page.waitForResponse(
      response => response.url().includes('/restore') && response.request().method() === 'POST'
    )
    await confirmation.getByRole('button', { name: '恢复此版本', exact: true }).click()
    expect((await restored).status()).toBe(201)
    await expect(history).toBeHidden()
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue('Restore fence')

    history = await openHistory()
    await history.getByRole('button', { name: '恢复此版本', exact: true }).click()
    confirmation = page.getByRole('dialog', { name: '恢复此版本', exact: true })
    await expect(confirmation).toBeVisible()
    await request(page, `/pages/${id}`, 'PATCH', { title: 'After confirmation', expected_title: 'Restore fence' })
    const conflict = page.waitForResponse(
      response => response.url().includes('/restore') && response.request().method() === 'POST'
    )
    await confirmation.getByRole('button', { name: '恢复此版本', exact: true }).click()
    expect((await conflict).status()).toBe(409)
    expect((await request<{ page: { title: string } }>(page, `/pages/${id}`)).page.title).toBe('After confirmation')
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})
