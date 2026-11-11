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

// A translated string isolates each interpolated value with bidi marks, so a match allows them around the value.
const named = (prefix: string, value: string, suffix: string) => new RegExp(`${prefix}\u2068?${value}\u2069?${suffix}`)

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

test('a repeating Issue with labels shows its next run, and its creator pauses its schedule', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1680, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto('/work')
    const title = `Weekly digest ${Date.now().toString(36)}`
    await page.getByRole('button', { name: '新建 Issue', exact: true }).click()
    await page.getByRole('textbox', { name: '标题', exact: true }).fill(title)
    await page.getByRole('textbox', { name: '标签', exact: true }).fill('增长, Q4')
    await page.getByRole('combobox', { name: '开始方式', exact: true }).click()
    await page.getByRole('option', { name: '稍后开始', exact: true }).click()
    await page.getByRole('combobox', { name: '重复', exact: true }).click()
    await page.getByRole('option', { name: '按计划重复', exact: true }).click()
    await expect(page.getByRole('dialog')).toContainText('每次运行的结果都会发在这个 Issue 的对话里')
    const created = page.waitForResponse(
      response => response.request().method() === 'POST' && new URL(response.url()).pathname.endsWith('/issues')
    )
    await page.getByRole('button', { name: '创建 Issue', exact: true }).click()
    expect((await created).ok()).toBe(true)

    const board = page.getByRole('main')
    const card = board.getByRole('region', { name: '待开始', exact: true }).locator('article', { hasText: title })
    await expect(card).toContainText('增长')
    await expect(card).toContainText('Q4')
    await expect(card).toContainText('下次：')

    // A label narrows the board to its Issues.
    const filter = board.getByRole('group', { name: '按标签筛选', exact: true })
    await filter.getByRole('button', { name: '增长', exact: true }).click()
    await expect(card).toBeVisible()
    await expect(board.locator('article', { hasNotText: '增长' })).toHaveCount(0)
    await filter.getByRole('button', { name: '全部', exact: true }).click()

    const changed = page.waitForResponse(
      response =>
        response.request().method() === 'PATCH' && new URL(response.url()).pathname.includes('/issues/scheduled/')
    )
    await board
      .getByRole('region', { name: '定时', exact: true })
      .getByRole('button', { name: `暂停 ${title}`, exact: true })
      .click()
    expect((await changed).ok()).toBe(true)
    await expect(card).toContainText('已暂停')
  } finally {
    await context.close()
  }
})

test('a sub-Issue names its parent, and the parent counts it', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1680, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto('/work')
    const parent = `Launch plan ${Date.now().toString(36)}`
    await request(page, '/issues', 'POST', { title: parent, agentUID: state.agent_uid, start: false })

    await page.getByRole('navigation', { name: 'Work', exact: true }).getByRole('link', { name: parent }).click()
    const panel = page.getByRole('complementary', { name: 'Issue', exact: true })
    await panel.getByRole('button', { name: '新建子 Issue', exact: true }).click()

    const dialog = page.getByRole('dialog')
    await expect(dialog).toContainText(named('属于「', parent, '」'))
    const child = `Competitor pricing ${Date.now().toString(36)}`
    await dialog.getByRole('textbox', { name: '标题', exact: true }).fill(child)
    await dialog.getByRole('combobox', { name: '开始方式', exact: true }).click()
    await page.getByRole('option', { name: '稍后开始', exact: true }).click()
    await dialog.getByRole('button', { name: '创建 Issue', exact: true }).click()

    const column = page.getByRole('main').getByRole('region', { name: '待开始', exact: true })
    await expect(column.locator('article', { hasText: child })).toContainText(named('属于「', parent, '」'))
    await expect(column.locator('article', { hasText: parent }).filter({ hasNotText: child }).first()).toContainText(
      named('子 Issue ', '0', '/\u2068?1')
    )
  } finally {
    await context.close()
  }
})

test("a personal assistant's Issue shows the Squad that shares its work", async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1680, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto('/work')
    const title = `Quarterly deck ${Date.now().toString(36)}`
    await page.getByRole('button', { name: '新建 Issue', exact: true }).click()
    const dialog = page.getByRole('dialog')
    await dialog.getByRole('textbox', { name: '标题', exact: true }).fill(title)
    await dialog.getByRole('combobox', { name: '开始方式', exact: true }).click()
    await page.getByRole('option', { name: '稍后开始', exact: true }).click()
    const squad = dialog.getByRole('group', { name: 'Squad', exact: true })
    await expect(squad).toContainText('你的助理会把工作分给这些同事')
    await squad.getByRole('checkbox').first().check()
    const created = page.waitForResponse(
      response => response.request().method() === 'POST' && new URL(response.url()).pathname.endsWith('/issues')
    )
    await dialog.getByRole('button', { name: '创建 Issue', exact: true }).click()
    const item = (await (await created).json()) as { squad: { name: string }[] }
    expect(item.squad).toHaveLength(1)

    const card = page.getByRole('main').locator('article', { hasText: title })
    await expect(card.getByLabel('Squad', { exact: true })).toBeVisible()
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
