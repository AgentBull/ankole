import { expect, test } from '@playwright/test'
import { state } from './fixtures'

test('Console navigation reuses the document within a tenant and replaces it when selecting an aggregate record', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.site_admin.cookies)
  const page = await context.newPage()
  const basePath = new URL(state.console_url).pathname
  try {
    await page.goto(`${state.console_url}/agents?data_tenant=`)
    const record = page.locator(`a[href*="/agents/${state.agent_uid}"]`).first()
    await expect(record).toBeVisible()
    await expect(record).toHaveAttribute('href', new RegExp(`data_tenant=${state.tenant_id}`))
    const aggregateDocument = await page.evaluate(() => performance.timeOrigin)
    const detailResponse = page.waitForResponse(
      response => new URL(response.url()).pathname === `/api/v2/agents/${state.agent_uid}`
    )
    await record.click()
    const response = await detailResponse
    expect(response.ok()).toBe(true)
    expect(response.request().headers()['x-ankole-tenant']).toBe(state.tenant_id)
    await expect(page).toHaveURL(new RegExp(`/agents/${state.agent_uid}`))
    const selectedDocument = await page.evaluate(() => performance.timeOrigin)
    expect(selectedDocument).not.toBe(aggregateDocument)

    await page.locator(`a[href="${basePath}/?data_tenant=${state.tenant_id}"]`).first().click()
    await expect(page).toHaveURL(new RegExp(`${basePath}/\\?data_tenant=`))
    await expect(page.locator('main h2').first()).toBeVisible()
    expect(await page.evaluate(() => performance.timeOrigin)).toBe(selectedDocument)

    await page.locator(`a[href="${basePath}/providers"]`).first().click()
    await expect(page).toHaveURL(new RegExp(`${basePath}/providers$`))
    await expect(page.locator('main h2').first()).toBeVisible()
    expect(await page.evaluate(() => performance.timeOrigin)).toBe(selectedDocument)
  } finally {
    await context.close()
  }
})
