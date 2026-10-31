import { closeRealtimeSocket, state, request, requestWithSharingVersion, login, continuePodEntry } from './fixtures'
import { expect, test, type Page } from '@playwright/test'
import { pageRoute, listRoute } from './routes'

const space = (page: Page) => page.getByRole('region', { name: '空间', exact: true })
const rootToggle = (page: Page) => space(page).getByRole('button', { name: '空间', exact: true })
const privateToggle = (page: Page) =>
  page.getByRole('region', { name: '私人页面', exact: true }).getByRole('button', { name: '私人页面', exact: true })

test('hidden Home pauses directory reads and resumes its expanded branches with remote changes', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const writer = await context.newPage()
  const page = await context.newPage()
  const changes: string[] = []
  const directories: URL[] = []
  const errors: string[] = []
  let navigationReads = 0
  page.on('pageerror', error => errors.push(error.message))
  page.on('websocket', socket => {
    socket.on('framereceived', frame => {
      const payload = String(frame.payload)
      if (payload.includes('tree_changed')) changes.push(payload)
    })
  })
  page.on('request', request => {
    const url = new URL(request.url())
    if (request.method() === 'GET' && url.pathname === '/api/v2/pod/pages/children') directories.push(url)
    if (request.method() === 'GET' && url.pathname === '/api/v2/pod/pages/navigation') navigationReads++
  })
  let parent: string | undefined
  try {
    await writer.goto(listRoute('trash'))
    const title = `Retained branch ${crypto.randomUUID()}`
    parent = await create(writer, title)
    await create(writer, `${title} first`, { parent_id: parent })
    await page.goto('/')
    await expect(page.getByRole('textbox', { name: '消息', exact: true })).toBeVisible()
    await page.waitForLoadState('networkidle')
    expect(navigationReads).toBe(0)
    expect(directories).toHaveLength(0)
    await page.getByRole('link', { name: '回收站', exact: true }).click()
    const branch = space(page).getByRole('button', { name: title, exact: true })
    await branch.click()
    await expect(space(page).getByRole('link', { name: `${title} first`, exact: true })).toBeVisible()
    await page.getByRole('tab', { name: '对话', exact: true }).click()
    await expect(space(page)).toBeHidden()
    await page.waitForLoadState('networkidle')
    directories.length = 0

    await privateToggle(writer).click()
    await expect(privateToggle(writer)).toHaveAttribute('aria-expanded', 'false')
    const second = await create(writer, `${title} second`, { parent_id: parent })
    await expect.poll(() => changes.some(frame => frame.includes(second))).toBe(true)
    await page.waitForLoadState('networkidle')
    expect(directories).toHaveLength(0)

    await page.getByRole('tab', { name: '主页', exact: true }).click()
    await expect(privateToggle(page)).toHaveAttribute('aria-expanded', 'false')
    await expect(branch).toHaveAttribute('aria-expanded', 'true')
    await expect(space(page).getByRole('link', { name: `${title} first`, exact: true })).toBeVisible()
    await expect(space(page).getByRole('link', { name: `${title} second`, exact: true })).toBeVisible()
    expect(directories.filter(url => url.searchParams.get('parent_id') === parent)).toHaveLength(1)
    await branch.click()
    await expect(branch).toHaveAttribute('aria-expanded', 'false')
    await branch.click()
    await expect(space(page).getByRole('link', { name: `${title} second`, exact: true })).toBeVisible()
    expect(errors).toEqual([])
  } finally {
    if (parent) await request(writer, `/pages/${parent}`, 'DELETE')
    await context.close()
  }
})

test('HTTP renders the page and directory while realtime waits, then reconciles changes made before subscribing', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const writer = await context.newPage()
  const reader = await context.newPage()
  const token = Promise.withResolvers<void>()
  let root: string | undefined
  try {
    await writer.goto(pageRoute(state.report_id))
    const title = `Parallel startup ${crypto.randomUUID()}`
    root = await create(writer, title)
    await reader.route('**/api/v2/pod/realtime-token', async route => {
      await token.promise
      await route.continue()
    })
    await reader.goto(pageRoute(root))
    await expect(reader.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(title)
    await expect(space(reader).getByRole('link', { name: title, exact: true })).toBeVisible()

    await request(writer, `/pages/${root}`, 'PATCH', { title: `${title} renamed`, expected_title: title })
    await create(writer, `${title} child`, { parent_id: root })
    token.resolve()
    await expect(space(reader).getByRole('link', { name: `${title} renamed`, exact: true })).toBeVisible()
    await expect(reader.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(`${title} renamed`)
    await space(reader)
      .getByRole('button', { name: `${title} renamed`, exact: true })
      .click()
    await expect(space(reader).getByRole('link', { name: `${title} child`, exact: true })).toBeVisible()
  } finally {
    token.resolve()
    if (root) await request(writer, `/pages/${root}`, 'DELETE')
    await context.close()
  }
})

test('deleting and restoring an audience source updates a separate directory for its reader', async ({ browser }) => {
  const owner = await browser.newContext({ baseURL: state.base_url })
  const reader = await browser.newContext({ baseURL: state.base_url })
  await owner.addCookies(state.owner.cookies)
  await reader.addCookies(state.member.cookies)
  const editor = await owner.newPage()
  const page = await reader.newPage()
  const roots: string[] = []
  try {
    await editor.goto(pageRoute(state.report_id))
    const label = crypto.randomUUID()
    const sourceParent = await create(editor, `Source folder ${label}`)
    roots.push(sourceParent)
    const source = await create(editor, `Audience source ${label}`, { parent_id: sourceParent })
    const targetParent = await create(editor, `Target folder ${label}`)
    roots.push(targetParent)
    const target = await create(editor, `Audience target ${label}`, { parent_id: targetParent })
    await requestWithSharingVersion(editor, `/pages/${target}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [{ source_page_id: source, source_action: 'page_view', role: 'view' }]
    })
    await page.goto(pageRoute(targetParent))
    await space(page)
      .getByRole('button', { name: `Target folder ${label}`, exact: true })
      .click()
    const targetLink = space(page).getByRole('link', { name: `Audience target ${label}`, exact: true })
    await expect(targetLink).toBeVisible()

    await editor.goto(pageRoute(source))
    const sourceRow = space(editor).locator('.pod-tree-row', {
      has: editor.getByRole('link', { name: `Audience source ${label}`, exact: true })
    })
    await sourceRow.click({ button: 'right' })
    await editor.getByRole('menuitem', { name: '移到回收站', exact: true }).click()
    await expect(targetLink).toHaveCount(0)
    await editor.getByRole('button', { name: '撤销', exact: true }).click()
    await space(page)
      .getByRole('button', { name: `Target folder ${label}`, exact: true })
      .click()
    await expect(targetLink).toBeVisible()
  } finally {
    for (const id of roots.reverse()) await request(editor, `/pages/${id}`, 'DELETE').catch(() => {})
    await owner.close()
    await reader.close()
  }
})

test('bootstrap restores the active path, intent prefetch opens from cache, and remote rename keeps branches fresh', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const created: string[] = []
  const token = Promise.withResolvers<void>()
  try {
    await page.goto(pageRoute(state.report_id))
    const label = crypto.randomUUID()
    const root = await create(page, `Root ${label}`)
    created.push(root)
    const middle = await create(page, `Middle ${label}`, { parent_id: root })
    const active = await create(page, `Active ${label}`, { parent_id: middle })
    const other = await create(page, `Other ${label}`)
    created.push(other)
    const otherChild = await create(page, `Other child ${label}`, { parent_id: other })
    const cold = await create(page, `Cold ${label}`)
    created.push(cold)
    await create(page, `Cold child ${label}`, { parent_id: cold })
    const requests: URL[] = []
    page.on('request', request => {
      if (request.method() === 'GET') requests.push(new URL(request.url()))
    })
    await page.route('**/api/v2/pod/realtime-token', async route => {
      await token.promise
      await route.continue()
    })
    await page.goto(pageRoute(active))
    const sidebar = space(page)
    await expect(sidebar.getByRole('link', { name: `Active ${label}`, exact: true })).toBeVisible()
    expect(requests.filter(url => url.pathname === '/api/v2/pod/pages/navigation')).toHaveLength(1)
    const rootRequests = requests.filter(url => url.pathname === '/api/v2/pod/pages/children')
    expect(rootRequests).toHaveLength(1)
    expect(rootRequests[0]!.searchParams.get('scope')).toBe('space')
    expect(rootRequests[0]!.searchParams.has('parent_id')).toBe(false)
    expect(rootRequests[0]!.searchParams.has('cursor')).toBe(false)
    expect(requests.filter(url => url.pathname === '/api/v2/pod/space')).toHaveLength(0)
    const reconciled = page.waitForResponse(
      response => new URL(response.url()).pathname === '/api/v2/pod/pages/navigation'
    )
    token.resolve()
    await (await reconciled).finished()
    await page.unroute('**/api/v2/pod/realtime-token')
    expect(requests.filter(url => url.pathname === '/api/v2/pod/pages/navigation')).toHaveLength(2)
    const otherToggle = sidebar.getByRole('button', { name: `Other ${label}`, exact: true })
    await expect(otherToggle).toHaveAttribute('aria-expanded', 'false')
    const preloaded = page.waitForResponse(response => new URL(response.url()).searchParams.get('parent_id') === other)
    await otherToggle.hover()
    expect((await preloaded).ok()).toBe(true)
    await otherToggle.click()
    await expect(sidebar.locator(`a[href="${pageRoute(otherChild)}"]`)).toBeVisible()
    await otherToggle.click()
    await otherToggle.click()
    await expect(sidebar.locator(`a[href="${pageRoute(otherChild)}"]`)).toBeVisible()
    expect(
      requests.filter(
        url => url.pathname === '/api/v2/pod/pages/children' && url.searchParams.get('parent_id') === other
      )
    ).toHaveLength(1)

    let release!: () => void
    const hold = new Promise<void>(resolve => {
      release = resolve
    })
    await page.route('**/pages/children?*', async route => {
      if (new URL(route.request().url()).searchParams.get('parent_id') === cold) await hold
      await route.continue()
    })
    const coldToggle = sidebar.getByRole('button', { name: `Cold ${label}`, exact: true })
    await coldToggle.focus()
    await coldToggle.press('Enter')
    await expect(coldToggle).toHaveAttribute('aria-expanded', 'true')
    await expect(coldToggle).toHaveAttribute('aria-busy', 'true')
    await expect(sidebar.locator('.pod-tree-children > li[role="status"]')).toHaveCount(0)
    release()
    await expect(sidebar.getByRole('link', { name: `Cold child ${label}`, exact: true })).toBeVisible()
    await page.unroute('**/pages/children?*')

    const writer = await context.newPage()
    await writer.goto(pageRoute(other))
    requests.length = 0
    const title = writer.getByRole('textbox', { name: '页面标题', exact: true })
    await title.fill(`Renamed ${label}`)
    await title.press('Tab')
    await expect(sidebar.getByRole('link', { name: `Renamed ${label}`, exact: true })).toBeVisible()
    expect(requests.filter(url => url.pathname === '/api/v2/pod/pages/children')).toHaveLength(0)
    await writer.close()

    const childLink = sidebar.locator(`a[href="${pageRoute(otherChild)}"]`)
    const details = page.waitForResponse(
      response => new URL(response.url()).pathname === `/api/v2/pod/pages/${otherChild}`
    )
    await childLink.hover()
    expect((await details).ok()).toBe(true)
    await childLink.click()
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(`Other child ${label}`)
    expect(requests.filter(url => url.pathname === `/api/v2/pod/pages/${otherChild}`)).toHaveLength(1)
  } finally {
    token.resolve()
    for (const id of created.reverse()) await request(page, `/pages/${id}`, 'DELETE').catch(() => {})
    await context.close()
  }
})

async function create(page: Page, title: string, attrs: Record<string, unknown> = {}) {
  const result = await request<{ page: { id: string } }>(page, '/pages', 'POST', { type: 'doc', title, ...attrs })
  return result.page.id
}

async function identity(page: Page) {
  return page.evaluate(async () => {
    const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)!.content
    const response = await fetch('/api/v2/browser/session', {
      headers: {
        'x-ankole-authentication': meta('ankole-authentication'),
        'x-ankole-pod': meta('ankole-pod')
      }
    })
    if (!response.ok) throw new Error(`Pinned identity: ${response.status}`)
    return (await response.json()).principalUID as string
  })
}

test('leaves keep child creation without an expansion request and become branches after creation', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let parent: string | undefined
  try {
    await page.goto(pageRoute(state.report_id))
    const title = `Navigation leaf ${crypto.randomUUID()}`
    parent = await create(page, title)
    const parentID = parent
    await page.evaluate(id => {
      const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)!.content
      localStorage.setItem(
        `ankole.pod.navigation:${meta('ankole-pod')}:${meta('ankole-authentication')}`,
        JSON.stringify({ expanded: [id] })
      )
    }, parentID)
    const childRequests: string[] = []
    page.on('request', request => {
      const url = new URL(request.url())
      if (url.pathname === '/api/v2/pod/pages/children' && url.searchParams.get('parent_id') === parentID) {
        childRequests.push(url.href)
      }
    })
    await page.reload()
    const row = space(page).locator('.pod-tree-row', { has: page.getByRole('link', { name: title, exact: true }) })
    await expect(row).toBeVisible()
    await expect(row.locator('.pod-tree-toggle')).toHaveCount(0)
    await expect(row.locator('.pod-tree-toggle-space')).toHaveCount(1)
    expect(childRequests).toEqual([])

    await row.hover()
    await row.getByRole('button', { name: '新建页面', exact: true }).click()
    await page.getByRole('menuitem', { name: '文档', exact: true }).click()
    await expect(page).not.toHaveURL(state.base_url + pageRoute(state.report_id))
    const toggle = row.getByRole('button', { name: title, exact: true })
    await expect(toggle).toHaveAttribute('aria-expanded', 'false')
    await toggle.click()
    await expect(row.locator('..').locator(':scope > .pod-tree-children > li')).toHaveCount(1)
    expect(childRequests.length).toBeGreaterThan(0)
  } finally {
    if (parent) await request(page, `/pages/${parent}`, 'DELETE').catch(() => {})
    await context.close()
  }
})

test('reconnecting reconciles directory changes made while offline', async ({ browser }) => {
  const reader = await browser.newContext({ baseURL: state.base_url })
  const writer = await browser.newContext({ baseURL: state.base_url })
  await reader.addCookies(state.owner.cookies)
  await writer.addCookies(state.owner.cookies)
  const page = await reader.newPage()
  const editor = await writer.newPage()
  let root: string | undefined
  try {
    await editor.goto(pageRoute(state.report_id))
    const title = `Reconnect ${crypto.randomUUID()}`
    root = await create(editor, title)
    const connected = page.waitForEvent('websocket', socket => socket.url().includes('/pod/socket/'))
    await page.goto(pageRoute(root))
    const socket = await connected
    const sidebar = space(page)
    await expect(sidebar.getByRole('link', { name: title, exact: true })).toBeVisible()
    // Chromium's offline emulation keeps an open socket until its heartbeat times out.
    const closed = socket.waitForEvent('close', { timeout: 10_000 })
    await closeRealtimeSocket(page)
    await closed
    await reader.setOffline(true)
    await request(editor, `/pages/${root}`, 'PATCH', { title: `${title} renamed`, expected_title: title })
    await create(editor, `${title} child`, { parent_id: root })
    await reader.setOffline(false)
    await expect(sidebar.getByRole('link', { name: `${title} renamed`, exact: true })).toBeVisible({ timeout: 30000 })
    const branch = sidebar.getByRole('button', { name: `${title} renamed`, exact: true })
    await branch.click()
    await expect(sidebar.getByRole('link', { name: `${title} child`, exact: true })).toBeVisible()
  } finally {
    await reader.setOffline(false)
    if (root) await request(editor, `/pages/${root}`, 'DELETE').catch(() => {})
    await reader.close()
    await writer.close()
  }
})

test('page search and quick jump distinguish matching titles by their parent paths', async ({ browser }, info) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const parents: string[] = []
  try {
    await page.goto(pageRoute(state.report_id))
    const title = `Weekly review ${crypto.randomUUID()}`
    const finance = await create(page, 'Finance team')
    parents.push(finance)
    const operations = await create(page, 'Operations team')
    parents.push(operations)
    const financeReview = await create(page, title, { parent_id: finance })
    const operationsReview = await create(page, title, { parent_id: operations })
    await page.getByRole('button', { name: '搜索或跳转', exact: true }).click()
    const dialog = page.getByRole('dialog', { name: '搜索或跳转', exact: true })
    await expect(dialog.locator('[data-value="scope:all"]')).toHaveCount(0)
    await dialog.getByRole('combobox').fill(title)
    const choices = dialog.locator('[data-value^="page:"]').filter({ hasText: title })
    await expect(choices).toHaveCount(2)
    await expect(choices.filter({ hasText: 'Finance team' })).toHaveCount(1)
    await expect(choices.filter({ hasText: 'Operations team' })).toHaveCount(1)
    await choices.filter({ hasText: 'Operations team' }).click()
    await expect(page).toHaveURL(state.base_url + pageRoute(operationsReview))
    await page.getByRole('button', { name: '搜索或跳转', exact: true }).click()
    await dialog.locator('[data-value="scope:search"]').click()
    await expect(page).toHaveURL(state.base_url + listRoute('search'))
    await page.getByRole('textbox', { name: '搜索页面', exact: true }).fill(title)
    const links = page.getByRole('main').getByRole('link', { name: title, exact: true })
    await expect(links).toHaveCount(2)
    await expect(links.filter({ hasText: 'Finance team' })).toHaveCount(1)
    await expect(links.filter({ hasText: 'Operations team' })).toHaveCount(1)
    await page.screenshot({ path: info.outputPath('search-parent-paths.png') })
    await links.filter({ hasText: 'Finance team' }).click()
    await expect(page).toHaveURL(state.base_url + pageRoute(financeReview))
    await page.goto('/')
    const composer = page.getByRole('textbox', { name: '消息', exact: true })
    await composer.fill('@')
    const suggestions = page.getByRole('listbox', { name: '补全建议', exact: true })
    await expect(suggestions).toBeVisible()
    await composer.fill(`@${title}`)
    const mentions = suggestions.getByRole('option').filter({ hasText: title })
    await expect(mentions).toHaveCount(2)
    await expect(mentions.filter({ hasText: 'Finance team' })).toHaveCount(1)
    await expect(mentions.filter({ hasText: 'Operations team' })).toHaveCount(1)
    await mentions.filter({ hasText: 'Finance team' }).click()
    await expect(composer).toHaveValue(`@${title} `)
    await composer.fill('')
  } finally {
    for (const id of parents) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('root folding retains branches and reload restores the first visible navigation without expanding it', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const created: string[] = []
  try {
    await page.goto(pageRoute(state.report_id))
    const title = `Navigation branch ${crypto.randomUUID()}`
    const parent = await create(page, title)
    created.push(parent)
    const childTitle = `Navigation child ${crypto.randomUUID()}`
    await create(page, childTitle, { parent_id: parent })
    const privatePage = await create(page, 'Navigation private destination', { private_owner_uid: state.owner.uid })
    created.push(privatePage)
    await page.goto(pageRoute(privatePage))
    const branch = space(page).getByRole('button', { name: title, exact: true })
    await expect(branch).toHaveAttribute('aria-expanded', 'false')
    await branch.click()
    await expect(space(page).getByRole('link', { name: childTitle, exact: true })).toBeVisible()
    await branch.click()
    await expect(branch).toHaveAttribute('aria-expanded', 'false')
    await rootToggle(page).click()
    await rootToggle(page).click()
    await expect(branch).toHaveAttribute('aria-expanded', 'false')
    await expect(space(page).getByRole('link', { name: childTitle, exact: true })).toHaveCount(0)
    await rootToggle(page).click()
    await page.addInitScript(() => {
      const observed = window as Window & { __spaceExpansion?: string[] }
      observed.__spaceExpansion = []
      new MutationObserver(records => {
        const button = document.querySelector('section[aria-label="空间"] button[aria-label="空间"]')
        if (!button) return
        observed.__spaceExpansion!.push(button.getAttribute('aria-expanded')!)
        for (const record of records) {
          if (record.target === button && record.attributeName === 'aria-expanded' && record.oldValue === 'true') {
            observed.__spaceExpansion!.push('true')
          }
        }
      }).observe(document, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['aria-expanded'],
        attributeOldValue: true
      })
    })
    await page.reload()
    await expect(rootToggle(page)).toHaveAttribute('aria-expanded', 'false')
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(
      'Navigation private destination'
    )
    const seen = await page.evaluate(() => (window as Window & { __spaceExpansion?: string[] }).__spaceExpansion!)
    expect(seen).toContain('false')
    expect(seen).not.toContain('true')
    const sameIdentity = await context.newPage()
    await sameIdentity.goto(pageRoute(privatePage))
    await expect(rootToggle(sameIdentity)).toHaveAttribute('aria-expanded', 'false')
    await rootToggle(sameIdentity).click()
    await expect(rootToggle(page)).toHaveAttribute('aria-expanded', 'true')
    await expect(branch).toHaveAttribute('aria-expanded', 'false')
  } finally {
    for (const id of created.reverse()) await request(page, `/pages/${id}`, 'DELETE').catch(() => {})
    await context.close()
  }
})

test('navigation stays with each real document identity and stored branches cannot restore revoked pages', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  const owner = await context.newPage()
  const member = await context.newPage()
  let parent: string | undefined
  try {
    await owner.goto(pageRoute(state.report_id))
    await login(owner, state.owner)
    await expect(owner.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()
    const title = `Navigation access ${crypto.randomUUID()}`
    parent = await create(owner, title)
    await create(owner, 'Navigation access child', { parent_id: parent })
    await rootToggle(owner).click()
    await expect(rootToggle(owner)).toHaveAttribute('aria-expanded', 'false')
    await member.goto(pageRoute(state.report_id))
    // A new document reveals its active path without changing another tab's folding choice.
    await expect(rootToggle(member)).toHaveAttribute('aria-expanded', 'true')
    await member.getByRole('button', { name: /^账户菜单/ }).click()
    await member.getByRole('menuitem', { name: '切换或添加账户', exact: true }).click()
    await login(member, state.member)
    await expect(member).toHaveURL(state.base_url + pageRoute(state.report_id))
    expect(await identity(member)).toBe(state.member.uid)
    expect(await identity(owner)).toBe(state.owner.uid)
    await expect(rootToggle(member)).toHaveAttribute('aria-expanded', 'true')
    const branch = space(member).getByRole('button', { name: title, exact: true })
    await branch.click()
    await privateToggle(member).click()
    await expect(privateToggle(member)).toHaveAttribute('aria-expanded', 'false')
    await expect(privateToggle(owner)).toHaveAttribute('aria-expanded', 'true')
    await expect(rootToggle(owner)).toHaveAttribute('aria-expanded', 'false')
    const baseline = await request<{ sharing_version: string }>(owner, `/pages/${parent}/sharing`)
    await request(owner, `/pages/${parent}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [],
      sharing_version: baseline.sharing_version
    })
    await member.reload()
    await expect(member.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()
    await expect(privateToggle(member)).toHaveAttribute('aria-expanded', 'false')
    await expect(space(member).getByRole('link', { name: title, exact: true })).toHaveCount(0)
    await owner.getByRole('button', { name: /^账户菜单/ }).click()
    await owner.getByRole('menuitem', { name: '切换或添加账户', exact: true }).click()
    const existingOwner = owner.getByRole('button', { name: /^以 .*Browser owner.* 继续/ })
    const podLogin = owner.getByRole('button', { name: '使用 Pod 自有登录', exact: true })
    await expect(existingOwner.or(podLogin).first()).toBeVisible()
    const throughPodEntry = await podLogin.isVisible()
    if (throughPodEntry) await podLogin.click()
    await existingOwner.click()
    if (throughPodEntry) await continuePodEntry(owner, state.owner.uid)
    await expect(owner).toHaveURL(state.base_url + pageRoute(state.report_id))
    await expect(rootToggle(owner)).toHaveAttribute('aria-expanded', 'true')
    await expect(privateToggle(owner)).toHaveAttribute('aria-expanded', 'true')
    expect(await identity(owner)).toBe(state.owner.uid)
    expect(await identity(member)).toBe(state.member.uid)
  } finally {
    if (parent) await request(owner, `/pages/${parent}`, 'DELETE').catch(() => {})
    await context.close()
  }
})
