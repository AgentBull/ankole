import { expect, test } from '@playwright/test'
import { request, requestResponse, requestWithSharingVersion, state } from './fixtures'
import { listRoute, pageRoute } from './routes'

const suffix = () => crypto.randomUUID().slice(0, 8)

test('document sharing grants comment access without editing or management, and revocation reaches the open page', async ({
  browser
}) => {
  const owner = await browser.newContext({ baseURL: state.base_url })
  const member = await browser.newContext({ baseURL: state.base_url })
  await owner.addCookies(state.owner.cookies)
  await member.addCookies(state.member.cookies)
  const ownerPage = await owner.newPage()
  const memberPage = await member.newPage()
  let id: string | undefined
  try {
    await ownerPage.goto(pageRoute(state.report_id))
    const title = `Comment permission ${suffix()}`
    id = (
      await request<{ page: { id: string } }>(ownerPage, '/pages', 'POST', {
        type: 'doc',
        title,
        private_owner_uid: state.owner.uid
      })
    ).page.id
    await ownerPage.goto(pageRoute(id))
    const sharingPath = `/pages/${id}/sharing`
    const sharing = await request<{ subjects: { principal_uid?: string; name: string }[] }>(ownerPage, sharingPath)
    const memberName = sharing.subjects.find(subject => subject.principal_uid === state.member.uid)!.name
    const saveSharing = async (action: () => Promise<unknown>) => {
      const saved = ownerPage.waitForResponse(
        response =>
          response.request().method() === 'PATCH' && new URL(response.url()).pathname === `/api/v2/pod${sharingPath}`
      )
      await action()
      expect((await saved).status()).toBe(200)
    }
    await ownerPage.getByRole('button', { name: '分享', exact: true }).click()
    const ownerShareDialog = ownerPage.getByRole('dialog', { name: '分享文档', exact: true })
    await expect(ownerShareDialog.getByText('私人页面', { exact: true })).toBeVisible()
    const collaborators = ownerPage.getByRole('combobox', { name: '搜索协作者', exact: true })
    await collaborators.fill(memberName)
    await ownerPage.getByRole('option').filter({ hasText: memberName }).first().click()
    await ownerPage.getByRole('combobox', { name: '授予权限', exact: true }).click()
    await expect(ownerPage.getByRole('listbox').last().getByRole('option')).toHaveText([
      '可阅读',
      '可评论',
      '可编辑',
      '可管理'
    ])
    await ownerPage.getByRole('option', { name: '可评论', exact: true }).click()
    await saveSharing(() => ownerPage.getByRole('button', { name: '确定', exact: true }).click())
    await ownerPage.getByRole('button', { name: '管理协作者', exact: true }).click()
    const memberGrant = ownerPage
      .getByRole('listitem')
      .filter({ has: ownerPage.getByText(memberName, { exact: true }) })
    await expect(memberGrant.getByRole('combobox', { name: '成员权限', exact: true })).toHaveText('可评论')
    await ownerPage.getByRole('button', { name: '返回', exact: true }).click()
    await collaborators.fill(memberName)
    await expect(
      ownerPage.getByRole('option').filter({ hasText: memberName }).getByText('可评论', { exact: true })
    ).toBeVisible()
    await ownerPage.keyboard.press('Escape')
    await ownerPage.keyboard.press('Escape')

    await memberPage.goto(pageRoute(id))
    const detail = await request<{ actions: string[]; page: { revision: number } }>(memberPage, `/pages/${id}`)
    expect(detail.actions.toSorted()).toEqual(['page_comment', 'page_view', 'page_write_records'])
    await expect(memberPage.getByRole('textbox', { name: '页面标题', exact: true })).toHaveCount(0)
    await expect(memberPage.getByRole('button', { name: '分享', exact: true })).toHaveCount(1)
    await memberPage.getByRole('button', { name: '分享', exact: true }).click()
    const memberShareDialog = memberPage.getByRole('dialog', { name: '分享文档', exact: true })
    await expect(memberShareDialog).toBeVisible()
    await expect(memberShareDialog.getByRole('button', { name: '权限设置', exact: true })).toHaveCount(0)
    await expect(memberShareDialog.getByRole('combobox', { name: '搜索协作者', exact: true })).toHaveCount(0)
    await expect(memberShareDialog.getByText('私人页面', { exact: true })).toBeVisible()
    await memberPage.keyboard.press('Escape')
    await expect(memberPage.locator('.pod-document .editor-content')).toBeVisible()
    await expect(memberPage.locator('.pod-document [contenteditable="true"]')).toHaveCount(0)
    expect((await requestResponse(memberPage, `/pages/${id}`, 'PATCH', { title: 'Forbidden rename' })).status).toBe(403)
    expect(
      (
        await requestResponse(memberPage, `/pages/${id}/content`, 'PUT', {
          base_revision: detail.page.revision,
          xml: '<page><p>Forbidden edit</p></page>'
        })
      ).status
    ).toBe(403)
    const version = await request<{ sharing_version: string }>(ownerPage, sharingPath)
    expect(
      (
        await requestResponse(memberPage, sharingPath, 'PUT', {
          sharing_version: version.sharing_version,
          inherit_permissions: true,
          grants: []
        })
      ).status
    ).toBe(403)
    expect((await requestResponse(memberPage, sharingPath, 'PATCH', { inherit_permissions: true })).status).toBe(403)

    for (const page of [ownerPage, memberPage]) {
      await page.locator('.pod-page-header').getByRole('button', { name: '评论', exact: true }).click()
    }
    const memberComments = memberPage.getByRole('complementary', { name: '评论', exact: true })
    const comment = `Shared comment ${suffix()}`
    await memberComments.getByRole('textbox', { name: '添加评论…', exact: true }).fill(comment)
    await memberComments.getByRole('button', { name: '发送', exact: true }).click()
    await expect(
      ownerPage.getByRole('complementary', { name: '评论', exact: true }).getByText(comment, { exact: true })
    ).toBeVisible()

    // Revoking comment access preserves the unsent draft, but makes it read-only immediately.
    const unsent = 'Keep this draft after my access changes.'
    const composer = memberComments.getByRole('textbox', { name: '添加评论…', exact: true })
    await composer.fill(unsent)
    await ownerPage.getByRole('button', { name: '分享', exact: true }).click()
    await ownerPage.getByRole('button', { name: '管理协作者', exact: true }).click()
    await memberGrant.getByRole('combobox', { name: '成员权限', exact: true }).click()
    await saveSharing(() => ownerPage.getByRole('option', { name: '可阅读', exact: true }).click())
    await expect(composer).not.toBeEditable()
    await expect(composer).toHaveAttribute('aria-disabled', 'true')
    await expect(composer).toHaveValue(unsent)
    await expect(memberComments.getByRole('button', { name: '发送', exact: true })).toBeDisabled()
    await expect(memberComments.getByText(comment, { exact: true })).toBeVisible()
    expect(
      (await requestResponse(memberPage, `/pages/${id}/comments`, 'POST', { body: 'Forbidden comment' })).status
    ).toBe(403)
    const final = await request<{ page: { title: string }; content: { plain_text: string }; actions: string[] }>(
      memberPage,
      `/pages/${id}`
    )
    expect(final.actions).toEqual(['page_view'])
    expect(final.page.title).toBe(title)
    expect(final.content.plain_text).toBe('')
  } finally {
    if (id) await request(ownerPage, `/pages/${id}`, 'DELETE')
    await Promise.all([owner.close(), member.close()])
  }
})

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
    // Only the active Page's section opens on reload; Space stays independently folded.
    await page.goto(pageRoute(sourceID))
    const space = page.getByRole('region', { name: '空间', exact: true })
    const toggle = space.getByRole('button', { name: '空间', exact: true })
    await expect(toggle).toHaveAttribute('aria-expanded', 'true')
    await toggle.click()
    await page.reload()
    await expect(toggle).toHaveAttribute('aria-expanded', 'false')
    const create = space.getByRole('button', { name: '新建页面', exact: true })
    await expect(create).toBeVisible()
    await create.click()
    const created = page.waitForResponse(
      response => response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/pages'
    )
    await page.getByRole('menuitem', { name: '文档', exact: true }).click()
    const response = await created
    expect(response.status()).toBe(201)
    const result = (await response.json()) as {
      page: { id: string; parent_id: string | null; private_owner_uid: string | null }
    }
    createdID = result.page.id
    expect(result.page).toMatchObject({ parent_id: null, private_owner_uid: null })
    await expect(page).toHaveURL(state.base_url + pageRoute(createdID))
    await expect(toggle).toHaveAttribute('aria-expanded', 'false')

    const privateRow = page
      .getByRole('region', { name: '私人页面', exact: true })
      .getByRole('link', { name: sourceTitle, exact: true })
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
    const root = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'doc',
      title,
      children_view: { collapsed: true }
    })
    const hiddenTitle = `Unloaded title ${suffix()}`
    let lastID = ''
    for (let index = 0; index < 201; index++) {
      const child = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
        type: 'doc',
        parent_id: root.page.id,
        title: index === 200 ? hiddenTitle : `Branch item ${index}`
      })
      lastID = child.page.id
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
    await page.goto(pageRoute(lastID))
    const lastRow = page.locator('.pod-tree-row', { has: page.locator(`a[href="${pageRoute(lastID)}"]`) })
    await expect(lastRow).toBeVisible()
    await lastRow.click({ button: 'right' })
    await expect(page.getByRole('menuitem', { name: '上移', exact: true })).toBeDisabled()
    await expect(page.getByRole('menuitem', { name: '下移', exact: true })).toBeDisabled()
    await page.keyboard.press('Escape')
    await branch.getByRole('button', { name: '加载更多页面', exact: true }).click()
    await lastRow.click({ button: 'right' })
    await expect(page.getByRole('menuitem', { name: '上移', exact: true })).toBeEnabled()
    await page.keyboard.press('Escape')

    // Finish the directory refresh before the path response to expose a bootstrap overwrite.
    const pathRead = Promise.withResolvers<void>()
    const releasePath = Promise.withResolvers<void>()
    await page.route('**/api/v2/pod/pages/navigation*', async route => {
      const response = await route.fetch()
      pathRead.resolve()
      await releasePath.promise
      await route.fulfill({ response })
    })
    const refreshedTail = page.waitForResponse(response => {
      const url = new URL(response.url())
      return (
        url.pathname.endsWith('/pages/children') &&
        url.searchParams.get('parent_id') === root.page.id &&
        url.searchParams.has('cursor')
      )
    })
    const refreshedPath = page.waitForResponse(response =>
      new URL(response.url()).pathname.endsWith('/pages/navigation')
    )
    try {
      await requestWithSharingVersion(page, `/pages/${root.page.id}/sharing`, 'PUT', {
        inherit_permissions: true,
        grants: []
      })
      await pathRead.promise
      await refreshedTail
    } finally {
      releasePath.resolve()
    }
    await (await refreshedPath).finished()
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
    await expect(branch.getByRole('button', { name: '加载更多页面', exact: true })).toHaveCount(0)
    await lastRow.click({ button: 'right' })
    await expect(page.getByRole('menuitem', { name: '上移', exact: true })).toBeEnabled()
    await page.keyboard.press('Escape')
    await page.unroute('**/api/v2/pod/pages/navigation*')
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

test('sharing offers useful roles and preserves read-only advanced grants through CAS recovery and removal', async ({
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
    await viewerPage.getByRole('button', { name: /权限设置/ }).click()
    await expect(viewerPage.getByText('你无权访问的页面', { exact: true })).toBeVisible()
    await expect(viewerPage.getByText(sourceTitle, { exact: true })).toHaveCount(0)
    await expect(viewerPage.getByRole('textbox', { name: '条件（CEL）', exact: true })).toHaveCount(0)
    await expect(viewerPage.getByRole('combobox', { name: '共享对象', exact: true })).toHaveCount(0)
    await expect(viewerPage.locator('code')).toHaveText(expression)
    const blockedWrite = Promise.withResolvers<void>()
    const releaseWrite = Promise.withResolvers<void>()
    await viewerPage.route(`**/api/v2/pod/pages/${targetID}/sharing`, async route => {
      if (route.request().method() !== 'PATCH') return route.continue()
      blockedWrite.resolve()
      await releaseWrite.promise
      await route.continue()
    })
    const savedSharing = viewerPage.waitForResponse(
      response =>
        response.request().method() === 'PATCH' &&
        new URL(response.url()).pathname === `/api/v2/pod/pages/${targetID}/sharing`
    )
    await viewerPage.getByRole('switch').first().click()
    await blockedWrite.promise
    await request(ownerPage, `/pages/${targetID}/sharing`, 'PATCH', {
      upserts: [{ principal_uid: state.member.uid, role: 'view', target_scope: 'container' }]
    })
    releaseWrite.resolve()
    expect((await savedSharing).status()).toBe(200)
    await expect(viewerPage.locator('code')).toHaveText(expression)
    const saved = await request<{
      inherit_permissions: boolean
      grants: { principal_uid?: string; source_page_id?: string; condition: string; target_scope: string }[]
    }>(ownerPage, `/pages/${targetID}/sharing`)
    expect(saved.inherit_permissions).toBe(true)
    expect(saved.grants.some(grant => grant.principal_uid === state.member.uid)).toBe(true)
    expect(saved.grants.find(grant => grant.source_page_id === sourceID)).toMatchObject({
      condition: expression,
      target_scope: 'self'
    })
    await ownerPage.goto(pageRoute(targetID))
    await ownerPage.getByRole('button', { name: '分享', exact: true }).click()
    await ownerPage.getByRole('button', { name: '浏览协作者', exact: true }).click()
    await ownerPage.getByRole('option').first().click()
    await ownerPage.getByRole('combobox', { name: '授予权限', exact: true }).click()
    const roleList = ownerPage.getByRole('listbox').last()
    await expect(roleList.getByRole('option')).toHaveText(['可阅读', '可评论', '可编辑', '可管理'])
    await expect(roleList.getByRole('option', { name: '可提交数据', exact: true })).toHaveCount(0)
    await ownerPage.keyboard.press('Escape')
    await ownerPage.getByRole('button', { name: '返回', exact: true }).click()
    await ownerPage.getByRole('button', { name: /权限设置/ }).click()
    const advanced = ownerPage.locator('li').filter({ has: ownerPage.getByText(sourceTitle, { exact: true }) })
    const removedSharing = ownerPage.waitForResponse(
      response =>
        response.request().method() === 'PATCH' &&
        new URL(response.url()).pathname === `/api/v2/pod/pages/${targetID}/sharing`
    )
    await advanced.getByRole('button', { name: '移除', exact: true }).click()
    expect((await removedSharing).status()).toBe(200)
    const removed = await request<{ grants: { source_page_id?: string }[] }>(ownerPage, `/pages/${targetID}/sharing`)
    expect(removed.grants.some(grant => grant.source_page_id === sourceID)).toBe(false)
  } finally {
    if (targetID) await request(ownerPage, `/pages/${targetID}`, 'DELETE')
    if (sourceID) await request(ownerPage, `/pages/${sourceID}`, 'DELETE')
    await Promise.all([owner.close(), viewer.close()])
  }
})
