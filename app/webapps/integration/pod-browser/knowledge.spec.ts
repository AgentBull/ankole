import { expect, test, type Page } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { stringify } from 'yaml'
import { request, requestWithSharingVersion, state } from './fixtures'
import { pageRoute } from './routes'

type Knowledge = {
  page: { id: string; revision: number; metadata: Record<string, unknown> }
  content: { content: string }
}
const knowledge = (page: Page) => page.locator('[data-knowledge-page]')
const editor = (page: Page) => knowledge(page).locator('.editor-content[contenteditable]').last()
const reader = (page: Page) => knowledge(page).locator('[data-knowledge-reader]')
const read = (page: Page, id: string) => request<Knowledge>(page, `/pages/${id}`)

async function brainCategory(page: Page) {
  const graph = await request<{ categories: { id: string; name: string }[] }>(page, '/meta/brain')
  const category = graph.categories.find(category => category.name === 'notes')
  if (!category) throw new Error('The fixture must install the notes ontology category')
  return category.id
}

async function create(page: Page, metadata: Record<string, unknown>, parent_id?: string) {
  return request<Knowledge>(page, '/pages', 'POST', {
    type: 'knowledge',
    title: 'Knowledge browser test',
    parent_id: parent_id ?? (await brainCategory(page)),
    xml: '<page><p>Original body</p></page>',
    metadata
  })
}

async function save(page: Page, id: string) {
  const response = page.waitForResponse(
    response =>
      response.request().method() === 'PUT' && new URL(response.url()).pathname.endsWith(`/pages/${id}/content`)
  )
  await knowledge(page).getByRole('button', { name: '保存', exact: true }).click()
  return response
}

test('knowledge reading has no editor canvas and preserves rich content across editing', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto(state.base_url + pageRoute(state.report_id))
    const created = await request<Knowledge>(page, '/pages', 'POST', {
      type: 'knowledge',
      title: 'Reader acceptance',
      parent_id: await brainCategory(page),
      xml: '<page/>',
      metadata: { summary: 'Read first' }
    })
    id = created.page.id
    await page.goto(state.base_url + pageRoute(id))
    await expect(knowledge(page).getByRole('button', { name: '编辑', exact: true })).toBeVisible()
    await expect(knowledge(page).locator('.editor-view')).toHaveCount(0)
    await expect(reader(page)).toHaveCount(0)
    await create(page, {}, id)
    await page.reload()
    await expect(knowledge(page)).toContainText('Knowledge browser test')
    await expect(knowledge(page).locator('.editor-view')).toHaveCount(0)

    const uploaded = await page.evaluate(async pageID => {
      const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content ?? ''
      const body = new FormData()
      body.set('role', 'asset')
      body.set(
        'file',
        new File(
          [
            '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" fill="blue"/></svg>'
          ],
          'reader.svg',
          { type: 'image/svg+xml' }
        )
      )
      const response = await fetch(`/api/v2/pod/pages/${pageID}/files`, {
        method: 'POST',
        body,
        credentials: 'same-origin',
        headers: {
          'x-csrf-token': meta('csrf-token'),
          'x-ankole-authentication': meta('ankole-authentication'),
          'x-ankole-pod': meta('ankole-pod')
        }
      })
      if (!response.ok) throw new Error(`Image upload failed: ${response.status}`)
      return response.json() as Promise<{ src: string }>
    }, id)
    const current = await read(page, id)
    await request(page, `/pages/${id}/content`, 'PUT', {
      base_revision: current.page.revision,
      metadata: current.page.metadata,
      xml:
        `<page><p>Short body with <mention page="${state.report_id}"/>.</p>` +
        `<media src="${uploaded.src}" title="Reader image" kind="image"/>` +
        `<callout tone="warning" icon="!"><p>Keep the source.</p></callout>` +
        `<pre lang="js">const value = 32;</pre>` +
        `<table><tr><th><p>Price</p></th></tr><tr><td><p>32</p></td></tr></table></page>`
    })
    await page.reload()
    await expect(reader(page)).toContainText('Short body')
    await expect(reader(page).locator('.editor-mention a')).toHaveCount(1)
    await expect(reader(page).locator('.editor-mention a')).toContainText(/./)
    const image = reader(page).getByRole('img', { name: 'Reader image' })
    await expect(image).toBeVisible()
    await expect.poll(() => image.evaluate(img => (img as HTMLImageElement).naturalWidth)).toBe(40)
    await expect(reader(page).getByRole('columnheader', { name: 'Price' })).toBeVisible()
    await expect(reader(page)).toContainText('const value = 32;')
    await expect(reader(page).locator('.callout[data-tone="warning"]')).toContainText('Keep the source.')
    await expect(knowledge(page).locator('.editor-view')).toHaveCount(0)
    await page.screenshot({ path: test.info().outputPath('knowledge-reader.png') })

    await knowledge(page).getByRole('button', { name: '编辑', exact: true }).click()
    await expect(editor(page)).toHaveAttribute('contenteditable', 'true')
    await expect(reader(page)).toHaveCount(0)
    await editor(page).fill('Discard this edit')
    await knowledge(page).getByRole('button', { name: '取消', exact: true }).click()
    await expect(knowledge(page).getByRole('button', { name: '编辑', exact: true })).toBeFocused()
    await expect(reader(page)).toContainText('Short body')
    await expect(reader(page)).not.toContainText('Discard this edit')
    await expect(knowledge(page).locator('.editor-view')).toHaveCount(0)
    await knowledge(page).getByRole('button', { name: '编辑', exact: true }).click()
    await editor(page).fill('Saved in reader')
    expect((await save(page, id)).ok()).toBe(true)
    await expect(knowledge(page).getByRole('button', { name: '编辑', exact: true })).toBeFocused()
    await expect(reader(page)).toHaveText('Saved in reader')
    await expect(knowledge(page).locator('.editor-view')).toHaveCount(0)
    expect(await reader(page).evaluate(node => node.getBoundingClientRect().height)).toBeLessThan(100)
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('knowledge saves body and nested YAML together, retains each version, and restores metadata', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto(state.base_url + pageRoute(state.report_id))
    const created = await create(page, { colors: { primary: '#123456' }, tags: ['brand'] })
    id = created.page.id
    const firstMetadata = { ...created.page.metadata, colors: { primary: '#abcdef' }, tags: ['brand', 'shared'] }
    await page.goto(state.base_url + pageRoute(id))
    await expect(reader(page)).toContainText('Original body')
    await expect(knowledge(page).locator('.editor-view')).toHaveCount(0)
    expect(await request(page, `/pages/${id}/knowledge`)).toMatchObject({
      panel: { backlinks: [], claims: [], timelines: [], scorecard: { takes: 0, brier: null } }
    })
    await knowledge(page).getByRole('button', { name: '编辑', exact: true }).click()
    await editor(page).fill('Saved body')
    await knowledge(page).getByRole('button', { name: 'YAML', exact: true }).click()
    const yaml = page.getByRole('dialog', { name: '属性 · YAML' })
    await yaml.getByRole('textbox').fill(stringify(firstMetadata))
    await yaml.getByRole('button', { name: '应用到草稿' }).click()
    expect((await read(page, id)).page.metadata).toEqual(created.page.metadata)
    expect((await save(page, id)).ok()).toBe(true)
    await expect(knowledge(page).getByRole('button', { name: '编辑', exact: true })).toBeVisible()
    expect(await read(page, id)).toMatchObject({
      page: { revision: 1, metadata: { colors: { primary: '#abcdef' }, tags: ['brand', 'shared'] } },
      content: { content: '<page><p>Saved body</p></page>' }
    })
    await knowledge(page).getByRole('button', { name: '编辑', exact: true }).click()
    await knowledge(page)
      .getByRole('textbox', { name: /colors.*的值/ })
      .fill("primary: '#ffffff'")
    expect((await save(page, id)).ok()).toBe(true)
    await expect(knowledge(page).getByRole('button', { name: '编辑', exact: true })).toBeVisible()
    const versions = await request<{ snapshots: { id: string; metadata: Record<string, unknown> }[] }>(
      page,
      `/pages/${id}/history`
    )
    expect(versions.snapshots).toHaveLength(3)
    await knowledge(page).getByRole('button', { name: '版本历史', exact: true }).click()
    await page.locator('.pod-document-history-list').getByRole('button').nth(2).click()
    await expect(page.locator('.pod-document-history-preview')).toContainText('#abcdef')
    const download = page.waitForEvent('download')
    await page.getByRole('button', { name: '导出此版本', exact: true }).click()
    const markdown = await readFile((await (await download).path())!, 'utf8')
    expect(markdown).toContain('#abcdef')
    expect(markdown).toContain('Saved body')
    expect(markdown).not.toContain('#ffffff')
    await page.getByRole('button', { name: '恢复此版本', exact: true }).click()
    await page
      .getByRole('dialog', { name: '恢复此版本', exact: true })
      .getByRole('button', { name: '恢复此版本', exact: true })
      .click()
    await expect.poll(async () => (await read(page, id!)).page.metadata).toEqual(firstMetadata)
    await page.reload()
    await expect(knowledge(page)).toContainText('#abcdef')
    await expect(knowledge(page).locator('.editor-view')).toHaveCount(0)
    await page.screenshot({ path: test.info().outputPath('knowledge-page.png') })
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('a conflicting knowledge save preserves the draft and allows comparison before retry', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto(state.base_url + pageRoute(state.report_id))
    id = (await create(page, { summary: 'original' })).page.id
    await page.goto(state.base_url + pageRoute(id))
    await knowledge(page).getByRole('button', { name: '编辑', exact: true }).click()
    await editor(page).fill('My draft')
    await request(page, `/pages/${id}/content`, 'PUT', {
      base_revision: 0,
      xml: '<page><p>Colleague update</p></page>',
      metadata: { summary: 'colleague' }
    })
    expect((await save(page, id)).status()).toBe(409)
    await expect(editor(page)).toContainText('My draft')
    await knowledge(page).getByRole('button', { name: '加载最新版本用于对比' }).click()
    await expect(knowledge(page).locator('details')).toContainText('Colleague update')
    await expect(editor(page)).toContainText('My draft')
    expect((await save(page, id)).ok()).toBe(true)
    expect(await read(page, id)).toMatchObject({
      page: { revision: 2, metadata: { summary: 'original' } },
      content: { content: '<page><p>My draft</p></page>' }
    })
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('folder table filters and sorts knowledge business properties', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let folderID: string | undefined
  try {
    await page.goto(state.base_url + pageRoute(state.report_id))
    folderID = (await create(page, { summary: 'Knowledge table' })).page.id
    await create(page, { priority: 10, team: 'sales' }, folderID)
    await create(page, { priority: 2, team: 'engineering' }, folderID)
    await page.goto(state.base_url + pageRoute(folderID))
    await page.getByRole('button', { name: '切换视图', exact: true }).click()
    await page.getByRole('menuitemradio', { name: '属性表格', exact: true }).click()
    const table = page.getByRole('table', { name: '属性表格', exact: true })
    await expect(table.locator('tbody tr')).toHaveCount(2)
    await table.getByRole('button', { name: 'priority', exact: true }).click()
    await expect(table.locator('tbody tr').first()).toContainText('engineering')
    await page.getByRole('combobox', { name: '按属性筛选' }).click()
    await page.getByRole('option', { name: 'team', exact: true }).click()
    await page.getByRole('textbox', { name: '筛选属性值' }).fill('sales')
    await expect(table.locator('tbody tr')).toHaveCount(1)
    await expect(table.locator('tbody')).toContainText('sales')
    await page.reload()
    await expect(table).toBeVisible()
    await page.screenshot({ path: test.info().outputPath('knowledge-table.png') })
  } finally {
    if (folderID) await request(page, `/pages/${folderID}`, 'DELETE')
    await context.close()
  }
})

test('knowledge supports whole-page discussions without inline anchors', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto(state.base_url + pageRoute(state.report_id))
    id = (await create(page, { summary: 'Discussion source' })).page.id
    await page.goto(state.base_url + pageRoute(id))
    await page.locator('.pod-page-header').getByRole('button', { name: '评论', exact: true }).click()
    const comments = page.getByRole('complementary', { name: '评论', exact: true })
    await comments.getByRole('textbox', { name: '添加评论…', exact: true }).fill('Please update the shared definition.')
    await comments.getByRole('button', { name: '发送', exact: true }).click()
    await expect(comments.locator('.pod-comment-thread')).toContainText('Please update the shared definition.')
    const threads = await request<{ threads: { can_reanchor: boolean; anchor_present: boolean }[] }>(
      page,
      `/pages/${id}/comments`
    )
    expect(threads.threads[0]).toMatchObject({ can_reanchor: false, anchor_present: false })
    expect(await read(page, id)).toMatchObject({
      page: { revision: 0, metadata: { summary: 'Discussion source' } },
      content: { content: '<page><p>Original body</p></page>' }
    })
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('starting and cancelling a knowledge edit preserve a title that is still autosaving', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto(state.base_url + pageRoute(state.report_id))
    id = (await create(page, {})).page.id
    await page.goto(state.base_url + pageRoute(id))
    const title = page.getByRole('textbox', { name: '页面标题', exact: true })
    await title.fill('团队报价复盘')
    await knowledge(page).getByRole('button', { name: '编辑', exact: true }).click()
    await expect(title).toHaveValue('团队报价复盘')
    await editor(page).fill('每次报价必须注明汇率日期。')
    expect((await save(page, id)).ok()).toBe(true)
    await expect.poll(async () => (await read(page, id!)).page).toMatchObject({ title: '团队报价复盘' })

    await knowledge(page).getByRole('button', { name: '编辑', exact: true }).click()
    await editor(page).fill('Discard this body draft')
    await title.fill('北美客户报价复盘')
    await knowledge(page).getByRole('button', { name: '取消', exact: true }).click()
    await expect(title).toHaveValue('北美客户报价复盘')
    await expect.poll(async () => (await read(page, id!)).page).toMatchObject({ title: '北美客户报价复盘' })
    await page.reload()
    await expect(title).toHaveValue('北美客户报价复盘')
    await expect(reader(page)).toContainText('每次报价必须注明汇率日期。')
    await expect(reader(page)).not.toContainText('Discard this body draft')
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('a manager can enable learning for existing folder content and see its inherited state', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto(state.base_url + pageRoute(state.report_id))
    id = (await request<Knowledge>(page, '/pages', 'POST', { type: 'doc', title: '采购资料' })).page.id
    const child = await request<Knowledge>(page, '/pages', 'POST', { type: 'doc', parent_id: id, title: '供应商' })
    await request(page, '/pages', 'POST', {
      type: 'doc',
      parent_id: child.page.id,
      title: '供应商复盘',
      xml: '<page><p>Supplier review</p></page>'
    })
    // Page managers find the learning toggle in the page header's more-actions menu.
    const learning = page.getByRole('menuitemcheckbox', { name: /^学习业务事实/ })
    const openMenu = async () => {
      await page.locator('.pod-page-header').getByRole('button', { name: '更多操作', exact: true }).click()
      await expect(learning).toBeVisible()
    }
    await page.goto(state.base_url + pageRoute(id))
    await expect(page.getByText('学习业务事实')).toHaveCount(0)
    await openMenu()
    await expect(learning).not.toBeChecked()
    await learning.focus()
    await page.keyboard.press('Space')
    await expect(learning).toBeChecked()
    await page.reload()
    await openMenu()
    await expect(learning).toBeChecked()
    expect((await read(page, id)).page.metadata.extract_facts).toBe(true)

    await page.goto(state.base_url + pageRoute(child.page.id))
    await openMenu()
    await expect(learning).toBeChecked()
    await expect(learning).toBeDisabled()
    await expect(learning).toContainText('上级页面已开启学习，设置适用于此页面。')

    await page.goto(state.base_url + pageRoute(id))
    await openMenu()
    await learning.click()
    await expect(learning).not.toBeChecked()
    await page.goto(state.base_url + pageRoute(child.page.id))
    await openMenu()
    await expect(learning).not.toBeChecked()
    await expect(learning).toBeEnabled()
    await page.screenshot({ path: test.info().outputPath('folder-learning.png') })
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('a colleague can correct shared knowledge without seeing the restricted purchasing subpage', async ({
  browser
}) => {
  const ownerContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  const owner = await ownerContext.newPage()
  const colleagueContext = await browser.newContext()
  await colleagueContext.addCookies(state.member.cookies)
  const colleague = await colleagueContext.newPage()
  let id: string | undefined
  try {
    await owner.goto(state.base_url + pageRoute(state.report_id))
    id = (await create(owner, { summary: '供应商资料' })).page.id
    await requestWithSharingVersion(owner, `/pages/${id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'edit' }
      ]
    })
    const secret = await create(owner, { summary: '采购阶梯底价' }, id)
    await request(owner, `/pages/${secret.page.id}`, 'PATCH', {
      title: '采购阶梯底价',
      expected_title: 'Knowledge browser test'
    })
    await requestWithSharingVersion(owner, `/pages/${secret.page.id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [{ principal_uid: state.owner.uid, role: 'manage' }]
    })

    await colleague.goto(state.base_url + pageRoute(id))
    await knowledge(colleague).getByRole('button', { name: '编辑', exact: true }).click()
    await editor(colleague).fill('经复核，工厂共有四条生产线。')
    expect((await save(colleague, id)).ok()).toBe(true)
    await expect(colleague.getByText('采购阶梯底价', { exact: true })).toHaveCount(0)
    expect(await request(colleague, `/pages/children?parent_id=${id}`)).toMatchObject({ pages: [] })

    await owner.goto(state.base_url + pageRoute(id))
    await expect(reader(owner)).toContainText('经复核，工厂共有四条生产线。')
    await expect(knowledge(owner).locator('.editor-view')).toHaveCount(0)
    await expect(owner.getByText('采购阶梯底价', { exact: true }).first()).toBeVisible()
    await colleague.screenshot({ path: test.info().outputPath('colleague-knowledge.png') })
  } finally {
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await colleagueContext.close()
    await ownerContext.close()
  }
})

test('knowledge recovers unsaved XML and invalid properties together after reload', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    await page.goto(state.base_url + pageRoute(state.report_id))
    id = (await create(page, { summary: 'Original metadata' })).page.id
    await page.goto(state.base_url + pageRoute(id))
    await knowledge(page).getByRole('button', { name: '编辑', exact: true }).click()
    await editor(page).fill('Recovered body')
    await knowledge(page)
      .getByRole('textbox', { name: /summary.*的值/ })
      .fill('[')
    await expect(knowledge(page).getByRole('button', { name: '保存', exact: true })).toBeDisabled()
    page.once('dialog', dialog => dialog.accept())
    await page.reload()
    await expect(editor(page)).toContainText('Recovered body')
    await expect(knowledge(page).getByRole('textbox', { name: /summary.*的值/ })).toHaveValue('[')
    await expect(knowledge(page).getByRole('button', { name: '保存', exact: true })).toBeDisabled()
    expect(await read(page, id)).toMatchObject({
      page: { revision: 0, metadata: { summary: 'Original metadata' } },
      content: { content: '<page><p>Original body</p></page>' }
    })
    await knowledge(page)
      .getByRole('textbox', { name: /summary.*的值/ })
      .fill('Recovered metadata')
    expect((await save(page, id)).ok()).toBe(true)
    await expect(knowledge(page).getByRole('button', { name: '编辑', exact: true })).toBeVisible()
    expect(await read(page, id)).toMatchObject({
      page: { metadata: { summary: 'Recovered metadata' } },
      content: { content: '<page><p>Recovered body</p></page>' }
    })
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('open metadata references resolve Page titles while preserving additional business fields', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const created: string[] = []
  try {
    await page.goto(state.base_url + pageRoute(state.report_id))
    const target = await create(page, {})
    created.push(target.page.id)
    await request(page, `/pages/${target.page.id}`, 'PATCH', {
      title: 'Referenced business object',
      expected_title: 'Knowledge browser test'
    })
    const metadata = {
      new_business_role: { page_id: target.page.id, confidence: 0.75, details: { flags: [true, null, 9] } },
      literal: '2026-11-03'
    }
    const source = await create(page, metadata)
    expect(source.page.metadata).toMatchObject(metadata)
    created.push(source.page.id)
    await page.goto(state.base_url + pageRoute(source.page.id))
    const link = knowledge(page).locator('a.pod-mention-page').filter({ hasText: 'Referenced business object' })
    await expect(link).toBeVisible()
    await expect(knowledge(page)).toContainText('confidence: 0.75')
    await knowledge(page).getByRole('button', { name: '编辑', exact: true }).click()
    await editor(page).fill('Business body')
    expect((await save(page, source.page.id)).ok()).toBe(true)
    expect((await read(page, source.page.id)).page.metadata).toEqual(source.page.metadata)
    await expect(link).toBeVisible()
    await link.click()
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue('Referenced business object')
  } finally {
    for (const id of created.reverse()) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})
