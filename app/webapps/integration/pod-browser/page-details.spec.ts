import { state, requestWithSharingVersion as request } from './fixtures'
import { pageRoute, listRoute } from './routes'
import { expect, test, type Page, type Route } from '@playwright/test'

async function pageAction(page: Page, name: string) {
  await page.locator('.pod-page-header').getByRole('button', { name: '更多操作', exact: true }).click()
  await page.getByRole('menuitem', { name, exact: true }).click()
}

async function create(page: Page, title: string, parent_id?: string) {
  return (await request<{ page: { id: string } }>(page, '/pages', 'POST', { type: 'doc', title, parent_id })).page.id
}

async function choose(page: Page, name: string, option: string) {
  if (name === '目标位置') {
    const dialog = page.getByRole('dialog', { name: '移动页面' })
    await dialog.getByRole('combobox', { name, exact: true }).fill(option)
    await dialog
      .getByRole('option')
      .filter({ has: page.getByText(option, { exact: true }) })
      .click()
    await expect(dialog.locator('.pod-selected-destination')).toContainText(option)
    return
  }
  const trigger = page.getByRole('combobox', { name, exact: true })
  await trigger.click()
  await expect(trigger).toHaveAttribute('aria-expanded', 'true')
  const popupID = await trigger.getAttribute('aria-controls')
  if (!popupID) throw new Error(`Select ${name} has no popup`)
  await page
    .locator(`[id=${JSON.stringify(popupID)}]`)
    .getByRole('option', { name: option, exact: true })
    .click()
  await expect(trigger).toHaveAttribute('aria-expanded', 'false')
}

async function cleanup(actions: (() => Promise<unknown>)[], failed: boolean) {
  const errors: unknown[] = []
  for (const action of actions) {
    try {
      await action()
    } catch (error) {
      errors.push(error)
    }
  }
  if (!errors.length) return
  await test.info().attach('cleanup-errors', { body: errors.map(String).join('\n'), contentType: 'text/plain' })
  if (!failed) throw new AggregateError(errors, 'Pod browser cleanup failed')
}

test('title saves keep edit order and a failed save protects navigation until retry', async ({ browser }) => {
  const context = await browser.newContext({ permissions: ['clipboard-read', 'clipboard-write'] })
  await context.addCookies(state.owner.cookies)
  const owner = await context.newPage()
  let release: (() => void) | undefined
  let id: string | undefined
  let failed = false
  const errors: string[] = []
  owner.on('pageerror', error => errors.push(error.message))
  try {
    await owner.goto(state.base_url + pageRoute(state.report_id))
    const originalTitle = `Title draft ${Date.now()}`
    id = await create(owner, originalTitle)
    await owner.goto(state.base_url + pageRoute(id))
    const title = owner.getByRole('textbox', { name: '页面标题', exact: true })
    await expect(title).toHaveValue(originalTitle)
    await pageAction(owner, '复制链接')
    const expectedLink = state.base_url + pageRoute(id)
    await expect.poll(() => owner.evaluate(() => navigator.clipboard.readText())).toBe(expectedLink)
    const copiedLink = await owner.evaluate(() => navigator.clipboard.readText())
    const linked = await context.newPage()
    await linked.goto(copiedLink)
    await expect(linked).toHaveURL(expectedLink)
    await expect(linked.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(originalTitle)
    await linked.close()
    const values: string[] = []
    let failNext = false
    let failReadNext = false
    await owner.route(`**/api/v2/pod/pages/${id}`, async route => {
      if (route.request().method() === 'GET' && failReadNext) {
        failReadNext = false
        return route.fulfill({ status: 503, json: { error: 'Page refresh unavailable' } })
      }
      if (route.request().method() !== 'PATCH') return route.continue()
      values.push(route.request().postDataJSON().data.title)
      if (values.length === 1) {
        await new Promise<void>(resolve => {
          release = resolve
        })
      }
      if (failNext) {
        failNext = false
        return route.fulfill({ status: 503, json: { error: 'Title save unavailable' } })
      }
      return route.continue()
    })
    await title.fill('First saved title')
    await title.press('Enter')
    await expect.poll(() => values).toEqual(['First saved title'])
    await title.fill('Latest saved title')
    await title.press('Enter')
    await expect(title).toHaveValue('Latest saved title')
    expect(values).toEqual(['First saved title'])
    release!()
    await expect
      .poll(async () => (await request<{ page: { title: string } }>(owner, `/pages/${id}`)).page.title)
      .toBe('Latest saved title')
    expect(values).toEqual(['First saved title', 'Latest saved title'])
    failNext = true
    await title.fill('Recoverable title')
    await title.blur()
    await expect(owner.getByRole('alert')).toContainText('Title save unavailable')
    failReadNext = true
    await owner.getByRole('button', { name: '分享', exact: true }).click()
    await owner
      .getByRole('dialog', { name: '分享页面', exact: true })
      .getByRole('button', { name: '保存分享设置', exact: true })
      .click()
    await expect(owner.getByRole('dialog', { name: '分享页面', exact: true })).toHaveCount(0)
    await expect(
      owner.getByText('无法读取页面的最新状态，未保存的草稿已保留。请重试后继续编辑。', { exact: true })
    ).toBeVisible()
    await expect(title).toHaveValue('Recoverable title')
    await expect(title).toBeDisabled()
    await owner
      .getByRole('navigation', { name: '页面导航' })
      .getByRole('link', { name: '最近访问', exact: true })
      .click()
    await expect(owner.getByRole('dialog', { name: '修改尚未保存' })).toBeVisible()
    await owner.keyboard.press('Escape')
    await expect(owner.getByRole('dialog')).toHaveCount(0)
    await expect(title).toHaveValue('Recoverable title')
    await owner.getByRole('button', { name: '重试', exact: true }).first().click()
    await expect(title).toBeEnabled()
    await owner.getByRole('button', { name: '重试', exact: true }).click()
    await expect
      .poll(async () => (await request<{ page: { title: string } }>(owner, `/pages/${id}`)).page.title)
      .toBe('Recoverable title')
    await owner
      .getByRole('navigation', { name: '页面导航' })
      .getByRole('link', { name: '最近访问', exact: true })
      .click()
    await expect(owner).toHaveURL(state.base_url + listRoute('recent'))
    expect(errors).toEqual([])
  } catch (error) {
    failed = true
    throw error
  } finally {
    release?.()
    await cleanup(
      [
        () => owner.unrouteAll({ behavior: 'wait' }),
        ...(id ? [() => request(owner, `/pages/${id}`, 'DELETE')] : []),
        () => context.close()
      ],
      failed
    )
  }
})

test('Trash searches deleted titles and restores a page through an explicit open action', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const owner = await context.newPage()
  const prefix = `Trash details ${Date.now()}`
  let restored: string | undefined
  let failed = false
  try {
    await owner.goto(state.base_url + pageRoute(state.report_id))
    const alpha = await create(owner, `${prefix} Alpha`)
    const beta = await create(owner, `${prefix} Beta`)
    await request(owner, `/pages/${alpha}`, 'DELETE')
    await request(owner, `/pages/${beta}`, 'DELETE')
    await owner.goto(state.base_url + listRoute('trash'))
    const searched = owner.waitForResponse(
      response =>
        response.request().method() === 'GET' &&
        new URL(response.url()).pathname === '/api/v2/pod/pages' &&
        new URL(response.url()).searchParams.get('scope') === 'trash' &&
        new URL(response.url()).searchParams.get('query') === `${prefix} Alpha`
    )
    await owner.getByRole('textbox', { name: '搜索回收站', exact: true }).fill(`${prefix} Alpha`)
    expect((await searched).status()).toBe(200)
    const main = owner.getByRole('main')
    await expect(main.getByRole('listitem')).toHaveCount(1)
    await expect(main.getByText(`${prefix} Beta`, { exact: true })).toHaveCount(0)
    await expect(main.getByRole('link', { name: `${prefix} Alpha` })).toHaveCount(0)
    await main.getByRole('button', { name: '恢复', exact: true }).click()
    await expect(main.getByText('回收站中没有匹配的页面', { exact: true })).toBeVisible()
    restored = alpha
    await owner.getByRole('button', { name: '打开页面', exact: true }).click()
    await expect(owner.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(`${prefix} Alpha`)
    expect(
      (await request<{ page: { deleted_at: string | null } }>(owner, `/pages/${alpha}`)).page.deleted_at
    ).toBeNull()
  } catch (error) {
    failed = true
    throw error
  } finally {
    await cleanup(
      [...(restored ? [() => request(owner, `/pages/${restored}`, 'DELETE')] : []), () => context.close()],
      failed
    )
  }
})

test('editors move pages without changing access and retain the destination after an access-changing rejection', async ({
  browser
}) => {
  const ownerContext = await browser.newContext(),
    editorContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await editorContext.addCookies(state.member.cookies)
  const owner = await ownerContext.newPage(),
    editor = await editorContext.newPage()
  const ids: string[] = []
  const errors: string[] = []
  editor.on('pageerror', error => errors.push(error.message))
  let failed = false
  try {
    await owner.goto(state.base_url + pageRoute(state.report_id))
    const prefix = `Editor move ${Date.now()}`
    const source = await create(owner, `${prefix} Source`, state.report_id)
    ids.push(source)
    const child = await create(owner, `${prefix} Child`, source)
    const target = await create(owner, `${prefix} Target`, state.report_id)
    ids.push(target)
    const restricted = await create(owner, `${prefix} Restricted`, state.report_id)
    ids.push(restricted)
    await request(owner, `/pages/${source}/content`, 'PUT', {
      base_revision: 0,
      xml: '<page><p>Keep the original source content.</p></page>'
    })
    await request(owner, `/pages/${child}/content`, 'PUT', {
      base_revision: 0,
      xml: '<page><p>Keep the original child content.</p></page>'
    })
    await request(owner, `/pages/${restricted}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'edit' }
      ]
    })
    const sharing = await request(owner, `/pages/${source}/sharing`)
    await editor.goto(state.base_url + pageRoute(source))
    expect((await request<{ role: string }>(editor, `/pages/${source}`)).role).toBe('edit')
    await expect(editor.getByRole('button', { name: '分享', exact: true })).toHaveCount(0)
    await editor.locator('.pod-page-header').getByRole('button', { name: '更多操作', exact: true }).click()
    await expect(editor.getByRole('menuitem', { name: '移到回收站', exact: true })).toHaveCount(0)
    await editor.getByRole('menuitem', { name: '移动', exact: true }).click()
    const dialog = editor.getByRole('dialog', { name: '移动页面' })
    await choose(editor, '目标位置', `${prefix} Target`)
    await dialog.getByRole('button', { name: '移动', exact: true }).click()
    await expect(dialog).toHaveCount(0)
    await expect(
      editor.locator('.pod-page-breadcrumbs').getByRole('link', { name: `${prefix} Target`, exact: true })
    ).toBeVisible()
    await editor.reload()
    await expect(editor.locator('.editor-content')).toContainText('Keep the original source content.')
    const moved = await request<{ page: { id: string; parent_id: string }; role: string }>(editor, `/pages/${source}`)
    expect(moved.page).toMatchObject({ id: source, parent_id: target })
    expect(moved.role).toBe('edit')
    expect(await request(owner, `/pages/${source}/sharing`)).toEqual(sharing)

    await pageAction(editor, '移动')
    await choose(editor, '目标位置', `${prefix} Restricted`)
    await dialog.getByRole('button', { name: '移动', exact: true }).click()
    await expect(dialog.getByRole('alert')).toContainText('需要完全访问权限')
    await expect(dialog.locator('.pod-selected-destination')).toContainText(`${prefix} Restricted`)
    expect((await request<{ page: { parent_id: string } }>(editor, `/pages/${source}`)).page.parent_id).toBe(target)
    const retained = await request<{ page: { id: string; parent_id: string }; content: { plain_text: string } }>(
      editor,
      `/pages/${child}`
    )
    expect(retained.page).toMatchObject({ id: child, parent_id: source })
    expect(retained.content.plain_text).toContain('Keep the original child content.')
    expect(await request(owner, `/pages/${source}/sharing`)).toEqual(sharing)
    expect(errors).toEqual([])
  } catch (error) {
    failed = true
    throw error
  } finally {
    await cleanup(
      [
        ...ids.map(id => () => request(owner, `/pages/${id}`, 'DELETE')),
        () => ownerContext.close(),
        () => editorContext.close()
      ],
      failed
    )
  }
})

test('move destinations respect the visible tree and sharing cannot discard a pending write', async ({ browser }) => {
  const context = await browser.newContext(),
    managerContext = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  await managerContext.addCookies(state.member.cookies)
  const owner = await context.newPage(),
    manager = await managerContext.newPage()
  const ids: string[] = []
  let readonlyID: string | undefined
  let held: (() => void) | undefined
  let failed = false
  try {
    await owner.goto(state.base_url + pageRoute(state.report_id))
    await manager.goto(state.base_url + pageRoute(state.report_id))
    const prefix = `Move details ${Date.now()}`
    const source = await create(owner, `${prefix} Source`)
    ids.unshift(source)
    const child = await create(owner, `${prefix} Child`, source)
    ids.unshift(child)
    const grandchild = await create(owner, `${prefix} Grandchild`, child)
    ids.unshift(grandchild)
    const target = await create(owner, `${prefix} Target`)
    ids.push(target)
    readonlyID = (
      await request<{ page: { id: string } }>(manager, '/pages', 'POST', {
        type: 'doc',
        title: `${prefix} Read only`,
        private_owner_uid: state.member.uid
      })
    ).page.id
    await request(manager, `/pages/${readonlyID}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'view' },
        { principal_uid: state.member.uid, role: 'manage' }
      ]
    })
    await owner.goto(state.base_url + pageRoute(source))
    await pageAction(owner, '移动')
    const dialog = owner.getByRole('dialog', { name: '移动页面' })
    await expect(dialog.getByRole('button', { name: '移动', exact: true })).toBeDisabled()
    const trigger = dialog.getByRole('combobox', { name: '目标位置', exact: true })
    await expect(trigger).toBeFocused()
    const popup = dialog.getByRole('listbox', { name: '目标位置', exact: true })
    await expect(
      popup.getByRole('option').filter({ has: owner.getByText(`${prefix} Target`, { exact: true }) })
    ).toBeVisible()
    for (const suffix of ['Source', 'Child', 'Grandchild', 'Read only']) {
      await expect(
        popup.getByRole('option').filter({ has: owner.getByText(`${prefix} ${suffix}`, { exact: true }) })
      ).toHaveCount(0)
    }
    const searched = owner.waitForResponse(response => {
      const url = new URL(response.url())
      return url.pathname === '/api/v2/pod/pages/search' && url.searchParams.get('query') === `${prefix} Grandchild`
    })
    await trigger.fill(`${prefix} Grandchild`)
    const grandchildSearch = await searched
    expect(grandchildSearch.ok()).toBe(true)
    expect(new URL(grandchildSearch.url()).searchParams.get('exclude_subtree_of')).toBe(source)
    expect((await grandchildSearch.json()).pages).toEqual([])
    await expect(popup.getByRole('option')).toHaveCount(0)
    await trigger.fill(`${prefix} Target`)
    await expect(
      popup.getByRole('option').filter({ has: owner.getByText(`${prefix} Target`, { exact: true }) })
    ).toBeVisible()
    await trigger.press('Enter')
    await expect(dialog.locator('.pod-selected-destination')).toContainText(`${prefix} Target`)
    await dialog.getByRole('button', { name: '移动', exact: true }).click()
    await expect(dialog).toHaveCount(0)
    expect((await request<{ page: { parent_id: string } }>(owner, `/pages/${source}`)).page.parent_id).toBe(target)
    await pageAction(owner, '移动')
    await expect(dialog.locator('.pod-selected-destination')).toContainText(`${prefix} Target`)
    await expect(dialog.getByRole('button', { name: '移动', exact: true })).toBeDisabled()
    await choose(owner, '目标位置', 'Private')
    await expect(dialog).toContainText('单独授权仍然保留')
    await owner.keyboard.press('Escape')
    await expect(owner.locator('.pod-page-header').getByRole('button', { name: '更多操作', exact: true })).toBeFocused()
    await owner.getByRole('button', { name: '分享', exact: true }).click()
    const inherit = owner.getByRole('checkbox')
    await expect(inherit).toBeChecked()
    await inherit.uncheck()
    await owner.keyboard.press('Escape')
    await owner.getByRole('button', { name: '分享', exact: true }).click()
    await expect(inherit).toBeChecked()
    await owner.route(`**/api/v2/pod/pages/${source}/sharing`, async (route: Route) => {
      if (route.request().method() === 'PUT') {
        await new Promise<void>(resolve => {
          held = resolve
        })
      }
      return route.continue()
    })
    await owner.getByRole('button', { name: '保存分享设置', exact: true }).click()
    await expect.poll(() => !!held).toBe(true)
    await expect(inherit).toBeDisabled()
    await owner.keyboard.press('Escape')
    await expect(owner.getByRole('dialog', { name: '分享页面' })).toBeVisible()
    held!()
    await expect(owner.getByRole('dialog')).toHaveCount(0)
  } catch (error) {
    failed = true
    throw error
  } finally {
    held?.()
    await cleanup(
      [
        () => owner.unrouteAll({ behavior: 'wait' }),
        ...(readonlyID ? [() => request(manager, `/pages/${readonlyID}`, 'DELETE')] : []),
        ...ids.map(id => () => request(owner, `/pages/${id}`, 'DELETE')),
        () => context.close(),
        () => managerContext.close()
      ],
      failed
    )
  }
})
