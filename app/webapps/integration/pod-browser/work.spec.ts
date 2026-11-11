import { chatWorkspace, request, state } from './fixtures'
import { expect, test, type Page } from '@playwright/test'

/** Hands work to the personal assistant through `POST /issues`, then reloads the page so that it reads the Issue. */
async function createIssue(page: Page, title: string, start: boolean) {
  await page.evaluate(
    async ({ title, start }) => {
      const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content
      const headers = {
        accept: 'application/vnd.api+json',
        'content-type': 'application/vnd.api+json',
        'x-ankole-authentication': meta('ankole-authentication')!,
        'x-ankole-pod': meta('ankole-pod')!,
        'x-csrf-token': meta('csrf-token')!
      }
      const post = async (path: string, data?: unknown) => {
        const options: RequestInit = { method: 'POST', headers }
        if (data !== undefined) options.body = JSON.stringify({ data })
        const response = await fetch(`/api/v2/pod${path}`, options)
        if (!response.ok) throw new Error(`Pod ${path}: ${response.status}`)
        return response.json()
      }
      const assistant = await post('/personal-assistant')
      await post('/issues', { title, agentUID: assistant.uid, start })
    },
    { title, start }
  )
  await page.reload()
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
    await createIssue(page, title, false)

    // Each column is a region of the page that the status names.
    const column = (name: string) => page.getByRole('main').getByRole('region', { name, exact: true })
    const card = (name: string) => column(name).getByRole('article').filter({ hasText: title })
    await expect(card('待开始')).toBeVisible()

    // An Issue that waits opens beside the board with its request ready to edit and nothing sent to the Agent.
    await card('待开始').getByRole('button', { name: title, exact: true }).click()
    const panel = page.getByRole('main').getByRole('complementary', { name: title, exact: true })
    await expect(panel.getByRole('heading', { name: title, exact: true })).toBeVisible()
    await expect(panel).toContainText('待开始')
    await expect(panel.getByRole('textbox', { name: '描述', exact: true })).toBeVisible()
    await expect(panel.getByRole('button', { name: '开始', exact: true })).toBeVisible()
    await panel.getByRole('button', { name: '关闭', exact: true }).click()
    await expect(panel).toHaveCount(0)

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
    await createIssue(page, title, true)

    // The board shows the Issue under the state that its room is in, and never under To do.
    const board = page.getByRole('main')
    await expect(board.getByRole('button', { name: title, exact: true })).toBeVisible()
    await expect(board.getByRole('region', { name: '待开始', exact: true }).getByText(title)).toHaveCount(0)

    // The room has received the request, so the panel no longer offers it for editing and links to the room.
    await board.getByRole('button', { name: title, exact: true }).click()
    const panel = board.getByRole('complementary', { name: title, exact: true })
    await expect(panel.getByRole('heading').first()).toBeVisible()
    await expect(panel.getByRole('textbox', { name: '描述', exact: true })).toHaveCount(0)
    await expect(panel.getByRole('link', { name: '在对话中打开', exact: true })).toBeVisible()
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
    // The card leads with its live run: how far the run has come and how it stands.
    await expect(card).toContainText('已执行 45 步')
    await expect(card).toContainText('运行中')
    // A card shows its Stop action while the pointer rests on it.
    await card.hover()
    await expect(card.getByRole('button', { name: '停止 Recorded workspace execution', exact: true })).toBeVisible()

    // The run opens beside the board in the inspector that the conversation uses for it.
    await card.getByRole('button').first().click()
    const panel = page.getByRole('main').getByRole('complementary')
    await expect(panel.getByRole('heading', { name: 'Recorded workspace execution', exact: true })).toBeVisible()
    await expect(panel).toContainText('已执行 45 步')

    await card.hover()
    await card.getByRole('button', { name: '停止 Recorded workspace execution', exact: true }).click()
    await expect
      .poll(() => stopped)
      .toMatch(/^POST \/api\/v2\/pod\/conversations\/[^/]+\/executions\/background_agent_job\/\d+\/stop$/)
  } finally {
    await context.close()
  }
})

test('Home links to the board while a work item waits to start or runs', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1680, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto('/content/shared')
    await createIssue(page, `Waiting issue ${Date.now().toString(36)}`, false)

    // The row stands directly above Shared with me in the Home tab.
    const home = page.getByRole('navigation', { name: '页面导航', exact: true })
    const work = home.getByRole('link', { name: '后台 Agent 任务', exact: true })
    await expect(work).toBeVisible()
    await expect(
      home.getByRole('listitem').filter({ has: work }).locator('xpath=following-sibling::*[1]')
    ).toContainText('与我共享')

    await work.click()
    await expect(page).toHaveURL(/\/work$/)
    await expect(work).toHaveAttribute('aria-current', 'page')
    await expect(page.getByRole('main').getByRole('heading', { name: '后台 Agent 任务', exact: true })).toBeVisible()

    // The page shows only the board: it has no list layout and no form for a new Issue.
    await expect(page.getByRole('main').getByRole('region', { name: '待开始', exact: true })).toBeVisible()
    await expect(page.getByRole('tab', { name: '列表', exact: true })).toHaveCount(0)
    await expect(page.getByRole('button', { name: '新建 Issue', exact: true })).toHaveCount(0)

    // Beside an open Issue on a laptop screen, the columns wrap onto another row instead of scrolling sideways.
    await page.setViewportSize({ width: 1280, height: 800 })
    const column = page.getByRole('main').getByRole('region', { name: '待开始', exact: true })
    await column.getByRole('article').first().getByRole('button').first().click()
    await expect(page.getByRole('main').getByRole('complementary')).toBeVisible()
    await expect
      .poll(() =>
        column.evaluate(region => {
          let scroller = region.parentElement
          while (scroller && getComputedStyle(scroller).overflowX !== 'auto') scroller = scroller.parentElement
          return scroller ? scroller.scrollWidth - scroller.clientWidth : 0
        })
      )
      .toBe(0)
  } finally {
    await context.close()
  }
})
