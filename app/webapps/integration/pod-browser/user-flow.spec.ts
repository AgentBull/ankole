import { state, publishApplet, requestWithSharingVersion as request } from './fixtures'
import { listRoute, conversationRoute, pageIDFromURL, pageRoute as route } from './routes'
import { readFileSync } from 'node:fs'
import { expect, test, type Page, type Route } from '@playwright/test'

const content = (page: Page) => page.locator('.editor-content')

async function pageAction(page: Page, name: string) {
  await page.locator('.pod-page-header').getByRole('button', { name: '更多操作', exact: true }).click()
  await page.getByRole('menuitem', { name, exact: true }).click()
}

async function documentAction(page: Page, name: string) {
  await page.locator('.editor-content > *').first().hover()
  await page.getByRole('button', { name: 'Block 菜单', exact: true }).click()
  await page.getByRole('menuitem', { name: '在下方添加 Block', exact: true }).click()
  if (name === '新建页面') {
    await page.getByRole('menuitem', { name, exact: true }).hover()
  } else {
    await page.getByRole('menuitem', { name, exact: true }).click()
  }
}
// Match the full visible label while preserving MF2's intentional bidi isolation in the product.
const visibleName = (name: string) =>
  new RegExp(`^\\p{Bidi_Control}*${[...name].map(RegExp.escape).join('\\p{Bidi_Control}*')}\\p{Bidi_Control}*$`, 'u')
async function choose(page: Page, name: string, option: string, parent?: string) {
  if (name === '目标位置' || name === '选择页面') {
    const dialog = page.getByRole('dialog', {
      name: name === '目标位置' ? '移动页面' : '嵌入多维表或应用',
      exact: true
    })
    const search = dialog.getByRole('combobox', { name, exact: true })
    await search.click()
    await expect(search).toBeFocused()
    await search.fill(option)
    const choices = dialog.getByRole('option').filter({ has: page.getByText(option, { exact: true }) })
    const choice = parent ? choices.filter({ hasText: parent }) : choices
    await choice.click()
    if (name === '目标位置') await expect(dialog.locator('.pod-selected-destination')).toContainText(option)
    else await expect(dialog).toHaveCount(0)
    return
  }
  const trigger = page.getByRole('combobox', { name, exact: true })
  await trigger.click()
  await expect(trigger).toHaveAttribute('aria-expanded', 'true')
  const popupID = await trigger.getAttribute('aria-controls')
  if (!popupID) throw new Error(`Select ${name} has no controlled popup`)
  await page
    .locator(`[id=${JSON.stringify(popupID)}]`)
    .getByRole('option', { name: visibleName(option) })
    .click()
  await expect(trigger).toHaveAttribute('aria-expanded', 'false')
}

test('people and Agent-authored content follow the real Pod persistence, permissions and runtime path', async ({
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
  const errors: string[] = []
  for (const page of [owner, member, viewer]) page.on('pageerror', error => errors.push(error.message))
  try {
    await owner.goto(state.base_url + route(state.report_id))
    await member.goto(state.base_url + route(state.report_id))
    await expect(owner.getByRole('textbox', { name: '页面标题' })).toHaveValue('Browser report')
    await expect(content(owner)).toBeVisible()
    await expect(content(member)).toBeVisible()
    await content(owner).click()
    await owner.keyboard.insertText('Owner research ')
    await content(member).click()
    await member.keyboard.insertText('Member analysis ')
    await expect(content(owner)).toContainText('Owner research')
    await expect(content(owner)).toContainText('Member analysis')
    await expect(content(member)).toHaveText(await content(owner).innerText())
    await expect
      .poll(
        async () =>
          (await request<{ content: { plain_text: string } }>(owner, `/pages/${state.report_id}`)).content.plain_text
      )
      .toContain('Member analysis')

    await documentAction(owner, '新建页面')
    await owner.getByRole('menuitem', { name: '文档', exact: true }).click()
    await expect(owner).not.toHaveURL(state.base_url + route(state.report_id))
    await expect(owner.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue('')
    const parent = await request<{ content: { content: string } }>(owner, `/pages/${state.report_id}`)
    expect(parent.content.content).toContain(pageIDFromURL(owner.url()))

    await owner.goto(state.base_url + route(state.base_id))
    await member.goto(state.base_url + route(state.base_id))
    const amountOwner = owner.getByRole('spinbutton', { name: 'Amount', exact: true }).first()
    await amountOwner.fill('25')
    await amountOwner.blur()
    await expect(member.getByRole('spinbutton', { name: 'Amount', exact: true }).first()).toHaveValue('25')
    await owner.getByRole('button', { name: '新增记录', exact: true }).click()
    await owner.getByRole('dialog').getByRole('spinbutton', { name: 'Amount', exact: true }).fill('12')
    await owner.getByRole('dialog').getByRole('button', { name: '提交记录', exact: true }).click()
    await expect(member.getByRole('spinbutton', { name: 'Amount', exact: true })).toHaveCount(2)

    await viewer.goto(state.base_url + route(state.applet_id))
    await expect(viewer.frameLocator('iframe').getByRole('heading', { name: 'Tracker v1', exact: true })).toBeVisible()
    const rejected = viewer.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/v2/pod/tables/${state.table_id}/records`
    )
    await viewer.frameLocator('iframe').getByRole('button', { name: 'Add sample', exact: true }).click()
    expect((await rejected).status()).toBe(403)
    await expect(viewer.frameLocator('iframe').getByRole('alert')).toHaveText('Write rejected')
    await expect(viewer.frameLocator('iframe').locator('.applet-record-count')).toHaveText('2 records')
    await owner.goto(state.base_url + route(state.applet_id))
    await expect(owner.frameLocator('iframe').getByRole('heading', { name: 'Tracker v1', exact: true })).toBeVisible()
    await owner.frameLocator('iframe').getByRole('button', { name: 'Add sample', exact: true }).click()
    await expect(owner.frameLocator('iframe').locator('.applet-record-count')).toHaveText('3 records')
    await expect(viewer.frameLocator('iframe').locator('.applet-record-count')).toHaveText('3 records')
    const applet = await request<{ page: { revision: number } }>(owner, `/pages/${state.applet_id}`)
    await publishApplet(state.applet_id, applet.page.revision, state.publish_v2_files)
    await expect(owner.frameLocator('iframe').getByRole('heading', { name: 'Tracker v2', exact: true })).toBeVisible()
    await expect(viewer.frameLocator('iframe').getByRole('heading', { name: 'Tracker v2', exact: true })).toBeVisible()
    await expect(
      owner.frameLocator('iframe').getByRole('button', { name: 'Local counter 0', exact: true })
    ).toBeVisible()

    await owner.goto(state.base_url + route(state.report_id))
    const report = await request<{ page: { revision: number } }>(owner, `/pages/${state.report_id}`)
    await request(owner, `/pages/${state.report_id}/content`, 'PUT', {
      base_revision: report.page.revision,
      xml: `<page><p>Published report</p><embed ref="${state.applet_id}"/><embed ref="${state.applet_id}"/></page>`
    })
    await expect(owner.locator('iframe')).toHaveCount(2)
    await owner.frameLocator('iframe').first().getByRole('button', { name: 'Local counter 0', exact: true }).click()
    await expect(
      owner.frameLocator('iframe').first().getByRole('button', { name: 'Local counter 1', exact: true })
    ).toBeVisible()
    await expect(
      owner.frameLocator('iframe').nth(1).getByRole('button', { name: 'Local counter 0', exact: true })
    ).toBeVisible()
    await request(owner, `/pages/${state.report_id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'edit' }
      ]
    })
    await expect(viewer.getByRole('alert')).toContainText('没有权限')
    expect(errors).toEqual([])
  } finally {
    await ownerContext.close()
    await memberContext.close()
    await viewerContext.close()
  }
})

test('uploaded workbooks and presentations preview through the authorized Pod file path', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const owner = await context.newPage()
  try {
    await owner.goto(state.base_url + route(state.report_id))
    await expect(content(owner)).toBeVisible()
    const XLSX = await import('xlsx')
    const workbook = XLSX.utils.book_new()
    XLSX.utils.book_append_sheet(
      workbook,
      XLSX.utils.aoa_to_sheet([
        ['Revenue', 'Currency'],
        [1234.5, 'USD']
      ]),
      'Revenue'
    )
    XLSX.utils.book_append_sheet(workbook, XLSX.utils.aoa_to_sheet([['Quarter two', 28]]), 'Forecast')
    const PPTX = await import('@office-kit/pptx')
    const presentation = PPTX.createPresentation()
    PPTX.addTitleSlide(presentation, 'Quarterly results')
    PPTX.addContentSlide(presentation, { title: 'Next quarter', body: 'Launch the research service' })
    const files = [
      {
        name: 'Forecast.xlsx',
        mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        buffer: Buffer.from(XLSX.write(workbook, { type: 'array', bookType: 'xlsx' }))
      },
      {
        name: 'Results.pptx',
        mimeType: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        buffer: Buffer.from(await PPTX.savePresentation(presentation))
      }
    ]
    for (const file of files) {
      const { page } = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
        type: 'file',
        title: file.name,
        parent_id: state.report_id
      })
      await owner.goto(state.base_url + route(page.id))
      await owner.getByLabel('选择上传文件', { exact: true }).setInputFiles(file)
      await expect(owner.getByRole('link', { name: '下载原文件', exact: true })).toBeVisible()
      if (file.name.endsWith('.xlsx')) {
        await expect(
          owner
            .getByTitle(/工作表.*Revenue/)
            .contentFrame()
            .getByText('1234.5', { exact: true })
        ).toBeVisible()
        await owner.getByRole('button', { name: 'Forecast', exact: true }).click()
        await expect(
          owner
            .getByTitle(/工作表.*Forecast/)
            .contentFrame()
            .getByText('Quarter two', { exact: true })
        ).toBeVisible()
      } else {
        await expect(
          owner.frameLocator('iframe[title="幻灯片 1"]').getByText('Quarterly results', { exact: true })
        ).toBeVisible()
        await owner.getByRole('button', { name: '第 2 页', exact: true }).click()
        await expect(
          owner.frameLocator('iframe[title="幻灯片 2"]').getByText('Launch the research service', { exact: true })
        ).toBeVisible()
      }
    }
  } finally {
    await context.close()
  }
})

test('private work moves, shares, searches, favorites and restores through the real page lifecycle', async ({
  browser
}) => {
  const context = await browser.newContext(),
    memberContext = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const owner = await context.newPage(),
    member = await memberContext.newPage()
  const title = `Lifecycle note ${Date.now()}`
  try {
    await owner.goto(state.base_url + route(state.report_id))
    await owner
      .locator('.pod-nav-section[aria-label="私人页面"] > .pod-nav-section-heading')
      .getByRole('button', { name: '新建页面', exact: true })
      .click()
    await owner.getByRole('menuitem', { name: '文档', exact: true }).click()
    await expect(owner).not.toHaveURL(state.base_url + route(state.report_id))
    const pageTitle = owner.getByRole('textbox', { name: '页面标题', exact: true })
    await expect(pageTitle).toHaveValue('')
    await pageTitle.fill(title)
    await pageTitle.blur()
    const id = pageIDFromURL(owner.url())
    await content(owner).click()
    await owner.keyboard.insertText('Private research result')
    await expect
      .poll(async () => (await request<{ content: { plain_text: string } }>(owner, `/pages/${id}`)).content.plain_text)
      .toBe('Private research result')
    await owner.getByRole('button', { name: '☆ 收藏', exact: true }).click()
    await expect(owner.getByRole('button', { name: '★ 已收藏', exact: true })).toBeVisible()
    await owner.getByRole('navigation', { name: '页面导航' }).getByRole('link', { name: '收藏', exact: true }).click()
    await expect(owner.getByRole('main').getByRole('link', { name: title })).toBeVisible()
    await owner.getByRole('main').getByRole('link', { name: title }).click()
    await owner.getByRole('button', { name: '分享', exact: true }).click()
    await owner.getByRole('combobox', { name: '搜索协作者', exact: true }).fill('Browser member')
    await owner.getByRole('option').filter({ hasText: 'Browser member' }).first().click()
    const shared = owner.waitForResponse(
      response =>
        response.request().method() === 'PATCH' &&
        new URL(response.url()).pathname === `/api/v2/pod/pages/${id}/sharing`
    )
    await owner.getByRole('dialog').getByRole('button', { name: '确定', exact: true }).click()
    expect((await shared).status()).toBe(200)
    await expect(owner.getByRole('dialog', { name: '分享文档', exact: true })).toBeVisible()
    await owner.keyboard.press('Escape')
    await member.goto(state.base_url + route(id))
    await expect(content(member)).toHaveText('Private research result')
    await expect(content(member)).toHaveAttribute('contenteditable', 'false')
    await pageAction(owner, '移动')
    await choose(owner, '目标位置', 'Browser report')
    await owner.getByRole('dialog').getByRole('button', { name: '移动', exact: true }).click()
    await expect
      .poll(async () => (await request<{ page: { parent_id: string } }>(owner, `/pages/${id}`)).page.parent_id)
      .toBe(state.report_id)
    await owner.getByRole('button', { name: '搜索或跳转', exact: true }).click()
    await owner
      .getByRole('dialog', { name: '搜索或跳转', exact: true })
      .locator('[cmdk-item][data-value="scope:search"]')
      .click()
    await owner.getByRole('textbox', { name: '搜索页面', exact: true }).fill('Private research result')
    await expect(owner.getByRole('main').getByRole('link', { name: title })).toBeVisible()
    await owner.getByRole('main').getByRole('link', { name: title }).click()
    await pageAction(owner, '移到回收站')
    await expect(owner).toHaveURL(state.base_url + route(state.report_id))
    await owner.locator('.pod-sidebar-footer').getByRole('link', { name: '回收站', exact: true }).click()
    const row = owner.getByRole('main').getByRole('listitem').filter({ hasText: title })
    await row.getByRole('button', { name: '恢复', exact: true }).click()
    await expect(row).toHaveCount(0)
    await owner.goto(state.base_url + route(id))
    await expect(content(owner)).toHaveText('Private research result')
  } finally {
    await context.close()
    await memberContext.close()
  }
})

test('Private creation and moves wait for identity after delayed and failed reads', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const owner = await context.newPage()
  let mode: 'hold' | 'fail' | 'pass' = 'hold'
  const held: Route[] = []
  const writes: { path: string; body: Record<string, unknown> }[] = []
  const createdIDs: string[] = []
  const fail = (route: Route) =>
    route.fulfill({
      status: 503,
      json: { error: { code: 'private_unavailable', message: 'Private temporarily unavailable' } }
    })
  await owner.route('**/api/v2/pod/pages**', async intercepted => {
    const url = new URL(intercepted.request().url())
    const identityRead =
      url.pathname === '/api/v2/pod/pages/navigation' ||
      url.searchParams.get('scope') === 'private' ||
      (url.pathname === '/api/v2/pod/pages/search' &&
        url.searchParams.get('required_action') === 'page_edit' &&
        url.searchParams.has('exclude_subtree_of'))
    if (!identityRead || mode === 'pass') {
      await intercepted.continue()
    } else if (mode === 'hold') held.push(intercepted)
    else await fail(intercepted)
  })
  owner.on('request', request => {
    const path = new URL(request.url()).pathname
    if (request.method() === 'POST' && (path === '/api/v2/pod/pages' || path.endsWith('/move'))) {
      writes.push({ path, body: request.postDataJSON().data as Record<string, unknown> })
    }
  })
  const rejectHeld = async () => {
    mode = 'fail'
    await Promise.all(held.splice(0).map(fail))
  }
  try {
    await owner.goto(`${state.base_url}${listRoute('private')}`)
    const treeCreate = owner
      .locator('.pod-nav-section[aria-label="私人页面"] > .pod-nav-section-heading')
      .getByRole('button', { name: '新建页面', exact: true })
    const listCreate = owner.getByRole('main').getByRole('button', { name: '新建页面', exact: true })
    await expect(treeCreate).toBeDisabled()
    await expect(listCreate).toBeDisabled()
    await expect.poll(() => held.length).toBeGreaterThan(0)
    expect(writes).toEqual([])
    await rejectHeld()
    await expect(owner.getByRole('alert').first()).toBeVisible({ timeout: 15000 })
    await expect(treeCreate).toBeDisabled()
    await expect(listCreate).toBeDisabled()
    expect(writes).toEqual([])

    mode = 'pass'
    await owner.getByRole('main').getByRole('button', { name: '重试', exact: true }).click()
    await expect(listCreate).toBeEnabled()
    await listCreate.click()
    await owner.getByRole('menuitem', { name: '文档', exact: true }).click()
    await expect(owner).toHaveURL(/\/pages\//)
    const privateID = pageIDFromURL(owner.url())
    createdIDs.push(privateID)
    expect(writes.at(-1)?.body.private_owner_uid).toBe(state.owner.uid)
    expect(
      (await request<{ page: { private_owner_uid: string } }>(owner, `/pages/${privateID}`)).page.private_owner_uid
    ).toBe(state.owner.uid)

    const { page: shared } = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      type: 'doc',
      title: `Move identity ${Date.now()}`
    })
    createdIDs.push(shared.id)
    const beforeMove = writes.length
    mode = 'hold'
    await owner.goto(state.base_url + route(shared.id))
    await pageAction(owner, '移动')
    await expect(owner.getByRole('dialog').getByRole('option', { name: '私人页面', exact: true })).toHaveCount(0)
    const submitMove = owner.getByRole('dialog').getByRole('button', { name: '移动', exact: true })
    await expect(submitMove).toBeDisabled()
    await expect
      .poll(() =>
        held.some(
          intercepted => new URL(intercepted.request().url()).searchParams.get('exclude_subtree_of') === shared.id
        )
      )
      .toBe(true)
    await rejectHeld()
    await expect(owner.getByRole('dialog').getByRole('alert')).toBeVisible({ timeout: 15000 })
    await expect(submitMove).toBeDisabled()
    expect(writes).toHaveLength(beforeMove)
    expect(
      (await request<{ page: { private_owner_uid: string | null } }>(owner, `/pages/${shared.id}`)).page
        .private_owner_uid
    ).toBeNull()

    mode = 'pass'
    await owner.getByRole('dialog').getByRole('button', { name: '重试', exact: true }).click()
    await choose(owner, '目标位置', '私人页面')
    await expect(submitMove).toBeEnabled()
    await submitMove.click()
    await expect(owner.getByRole('dialog')).toHaveCount(0)
    expect(writes.at(-1)?.body).toMatchObject({ parent_id: null, private_owner_uid: state.owner.uid })
    expect(
      (await request<{ page: { private_owner_uid: string } }>(owner, `/pages/${shared.id}`)).page.private_owner_uid
    ).toBe(state.owner.uid)
  } finally {
    mode = 'pass'
    for (const intercepted of held.splice(0)) await intercepted.continue().catch(() => {})
    for (const id of createdIDs) await request(owner, `/pages/${id}`, 'DELETE').catch(() => {})
    await context.close()
  }
})

test('a large business table uses global groups and per-group paging across its built-in views', async ({
  browser
}) => {
  test.setTimeout(240000)
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const owner = await context.newPage()
  await owner.clock.setFixedTime(new Date('2026-10-19T12:00:00Z'))
  try {
    await owner.goto(state.base_url + route(state.report_id))
    await expect(content(owner)).toBeVisible()
    const title = `Large workflow ${crypto.randomUUID()}`
    await documentAction(owner, '新建页面')
    const createdBase = owner.waitForResponse(
      response => response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/pages'
    )
    await owner.getByRole('menuitem', { name: '多维表', exact: true }).click()
    const { page } = (await (await createdBase).json()) as { page: { id: string; title: string } }
    await request(owner, `/pages/${page.id}`, 'PATCH', { title, expected_title: page.title })
    await expect
      .poll(
        async () =>
          (await request<{ content: { content: string } }>(owner, `/pages/${state.report_id}`)).content.content
      )
      .toContain(page.id)
    const { tables } = await request<{ tables: { id: string }[] }>(owner, `/bases/${page.id}`)
    expect(tables).toHaveLength(1)
    const table = tables[0]!
    const schema = await request<{ fields: { id: string; is_primary: boolean }[] }>(owner, `/tables/${table.id}`)
    const primary = schema.fields.find(field => field.is_primary)!.id
    const addField = async (name: string, type: string, config = {}) =>
      (await request<{ field: { id: string } }>(owner, `/tables/${table.id}/fields`, 'POST', { name, type, config }))
        .field.id
    const amount = await addField('Revenue', 'number'),
      status = await addField('Status', 'select', {
        options: [
          { id: 'new', name: 'New' },
          { id: 'done', name: 'Done' }
        ]
      })
    for (let offset = 0; offset < 5002; offset += 200) {
      await request(owner, `/tables/${table.id}/records`, 'POST', {
        creates: Array.from({ length: Math.min(200, 5002 - offset) }, (_, index) => ({
          data: {
            [primary]: `Record ${String(offset + index).padStart(5, '0')}`,
            [amount]: offset + index,
            [status]: (offset + index) % 2 ? 'new' : 'done'
          }
        }))
      })
    }
    expect((await request<{ mode: string }>(owner, `/tables/${table.id}`)).mode).toBe('remote')
    await owner.goto(state.base_url + route(page.id))
    await expect(owner.getByText('5,002 条记录', { exact: true })).toBeVisible()
    const expectDensity = async (rowSelector: string, field: string) => {
      const row = owner.locator(rowSelector).first()
      const input = row.getByRole('textbox', { name: field, exact: true })
      for (const [width, rowHeight, inputHeight] of [
        [1440, 32, 28],
        [390, 40, 32]
      ]) {
        await owner.setViewportSize({ width: width!, height: 1000 })
        await expect.poll(async () => (await row.boundingBox())?.height ?? 0).toBeCloseTo(rowHeight!, 0)
        await expect.poll(async () => (await input.boundingBox())?.height ?? 0).toBeCloseTo(inputHeight!, 0)
        expect(await owner.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true)
      }
      await owner.setViewportSize({ width: 1440, height: 1000 })
    }
    await expectDensity('.pod-base-grid [data-grid-record]', 'Name')
    const createView = async (type: string) => {
      await owner.getByRole('button', { name: '+ 视图', exact: true }).click()
      await owner.getByRole('menuitem', { name: type, exact: true }).click()
    }
    await createView('看板')
    await choose(owner, '选择分组字段', 'Status')
    const column = owner.getByRole('heading', { name: 'New 2501', exact: true }).locator('xpath=ancestor::section[1]')
    await expect(column).toBeVisible()
    await expect(column.locator('article')).toHaveCount(100)
    const first = await column.locator('article').first().innerText()
    await column.getByRole('button', { name: '下一页', exact: true }).click()
    await expect(column.locator('article').first()).not.toHaveText(first)
    await createView('画册')
    await expect(owner.locator('article')).toHaveCount(100)
    await owner.getByRole('button', { name: '新增记录', exact: true }).click()
    const recordDialog = owner.getByRole('dialog', { name: '新增记录', exact: true })
    await recordDialog.getByRole('textbox', { name: 'Name', exact: true }).fill('Customer request')
    await recordDialog.getByRole('spinbutton', { name: 'Revenue', exact: true }).fill('12')
    await recordDialog.getByRole('button', { name: '提交记录', exact: true }).click()
    await expect(recordDialog).toHaveCount(0)
    await owner.getByRole('button', { name: '分组统计', exact: true }).click()
    await choose(owner, '统计方式', '求和')
    await choose(owner, '统计字段', 'Revenue')
    await expect(owner.getByRole('cell', { name: '12507513', exact: true })).toBeVisible()
    await owner.getByRole('button', { name: 'Grid', exact: true }).click()
    await expect(owner.getByRole('button', { name: '下一页', exact: true })).toBeVisible()
    await owner.goto(state.base_url + route(state.report_id))
    const inline = content(owner)
      .locator('.embed')
      .filter({ has: owner.getByRole('button', { name: title, exact: true }) })
    await inline.getByRole('button', { name: '筛选与排序', exact: true }).click()
    await owner.getByRole('button', { name: '添加筛选条件', exact: true }).click()
    await choose(owner, '筛选字段', 'Status')
    await owner.getByRole('dialog').getByRole('combobox', { name: 'Status', exact: true }).click()
    await owner.getByRole('option', { name: 'New', exact: true }).click()
    await owner.getByRole('button', { name: '应用', exact: true }).click()
    await expect
      .poll(
        async () =>
          (await request<{ content: { content: string } }>(owner, `/pages/${state.report_id}`)).content.content
      )
      .toContain(status)
    expect(
      (
        await request<{ views: { type: string; config: { filter?: unknown } }[] }>(owner, `/tables/${table.id}`)
      ).views.find(view => view.type === 'grid')?.config.filter
    ).toBeUndefined()
  } finally {
    await context.close()
  }
})

test('block-menu removal follows direct-child ownership and preserves references to other pages', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const owner = await context.newPage()
  try {
    await owner.goto(state.base_url + route(state.report_id))
    const { page } = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      title: 'Embed lifecycle',
      parent_id: state.report_id
    })
    await owner.goto(state.base_url + route(page.id))
    await expect(content(owner)).toBeVisible()
    await documentAction(owner, '新建页面')
    const created = owner.waitForResponse(
      response => response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/pages'
    )
    await owner.getByRole('menuitem', { name: '多维表', exact: true }).click()
    const response = await created
    expect(response.status()).toBe(201)
    const child = ((await response.json()) as { page: { id: string; type: string; parent_id: string } }).page
    expect(child).toMatchObject({ type: 'base', parent_id: page.id })
    const embedded = content(owner).locator('.embed')
    await expect(embedded).toContainText('无标题')
    await embedded.hover()
    await owner.getByRole('button', { name: 'Block 菜单', exact: true }).click()
    await owner.getByRole('menuitem', { name: '删除 Block', exact: true }).click()
    await expect(embedded).toHaveCount(0)
    await expect
      .poll(async () =>
        (await request<{ pages: { id: string }[] }>(owner, '/pages?scope=trash')).pages.some(
          item => item.id === child.id
        )
      )
      .toBe(true)
    await documentAction(owner, '嵌入多维表或应用')
    await choose(owner, '选择页面', 'Browser sales')
    await expect(embedded).toContainText('Browser sales')
    const sourcePage = owner.locator(`.pod-tree-link[href="${route(state.base_id)}"]`)
    await expect(sourcePage).toBeVisible()
    await embedded.hover()
    await owner.getByRole('button', { name: 'Block 菜单', exact: true }).click()
    await owner.getByRole('menuitem', { name: '删除 Block', exact: true }).click()
    await expect(embedded).toHaveCount(0)
    expect((await request<{ page: { id: string } }>(owner, `/pages/${state.base_id}`)).page.id).toBe(state.base_id)
    await expect(sourcePage).toBeVisible()
  } finally {
    await context.close()
  }
})

test('one block-menu request deletes a batch atomically and a forbidden child leaves every page intact', async ({
  browser
}) => {
  const ownerContext = await browser.newContext()
  const memberContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const owner = await ownerContext.newPage()
  const member = await memberContext.newPage()
  let parentID: string | undefined
  try {
    await owner.goto(state.base_url + route(state.report_id))
    await member.goto(state.base_url + route(state.report_id))
    const { page: parent } = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      title: 'Atomic embed batch'
    })
    parentID = parent.id
    const share = (role: string) =>
      request(owner, `/pages/${parent.id}/sharing`, 'PUT', {
        inherit_permissions: false,
        grants: [{ principal_uid: state.member.uid, role }]
      })
    await share('edit')
    const { page: first } = await request<{ page: { id: string } }>(member, '/pages', 'POST', {
      parent_id: parent.id,
      title: 'Own child'
    })
    const { page: second } = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      parent_id: parent.id,
      title: 'Other child'
    })
    await request(owner, `/pages/${parent.id}/content`, 'PUT', {
      base_revision: 0,
      xml: `<page><p>Batch selection</p><embed ref="${first.id}"/><embed ref="${second.id}"/></page>`
    })
    const endpoint = `/api/v2/pod/pages/${parent.id}/embeds/delete`
    const requests: unknown[] = []
    member.on('request', request => {
      if (request.method() === 'POST' && new URL(request.url()).pathname === endpoint) {
        requests.push(request.postDataJSON())
      }
    })
    const remove = async () => {
      await member.goto(state.base_url + route(parent.id))
      await expect(content(member).locator('.embed')).toHaveCount(2)
      await content(member).locator('p').first().click()
      await member.keyboard.press('Escape')
      await member.keyboard.press('ControlOrMeta+a')
      await member.keyboard.press('ControlOrMeta+/')
      const response = member.waitForResponse(response => new URL(response.url()).pathname === endpoint)
      await member.getByRole('menuitem', { name: '删除 Block', exact: true }).click()
      return response
    }
    expect((await remove()).status()).toBe(403)
    expect(requests).toEqual([{ data: { refs: [first.id, second.id] } }])
    await expect(content(member).locator('.embed')).toHaveCount(2)
    for (const id of [first.id, second.id]) {
      expect((await request<{ page: { deleted_at: string | null } }>(owner, `/pages/${id}`)).page.deleted_at).toBeNull()
    }
    await share('manage')
    expect((await remove()).status()).toBe(201)
    expect(requests).toHaveLength(2)
    await expect(content(member).locator('.embed')).toHaveCount(0)
    for (const id of [first.id, second.id]) {
      expect(
        (await request<{ page: { deleted_at: string | null } }>(owner, `/pages/${id}`)).page.deleted_at
      ).not.toBeNull()
    }
  } finally {
    if (parentID) await request(owner, `/pages/${parentID}`, 'DELETE')
    await ownerContext.close()
    await memberContext.close()
  }
})

test('chat findings and attachments become durable pages after the native source conversation is deleted', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const owner = await context.newPage()
  try {
    await owner.goto(`${state.base_url}${conversationRoute(state.conversation_id)}`)
    const conversation = await request<{ conversation: { title: string }; messages: { id: string }[] }>(
      owner,
      `/conversations/${state.conversation_id}`
    )
    expect(conversation.messages.some(message => message.id === state.message_id)).toBe(true)
    const message = owner.locator(`[data-chat-message-id="${state.message_id}"]`)
    await expect(message.getByRole('link', { name: 'Open the report', exact: true })).toHaveAttribute(
      'href',
      route(state.report_id)
    )
    await message.hover()
    await message.getByRole('button', { name: '保存为页面', exact: true }).click()
    await owner.getByRole('textbox', { name: '页面标题', exact: true }).fill('Saved chat findings')
    await owner.getByRole('button', { name: '保存', exact: true }).click()
    await message.getByRole('link', { name: 'Saved chat findings', exact: true }).click()
    await expect(content(owner)).toContainText('Browser chat findings.')
    const notesID = pageIDFromURL(owner.url())
    await owner.getByRole('link', { name: /^来源对话：/ }).click()
    await owner.getByRole('button', { name: visibleName(`保存文件：${state.chat_attachment_name}`) }).click()
    await owner.getByRole('textbox', { name: '页面标题', exact: true }).fill('Saved source evidence')
    await owner.getByRole('button', { name: '保存', exact: true }).click()
    await message.getByRole('link', { name: 'Saved source evidence', exact: true }).first().click()
    const downloadEvent = owner.waitForEvent('download')
    await owner.getByRole('link', { name: '下载原文件', exact: true }).click()
    const download = await downloadEvent
    expect(readFileSync((await download.path())!, 'utf8')).toBe('Original browser research evidence.')
    const fileID = pageIDFromURL(owner.url())
    await owner.getByRole('link', { name: /^来源对话：/ }).click()
    await owner.locator('.pod-room-header').getByRole('button', { name: '更多操作', exact: true }).click()
    await owner.getByRole('menuitem', { name: '删除会话', exact: true }).click()
    const [deleted] = await Promise.all([
      owner.waitForResponse(
        response =>
          new URL(response.url()).pathname === `/api/v2/pod/conversations/${state.conversation_id}` &&
          response.request().method() === 'DELETE'
      ),
      owner.getByRole('dialog').getByRole('button', { name: '删除会话', exact: true }).click()
    ])
    expect(deleted.status()).toBe(200)
    await expect
      .poll(
        async () =>
          (await request<{ source_conversation: { deleted: boolean } | null }>(owner, `/pages/${notesID}`))
            .source_conversation?.deleted
      )
      .toBe(true)
    expect((await request<{ page: { id: string } }>(owner, `/pages/${fileID}`)).page.id).toBe(fileID)
    await owner.goto(state.base_url + route(fileID))
    await expect(owner.getByText('来源对话已删除', { exact: true })).toBeVisible()
    const retainedDownloadEvent = owner.waitForEvent('download')
    await owner.getByRole('link', { name: '下载原文件', exact: true }).click()
    const retainedDownload = await retainedDownloadEvent
    expect(readFileSync((await retainedDownload.path())!, 'utf8')).toBe('Original browser research evidence.')
    await owner.goto(state.base_url + route(notesID))
    await expect(content(owner)).toContainText('Browser chat findings.')
    await expect(owner.getByText('来源对话已删除', { exact: true })).toBeVisible()
    await owner.getByRole('tab', { name: '主页', exact: true }).click()
    await expect(
      owner.getByRole('region', { name: '私人页面', exact: true }).getByRole('link', { name: 'Saved chat findings' })
    ).toBeVisible()
  } finally {
    await context.close()
  }
})
