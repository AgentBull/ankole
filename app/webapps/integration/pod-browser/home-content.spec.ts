import { expect, test } from '@playwright/test'
import { state, request } from './fixtures'
import { listRoute, pageRoute } from './routes'

test('a database owns child documents and full-text search respects the private page tree', async ({ browser }) => {
  const ownerContext = await browser.newContext(),
    viewerContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await viewerContext.addCookies(state.viewer.cookies)
  const owner = await ownerContext.newPage(),
    viewer = await viewerContext.newPage()
  let parent: string | undefined
  try {
    await owner.goto(state.base_url + pageRoute(state.report_id))
    const title = `Private database ${crypto.randomUUID().slice(0, 8)}`
    const created = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      type: 'database',
      title,
      private_owner_uid: state.owner.uid
    })
    parent = created.page.id
    const child = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      type: 'doc',
      title: 'Interview preparation',
      parent_id: parent
    })
    const body = `招聘评价正文搜索词${crypto.randomUUID().slice(0, 8)}`
    await request(owner, `/pages/${child.page.id}/content`, 'PUT', {
      base_revision: 0,
      xml: `<page><p>${body}</p></page>`
    })
    await owner.goto(state.base_url + pageRoute(parent))
    await expect(owner.getByRole('button', { name: 'Table 1', exact: true })).toBeVisible()
    const row = owner.locator('.pod-tree-row').filter({ has: owner.getByRole('link', { name: title, exact: true }) })
    await row.getByRole('button', { name: title, exact: true }).click()
    await expect(owner.getByRole('link', { name: 'Interview preparation', exact: true })).toBeVisible()
    await owner.goto(state.base_url + listRoute('search'))
    await owner.getByRole('textbox', { name: '搜索页面', exact: true }).fill(body)
    await expect(
      owner.getByRole('main').getByRole('link', { name: 'Interview preparation', exact: true })
    ).toBeVisible()
    await viewer.goto(state.base_url + listRoute('search'))
    const searched = viewer.waitForResponse(
      response =>
        new URL(response.url()).pathname.endsWith('/pages/search') &&
        new URL(response.url()).searchParams.get('query') === body
    )
    await viewer.getByRole('textbox', { name: '搜索页面', exact: true }).fill(body)
    expect((await searched).status()).toBe(200)
    await expect(
      viewer.getByRole('main').getByRole('link', { name: 'Interview preparation', exact: true })
    ).toHaveCount(0)
  } finally {
    if (parent) await request(owner, `/pages/${parent}`, 'DELETE')
    await Promise.all([ownerContext.close(), viewerContext.close()])
  }
})
