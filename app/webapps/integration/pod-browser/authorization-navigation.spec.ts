import { expect, test } from '@playwright/test'
import { request, requestWithSharingVersion, state } from './fixtures'
import { listRoute, pageRoute } from './routes'

const suffix = () => crypto.randomUUID().slice(0, 8)

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

test('sharing adds Userset rules, redacts source titles and retains a conditional self rule through a CAS conflict', async ({
  browser
}) => {
  const owner = await browser.newContext({ baseURL: state.base_url })
  const viewer = await browser.newContext({ baseURL: state.base_url })
  await owner.addCookies(state.owner.cookies)
  await viewer.addCookies(state.viewer.cookies)
  const ownerPage = await owner.newPage()
  const viewerPage = await viewer.newPage()
  try {
    await ownerPage.goto(pageRoute(state.report_id))
    const sourceTitle = `Private source ${suffix()}`
    const source = await request<{ page: { id: string } }>(ownerPage, '/pages', 'POST', {
      type: 'doc',
      title: sourceTitle,
      private_owner_uid: state.owner.uid
    })
    const target = await request<{ page: { id: string } }>(ownerPage, '/pages', 'POST', {
      type: 'doc',
      title: `Shared target ${suffix()}`
    })
    const grants = [
      { principal_uid: state.viewer.uid, role: 'manage', target_scope: 'container', condition: 'true' },
      {
        source_page_id: source.page.id,
        source_action: 'page_view',
        role: 'view',
        target_scope: 'self',
        condition: 'true'
      }
    ]
    await requestWithSharingVersion(ownerPage, `/pages/${target.page.id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants
    })
    await viewerPage.goto(pageRoute(target.page.id))
    await viewerPage.getByRole('button', { name: '分享', exact: true }).click()
    await expect(viewerPage.getByText('你无权访问的页面', { exact: true })).toBeVisible()
    await expect(viewerPage.getByText(sourceTitle, { exact: true })).toHaveCount(0)
    const sourceRule = viewerPage
      .locator('li')
      .filter({ has: viewerPage.getByText('你无权访问的页面', { exact: true }) })
    const condition = sourceRule.getByRole('textbox', { name: '条件（CEL）', exact: true })
    const expression = 'context.request.surface == "pod_browser"'
    await condition.fill(expression)
    await requestWithSharingVersion(ownerPage, `/pages/${target.page.id}/sharing`, 'PUT', {
      inherit_permissions: true,
      grants
    })
    await viewerPage.getByRole('button', { name: '保存分享设置', exact: true }).click()
    await viewerPage.getByRole('button', { name: '保留我的设置并读取最新版本', exact: true }).click()
    await expect(condition).toHaveValue(expression)
    await expect(viewerPage.getByText(/^已读取最新版本/)).toBeVisible()
    await viewerPage.getByRole('button', { name: '保存分享设置', exact: true }).click()
    await expect(viewerPage.getByRole('textbox', { name: '条件（CEL）', exact: true })).toHaveCount(0)
    const saved = await request<{
      grants: Array<{ source_page_id?: string; target_scope: string; condition: string }>
    }>(ownerPage, `/pages/${target.page.id}/sharing`)
    expect(saved.grants.find(grant => grant.source_page_id === source.page.id)).toMatchObject({
      target_scope: 'self',
      condition: expression
    })
    await ownerPage.goto(pageRoute(target.page.id))
    await ownerPage.getByRole('button', { name: '分享', exact: true }).click()
    await ownerPage.getByRole('combobox', { name: '共享对象', exact: true }).click()
    await ownerPage.getByRole('option', { name: '有权访问其他页面的用户', exact: true }).click()
    await ownerPage.getByRole('combobox', { name: '来源页面', exact: true }).fill(sourceTitle)
    await ownerPage
      .getByRole('option')
      .filter({ has: ownerPage.getByText(sourceTitle, { exact: true }) })
      .click()
    await ownerPage.getByRole('combobox', { name: '生效范围', exact: true }).first().click()
    await ownerPage.getByRole('option', { name: '仅此页面', exact: true }).click()
    await ownerPage.getByRole('button', { name: '添加', exact: true }).click()
    await ownerPage.getByRole('button', { name: '保存分享设置', exact: true }).click()
    await expect(ownerPage.getByRole('dialog', { name: '分享页面', exact: true })).toHaveCount(0)
    const added = await request<{
      grants: Array<{ source_page_id?: string; target_scope: string; condition: string }>
    }>(ownerPage, `/pages/${target.page.id}/sharing`)
    expect(added.grants.filter(grant => grant.source_page_id === source.page.id)).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ target_scope: 'self', condition: expression }),
        expect.objectContaining({ target_scope: 'self', condition: 'true' })
      ])
    )
  } finally {
    await owner.close()
    await viewer.close()
  }
})
