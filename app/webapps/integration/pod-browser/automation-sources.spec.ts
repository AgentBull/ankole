import { expect, test, type Page } from '@playwright/test'
import type { JobSchedule } from '@ankole/applet-sdk'
import type { ActionRun } from '@ankole/applet-sdk/types'
import { createHash, randomUUID } from 'node:crypto'
import { createServer } from 'node:http'
import { request, state } from './fixtures'
import { pageRoute } from './routes'

async function choose(page: Page, label: string, name: string) {
  await page.getByRole('combobox', { name: label, exact: true }).click()
  await page.getByRole('option', { name, exact: true }).click()
}

test('connector errors stay visible on the Job and retry returns to the same automation', async ({ browser }) => {
  test.setTimeout(180_000)
  test.skip(!state.actions, 'Start the real fixture with POD_BROWSER_ACTIONS=true')
  if (!state.connector_provider_url) throw new Error('Set POD_BROWSER_CONNECTOR_PROVIDER_URL on the real fixture')
  let finishSubscription: (() => void) | undefined
  let subscriptions = 0
  const provider = createServer((req, res) => {
    const path = new URL(req.url!, state.connector_provider_url).pathname
    res.setHeader('content-type', 'application/json')
    if (path === '/open-apis/auth/v3/tenant_access_token/internal') {
      res.end(JSON.stringify({ code: 0, tenant_access_token: 'browser-approval-token', expire: 7200 }))
    } else if (path.endsWith('/subscribe')) {
      const attempt = ++subscriptions
      finishSubscription = () => {
        res.statusCode = attempt === 1 ? 403 : 200
        res.end(
          JSON.stringify(
            attempt === 1
              ? { code: 99991400, msg: 'Approval permission must be enabled in the platform app.' }
              : { code: 0, data: {} }
          )
        )
      }
    } else if (path.endsWith('/unsubscribe')) {
      res.end(JSON.stringify({ code: 0, data: {} }))
    } else {
      res.writeHead(404).end(JSON.stringify({ code: 404 }))
    }
  })
  await new Promise<void>(resolve =>
    provider.listen(Number(new URL(state.connector_provider_url!).port), '127.0.0.1', resolve)
  )
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const bindingRequests: URL[] = []
  page.on('request', request => {
    const url = new URL(request.url())
    if (request.method() === 'GET' && url.pathname.endsWith('/signal-bindings')) bindingRequests.push(url)
  })
  const pageID = state.actions!.page_id
  const suffix = Date.now()
  const connectionName = `Approval status ${suffix}`
  let jobID: number | undefined
  try {
    await page.goto(state.base_url + pageRoute(pageID))
    const { connection } = await request<{ connection: { id: string } }>(page, '/connectors/auth-configs', 'POST', {
      plugin_id: 'lark',
      auth_scheme: 'lark_app',
      slug: `approval-${suffix}`,
      display_name: connectionName,
      secret: { appID: `approval-${suffix}`, appSecret: 'browser-approval-secret' }
    })
    const { trigger } = await request<{ trigger: { id: string } }>(page, '/connectors/triggers', 'POST', {
      auth_config_id: connection.id,
      trigger_type: 'lark_approval',
      scope_key: `approval-${suffix}`
    })
    const { job } = await request<{ job: { id: number } }>(page, `/pages/${pageID}/jobs`, 'POST', {
      action_key: 'capture',
      label: connectionName,
      authorization_kind: 'human',
      config: {}
    })
    jobID = job.id
    await page.getByRole('button', { name: '自动化', exact: true }).click()
    await choose(page, '自动化任务', connectionName)
    const section = page.getByRole('region', { name: '外部事件', exact: true })
    await choose(page, '事件来源', `${connectionName} · Approval definition · approval-${suffix}`)
    await expect
      .poll(() => bindingRequests.filter(url => url.searchParams.get('job_id') === String(job.id)).length)
      .toBe(1)
    expect(bindingRequests.every(url => url.searchParams.has('job_id') && !url.searchParams.has('config_ref'))).toBe(
      true
    )
    const pending = page.waitForResponse(
      response =>
        response.request().method() === 'GET' && new URL(response.url()).pathname.endsWith('/connectors/triggers')
    )
    await expect(section.getByRole('button', { name: '关联事件', exact: true })).toBeEnabled()
    await section.getByRole('button', { name: '关联事件', exact: true }).click()
    await pending
    await expect(section).toContainText('已关联，等待订阅就绪。')
    await expect.poll(() => Boolean(finishSubscription), { timeout: 70_000 }).toBe(true)
    finishSubscription!()
    await expect(section).toContainText('Approval permission must be enabled in the platform app.', { timeout: 12_000 })
    await page.screenshot({ path: '/tmp/ankole-connectors-job-recovery.png', fullPage: true, animations: 'disabled' })
    await section.getByRole('link', { name: '管理事件来源', exact: true }).click()
    const subscriptionCard = page.locator(`#connector-${trigger.id}`)
    await expect(subscriptionCard).toBeFocused()
    await expect(subscriptionCard).toContainText('Approval permission must be enabled in the platform app.')
    const retried = page.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname.endsWith(`/triggers/${trigger.id}/retry`)
    )
    await subscriptionCard.getByRole('button', { name: '重试', exact: true }).click()
    expect((await retried).ok()).toBe(true)
    await subscriptionCard.getByRole('link', { name: '返回自动化并选择此来源', exact: true }).click()
    await expect(page.getByRole('combobox', { name: '自动化任务', exact: true })).toContainText(connectionName)
    await expect(section.getByRole('button', { name: '已关联', exact: true })).toBeVisible()
    await expect.poll(() => subscriptions, { timeout: 70_000 }).toBe(2)
    finishSubscription!()
    await expect
      .poll(async () => {
        const result = await request<{ triggers: { id: string; status: string }[] }>(page, '/connectors/triggers')
        return result.triggers.find(item => item.id === trigger.id)?.status
      })
      .toBe('active')
    await expect(section).toContainText('此事件会触发当前自动化任务。', { timeout: 12_000 })
  } finally {
    finishSubscription?.()
    if (jobID) await request(page, `/pages/${pageID}/jobs/${jobID}`, 'DELETE')
    await context.close()
    await new Promise<void>(resolve => provider.close(() => resolve()))
  }
})

test('a member configures an Action, runs its schedule, receives a callback, and inspects durable results', async ({
  browser
}, testInfo) => {
  test.skip(!state.actions, 'Start the real fixture with POD_BROWSER_ACTIONS=true')
  const context = await browser.newContext({ viewport: { width: 1280, height: 960 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const pageID = state.actions!.page_id
  const jobName = `行情捕获 ${Date.now()}`
  let jobID: number | undefined
  try {
    await page.goto(state.base_url + pageRoute(pageID))
    await page.getByRole('button', { name: '自动化', exact: true }).click()
    const dialog = page.getByRole('dialog', { name: '自动化' })
    await dialog.getByRole('button', { name: '新建自动化任务' }).click()
    await choose(page, '执行动作', 'capture')
    await dialog.getByLabel('名称', { exact: true }).fill(jobName)
    await dialog.getByLabel('自动化任务配置（JSON）').fill('{"market":"CN"}')
    await dialog.getByRole('button', { name: '创建自动化任务', exact: true }).click()
    await expect(dialog.getByRole('combobox', { name: '自动化任务', exact: true })).toContainText(jobName)
    const { jobs } = await request<{ jobs: { id: number; label: string }[] }>(page, `/pages/${pageID}/jobs`)
    jobID = jobs.find(job => job.label === jobName)!.id
    const root = `/pages/${pageID}/jobs/${jobID}`
    const schedules = dialog.getByRole('region', { name: '定时规则', exact: true })
    await schedules.getByRole('button', { name: '添加定时规则' }).click()
    await schedules.getByLabel('名称', { exact: true }).fill('分钟行情')
    await schedules.getByLabel('间隔（分钟）').fill('60')
    await schedules.getByLabel('事件数据（JSON）').fill('{"mode":"intraday"}')
    await schedules.getByRole('button', { name: '保存', exact: true }).click()
    await expect(schedules).toContainText('分钟行情 · 启用中')
    await schedules.getByRole('button', { name: '立即运行' }).click()
    const history = dialog.getByRole('region', { name: '运行历史', exact: true })
    await expect(history.locator(':scope > details > summary')).toContainText('已成功', { timeout: 30000 })
    await history.locator(':scope > details > summary').first().click()
    await expect(history).toContainText('"mode": "intraday"')
    await expect(history).toContainText('"market": "CN"')

    await schedules.getByRole('button', { name: '暂停', exact: true }).click()
    await expect(schedules).toContainText('分钟行情 · 已暂停')
    await schedules.getByRole('button', { name: '恢复', exact: true }).click()
    await expect(schedules).toContainText('分钟行情 · 启用中')
    await schedules.getByRole('button', { name: '编辑', exact: true }).click()
    await schedules.getByLabel('名称', { exact: true }).fill('收盘行情')
    await schedules.getByLabel('事件数据（JSON）').fill('{"mode":"closing"}')
    await schedules.getByRole('button', { name: '保存', exact: true }).click()
    await expect(schedules).toContainText('收盘行情 · 启用中')
    await schedules.getByRole('button', { name: '触发历史' }).click()
    await schedules.getByText(/^投递回执/).click()
    await expect(schedules).toContainText('已成功')
    await schedules.getByRole('button', { name: /^#\d+$/ }).click()
    await expect(dialog.getByLabel('运行详情', { exact: true })).toContainText('"mode": "intraday"')

    await schedules.getByRole('button', { name: '暂停', exact: true }).click()
    await expect(schedules).toContainText('收盘行情 · 已暂停')
    await schedules.getByRole('button', { name: '编辑', exact: true }).click()
    await choose(page, '重复方式', '按日历重复')
    await choose(page, '调度方式', '每天')
    await schedules.getByLabel('时间', { exact: true }).fill('09:35')
    await schedules.getByLabel('时区', { exact: true }).fill('UTC')
    await schedules.getByRole('button', { name: '保存', exact: true }).click()
    await expect(schedules.getByRole('button', { name: '保存', exact: true })).toHaveCount(0)
    const daily = await request<{ result: JobSchedule[] }>(page, `${root}/schedules`)
    expect(daily.result).toHaveLength(1)
    expect(daily.result[0]).toMatchObject({
      name: '收盘行情',
      status: 'paused',
      timezone: 'Etc/UTC',
      schedule: { kind: 'cron', expression: '35 9 * * *' }
    })
    await schedules.getByRole('button', { name: '编辑', exact: true }).click()
    await expect(schedules.getByRole('combobox', { name: '调度方式', exact: true })).toContainText('每天')
    await expect(schedules.getByLabel('时间', { exact: true })).toHaveValue('09:35')
    await schedules.locator('[data-slot="cron-editor"]').scrollIntoViewIfNeeded()
    await page.screenshot({ path: testInfo.outputPath('automation-daily-schedule.png'), fullPage: true })
    await choose(page, '调度方式', '每周')
    await schedules.getByRole('button', { name: '周五', exact: true }).click()
    await schedules.getByLabel('时间', { exact: true }).fill('15:10')
    await schedules.locator('[data-slot="cron-editor"]').scrollIntoViewIfNeeded()
    await page.screenshot({ path: testInfo.outputPath('automation-weekly-schedule.png'), fullPage: true })
    await schedules.getByRole('button', { name: '保存', exact: true }).click()
    await expect(schedules.getByRole('button', { name: '保存', exact: true })).toHaveCount(0)
    const weekly = await request<{ result: JobSchedule[] }>(page, `${root}/schedules`)
    expect(weekly.result).toHaveLength(1)
    expect(weekly.result[0]).toMatchObject({
      name: '收盘行情',
      status: 'paused',
      timezone: 'Etc/UTC',
      schedule: { kind: 'cron', expression: '10 15 * * 5' }
    })

    const webhooks = dialog.getByRole('region', { name: 'Webhook 回调', exact: true })
    await webhooks.getByRole('button', { name: '添加 Webhook' }).click()
    await webhooks.getByLabel('名称', { exact: true }).fill('行情回调')
    const expires = webhooks.getByLabel('过期时间', { exact: true })
    const futureExpiry = await expires.inputValue()
    await expires.fill('2000-01-01T00:00')
    await webhooks.getByRole('button', { name: '保存', exact: true }).click()
    const error = dialog.getByRole('alert')
    await expect(error).toContainText('请选择晚于当前时间的过期时间，然后重新保存。')
    await expect(error).toBeInViewport()
    await expect.poll(() => error.evaluate(element => document.activeElement?.contains(element))).toBe(true)
    await expect(webhooks.getByLabel('名称', { exact: true })).toHaveValue('行情回调')
    await expect(expires).toHaveValue('2000-01-01T00:00')
    await expires.fill(futureExpiry)
    await webhooks.getByRole('button', { name: '保存', exact: true }).click()
    const callback = await webhooks.getByRole('textbox', { name: '回调地址' }).inputValue()
    expect(callback).toContain('/webhooks/v1/event-callbacks/wh_')
    await webhooks.getByRole('button', { name: '暂停', exact: true }).click()
    await expect(webhooks).toContainText('行情回调 · 已暂停')
    expect((await context.request.post(callback, { data: 'paused-receipt' })).status()).toBe(204)
    const before = await request<{ runs: unknown[] }>(page, `${root}/runs`)
    expect(before.runs).toHaveLength(1)
    await webhooks.getByRole('button', { name: '恢复', exact: true }).click()
    await expect(webhooks).toContainText('行情回调 · 启用中')
    expect((await context.request.post(callback, { data: 'closing-receipt' })).status()).toBe(204)
    await expect
      .poll(async () => {
        const { runs } = await request<{ runs: { status: string; result: { data: { body: string } } }[] }>(
          page,
          `${root}/runs`
        )
        return runs.filter(run => run.status === 'succeeded' && run.result.data.body === 'closing-receipt').length
      })
      .toBe(1)
    await webhooks.getByRole('button', { name: '编辑', exact: true }).click()
    await webhooks.getByLabel('名称', { exact: true }).fill('收盘回调')
    await webhooks.getByRole('button', { name: '保存', exact: true }).click()
    await expect(webhooks).toContainText('收盘回调 · 启用中')
    await dialog.evaluate(element => element.scrollTo({ top: 0 }))
    await page.screenshot({ path: testInfo.outputPath('automation-with-results.png'), fullPage: true })

    await page.reload()
    await page.getByRole('button', { name: '自动化', exact: true }).click()
    await choose(page, '自动化任务', jobName)
    await expect(schedules).toContainText('收盘行情')
    await expect(history.locator(':scope > details')).toHaveCount(2)
    await webhooks.getByRole('button', { name: '吊销', exact: true }).click()
    await expect(webhooks).toContainText('收盘回调 · 已取消')
    expect((await context.request.post(callback, { data: 'revoked' })).status()).toBe(204)
    expect((await request<{ runs: unknown[] }>(page, `${root}/runs`)).runs).toHaveLength(2)
    await schedules.getByRole('button', { name: '删除', exact: true }).click()
    await expect(schedules).not.toContainText('收盘行情 ·')
    await dialog.getByRole('button', { name: '删除自动化任务', exact: true }).click()
    await dialog.getByRole('button', { name: '删除', exact: true }).click()
    await expect(dialog.getByRole('combobox', { name: '自动化任务', exact: true })).not.toContainText(jobName)
    jobID = undefined
    expect((await context.request.post(callback, { data: 'deleted' })).status()).toBe(404)
  } finally {
    if (jobID) await request(page, `/pages/${pageID}/jobs/${jobID}`, 'DELETE')
    await context.close()
  }
})

test('an administrator selects Lark task events and receives only the enabled event type in the Action', async ({
  browser
}) => {
  test.skip(!state.actions, 'Start the real fixture with POD_BROWSER_ACTIONS=true')
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const pageID = state.actions!.page_id
  const suffix = Date.now()
  const connectionName = `Task events ${suffix}`
  let jobID: number | undefined
  try {
    await page.goto(state.base_url + pageRoute(pageID))
    const { connection } = await request<{ connection: { id: string } }>(page, '/connectors/auth-configs', 'POST', {
      plugin_id: 'lark',
      auth_scheme: 'lark_app',
      slug: `tasks-${suffix}`,
      display_name: connectionName,
      secret: {
        appID: `tasks-${suffix}`,
        appSecret: 'local-task-app-secret',
        verificationToken: 'local-task-verification',
        encryptKey: 'local-task-signature-key'
      }
    })
    await page.getByRole('button', { name: '自动化', exact: true }).click()
    const dialog = page.getByRole('dialog', { name: '自动化' })
    await dialog.getByRole('button', { name: '新建自动化任务' }).click()
    await choose(page, '执行动作', 'capture')
    const jobName = `任务变化 ${suffix}`
    await dialog.getByLabel('名称', { exact: true }).fill(jobName)
    await dialog.getByRole('button', { name: '创建自动化任务', exact: true }).click()
    await expect(dialog.getByRole('combobox', { name: '自动化任务', exact: true })).toContainText(jobName)
    const { jobs } = await request<{ jobs: { id: number; label: string }[] }>(page, `/pages/${pageID}/jobs`)
    jobID = jobs.find(job => job.label === jobName)!.id
    await choose(page, '事件来源', `${connectionName} · Lark business events`)
    await choose(page, '事件类型', 'task.task.updated_v1')
    const events = dialog.getByRole('region', { name: '外部事件' })
    await expect(events).toContainText('连接状态: 已启用')
    await expect(events).toContainText('关联此事件，收到事件时自动运行当前自动化任务。')
    await events.getByRole('button', { name: '关联事件', exact: true }).click()
    await expect(events).toContainText('此事件会触发当前自动化任务。')
    await page.keyboard.press('Escape')
    await expect(dialog).not.toBeVisible()
    await page.getByRole('button', { name: '自动化', exact: true }).click()
    await choose(page, '自动化任务', jobName)
    const linked = events.getByLabel('已关联事件', { exact: true })
    await expect(linked.locator(':scope > div')).toHaveCount(1)
    await expect(linked).toContainText(`${connectionName} · Lark business events`)
    await expect(linked).toContainText('task.task.updated_v1')
    await expect(linked).not.toContainText('不限事件类型')
    await expect(linked).not.toContainText('task.task.comment.updated_v1')

    async function sendEvent(type: string) {
      const body = JSON.stringify({
        schema: '2.0',
        header: {
          event_id: randomUUID(),
          event_type: type,
          token: 'local-task-verification',
          app_id: `tasks-${suffix}`
        },
        event: { task_id: 'task-42', summary: 'Review the closing report' }
      })
      const timestamp = String(Math.floor(Date.now() / 1000))
      const signature = createHash('sha256').update(`${timestamp}noncelocal-task-signature-key${body}`).digest('hex')
      const response = await context.request.post(
        `${state.base_url}/webhooks/connectors/${state.tenant_id}/auth/${connection.id}`,
        {
          headers: {
            'content-type': 'application/json',
            'x-lark-request-timestamp': timestamp,
            'x-lark-request-nonce': 'nonce',
            'x-lark-signature': signature
          },
          data: body
        }
      )
      expect(response.status()).toBe(200)
    }

    await sendEvent('task.task.comment.updated_v1')
    expect((await request<{ runs: unknown[] }>(page, `/pages/${pageID}/jobs/${jobID}/runs`)).runs).toHaveLength(0)
    await sendEvent('task.task.updated_v1')
    const history = dialog.getByRole('region', { name: '运行历史' })
    await expect(history.locator(':scope > details > summary')).toContainText('已成功', { timeout: 30000 })
    await history.locator(':scope > details > summary').click()
    await expect(history).toContainText('task-42')
    await request(page, `/connectors/auth-configs/${connection.id}`, 'PATCH', { status: 'disabled' })
    await expect(linked).toContainText('连接状态: 已停用', { timeout: 12_000 })
    await expect(linked.locator(':scope > div')).toHaveCount(1)
    await expect(linked).toContainText(`${connectionName} · Lark business events`)
    await expect(linked).toContainText('task.task.updated_v1')
    await linked.getByRole('button', { name: '取消关联', exact: true }).click()
    await expect(linked).toHaveCount(0)
    await request(page, `/connectors/auth-configs/${connection.id}`, 'PATCH', { status: 'active' })
    await page.getByRole('combobox', { name: '事件来源', exact: true }).click({ timeout: 12_000 })
    const source = page.getByRole('option', { name: `${connectionName} · Lark business events`, exact: true })
    await expect(source).toBeVisible({ timeout: 12_000 })
    await source.click()
    await choose(page, '事件类型', 'task.task.updated_v1')
    await expect(events).toContainText('连接状态: 已启用')
    await expect(events.getByRole('button', { name: '关联事件', exact: true })).toBeEnabled()
    await sendEvent('task.task.updated_v1')
    expect((await request<{ runs: unknown[] }>(page, `/pages/${pageID}/jobs/${jobID}/runs`)).runs).toHaveLength(1)
  } finally {
    if (jobID) await request(page, `/pages/${pageID}/jobs/${jobID}`, 'DELETE')
    await context.close()
  }
})

test('a failed Action retains its trigger data and completion time for troubleshooting', async ({
  browser
}, testInfo) => {
  test.skip(!state.actions, 'Start the real fixture with POD_BROWSER_ACTIONS=true')
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const pageID = state.actions!.page_id
  const suffix = Date.now()
  const payload = { incident: `missing-sync-config-${suffix}`, source: 'closing-report' }
  let jobID: number | undefined
  try {
    await page.goto(state.base_url + pageRoute(pageID))
    await page.getByRole('button', { name: '自动化', exact: true }).click()
    const dialog = page.getByRole('dialog', { name: '自动化' })
    await dialog.getByRole('button', { name: '新建自动化任务' }).click()
    await choose(page, '执行动作', 'sync')
    const jobName = `同步失败排查 ${suffix}`
    await dialog.getByLabel('名称', { exact: true }).fill(jobName)
    await dialog.getByLabel('自动化任务配置（JSON）').fill('{}')
    await dialog.getByRole('button', { name: '创建自动化任务', exact: true }).click()
    await expect(dialog.getByRole('combobox', { name: '自动化任务', exact: true })).toContainText(jobName)
    const { jobs } = await request<{ jobs: { id: number; label: string }[] }>(page, `/pages/${pageID}/jobs`)
    jobID = jobs.find(job => job.label === jobName)!.id
    const schedules = dialog.getByRole('region', { name: '定时规则', exact: true })
    await schedules.getByRole('button', { name: '添加定时规则' }).click()
    await schedules.getByLabel('名称', { exact: true }).fill('失败输入保留')
    await schedules.getByLabel('间隔（分钟）').fill('60')
    await schedules.getByLabel('事件数据（JSON）').fill(JSON.stringify(payload))
    await schedules.getByRole('button', { name: '保存', exact: true }).click()
    await expect(schedules).toContainText('失败输入保留 · 启用中')
    await schedules.getByRole('button', { name: '立即运行' }).click()
    const history = dialog.getByRole('region', { name: '运行历史', exact: true })
    const details = history.locator(':scope > details').first()
    await expect(details.locator(':scope > summary')).toContainText('失败', { timeout: 30_000 })
    const { runs } = await request<{ runs: ActionRun[] }>(page, `/pages/${pageID}/jobs/${jobID}/runs`)
    expect(runs).toHaveLength(1)
    const run = runs[0]!
    expect(run.status).toBe('failed')
    expect(run.error).toBe('not_found')
    expect(run.result).toEqual({ error: { code: 'not_found', message: 'not_found', details: null } })
    expect(run.event.data).toMatchObject(payload)
    expect(run.started_at).toBeTruthy()
    expect(run.finished_at).toBeTruthy()
    await details.locator(':scope > summary').click()
    const finishedAt = await page.evaluate(
      iso =>
        new Intl.DateTimeFormat(document.documentElement.lang, { dateStyle: 'medium', timeStyle: 'medium' }).format(
          new Date(iso)
        ),
      run.finished_at!
    )
    await expect(details.getByText(`完成时间: ${finishedAt}`, { exact: true })).toBeVisible()
    const output = details.locator(':scope > div > pre')
    await expect(output).toBeVisible()
    await expect(output).toContainText(JSON.stringify(run.error!))
    await details.getByText('触发事件', { exact: true }).click()
    const input = details.locator('details', { has: page.getByText('触发事件', { exact: true }) }).locator('pre')
    await expect(input).toBeVisible()
    await expect(input).toContainText(`"incident": "${payload.incident}"`)
    await expect(input).toContainText('"source": "closing-report"')
    await input.scrollIntoViewIfNeeded()
    await page.screenshot({ path: testInfo.outputPath('automation-failed-run.png'), fullPage: true })
  } finally {
    if (jobID) await request(page, `/pages/${pageID}/jobs/${jobID}`, 'DELETE')
    await context.close()
  }
})

test('a recurring Cron fires the Action automatically and retains its business payload and slot time', async ({
  browser
}) => {
  test.skip(!state.actions, 'Start the real fixture with POD_BROWSER_ACTIONS=true')
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const pageID = state.actions!.page_id
  let jobID: number | undefined
  try {
    await page.goto(state.base_url + pageRoute(pageID))
    await page.getByRole('button', { name: '自动化', exact: true }).click()
    const dialog = page.getByRole('dialog', { name: '自动化' })
    await dialog.getByRole('button', { name: '新建自动化任务' }).click()
    await choose(page, '执行动作', 'capture')
    const jobName = `自动行情 ${Date.now()}`
    await dialog.getByLabel('名称', { exact: true }).fill(jobName)
    await dialog.getByRole('button', { name: '创建自动化任务', exact: true }).click()
    await expect(dialog.getByRole('combobox', { name: '自动化任务', exact: true })).toContainText(jobName)
    const { jobs } = await request<{ jobs: { id: number; label: string }[] }>(page, `/pages/${pageID}/jobs`)
    jobID = jobs.find(job => job.label === jobName)!.id
    const schedules = dialog.getByRole('region', { name: '定时规则', exact: true })
    await schedules.getByRole('button', { name: '添加定时规则' }).click()
    await schedules.getByLabel('名称', { exact: true }).fill('每分钟自动行情')
    await choose(page, '重复方式', '按日历重复')
    await choose(page, '调度方式', '自定义表达式')
    await schedules.getByLabel('Cron 表达式', { exact: true }).fill('* * * * *')
    await schedules.getByLabel('时区', { exact: true }).fill('UTC')
    await schedules.getByLabel('事件数据（JSON）').fill('{"mode":"intraday"}')
    await schedules.getByRole('button', { name: '保存', exact: true }).click()
    await expect(schedules).toContainText('每分钟自动行情 · 启用中')
    const history = dialog.getByRole('region', { name: '运行历史', exact: true })
    await expect(history.locator(':scope > details > summary').first()).toContainText('已成功', { timeout: 75000 })
    await schedules.getByRole('button', { name: '暂停', exact: true }).click()
    await history.locator(':scope > details > summary').first().click()
    await expect(history).toContainText('"mode": "intraday"')
    await expect(history).toContainText('"cron_fire_slot_at":')
    await expect(history).toContainText('"fired_at":')
  } finally {
    if (jobID) await request(page, `/pages/${pageID}/jobs/${jobID}`, 'DELETE')
    await context.close()
  }
})
