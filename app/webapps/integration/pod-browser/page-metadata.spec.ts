import { expect, test } from '@playwright/test'
import { state, requestWithSharingVersion as request } from './fixtures'
import { listRoute, pageRoute } from './routes'

test('Page metadata stays shared across live navigation, breadcrumbs and a cached SPA list', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const reader = await context.newPage()
  const writer = await context.newPage()
  const created: string[] = []
  const errors: string[] = []
  for (const page of [reader, writer]) page.on('pageerror', error => errors.push(error.message))
  try {
    await writer.goto(state.base_url + pageRoute(state.report_id))
    const initialTitle = `Shared metadata ${Date.now()}`
    const renamedTitle = `${initialTitle} renamed`
    const { page: parent } = await request<{ page: { id: string } }>(writer, '/pages', 'POST', {
      type: 'doc',
      title: initialTitle
    })
    created.push(parent.id)
    const { page: child } = await request<{ page: { id: string } }>(writer, '/pages', 'POST', {
      type: 'doc',
      title: 'Metadata child',
      parent_id: parent.id
    })
    created.push(child.id)
    await request(writer, `/pages/${child.id}/content`, 'PUT', {
      base_revision: 0,
      xml: `<page><p>Parent: <mention page="${parent.id}"/></p></page>`
    })
    await request(writer, `/pages/${parent.id}/user-state`, 'PUT', { favorite: true })
    await writer.goto(state.base_url + pageRoute(parent.id))
    await expect(writer.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(initialTitle)

    await reader.goto(state.base_url + listRoute('favorites'))
    const list = reader.locator('.pod-content-list')
    await expect(list.getByRole('link', { name: initialTitle, exact: true })).toBeVisible()
    await list.getByRole('link', { name: initialTitle, exact: true }).click()
    await reader.locator('.pod-navigation').getByRole('button', { name: initialTitle, exact: true }).click()
    await reader.locator('.pod-navigation').getByRole('link', { name: 'Metadata child', exact: true }).first().click()
    await expect(reader).toHaveURL(state.base_url + pageRoute(child.id))
    const breadcrumb = reader.locator('.pod-page-breadcrumbs').getByRole('link', { name: initialTitle, exact: true })
    await expect(breadcrumb).toBeVisible()
    const mention = reader.locator(`[data-mention-page="${parent.id}"] a.pod-mention-page`)
    await expect(mention).toHaveText(initialTitle)

    const listReads: string[] = []
    const mentionReads: string[] = []
    reader.on('request', req => {
      const url = new URL(req.url())
      if (url.pathname === '/api/v2/pod/mentions/resolve') mentionReads.push(req.url())
      if (
        req.method() === 'GET' &&
        url.pathname === '/api/v2/pod/pages' &&
        url.searchParams.get('scope') === 'favorites'
      ) {
        listReads.push(req.url())
      }
    })
    const title = writer.getByRole('textbox', { name: '页面标题', exact: true })
    await title.fill(renamedTitle)
    await title.blur()
    await expect(
      reader.locator('.pod-page-breadcrumbs').getByRole('link', { name: renamedTitle, exact: true })
    ).toBeVisible()
    await expect(mention).toHaveText(renamedTitle)
    const favorite = reader
      .locator('.pod-nav-section')
      .filter({ has: reader.getByRole('link', { name: '收藏', exact: true }) })
    await expect(favorite.getByRole('link', { name: renamedTitle, exact: true })).toBeVisible()

    await request(writer, `/pages/${parent.id}`, 'PATCH', { icon: '🚀' })
    await expect(favorite.locator(`a[href="${pageRoute(parent.id)}"] .pod-page-icon`)).toHaveText('🚀')
    await expect(mention.locator('.pod-page-icon')).toHaveText('🚀')
    expect(mentionReads).toEqual([])
    await reader
      .locator(`.pod-navigation a[href="${listRoute('favorites')}"]`)
      .first()
      .click()
    await expect(list.getByRole('link', { name: renamedTitle, exact: true })).toBeVisible()
    await expect(list.locator(`a[href="${pageRoute(parent.id)}"] .pod-page-icon`)).toHaveText('🚀')
    expect(listReads).toEqual([])
    await request(writer, `/pages/${parent.id}`, 'PATCH', { icon: null })
    await expect(list.locator(`a[href="${pageRoute(parent.id)}"] .pod-page-icon`)).not.toHaveText('🚀')
    expect(errors).toEqual([])
  } finally {
    for (const id of created.reverse()) await request(writer, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('revoking access hides a mention even when its title and icon are already in shared metadata', async ({
  browser
}) => {
  const ownerContext = await browser.newContext()
  const readerContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await readerContext.addCookies(state.viewer.cookies)
  const owner = await ownerContext.newPage()
  const reader = await readerContext.newPage()
  const created: string[] = []
  try {
    await owner.goto(state.base_url + pageRoute(state.report_id))
    const title = `Metadata access ${Date.now()}`
    const { page: target } = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      type: 'doc',
      title,
      icon: '🚀'
    })
    created.push(target.id)
    const { page: document } = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      type: 'doc',
      title: 'Metadata reference',
      xml: `<page><p><mention page="${target.id}"/></p></page>`
    })
    created.push(document.id)
    for (const id of created) {
      await request(owner, `/pages/${id}/sharing`, 'PUT', {
        inherit_permissions: false,
        grants: [
          { principal_uid: state.owner.uid, role: 'manage' },
          { principal_uid: state.viewer.uid, role: 'view' }
        ]
      })
    }
    await reader.goto(state.base_url + pageRoute(document.id))
    const mention = reader.locator(`[data-mention-page="${target.id}"]`)
    await expect(mention.locator('a.pod-mention-page')).toContainText(title)
    await expect(mention.locator('.pod-page-icon')).toHaveText('🚀')
    await request(owner, `/pages/${target.id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [{ principal_uid: state.owner.uid, role: 'manage' }]
    })
    await expect(mention.locator('[data-mention-access="restricted"]')).toHaveText('受限页面')
    await expect(reader.locator('body')).not.toContainText(title)
    await expect(mention).not.toContainText('🚀')
  } finally {
    for (const id of created.reverse()) await request(owner, `/pages/${id}`, 'DELETE')
    await ownerContext.close()
    await readerContext.close()
  }
})
