import { chatWorkspace, state } from './fixtures'
import { expect, test } from '@playwright/test'

test('Home permanently links to Jobs above Shared with me and opens the 3-column board without sideways scroll', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1680, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto('/content/shared')

    const home = page.getByRole('navigation', { name: '页面导航', exact: true })
    const jobsLink = home.getByRole('link', { name: 'Jobs', exact: true })
    await expect(jobsLink).toBeVisible()
    await expect(
      home
        .getByRole('listitem')
        .filter({ has: page.getByRole('link', { name: 'Jobs', exact: true }) })
        .locator('xpath=following-sibling::*[1]')
    ).toContainText('与我共享')

    await jobsLink.click()
    await expect(page).toHaveURL(/\/jobs$/)
    await expect(jobsLink).toHaveAttribute('aria-current', 'page')
    await expect(page.getByRole('main').getByRole('heading', { name: 'Jobs', exact: true })).toBeVisible()
    await expect(page.getByRole('main').getByRole('button', { name: '新建作业', exact: true })).toBeVisible()
  } finally {
    await context.close()
  }
})

test('creating a recurring Cron job from New Job places a Living Routine card in Scheduled and manages its lifecycle', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1680, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto('/jobs')

    const title = `Routine digest ${Date.now().toString(36)}`
    await page.getByRole('main').getByRole('button', { name: '新建作业', exact: true }).click()

    const dialog = page.getByRole('dialog', { name: '新建作业' })
    await expect(dialog).toBeVisible()
    await dialog.getByRole('tab', { name: '周期性 Cron', exact: true }).click()
    await dialog.getByLabel('标题').fill(title)
    await dialog.getByLabel('执行指令').fill('汇总关键变更并在需要关注时提醒。')
    await dialog.getByRole('button', { name: '创建定时任务', exact: true }).click()

    await expect(dialog).toHaveCount(0)

    const scheduledColumn = page.getByRole('main').getByRole('region', { name: '待运行', exact: true })
    const card = scheduledColumn.getByRole('article').filter({ hasText: title })
    await expect(card).toBeVisible()
    await expect(card).toContainText('0 9 * * 1-5')

    // Newly created routine automatically opens its inspector beside the board.
    const panel = page.getByRole('main').getByRole('complementary')
    await expect(panel.getByRole('heading', { name: title, exact: true })).toBeVisible()
    await expect(panel).toContainText('汇总关键变更并在需要关注时提醒。')

    await panel.getByRole('button', { name: '暂停', exact: true }).click()
    await expect(panel.getByRole('button', { name: '恢复', exact: true })).toBeVisible()
    await expect(card).toContainText('已暂停')

    await panel.getByRole('button', { name: '恢复', exact: true }).click()
    await expect(panel.getByRole('button', { name: '暂停', exact: true })).toBeVisible()

    // Beside an open inspector on a 1280px screen, the columns wrap cleanly without horizontal scroll.
    await page.setViewportSize({ width: 1280, height: 800 })
    await expect
      .poll(() =>
        scheduledColumn.evaluate(region => {
          let scroller = region.parentElement
          while (scroller && getComputedStyle(scroller).overflowX !== 'auto') scroller = scroller.parentElement
          return scroller ? scroller.scrollWidth - scroller.clientWidth : 0
        })
      )
      .toBe(0)

    await panel.getByRole('button', { name: '移除', exact: true }).click()
    await expect(panel).toHaveCount(0)
    await expect(card).toHaveCount(0)
  } finally {
    await context.close()
  }
})

test('a running Background Agent Job appears in Running, opens its execution log, and stops through /api/v2/pod/jobs', async ({
  browser
}) => {
  chatWorkspace()
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1680, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    let stopped: string | undefined
    await page.route('**/api/v2/pod/jobs/executions/background_agent_job/*/stop', async route => {
      stopped = `${route.request().method()} ${new URL(route.request().url()).pathname}`
      await route.fulfill({
        status: 200,
        contentType: 'application/vnd.api+json',
        body: JSON.stringify({ runID: '1', status: 'stopped' })
      })
    })

    await page.goto('/jobs')

    const card = page
      .getByRole('main')
      .getByRole('region', { name: '运行中', exact: true })
      .getByRole('article')
      .filter({ hasText: 'Recorded workspace execution' })
    await expect(card).toBeVisible()
    await expect(card).toContainText('45 步')

    await card.getByRole('button', { name: 'Recorded workspace execution', exact: true }).click()
    const panel = page.getByRole('main').getByRole('complementary')
    await expect(panel.getByRole('heading', { name: 'Recorded workspace execution', exact: true })).toBeVisible()

    await card.hover()
    await card.getByRole('button', { name: '停止', exact: true }).click()
    await expect.poll(() => stopped).toMatch(/^POST \/api\/v2\/pod\/jobs\/executions\/background_agent_job\/\d+\/stop$/)
  } finally {
    await context.close()
  }
})
