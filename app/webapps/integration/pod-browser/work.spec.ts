import { chatWorkspace, request, state } from './fixtures'
import { expect, test, type Page } from '@playwright/test'

async function createIssue(page: Page, title: string, start: '立即开始' | '稍后开始') {
  await page.getByRole('button', { name: '新建 Issue', exact: true }).click()
  await page.getByRole('textbox', { name: '标题', exact: true }).fill(title)
  if (start === '稍后开始') {
    await page.getByRole('combobox', { name: '开始方式', exact: true }).click()
    await page.getByRole('option', { name: start, exact: true }).click()
  }
  const created = page.waitForResponse(
    response => response.request().method() === 'POST' && new URL(response.url()).pathname.endsWith('/issues')
  )
  await page.getByRole('button', { name: '创建 Issue', exact: true }).click()
  expect((await created).ok()).toBe(true)
}

const moved = (page: Page) =>
  page.waitForResponse(
    response => response.request().method() === 'PATCH' && /\/issues\/[^/]+$/.test(new URL(response.url()).pathname)
  )

test('an Issue waits until it starts, and a person accepts and reopens it on the Work board', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1680, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto('/work')
    const title = `Board issue ${Date.now().toString(36)}`
    await createIssue(page, title, '稍后开始')

    // A new Issue opens beside the board with its request ready to edit and nothing sent to the Agent.
    const panel = page.getByRole('complementary', { name: 'Issue', exact: true })
    await expect(panel.getByRole('heading', { name: '待开始', exact: true })).toBeVisible()
    await expect(panel.getByRole('textbox', { name: '描述', exact: true })).toBeVisible()
    await panel.getByRole('button', { name: '关闭 Issue 面板', exact: true }).click()

    // The sidebar names its sections after the same states, so a column is a region of the page itself.
    const column = (name: string) => page.getByRole('main').getByRole('region', { name, exact: true })
    const card = (name: string) => column(name).getByRole('article').filter({ hasText: title })
    await expect(card('待开始')).toBeVisible()

    // The columns that follow the Agent's work take no card from a person.
    await card('待开始').dragTo(column('等你处理'))
    await expect(card('待开始')).toBeVisible()

    let patched = moved(page)
    await card('待开始').dragTo(column('已完成'))
    expect((await patched).ok()).toBe(true)
    await expect(card('已完成')).toBeVisible()
    await page.reload()
    await expect(card('已完成')).toBeVisible()

    // The request was never sent, so the reopened Issue returns to To do, where a person can still start it.
    patched = moved(page)
    await card('已完成').dragTo(column('待验收'))
    expect((await patched).ok()).toBe(true)
    await expect(card('待开始')).toBeVisible()

    await page.getByRole('tab', { name: '列表', exact: true }).click()
    await expect(page.getByRole('button', { name: new RegExp(title) })).toContainText('待开始')
  } finally {
    await context.close()
  }
})

test('starting an Issue sends its request to the Agent as the first message of its room', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1680, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto('/work')
    const title = `Started issue ${Date.now().toString(36)}`
    await createIssue(page, title, '立即开始')

    const panel = page.getByRole('complementary', { name: 'Issue', exact: true })
    await expect(panel.getByText(title, { exact: true }).last()).toBeVisible()
    await expect(panel.getByRole('textbox', { name: '描述', exact: true })).toHaveCount(0)

    // The sidebar lists the Issue under the state that its room is in, and never under To do.
    const sidebar = page.getByRole('navigation', { name: 'Work', exact: true })
    await expect(sidebar.getByRole('link', { name: title })).toBeVisible()
    await expect(
      page.getByRole('main').getByRole('region', { name: '待开始', exact: true }).getByText(title)
    ).toHaveCount(0)
  } finally {
    await context.close()
  }
})

test("an Issue shared with a teammate still addresses the Issue's Agent by default", async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1680, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto('/work')
    const title = `Shared issue ${Date.now().toString(36)}`
    const issue = await request<{ id: string; agent: { name: string } }>(page, '/issues', 'POST', {
      title,
      agentUID: state.agent_uid
    })
    await request(page, `/conversations/${issue.id}/participants`, 'POST', { addUIDs: [state.member.uid] })

    await page.getByRole('navigation', { name: 'Work', exact: true }).getByRole('link', { name: title }).click()
    const panel = page.getByRole('complementary', { name: 'Issue', exact: true })
    const recipient = panel.getByRole('combobox', { name: '选择 Agent', exact: true })
    await expect(recipient).toHaveText(issue.agent.name)

    // The person can still write to the teammates alone and leave the answer to the Agent's judgment.
    await recipient.click()
    await page.getByRole('option', { name: '允许主动回应的 Agent', exact: true }).click()
    await expect(recipient).toHaveText('允许主动回应的 Agent')
  } finally {
    await context.close()
  }
})

test('the Stop action on a card asks Ankole to stop the run of that room', async ({ browser }) => {
  chatWorkspace()
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1680, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    // The other stories read this recorded run while it is live, so its stop request ends at the browser's edge.
    let stopped: string | undefined
    await page.route('**/api/v2/pod/conversations/*/executions/background_agent_job/*/stop', async route => {
      stopped = `${route.request().method()} ${new URL(route.request().url()).pathname}`
      await route.fulfill({ status: 200, contentType: 'application/vnd.api+json', body: '{}' })
    })
    await page.goto('/work')

    // A room without an Issue is on the board while a Background Agent Job runs in it.
    const card = page
      .getByRole('main')
      .getByRole('region', { name: '进行中', exact: true })
      .getByRole('article')
      .filter({ hasText: 'Review recorded background execution.' })
    await expect(card).toContainText('Recorded workspace execution')
    await expect(card).toContainText('已执行 45 步')

    await card.getByRole('button', { name: '停止 Recorded workspace execution', exact: true }).click()
    await expect
      .poll(() => stopped)
      .toMatch(/^POST \/api\/v2\/pod\/conversations\/[^/]+\/executions\/background_agent_job\/\d+\/stop$/)
  } finally {
    await context.close()
  }
})
