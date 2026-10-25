import { expect, test } from '@playwright/test'
import { state, request, requestWithSharingVersion } from './fixtures'
import { listRoute, pageRoute } from './routes'

test('a manager can take a shared private root into their own Private space', async ({ browser }) => {
  const ownerContext = await browser.newContext(),
    memberContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const owner = await ownerContext.newPage(),
    member = await memberContext.newPage()
  let id: string | undefined
  try {
    await owner.goto(state.base_url + pageRoute(state.report_id))
    const source = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      title: 'Shared private project takeover',
      private_owner_uid: state.owner.uid
    })
    id = source.page.id
    await request(owner, `/pages/${id}/content`, 'PUT', {
      base_revision: 0,
      xml: '<page><p>The project work stays with the page.</p></page>'
    })
    await requestWithSharingVersion(owner, `/pages/${id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, actions: ['page_view', 'page_manage'] }
      ]
    })
    await member.goto(state.base_url + pageRoute(id))
    await expect(member.getByRole('textbox', { name: '页面标题', exact: true })).toHaveCount(0)
    await member.getByRole('button', { name: '更多操作', exact: true }).click()
    await member.getByRole('menuitem', { name: '移动', exact: true }).click()
    const dialog = member.getByRole('dialog')
    await dialog.getByRole('option', { name: 'Private', exact: true }).click()
    await expect(dialog.getByRole('button', { name: '移动', exact: true })).toBeEnabled()
    const moved = member.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname === `/api/v2/pod/pages/${id}/move`
    )
    await dialog.getByRole('button', { name: '移动', exact: true }).click()
    expect((await moved).status()).toBe(201)
    await expect(dialog).toBeHidden()
    const current = await request<{ page: { private_owner_uid: string; parent_id: string | null } }>(
      member,
      `/pages/${id}`
    )
    expect(current.page.private_owner_uid).toBe(state.member.uid)
    expect(current.page.parent_id).toBeNull()
    await expect(
      member.locator('.pod-nav-section[aria-label="Private"]').getByRole('link', {
        name: 'Shared private project takeover',
        exact: true
      })
    ).toBeVisible()
    await expect(member.locator('.editor-content')).toContainText('The project work stays with the page.')
  } finally {
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await Promise.all([ownerContext.close(), memberContext.close()])
  }
})

test('page creation, movement and copies offer destinations the current member can use', async ({ browser }) => {
  const ownerContext = await browser.newContext(),
    memberContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const owner = await ownerContext.newPage(),
    member = await memberContext.newPage()
  let originalRole: string | undefined
  let parentID: string | undefined
  let createdID: string | undefined
  let delegatedChildID: string | undefined
  const privateCopies: string[] = []
  try {
    await owner.goto(state.base_url + pageRoute(state.report_id))
    originalRole = (await request<{ role: string }>(owner, '/space')).role
    const parent = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      title: 'Shared working folder',
      private_owner_uid: state.owner.uid
    })
    parentID = parent.page.id
    await requestWithSharingVersion(owner, `/pages/${parentID}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'edit' }
      ]
    })
    const database = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      parent_id: parentID,
      type: 'database',
      title: 'Working data'
    })

    for (const role of ['view', 'contribute', 'edit']) {
      await member.goto(state.base_url + listRoute('space'))
      await request(owner, '/space', 'PUT', { role })
      const allowed = role === 'edit'
      const directory = await request<{ can_create_space: boolean; can_create_private: boolean }>(
        member,
        '/pages/children'
      )
      expect(directory.can_create_space).toBe(allowed)
      expect(directory.can_create_private).toBe(true)
      await expect(member.locator('.pod-content-list [role="status"]')).toHaveCount(0)
      await expect(
        member
          .locator('.pod-nav-section[aria-label="空间"] > .pod-nav-section-heading')
          .getByRole('button', { name: '新建页面', exact: true })
      ).toHaveCount(allowed ? 1 : 0)
      await expect(
        member.locator('.pod-content-list').getByRole('button', { name: '新建页面', exact: true })
      ).toHaveCount(allowed ? 1 : 0)
      await expect(
        member
          .locator('.pod-nav-section[aria-label="Private"] > .pod-nav-section-heading')
          .getByRole('button', { name: '新建页面', exact: true })
      ).toBeEnabled()

      if (!allowed) {
        await member.locator('.pod-sidebar-top').getByRole('button', { name: '新建页面', exact: true }).click()
        const dialog = member.getByRole('dialog')
        await dialog.getByRole('textbox', { name: '标题', exact: true }).fill(`Private work in ${role} Space`)
        const saved = member.waitForResponse(
          response => response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/pages'
        )
        await dialog.getByRole('button', { name: '创建', exact: true }).click()
        const response = await saved
        expect(response.status()).toBe(201)
        const created = (await response.json()).page
        privateCopies.push(created.id)
        expect(created.private_owner_uid).toBe(state.member.uid)
        expect(created.parent_id).toBeNull()
        await member.goto(state.base_url + listRoute('space'))
      }

      if (role === 'view') {
        const project = member
          .locator('.pod-tree-row')
          .filter({ has: member.locator(`a[href="${pageRoute(state.report_id)}"]`) })
        await project.hover()
        await project.getByRole('button', { name: '新建页面', exact: true }).click()
        const dialog = member.getByRole('dialog')
        await dialog.getByRole('textbox', { name: '标题', exact: true }).fill('Work inside the shared project')
        const saved = member.waitForResponse(
          response => response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/pages'
        )
        await dialog.getByRole('button', { name: '创建', exact: true }).click()
        const response = await saved
        expect(response.status()).toBe(201)
        const child = ((await response.json()) as { page: { id: string; parent_id: string } }).page
        delegatedChildID = child.id
        expect(child.parent_id).toBe(state.report_id)
        await expect(member.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(
          'Work inside the shared project'
        )
      }

      if (allowed) {
        await member.locator('.pod-content-list').getByRole('button', { name: '新建页面', exact: true }).click()
        const dialog = member.getByRole('dialog')
        await dialog.getByRole('textbox', { name: '标题', exact: true }).fill('New shared work')
        const saved = member.waitForResponse(
          response => response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/pages'
        )
        await dialog.getByRole('button', { name: '创建', exact: true }).click()
        const response = await saved
        expect(response.status()).toBe(201)
        createdID = ((await response.json()) as { page: { id: string } }).page.id
        await expect(member.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue('New shared work')
      }

      await member.goto(state.base_url + pageRoute(database.page.id))
      await member.getByRole('button', { name: '复制当前结果', exact: true }).click()
      const copy = member.getByRole('dialog')
      await copy.getByRole('combobox', { name: '保存到', exact: true }).click()
      await expect(member.getByRole('listbox')).toBeVisible()
      await expect(
        member.getByRole('option', { name: allowed ? 'Shared working folder' : 'Private', exact: true })
      ).toBeFocused()
      await expect(member.getByRole('option', { name: '空间', exact: true })).toHaveCount(allowed ? 1 : 0)
      await expect(member.getByRole('option', { name: 'Private', exact: true })).toBeVisible()
      await member.keyboard.press('Escape')
      await expect(member.getByRole('listbox')).toBeHidden()
      await expect(copy).toBeVisible()
      if (!allowed) {
        const copied = member.waitForResponse(
          response => response.request().method() === 'POST' && new URL(response.url()).pathname.endsWith('/copy')
        )
        await copy.getByRole('button', { name: '复制', exact: true }).click()
        const response = await copied
        expect(response.status()).toBe(201)
        expect(response.request().postDataJSON().data.private_owner_uid).toBe(state.member.uid)
        expect(response.request().postDataJSON().data.parent_id).toBeNull()
        expect(response.request().postDataJSON().data).not.toHaveProperty('title')
        const created = (await response.json()).page
        privateCopies.push(created.id)
        expect(created.private_owner_uid).toBe(state.member.uid)
        expect(created.parent_id).toBeNull()
      } else await copy.getByRole('button', { name: '取消', exact: true }).click()

      await member.getByRole('button', { name: '更多操作', exact: true }).click()
      await member.getByRole('menuitem', { name: '移动', exact: true }).click()
      const move = member.getByRole('dialog')
      await expect(move.getByRole('combobox', { name: '目标位置', exact: true })).toBeVisible()
      await expect(move.getByRole('option', { name: '空间', exact: true })).toHaveCount(allowed ? 1 : 0)
      await move.getByRole('button', { name: '取消', exact: true }).click()
    }
  } finally {
    if (originalRole) await request(owner, '/space', 'PUT', { role: originalRole })
    if (delegatedChildID) await request(owner, `/pages/${delegatedChildID}`, 'DELETE')
    if (createdID) await request(owner, `/pages/${createdID}`, 'DELETE')
    for (const id of privateCopies) await request(member, `/pages/${id}`, 'DELETE')
    if (parentID) await request(owner, `/pages/${parentID}`, 'DELETE')
    await Promise.all([ownerContext.close(), memberContext.close()])
  }
})

test('destination searches find editable work beyond thirty read-only matches', async ({ browser }) => {
  const ownerContext = await browser.newContext(),
    memberContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const owner = await ownerContext.newPage(),
    member = await memberContext.newPage()
  let rootID: string | undefined
  try {
    await owner.goto(state.base_url + pageRoute(state.report_id))
    const root = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      title: 'Searchable destinations',
      private_owner_uid: state.owner.uid
    })
    rootID = root.page.id
    await requestWithSharingVersion(owner, `/pages/${rootID}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'view' }
      ]
    })
    for (let index = 0; index < 30; index++) {
      await request(owner, '/pages', 'POST', { parent_id: rootID, title: 'Needle destination' })
    }
    const target = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      parent_id: rootID,
      title: 'Needle destination available'
    })
    const source = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      parent_id: rootID,
      type: 'database',
      title: 'Working data to reorganize'
    })
    for (const id of [target.page.id, source.page.id]) {
      await requestWithSharingVersion(owner, `/pages/${id}/sharing`, 'PUT', {
        inherit_permissions: false,
        grants: [
          { principal_uid: state.owner.uid, role: 'manage' },
          { principal_uid: state.member.uid, role: 'edit' }
        ]
      })
    }

    await member.goto(state.base_url + pageRoute(source.page.id))
    await member.getByRole('button', { name: '复制当前结果', exact: true }).click()
    const copy = member.getByRole('dialog')
    const searched = member.waitForResponse(response => {
      const url = new URL(response.url())
      return (
        url.pathname === '/api/v2/pod/pages/search' &&
        url.searchParams.get('query') === 'Needle destination' &&
        url.searchParams.get('required_action') === 'page_edit'
      )
    })
    await copy.getByRole('textbox', { name: '搜索页面', exact: true }).fill('Needle destination')
    expect((await searched).status()).toBe(200)
    await copy.getByRole('combobox', { name: '保存到', exact: true }).click()
    await member.getByRole('option', { name: 'Needle destination available', exact: true }).click()
    await copy.getByRole('textbox', { name: '页面标题', exact: true }).fill('Copied working data')
    const copied = member.waitForResponse(
      response => response.request().method() === 'POST' && new URL(response.url()).pathname.endsWith('/copy')
    )
    await copy.getByRole('button', { name: '复制', exact: true }).click()
    const copyResponse = await copied
    expect(copyResponse.status()).toBe(201)
    expect(((await copyResponse.json()) as { page: { parent_id: string } }).page.parent_id).toBe(target.page.id)
    await expect(copy).toBeHidden()

    await member.getByRole('button', { name: '更多操作', exact: true }).click()
    await member.getByRole('menuitem', { name: '移动', exact: true }).click()
    const move = member.getByRole('dialog')
    await move.getByRole('combobox', { name: '目标位置', exact: true }).fill('Needle destination')
    await move.getByRole('option', { name: 'Needle destination available', exact: true }).click()
    const moved = member.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/v2/pod/pages/${source.page.id}/move`
    )
    await move.getByRole('button', { name: '移动', exact: true }).click()
    expect((await moved).status()).toBe(201)
    await expect(move).toBeHidden()
    const current = await request<{ page: { parent_id: string } }>(member, `/pages/${source.page.id}`)
    expect(current.page.parent_id).toBe(target.page.id)
  } finally {
    if (rootID) await request(owner, `/pages/${rootID}`, 'DELETE')
    await Promise.all([ownerContext.close(), memberContext.close()])
  }
})

test('structure edits and page management do not imply record submission', async ({ browser }) => {
  const ownerContext = await browser.newContext(),
    memberContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const owner = await ownerContext.newPage(),
    member = await memberContext.newPage()
  let sourceID: string | undefined
  let destinationID: string | undefined
  try {
    await owner.goto(state.base_url + pageRoute(state.report_id))
    const source = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      title: 'Independent page capabilities',
      type: 'database',
      private_owner_uid: state.owner.uid
    })
    sourceID = source.page.id
    const destination = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      title: 'Shared working destination',
      private_owner_uid: state.owner.uid
    })
    destinationID = destination.page.id
    await requestWithSharingVersion(owner, `/pages/${destinationID}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'edit' }
      ]
    })

    for (const role of ['edit', 'manage']) {
      const actions = ['page_view', role === 'edit' ? 'page_edit' : 'page_manage']
      await requestWithSharingVersion(owner, `/pages/${sourceID}/sharing`, 'PUT', {
        inherit_permissions: false,
        grants: [
          { principal_uid: state.owner.uid, role: 'manage' },
          { principal_uid: state.member.uid, actions }
        ]
      })
      await member.goto(state.base_url + pageRoute(sourceID))
      await expect(member.getByRole('button', { name: 'Table 1', exact: true })).toBeVisible()
      expect((await request<{ actions: string[] }>(member, `/pages/${sourceID}`)).actions).toEqual(actions)
      await expect(member.getByRole('button', { name: '新增记录', exact: true })).toHaveCount(0)
      await expect(member.getByRole('button', { name: '+ 数据表', exact: true })).toHaveCount(role === 'edit' ? 1 : 0)
      await expect(member.getByRole('button', { name: '删除数据表', exact: true })).toHaveCount(
        role === 'manage' ? 1 : 0
      )
      await expect(member.getByRole('button', { name: '分享', exact: true })).toHaveCount(role === 'manage' ? 1 : 0)
      const title = member.getByRole('textbox', { name: '页面标题', exact: true })
      await expect(title).toHaveCount(role === 'edit' ? 1 : 0)

      if (role === 'edit') {
        await title.fill('Structure-only work')
        const saved = member.waitForResponse(
          response =>
            response.request().method() !== 'GET' &&
            new URL(response.url()).pathname === `/api/v2/pod/pages/${sourceID}`
        )
        await member.getByRole('button', { name: 'Table 1', exact: true }).click()
        expect((await saved).status()).toBe(200)
      } else {
        await member.getByRole('button', { name: '更多操作', exact: true }).click()
        await member.getByRole('menuitem', { name: '移动', exact: true }).click()
        const dialog = member.getByRole('dialog')
        await dialog.getByRole('option', { name: 'Shared working destination', exact: true }).click()
        const moved = member.waitForResponse(
          response =>
            response.request().method() === 'POST' &&
            new URL(response.url()).pathname === `/api/v2/pod/pages/${sourceID}/move`
        )
        await dialog.getByRole('button', { name: '移动', exact: true }).click()
        expect((await moved).status()).toBe(201)
        await expect(dialog).toBeHidden()
        const current = await request<{ page: { parent_id: string }; actions: string[] }>(member, `/pages/${sourceID}`)
        expect(current.page.parent_id).toBe(destinationID)
        expect(current.actions).toEqual(actions)
      }
    }
  } finally {
    if (sourceID) await request(owner, `/pages/${sourceID}`, 'DELETE')
    if (destinationID) await request(owner, `/pages/${destinationID}`, 'DELETE')
    await Promise.all([ownerContext.close(), memberContext.close()])
  }
})

test('a shared private project exposes its children and lets collaborators continue organizing it', async ({
  browser
}) => {
  const ownerContext = await browser.newContext(),
    memberContext = await browser.newContext(),
    viewerContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  await viewerContext.addCookies(state.viewer.cookies)
  const owner = await ownerContext.newPage(),
    member = await memberContext.newPage(),
    viewer = await viewerContext.newPage()
  let parentID: string | undefined
  try {
    await owner.goto(state.base_url + pageRoute(state.report_id))
    const parent = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      title: 'Shared private business project',
      type: 'database',
      private_owner_uid: state.owner.uid
    })
    parentID = parent.page.id
    const guide = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      parent_id: parentID,
      title: 'Project operating guide'
    })
    await request(owner, `/pages/${guide.page.id}/content`, 'PUT', {
      base_revision: 0,
      xml: '<page><p>How this project works</p></page>'
    })
    await requestWithSharingVersion(owner, `/pages/${parentID}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'edit' },
        { principal_uid: state.viewer.uid, role: 'view' }
      ]
    })
    await member.goto(state.base_url + pageRoute(parentID))
    await member.getByRole('button', { name: '子页面', exact: true }).click()
    await member.getByRole('link', { name: 'Project operating guide', exact: true }).click()
    await expect(member.locator('.editor-content')).toContainText('How this project works')
    await member.goBack()
    await member.getByRole('button', { name: '子页面', exact: true }).click()
    await member.getByRole('button', { name: '新建子页面', exact: true }).click()
    const dialog = member.getByRole('dialog')
    await dialog.getByRole('textbox', { name: '标题', exact: true }).fill('Collaborative project notes')
    const created = member.waitForResponse(
      response => response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/pages'
    )
    await dialog.getByRole('button', { name: '创建', exact: true }).click()
    const createdResponse = await created
    expect(createdResponse.status()).toBe(201)
    const child = ((await createdResponse.json()) as { page: { id: string; parent_id: string } }).page
    expect(child.parent_id).toBe(parentID)
    await expect(member.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(
      'Collaborative project notes'
    )
    const editor = member.locator('.editor-content')
    await editor.click()
    await member.keyboard.insertText('Work continues from this project.')
    await expect
      .poll(async () => (await request<{ content: { content: string } }>(member, `/pages/${child.id}`)).content.content)
      .toContain('Work continues from this project.')

    await viewer.goto(state.base_url + pageRoute(parentID))
    await viewer.getByRole('button', { name: '子页面', exact: true }).click()
    await expect(viewer.getByRole('button', { name: '新建子页面', exact: true })).toHaveCount(0)
    await viewer.getByRole('link', { name: 'Collaborative project notes', exact: true }).click()
    await expect(viewer.locator('.editor-content')).toContainText('Work continues from this project.')

    await requestWithSharingVersion(owner, `/pages/${child.id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.viewer.uid, role: 'view' }
      ]
    })
    await requestWithSharingVersion(owner, `/pages/${parentID}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'edit' }
      ]
    })
    await viewer.reload()
    await expect(viewer.locator('.editor-content')).toContainText('Work continues from this project.')
    await expect(viewer.getByRole('navigation', { name: '↑ 父页面', exact: true }).getByRole('link')).toHaveCount(0)
  } finally {
    if (parentID) await request(owner, `/pages/${parentID}`, 'DELETE')
    await Promise.all([ownerContext.close(), memberContext.close(), viewerContext.close()])
  }
})

test('an open record draft survives a permission change and submits once when write access returns', async ({
  browser
}) => {
  const ownerContext = await browser.newContext(),
    memberContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const owner = await ownerContext.newPage(),
    member = await memberContext.newPage()
  let id: string | undefined
  try {
    await owner.goto(state.base_url + pageRoute(state.report_id))
    const created = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      type: 'database',
      title: 'Record draft continuity',
      private_owner_uid: state.owner.uid
    })
    id = created.page.id
    const { tables } = await request<{ tables: { id: string }[] }>(owner, `/databases/${id}`)
    const tableID = tables[0]!.id
    const { fields } = await request<{ fields: { id: string; is_primary: boolean }[] }>(owner, `/tables/${tableID}`)
    const primary = fields.find(field => field.is_primary)!
    const share = (role: string) =>
      requestWithSharingVersion(owner, `/pages/${id}/sharing`, 'PUT', {
        inherit_permissions: false,
        grants: [
          { principal_uid: state.owner.uid, role: 'manage' },
          { principal_uid: state.member.uid, role }
        ]
      })
    await share('contribute')
    await member.goto(state.base_url + pageRoute(id))
    await member.getByRole('button', { name: '新增记录', exact: true }).click()
    const dialog = member.getByRole('dialog')
    const name = dialog.getByRole('textbox', { name: 'Name', exact: true })
    await name.fill('Unsubmitted work stays here')
    await share('view')
    await expect(dialog.getByRole('button', { name: '提交记录', exact: true })).toBeDisabled()
    await expect(name).toHaveValue('Unsubmitted work stays here')
    await expect(dialog).toContainText('你没有权限执行此操作。')
    await share('contribute')
    await expect(dialog.getByRole('button', { name: '提交记录', exact: true })).toBeEnabled()
    await expect(name).toHaveValue('Unsubmitted work stays here')
    const saved = member.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/v2/pod/tables/${tableID}/records`
    )
    await dialog.getByRole('button', { name: '提交记录', exact: true }).click()
    expect((await saved).status()).toBe(201)
    await expect(dialog).toBeHidden()
    const { records } = await request<{ records: { data: Record<string, string> }[] }>(
      owner,
      `/tables/${tableID}/query`,
      'POST',
      {}
    )
    expect(records).toHaveLength(1)
    expect(records[0]!.data[primary.id]).toBe('Unsubmitted work stays here')
  } finally {
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await Promise.all([ownerContext.close(), memberContext.close()])
  }
})
