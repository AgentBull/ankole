import { expect, test } from '@playwright/test'
import { request, requestWithSharingVersion, state } from './fixtures'
import { listRoute, pageRoute } from './routes'

const suffix = () => crypto.randomUUID().slice(0, 8)

test('a collapsed Space loads root permissions after reload for page creation and drag moves', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1365, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let sourceID: string | undefined
  let createdID: string | undefined
  try {
    await page.goto(pageRoute(state.report_id))
    const sourceTitle = `Private root move ${suffix()}`
    const source = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'doc',
      title: sourceTitle,
      private_owner_uid: state.owner.uid
    })
    sourceID = source.page.id
    const space = page.getByRole('region', { name: '空间', exact: true })
    const toggle = space.getByRole('button', { name: '空间', exact: true })
    await expect(toggle).toHaveAttribute('aria-expanded', 'true')
    await toggle.click()
    await page.reload()
    await expect(toggle).toHaveAttribute('aria-expanded', 'false')
    const create = space.getByRole('button', { name: '新建页面', exact: true })
    await expect(create).toBeVisible()
    await create.click()
    const dialog = page.getByRole('dialog', { name: '新建页面', exact: true })
    const title = `Collapsed Space page ${suffix()}`
    await dialog.getByRole('textbox', { name: '标题', exact: true }).fill(title)
    const created = page.waitForResponse(
      response => response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/pages'
    )
    await dialog.getByRole('button', { name: '创建', exact: true }).click()
    const response = await created
    expect(response.status()).toBe(201)
    const result = (await response.json()) as {
      page: { id: string; parent_id: string | null; private_owner_uid: string | null }
    }
    createdID = result.page.id
    expect(result.page).toMatchObject({ parent_id: null, private_owner_uid: null })
    await expect(page).toHaveURL(state.base_url + pageRoute(createdID))
    await expect(toggle).toHaveAttribute('aria-expanded', 'false')

    const privateRow = page.getByRole('link', { name: sourceTitle, exact: true })
    await expect(privateRow).toHaveAttribute('draggable', 'true')
    const moved = page.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/v2/pod/pages/${sourceID}/move`
    )
    await privateRow.dragTo(space.locator('.pod-nav-section-heading'))
    expect((await moved).status()).toBe(201)
    await expect(toggle).toHaveAttribute('aria-expanded', 'true')
    await expect(space.getByRole('link', { name: sourceTitle, exact: true })).toBeVisible()
    const persisted = await request<{ page: { parent_id: string | null; private_owner_uid: string | null } }>(
      page,
      `/pages/${sourceID}`
    )
    expect(persisted.page).toMatchObject({ parent_id: null, private_owner_uid: null })
  } finally {
    if (sourceID) await request(page, `/pages/${sourceID}`, 'DELETE')
    if (createdID) await request(page, `/pages/${createdID}`, 'DELETE')
    await context.close()
  }
})

test('navigation fetches a branch on expansion, follows its cursor, and searches an unloaded title', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(pageRoute(state.report_id))
    const title = `Cursor branch ${suffix()}`
    const root = await request<{ page: { id: string } }>(page, '/pages', 'POST', { type: 'doc', title })
    const hiddenTitle = `Unloaded title ${suffix()}`
    for (let index = 0; index < 201; index++) {
      await request(page, '/pages', 'POST', {
        type: 'doc',
        parent_id: root.page.id,
        title: index === 200 ? hiddenTitle : `Branch item ${index}`
      })
    }
    const childRequests: URL[] = []
    page.on('request', request => {
      const url = new URL(request.url())
      if (url.pathname.endsWith('/pages/children') && url.searchParams.get('parent_id') === root.page.id) {
        childRequests.push(url)
      }
    })
    await page.goto(pageRoute(root.page.id))
    const row = page.locator('.pod-tree-row', { has: page.getByRole('link', { name: title, exact: true }) })
    await expect(row).toBeVisible()
    expect(childRequests).toHaveLength(0)
    await row.getByRole('button', { name: title, exact: true }).click()
    const branch = row.locator('..').locator(':scope > .pod-tree-children')
    await expect(branch.locator(':scope > li > .pod-tree-row')).toHaveCount(200)
    expect(childRequests).toHaveLength(1)
    await branch.getByRole('button', { name: '加载更多页面', exact: true }).click()
    await expect(branch.locator(':scope > li > .pod-tree-row')).toHaveCount(201)
    expect(childRequests.some(url => url.searchParams.has('cursor'))).toBe(true)
    await page.goto(listRoute('search'))
    const searched = page.waitForResponse(response => {
      const url = new URL(response.url())
      return url.pathname.endsWith('/pages/search') && url.searchParams.get('query') === hiddenTitle && response.ok()
    })
    await page.getByRole('textbox', { name: '搜索页面', exact: true }).fill(hiddenTitle)
    await searched
    await expect(page.getByRole('main').getByRole('link', { name: hiddenTitle, exact: true })).toBeVisible()
  } finally {
    await context.close()
  }
})

test('sharing exposes four roles and preserves read-only advanced grants through CAS recovery and removal', async ({
  browser
}) => {
  const owner = await browser.newContext({ baseURL: state.base_url }),
    viewer = await browser.newContext({ baseURL: state.base_url })
  await owner.addCookies(state.owner.cookies)
  await viewer.addCookies(state.viewer.cookies)
  const ownerPage = await owner.newPage(),
    viewerPage = await viewer.newPage()
  let sourceID: string | undefined, targetID: string | undefined
  try {
    await ownerPage.goto(pageRoute(state.report_id))
    const sourceTitle = `Private source ${suffix()}`
    const source = await request<{ page: { id: string } }>(ownerPage, '/pages', 'POST', {
      type: 'doc',
      title: sourceTitle,
      private_owner_uid: state.owner.uid
    })
    sourceID = source.page.id
    const target = await request<{ page: { id: string } }>(ownerPage, '/pages', 'POST', {
      type: 'doc',
      title: `Shared target ${suffix()}`
    })
    targetID = target.page.id
    const expression = 'context.request.surface == "pod_browser"'
    const grants = [
      { principal_uid: state.viewer.uid, role: 'manage', target_scope: 'container', condition: 'true' },
      {
        source_page_id: sourceID,
        source_action: 'page_view',
        role: 'view',
        target_scope: 'self',
        condition: expression
      }
    ]
    await requestWithSharingVersion(ownerPage, `/pages/${targetID}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants
    })
    await viewerPage.goto(pageRoute(targetID))
    await viewerPage.getByRole('button', { name: '分享', exact: true }).click()
    await expect(viewerPage.getByText('你无权访问的页面', { exact: true })).toBeVisible()
    await expect(viewerPage.getByText(sourceTitle, { exact: true })).toHaveCount(0)
    await expect(viewerPage.getByRole('textbox', { name: '条件（CEL）', exact: true })).toHaveCount(0)
    await expect(viewerPage.getByRole('combobox', { name: '共享对象', exact: true })).toHaveCount(0)
    await expect(viewerPage.locator('code')).toHaveText(expression)
    await viewerPage.getByRole('checkbox').first().check()
    await requestWithSharingVersion(ownerPage, `/pages/${targetID}/sharing`, 'PUT', {
      inherit_permissions: true,
      grants
    })
    await viewerPage.getByRole('button', { name: '保存分享设置', exact: true }).click()
    await viewerPage.getByRole('button', { name: '保留我的设置并读取最新版本', exact: true }).click()
    await expect(viewerPage.locator('code')).toHaveText(expression)
    const savedSharing = viewerPage.waitForResponse(
      response =>
        response.request().method() === 'PUT' &&
        new URL(response.url()).pathname === `/api/v2/pod/pages/${targetID}/sharing`
    )
    await viewerPage.getByRole('button', { name: '保存分享设置', exact: true }).click()
    await expect(viewerPage.getByRole('button', { name: '保存分享设置', exact: true })).toHaveCount(0)
    expect((await savedSharing).status()).toBe(200)
    const saved = await request<{
      inherit_permissions: boolean
      grants: { source_page_id?: string; condition: string; target_scope: string }[]
    }>(ownerPage, `/pages/${targetID}/sharing`)
    expect(saved.inherit_permissions).toBe(true)
    expect(saved.grants.find(grant => grant.source_page_id === sourceID)).toMatchObject({
      condition: expression,
      target_scope: 'self'
    })
    await ownerPage.goto(pageRoute(targetID))
    await ownerPage.getByRole('button', { name: '分享', exact: true }).click()
    await ownerPage.getByRole('combobox', { name: '授予权限', exact: true }).click()
    await expect(ownerPage.getByRole('option')).toHaveCount(4)
    await ownerPage.getByRole('option', { name: '可提交数据', exact: true }).click()
    const advanced = ownerPage.locator('li').filter({ has: ownerPage.getByText(sourceTitle, { exact: true }) })
    await advanced.getByRole('button', { name: '移除', exact: true }).click()
    const removedSharing = ownerPage.waitForResponse(
      response =>
        response.request().method() === 'PUT' &&
        new URL(response.url()).pathname === `/api/v2/pod/pages/${targetID}/sharing`
    )
    await ownerPage.getByRole('button', { name: '保存分享设置', exact: true }).click()
    await expect(ownerPage.getByRole('button', { name: '保存分享设置', exact: true })).toHaveCount(0)
    expect((await removedSharing).status()).toBe(200)
    const removed = await request<{ grants: { source_page_id?: string }[] }>(ownerPage, `/pages/${targetID}/sharing`)
    expect(removed.grants.some(grant => grant.source_page_id === sourceID)).toBe(false)
  } finally {
    if (targetID) await request(ownerPage, `/pages/${targetID}`, 'DELETE')
    if (sourceID) await request(ownerPage, `/pages/${sourceID}`, 'DELETE')
    await Promise.all([owner.close(), viewer.close()])
  }
})
