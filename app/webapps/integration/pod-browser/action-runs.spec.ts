import { expect, test } from '@playwright/test'
import { closeRealtimeSocket, publishApplet, request, state } from './fixtures'
import { pageRoute } from './routes'

test('an import reports failure, resumes saved work after a repair, and catches up after reconnecting', async ({
  browser
}, testInfo) => {
  test.skip(!state.actions, 'Start the fixture with POD_BROWSER_ACTIONS=true')
  const action = state.actions!
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let revision = 1
  try {
    await page.goto(state.base_url + pageRoute(action.page_id))
    const frame = page.frameLocator('iframe')
    await expect(frame.getByRole('heading', { name: 'Import 100 records' })).toBeVisible()
    await frame.getByRole('button', { name: 'Start import' }).click()
    await expect(frame.getByRole('status', { name: 'Import status' })).toHaveText(/Importing: [1-9]\d of 100/, {
      timeout: 30000
    })
    const initialID = await frame.getByLabel('Run ID').textContent()
    revision = (await publishApplet(action.page_id, revision, action.missing_files)).revision
    await expect(frame.getByRole('alert')).toContainText('missing_action_key', { timeout: 30000 })
    const retained = Number(await frame.getByLabel('Imported row count').textContent())
    expect(retained).toBeGreaterThan(0)
    expect(retained).toBeLessThan(100)
    await page.screenshot({ path: testInfo.outputPath('saved-after-failure.png'), fullPage: true })

    revision = (await publishApplet(action.page_id, revision, action.complete_files)).revision
    await expect(frame.getByLabel('Published revision')).toHaveText(String(revision))
    await expect(frame.getByRole('button', { name: 'Retry import' })).toBeEnabled()
    await frame.getByRole('button', { name: 'Retry import' }).click()
    await expect(frame.getByLabel('Run ID')).not.toHaveText(initialID!)
    const resumedID = await frame.getByLabel('Run ID').textContent()
    await expect
      .poll(async () => Number(await frame.getByLabel('Imported row count').textContent()))
      .toBeGreaterThan(retained)

    await context.setOffline(true)
    await closeRealtimeSocket(page)
    // The real Oban queue keeps running while this browser is offline.
    await page.waitForTimeout(5000)
    await context.setOffline(false)
    await expect(frame.getByRole('status', { name: 'Import status' })).toHaveText('Imported 100 records.', {
      timeout: 60000
    })
    await expect(frame.getByLabel('Imported row count')).toHaveText('100')
    await page.reload()
    await expect(frame.getByRole('status', { name: 'Import status' })).toHaveText('Imported 100 records.')
    await expect(frame.getByLabel('Run ID')).toHaveText(resumedID!)
    const result = await request<{ records: unknown[]; data_version: number }>(
      page,
      `/tables/${action.target_table_id}/query`,
      'POST',
      { page_size: 200 }
    )
    expect(result.records).toHaveLength(100)
    await page.screenshot({ path: testInfo.outputPath('completed-import.png'), fullPage: true })

    await frame.getByRole('button', { name: 'Start import' }).click()
    await expect(frame.getByLabel('Run ID')).not.toHaveText(resumedID!)
    await expect(frame.getByRole('status', { name: 'Import status' })).toHaveText('Imported 100 records.', {
      timeout: 60000
    })
    const unchanged = await request<{ records: unknown[]; data_version: number }>(
      page,
      `/tables/${action.target_table_id}/query`,
      'POST',
      { page_size: 200 }
    )
    expect(unchanged.records).toHaveLength(100)
    expect(unchanged.data_version).toBe(result.data_version)
  } finally {
    await context.setOffline(false)
    await context.close()
  }
})
