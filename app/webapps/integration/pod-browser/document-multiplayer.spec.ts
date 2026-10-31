import { readFile } from 'node:fs/promises'
import { expect, test, type BrowserContext, type Page } from '@playwright/test'
import { closeRealtimeSocket, request, requestWithSharingVersion, state } from './fixtures'
import { pageRoute } from './routes'

test.use({ actionTimeout: 15_000 })

const editor = (page: Page) => page.locator('.pod-document .editor-content')
const title = (page: Page) => page.getByRole('textbox', { name: '页面标题', exact: true })

/** Hold only outgoing document batches, while forwarding the real Phoenix connection. */
async function documentGate(context: BrowserContext) {
  let held = false
  const queued: (() => void)[] = []
  await context.routeWebSocket('**/pod/socket/websocket**', socket => {
    const server = socket.connectToServer()
    socket.onMessage(message => {
      const event = typeof message === 'string' ? JSON.parse(message)[3] : undefined
      if (held && event === 'changes') queued.push(() => server.send(message))
      else server.send(message)
    })
    server.onMessage(message => socket.send(message))
  })
  return {
    hold() {
      held = true
    },
    count: () => queued.length,
    release() {
      held = false
      for (const send of queued.splice(0)) send()
    }
  }
}

async function create(page: Page, name: string, xml = '<page><p>Alpha</p><p>Beta</p></page>') {
  await page.goto(state.base_url + pageRoute(state.report_id))
  const { page: doc } = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
    type: 'doc',
    title: name,
    xml
  })
  await requestWithSharingVersion(page, `/pages/${doc.id}/sharing`, 'PUT', {
    inherit_permissions: false,
    grants: [
      { principal_uid: state.owner.uid, role: 'manage' },
      { principal_uid: state.member.uid, role: 'edit' },
      ...(state.document_agent_uid ? [{ principal_uid: state.document_agent_uid, role: 'edit' }] : [])
    ]
  })
  await page.goto(state.base_url + pageRoute(doc.id))
  await expect(editor(page)).toBeVisible()
  return doc.id
}

async function stored(page: Page, id: string) {
  return request<{
    page: { revision: number }
    content: { content: string; plain_text: string }
  }>(page, `/pages/${id}`)
}

async function lastEditor(page: Page, id: string) {
  const insights = await request<{ contributors: { principal_uid: string; kind: string; role: string }[] }>(
    page,
    `/pages/${id}/insights`
  )
  return insights.contributors.find(person => person.role === 'last_edited')
}

async function bullet(page: Page, text: string) {
  await editor(page).getByText(text, { exact: true }).hover()
  await page.getByRole('button', { name: '当前 Block 菜单', exact: true }).click()
  await page.getByRole('menuitem', { name: '转换为', exact: true }).hover()
  await page
    .getByRole('menu', { name: '转换 Block 类型', exact: true })
    .getByRole('menuitem', { name: '项目列表', exact: true })
    .click()
}

test('two real editors merge simultaneous list conversions, keep typing, and undo only their own work', async ({
  browser
}, info) => {
  const ownerContext = await browser.newContext(),
    memberContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const ownerGate = await documentGate(ownerContext),
    memberGate = await documentGate(memberContext)
  const owner = await ownerContext.newPage(),
    member = await memberContext.newPage()
  const errors: string[] = []
  for (const page of [owner, member]) page.on('pageerror', error => errors.push(error.message))
  let id: string | undefined
  try {
    id = await create(owner, 'Simultaneous lists')
    await member.goto(state.base_url + pageRoute(id))
    await expect(editor(member).locator('p')).toHaveText(['Alpha', 'Beta'])
    ownerGate.hold()
    memberGate.hold()
    await bullet(owner, 'Alpha')
    await bullet(member, 'Beta')
    await expect.poll(ownerGate.count).toBeGreaterThan(0)
    await expect.poll(memberGate.count).toBeGreaterThan(0)
    ownerGate.release()
    memberGate.release()
    for (const page of [owner, member]) {
      await expect(editor(page).locator(':scope > ul')).toHaveCount(1)
      await expect(editor(page).locator('li')).toHaveText(['Alpha', 'Beta'])
    }
    await expect
      .poll(async () => (await stored(owner, id!)).content.content)
      .toBe('<page><ul><li><p>Alpha</p></li><li><p>Beta</p></li></ul></page>')
    ownerGate.hold()
    memberGate.hold()
    await editor(owner).locator('li').first().click()
    await owner.keyboard.press('End')
    await owner.keyboard.type(' OWNER')
    await editor(member).locator('li').last().click()
    await member.keyboard.press('End')
    await member.keyboard.type(' MEMBER')
    await expect.poll(ownerGate.count).toBeGreaterThan(0)
    await expect.poll(memberGate.count).toBeGreaterThan(0)
    ownerGate.release()
    memberGate.release()
    await expect.poll(async () => (await stored(owner, id!)).content.plain_text).toBe('Alpha OWNER\nBeta MEMBER')
    for (const page of [owner, member]) await expect(editor(page)).toHaveText('Alpha OWNERBeta MEMBER')
    await owner.keyboard.press('ControlOrMeta+z')
    await expect.poll(async () => (await stored(owner, id!)).content.plain_text).toBe('Alpha\nBeta MEMBER')
    await expect(editor(member)).toHaveText('AlphaBeta MEMBER')
    await owner.screenshot({ path: info.outputPath('two-editors-converged.png') })
    await member.reload()
    await expect(editor(member)).toHaveText('AlphaBeta MEMBER')
    expect(errors).toEqual([])
  } finally {
    ownerGate.release()
    memberGate.release()
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await ownerContext.close()
    await memberContext.close()
  }
})

test('table row and column commands preserve simultaneous peer cell edits', async ({ browser }, info) => {
  const a = await browser.newContext(),
    b = await browser.newContext()
  await a.addCookies(state.owner.cookies)
  await b.addCookies(state.member.cookies)
  const ownerGate = await documentGate(a),
    memberGate = await documentGate(b)
  const owner = await a.newPage(),
    member = await b.newPage()
  const errors: string[] = []
  for (const page of [owner, member]) page.on('pageerror', error => errors.push(error.message))
  let id: string | undefined
  try {
    id = await create(
      owner,
      'Concurrent table structure',
      '<page><table><tr><td><p>A</p></td><td><p>B</p></td></tr><tr><td><p>C</p></td><td><p>D</p></td></tr></table></page>'
    )
    await member.goto(state.base_url + pageRoute(id))
    await expect(editor(member).locator('td')).toHaveText(['A', 'B', 'C', 'D'])
    ownerGate.hold()
    memberGate.hold()
    await editor(owner).locator('td').first().click()
    await owner.getByRole('button', { name: '行', exact: true }).click()
    await owner.getByRole('menuitem', { name: '在下方插入行', exact: true }).click()
    await editor(member).locator('td').nth(2).click()
    await member.keyboard.press('End')
    await member.keyboard.type(' PEER')
    await expect.poll(ownerGate.count).toBeGreaterThan(0)
    await expect.poll(memberGate.count).toBeGreaterThan(0)
    ownerGate.release()
    memberGate.release()
    for (const page of [owner, member]) {
      await expect(editor(page).locator('tr')).toHaveCount(3)
      await expect(editor(page).locator('td')).toHaveText(['A', 'B', '', '', 'C PEER', 'D'])
    }
    ownerGate.hold()
    memberGate.hold()
    await editor(owner).locator('td').first().click()
    await owner.getByRole('button', { name: '列', exact: true }).click()
    await owner.getByRole('menuitem', { name: '在右侧插入列', exact: true }).click()
    await editor(member).locator('td').nth(4).click()
    await member.keyboard.press('End')
    await member.keyboard.type(' AGAIN')
    await expect.poll(ownerGate.count).toBeGreaterThan(0)
    await expect.poll(memberGate.count).toBeGreaterThan(0)
    ownerGate.release()
    memberGate.release()
    for (const page of [owner, member]) {
      await expect(editor(page).locator('tr')).toHaveCount(3)
      await expect(editor(page).locator('td')).toHaveText(['A', '', 'B', '', '', '', 'C PEER AGAIN', '', 'D'])
    }
    await expect.poll(async () => (await stored(owner, id!)).content.content).toContain('<p>C PEER AGAIN</p>')
    await owner.reload()
    await expect(editor(owner).locator('td')).toHaveText(['A', '', 'B', '', '', '', 'C PEER AGAIN', '', 'D'])
    await expect(owner.locator('[data-sync-status=saved]')).toBeVisible()
    await expect(
      owner.locator('[data-document-presence]').getByRole('button', { name: '2 人在线', exact: true })
    ).toBeVisible()
    await owner.screenshot({ path: info.outputPath('concurrent-table-converged.png') })
    expect(errors).toEqual([])
  } finally {
    ownerGate.release()
    memberGate.release()
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await a.close()
    await b.close()
  }
})

test('sorting over a peer cell edit keeps the committed table intact and offers the peer draft for recovery', async ({
  browser
}) => {
  const a = await browser.newContext(),
    b = await browser.newContext()
  await a.addCookies(state.owner.cookies)
  await b.addCookies(state.member.cookies)
  const ownerGate = await documentGate(a),
    memberGate = await documentGate(b)
  const owner = await a.newPage(),
    member = await b.newPage()
  let id: string | undefined
  try {
    id = await create(
      owner,
      'Concurrent table sorting',
      '<page><table><tr><td><p>B</p></td></tr><tr><td><p>A</p></td></tr></table></page>'
    )
    await member.goto(state.base_url + pageRoute(id))
    await expect(editor(member).locator('td')).toHaveText(['B', 'A'])
    ownerGate.hold()
    memberGate.hold()
    await editor(member).locator('td').last().click()
    await member.keyboard.press('End')
    await member.keyboard.insertText(' PEER')
    await editor(owner).locator('td').first().click()
    await owner.getByRole('button', { name: '列', exact: true }).click()
    await owner.getByRole('menuitem', { name: '排序', exact: true }).hover()
    await owner.getByRole('menuitem', { name: '升序排列', exact: true }).click()
    await expect.poll(ownerGate.count).toBeGreaterThan(0)
    await expect.poll(memberGate.count).toBeGreaterThan(0)
    ownerGate.release()
    const recovery = member.getByRole('button', { name: '导出保留的草稿 1', exact: true })
    await expect(recovery).toBeVisible()
    memberGate.release()
    for (const page of [owner, member]) {
      await expect(editor(page).locator('td')).toHaveText(['A', 'B'])
      await expect(editor(page).locator('table')).toHaveCount(1)
    }
    const downloadEvent = member.waitForEvent('download')
    await recovery.click()
    const downloaded = await (await downloadEvent).path()
    expect(downloaded).not.toBeNull()
    expect(await readFile(downloaded!, 'utf8')).toBe(`# Concurrent table sorting

<table>
  <tr>
    <td>B</td>
  </tr>

  <tr>
    <td>A PEER</td>
  </tr>
</table>
`)
    expect((await stored(owner, id)).content.content).toBe(
      '<page><table><tr><td><p>A</p></td></tr><tr><td><p>B</p></td></tr></table></page>'
    )
  } finally {
    ownerGate.release()
    memberGate.release()
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await a.close()
    await b.close()
  }
})

test('deleting a row being edited preserves the peer draft and never persists a split table', async ({ browser }) => {
  const a = await browser.newContext(),
    b = await browser.newContext()
  await a.addCookies(state.owner.cookies)
  await b.addCookies(state.member.cookies)
  const gate = await documentGate(b)
  const owner = await a.newPage(),
    member = await b.newPage()
  let id: string | undefined
  try {
    id = await create(
      owner,
      'Concurrent row deletion',
      '<page><table><tr><td><p>A</p></td></tr><tr><td><p>B</p></td></tr><tr><td><p>C</p></td></tr></table></page>'
    )
    await member.goto(state.base_url + pageRoute(id))
    await expect(editor(member).locator('td')).toHaveText(['A', 'B', 'C'])
    gate.hold()
    await editor(member).locator('td').nth(1).click()
    await member.keyboard.press('End')
    await member.keyboard.insertText(' PEER')
    await expect.poll(gate.count).toBeGreaterThan(0)
    await editor(owner).locator('td').nth(1).click()
    await owner.getByRole('button', { name: '行', exact: true }).click()
    await owner.getByRole('menuitem', { name: '删除行', exact: true }).click()
    const recovery = member.getByRole('button', { name: '导出保留的草稿 1', exact: true })
    await expect(recovery).toBeVisible()
    gate.release()
    for (const page of [owner, member]) {
      await expect(editor(page).locator('td')).toHaveText(['A', 'C'])
      await expect(editor(page).locator('table')).toHaveCount(1)
    }
    const downloading = member.waitForEvent('download')
    await recovery.click()
    const downloaded = await (await downloading).path()
    expect(await readFile(downloaded!, 'utf8')).toContain('B PEER')
    expect((await stored(owner, id)).content.content).toBe(
      '<page><table><tr><td><p>A</p></td></tr><tr><td><p>C</p></td></tr></table></page>'
    )
  } finally {
    gate.release()
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await a.close()
    await b.close()
  }
})

test('a disconnected editor rebases its pending draft over another human without reloading', async ({ browser }) => {
  const a = await browser.newContext(),
    b = await browser.newContext()
  await a.addCookies(state.owner.cookies)
  await b.addCookies(state.member.cookies)
  const owner = await a.newPage(),
    member = await b.newPage()
  let id: string | undefined
  try {
    id = await create(owner, 'Reconnect draft', '<page><p>Start</p></page>')
    await member.goto(state.base_url + pageRoute(id))
    await expect(editor(member)).toHaveText('Start')
    const started = await member.evaluate(() => performance.timeOrigin)
    await closeRealtimeSocket(member)
    await b.setOffline(true)
    await editor(member).locator('p').click()
    await member.keyboard.press('End')
    await member.keyboard.insertText(' OFFLINE')
    await editor(owner).locator('p').click()
    await owner.keyboard.press('Home')
    await owner.keyboard.insertText('ONLINE ')
    await expect.poll(async () => (await stored(owner, id!)).content.plain_text).toBe('ONLINE Start')
    await b.setOffline(false)
    await expect
      .poll(async () => (await stored(owner, id!)).content.plain_text, { timeout: 25_000 })
      .toBe('ONLINE Start OFFLINE')
    await expect(editor(owner)).toHaveText('ONLINE Start OFFLINE')
    await expect(editor(member)).toHaveText('ONLINE Start OFFLINE')
    expect(await member.evaluate(() => performance.timeOrigin)).toBe(started)
  } finally {
    await b.setOffline(false)
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await a.close()
    await b.close()
  }
})

test('a browser reload keeps an offline draft for explicit recovery without replacing current content', async ({
  browser
}) => {
  const a = await browser.newContext(),
    b = await browser.newContext()
  await a.addCookies(state.owner.cookies)
  await b.addCookies(state.member.cookies)
  const owner = await a.newPage(),
    member = await b.newPage()
  let id: string | undefined
  try {
    id = await create(owner, 'Recover after reload', '<page><p>Start</p></page>')
    const url = state.base_url + pageRoute(id)
    await member.goto(url)
    await expect(editor(member)).toHaveText('Start')
    await b.setOffline(true)
    await closeRealtimeSocket(member)
    await editor(member).locator('p').click()
    await member.keyboard.press('End')
    await member.keyboard.insertText(' OFFLINE DRAFT')
    await expect(editor(member)).toHaveText('Start OFFLINE DRAFT')
    await editor(owner).locator('p').click()
    await owner.keyboard.press('Home')
    await owner.keyboard.insertText('CURRENT ')
    await expect.poll(async () => (await stored(owner, id!)).content.plain_text).toBe('CURRENT Start')
    // Reload while disconnected so the old client cannot submit before unloading.
    await expect(member.reload()).rejects.toThrow(/ERR_INTERNET_DISCONNECTED/)
    await b.setOffline(false)
    await member.goto(url)
    await expect(editor(member)).toHaveText('CURRENT Start')
    const recovery = member.getByRole('button', { name: '导出保留的草稿 1', exact: true })
    await expect(recovery).toBeVisible()
    const downloadEvent = member.waitForEvent('download')
    await recovery.click()
    const download = await downloadEvent
    const downloaded = await download.path()
    expect(downloaded).not.toBeNull()
    expect(await readFile(downloaded!, 'utf8')).toContain('Start OFFLINE DRAFT')
    expect((await stored(owner, id)).content.plain_text).toBe('CURRENT Start')
    await editor(member).locator('p').click()
    await member.keyboard.press('End')
    await member.keyboard.insertText(' FRESH')
    await expect.poll(async () => (await stored(owner, id!)).content.plain_text).toBe('CURRENT Start FRESH')
    await member.reload()
    await expect(editor(member)).toHaveText('CURRENT Start FRESH')
    await expect(recovery).toBeVisible()
    await recovery.locator('..').getByRole('button', { name: '放弃修改', exact: true }).click()
    await member.reload()
    await expect(recovery).toHaveCount(0)
  } finally {
    await b.setOffline(false)
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await a.close()
    await b.close()
  }
})

test('concurrent title edits retain the losing draft until its author reviews the current title', async ({
  browser
}) => {
  const a = await browser.newContext(),
    b = await browser.newContext()
  await a.addCookies(state.owner.cookies)
  await b.addCookies(state.member.cookies)
  const owner = await a.newPage(),
    member = await b.newPage()
  let id: string | undefined
  let release!: () => void
  const delayed = new Promise<void>(resolve => {
    release = resolve
  })
  let intercepted = false
  try {
    id = await create(owner, 'Initial title')
    await member.goto(state.base_url + pageRoute(id))
    await expect(title(member)).toHaveValue('Initial title')
    await member.route(`**/api/v2/pod/pages/${id}`, async route => {
      if (route.request().method() === 'PATCH' || route.request().method() === 'PUT') {
        intercepted = true
        await delayed
      }
      await route.continue()
    })
    await title(member).fill('Member draft')
    await expect.poll(() => intercepted).toBe(true)
    await title(owner).fill('Owner title')
    await expect
      .poll(async () => (await request<{ page: { title: string } }>(owner, `/pages/${id}`)).page.title)
      .toBe('Owner title')
    release()
    await expect(
      member.getByText('标题已被其他人修改。你的草稿已保留，请核对后再保存。', { exact: true })
    ).toBeVisible()
    await expect(title(member)).toHaveValue('Member draft')
    await member.getByRole('button', { name: '保存我的标题', exact: true }).click()
    await expect
      .poll(async () => (await request<{ page: { title: string } }>(owner, `/pages/${id}`)).page.title)
      .toBe('Member draft')
    await expect(title(owner)).toHaveValue('Member draft')
  } finally {
    release()
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await a.close()
    await b.close()
  }
})

test('revoking an editor prevents a buffered write from changing the stored document', async ({ browser }) => {
  const a = await browser.newContext(),
    b = await browser.newContext()
  await a.addCookies(state.owner.cookies)
  await b.addCookies(state.member.cookies)
  const gate = await documentGate(b)
  const owner = await a.newPage(),
    member = await b.newPage()
  let id: string | undefined
  try {
    id = await create(owner, 'Revoke pending')
    await member.goto(state.base_url + pageRoute(id))
    await expect(editor(member)).toBeVisible()
    gate.hold()
    await editor(member).locator('p').first().click()
    await member.keyboard.insertText('MUST NOT COMMIT')
    await expect.poll(gate.count).toBeGreaterThan(0)
    await requestWithSharingVersion(owner, `/pages/${id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [{ principal_uid: state.owner.uid, role: 'manage' }]
    })
    gate.release()
    await expect(editor(member)).toHaveCount(0)
    expect((await stored(owner, id)).content.plain_text).toBe('Alpha\nBeta')
    await owner.reload()
    await expect(editor(owner)).toHaveText('AlphaBeta')
  } finally {
    gate.release()
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await a.close()
    await b.close()
  }
})

test('a real Agent Pod CLI preserves pending human edits when converting their paragraph to a heading', async ({
  browser
}, info) => {
  test.skip(!state.document_agent_uid, 'Start the fixture with POD_BROWSER_AGENT_COLLAB=true and a real Worker image')
  test.setTimeout(150_000)
  const a = await browser.newContext(),
    b = await browser.newContext()
  await a.addCookies(state.owner.cookies)
  await b.addCookies(state.member.cookies)
  const memberGate = await documentGate(b)
  const owner = await a.newPage(),
    member = await b.newPage()
  let id: string | undefined
  let execution:
    | Promise<{
        first_revision: number
        human_revision: number
        final_revision: number
        stale_rejected: boolean
        title_conflicts_rejected: boolean
      }>
    | undefined
  try {
    id = await create(owner, 'Human and Agent collaboration', '<page><p>Human introduction</p></page>')
    await member.goto(state.base_url + pageRoute(id))
    await expect(editor(member)).toHaveText('Human introduction')
    execution = fetch(`${state.agent_actions_url}/document`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ page_id: id })
    }).then(async response => {
      const body = await response.text()
      if (!response.ok) throw new Error(`Agent execution ${response.status}: ${body}`)
      return JSON.parse(body)
    })
    void execution.catch(() => {})
    await Promise.race([execution, expect(editor(owner)).toContainText('Agent outline', { timeout: 90_000 })])
    await expect(editor(member)).toContainText('Agent outline')
    memberGate.hold()
    await editor(member).locator('p').first().click()
    await member.keyboard.press('Home')
    await member.keyboard.insertText('Reviewed: ')
    await expect.poll(memberGate.count).toBeGreaterThan(0)
    await title(owner).fill('Human reviewed title')
    await expect
      .poll(async () => (await request<{ page: { title: string } }>(owner, `/pages/${id}`)).page.title)
      .toBe('Human reviewed title')
    await editor(owner).locator('p').first().click()
    await owner.keyboard.press('End')
    await owner.keyboard.insertText(' owner-note')
    const result = await execution
    expect(result.stale_rejected).toBe(true)
    expect(result.title_conflicts_rejected).toBe(true)
    expect(result.human_revision).toBeGreaterThan(result.first_revision)
    expect(result.final_revision).toBeGreaterThan(result.human_revision)
    // The Agent's actual native delta reaches a browser with an unacknowledged local edit.
    await expect(editor(member).locator('h1')).toHaveText('Reviewed: Human introduction (Agent reviewed) owner-note')
    expect(await lastEditor(owner, id)).toMatchObject({ principal_uid: state.document_agent_uid, kind: 'agent' })
    memberGate.release()
    for (const page of [owner, member]) {
      await expect(title(page)).toHaveValue('Agent reviewed title')
      await expect(editor(page).locator('h1')).toHaveText('Reviewed: Human introduction (Agent reviewed) owner-note')
      await expect(editor(page).locator('p')).toHaveText(['Agent outline', 'Agent conclusion'])
    }
    const committed = (await stored(owner, id)).content
    expect(committed.content).toContain('<h1>Reviewed: Human introduction (Agent reviewed) owner-note</h1>')
    expect(committed.plain_text).toBe(
      'Reviewed: Human introduction (Agent reviewed) owner-note\nAgent outline\nAgent conclusion'
    )
    // The durable document, both peer views, and a fresh reload must agree.
    await owner.reload()
    await expect(editor(owner).locator('h1')).toHaveText('Reviewed: Human introduction (Agent reviewed) owner-note')
    await expect(editor(owner).locator('p')).toHaveText(['Agent outline', 'Agent conclusion'])
    await expect(owner.locator('[data-sync-status=saved]')).toBeVisible()
    await expect(
      owner.locator('[data-document-presence]').getByRole('button', { name: '2 人在线', exact: true })
    ).toBeVisible()
    await owner.screenshot({ path: info.outputPath('agent-human-converged.png') })
    expect(await lastEditor(owner, id)).toMatchObject({ principal_uid: state.member.uid, kind: 'human' })
  } finally {
    memberGate.release()
    if (execution) await execution.catch(() => {})
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await a.close()
    await b.close()
  }
})

test('live collaborators show remote selections and disappear when access is revoked', async ({ browser }, info) => {
  const a = await browser.newContext(),
    b = await browser.newContext()
  await a.addCookies(state.owner.cookies)
  await b.addCookies(state.member.cookies)
  const owner = await a.newPage(),
    member = await b.newPage()
  let id: string | undefined
  try {
    id = await create(owner, 'Live collaborator selections')
    await member.goto(state.base_url + pageRoute(id))
    for (const page of [owner, member]) {
      await expect(
        page.locator('[data-document-presence]').getByRole('button', { name: '2 人在线', exact: true })
      ).toBeVisible()
      await expect(page.locator('[data-sync-status=saved]')).toBeVisible()
    }
    await editor(member).locator('p').first().click()
    await member.keyboard.press('Home')
    await member.keyboard.press('Shift+ArrowRight')
    await member.keyboard.press('Shift+ArrowRight')
    await expect(owner.locator('.editor-remote-selection')).toBeVisible()
    await expect(owner.locator('.editor-remote-caret')).toBeVisible()
    await owner.screenshot({ path: info.outputPath('live-collaborator-selection.png') })
    await requestWithSharingVersion(owner, `/pages/${id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [{ principal_uid: state.owner.uid, role: 'manage' }]
    })
    await expect(editor(member)).toHaveCount(0)
    await expect(
      owner.locator('[data-document-presence]').getByRole('button', { name: '1 人在线', exact: true })
    ).toBeVisible()
    await expect(owner.locator('.editor-remote-selection')).toHaveCount(0)
    await expect(owner.locator('.editor-remote-caret')).toHaveCount(0)
  } finally {
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await a.close()
    await b.close()
  }
})

test('three real sessions render remote selections in either position order and count people once', async ({
  browser
}, info) => {
  const contexts = await Promise.all([browser.newContext(), browser.newContext(), browser.newContext()])
  const [ownerContext, twinContext, memberContext] = contexts as [BrowserContext, BrowserContext, BrowserContext]
  await ownerContext.addCookies(state.owner.cookies)
  await twinContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const owner = await ownerContext.newPage(),
    twin = await twinContext.newPage(),
    member = await memberContext.newPage()
  const errors: string[] = []
  for (const page of [owner, twin, member]) page.on('pageerror', error => errors.push(error.message))
  const select = async (page: Page, paragraph: number) => {
    await editor(page).locator('p').nth(paragraph).click()
    await page.keyboard.press('Home')
    await page.keyboard.press('Shift+ArrowRight')
    await page.keyboard.press('Shift+ArrowRight')
  }
  let id: string | undefined
  try {
    id = await create(owner, 'Three sessions and two people')
    await twin.goto(state.base_url + pageRoute(id))
    await expect(editor(twin)).toHaveText('AlphaBeta')
    await member.goto(state.base_url + pageRoute(id))
    await expect(editor(member)).toHaveText('AlphaBeta')
    for (const page of [owner, twin, member]) {
      await expect(
        page.locator('[data-document-presence]').getByRole('button', { name: '2 人在线', exact: true })
      ).toBeVisible()
    }
    // Read every paragraph at once: carets of a moving session briefly share a paragraph.
    const caretNames = () =>
      editor(owner)
        .locator('p')
        .evaluateAll(paragraphs =>
          paragraphs.map(paragraph =>
            Array.from(paragraph.querySelectorAll('.editor-remote-caret-label'), label =>
              label.getAttribute('data-name')
            )
          )
        )
    // Session order stays stable while selection positions run in both directions.
    await select(twin, 1)
    await select(member, 0)
    await expect(owner.locator('.editor-remote-caret')).toHaveCount(2)
    await expect(owner.locator('.editor-remote-selection')).toHaveCount(2)
    await expect.poll(caretNames).toEqual([['Browser member'], ['Browser owner']])
    await select(twin, 0)
    await select(member, 1)
    await expect(owner.locator('.editor-remote-caret')).toHaveCount(2)
    await expect(owner.locator('.editor-remote-selection')).toHaveCount(2)
    await expect.poll(caretNames).toEqual([['Browser owner'], ['Browser member']])
    expect((await stored(owner, id)).content.plain_text).toBe('Alpha\nBeta')
    await owner.screenshot({ path: info.outputPath('three-sessions-two-people.png') })
    expect(errors).toEqual([])
  } finally {
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await Promise.all(contexts.map(context => context.close()))
  }
})

test('losing a committed batch acknowledgement retries the same payload without duplicating text', async ({
  browser
}) => {
  const a = await browser.newContext(),
    b = await browser.newContext()
  await a.addCookies(state.owner.cookies)
  await b.addCookies(state.member.cookies)
  const requests: Record<string, unknown>[] = []
  let drop = false
  let firstClient: string | undefined
  let firstSequence: number | undefined
  await a.routeWebSocket('**/pod/socket/websocket**', socket => {
    const server = socket.connectToServer()
    socket.onMessage(message => {
      if (typeof message === 'string') {
        const frame = JSON.parse(message)
        if (drop && frame[3] === 'changes') {
          const batch = frame[4]
          requests.push(structuredClone(batch))
          if (firstClient === undefined) {
            firstClient = batch.client_id
            firstSequence = batch.client_seq
          } else if (batch.client_id === firstClient && batch.client_seq === firstSequence) drop = false
        }
      }
      server.send(message)
    })
    server.onMessage(message => {
      if (drop && firstClient && typeof message === 'string') {
        const frame = JSON.parse(message)
        const changes = frame[3] === 'phx_reply' ? frame[4]?.response?.changes : frame[4]?.changes
        if (
          Array.isArray(changes) &&
          changes.some(change => change.client_id === firstClient && change.client_seq === firstSequence)
        ) {
          return
        }
      }
      socket.send(message)
    })
  })
  const owner = await a.newPage(),
    member = await b.newPage()
  let id: string | undefined
  try {
    id = await create(owner, 'Lost acknowledgement', '<page><p>Start</p></page>')
    await member.goto(state.base_url + pageRoute(id))
    await expect(editor(member)).toHaveText('Start')
    drop = true
    await editor(owner).locator('p').click()
    await owner.keyboard.press('End')
    await owner.keyboard.insertText(' ONCE')
    await expect(editor(member)).toHaveText('Start ONCE')
    // Continue typing while the first transport request has no reply.
    await owner.keyboard.insertText(' AFTER')
    await expect.poll(() => requests.length, { timeout: 30_000 }).toBeGreaterThanOrEqual(2)
    expect(requests[1]).toEqual(requests[0])
    await expect
      .poll(async () => (await stored(owner, id!)).content.plain_text, { timeout: 15_000 })
      .toBe('Start ONCE AFTER')
    await expect(editor(member)).toHaveText('Start ONCE AFTER')
    await owner.reload()
    await expect(editor(owner)).toHaveText('Start ONCE AFTER')
  } finally {
    drop = false
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await a.close()
    await b.close()
  }
})

test('a lost sync reply keeps collaborators online and retry restores the missing edits', async ({ browser }, info) => {
  const a = await browser.newContext(),
    b = await browser.newContext()
  await a.addCookies(state.owner.cookies)
  await b.addCookies(state.member.cookies)
  let topic = ''
  let missedChange = false
  let droppedReply: string | undefined
  let syncRequests = 0
  await a.routeWebSocket('**/pod/socket/websocket**', socket => {
    const server = socket.connectToServer()
    socket.onMessage(message => {
      if (typeof message === 'string') {
        const frame = JSON.parse(message)
        if (frame[2] === topic && frame[3] === 'sync' && ++syncRequests === 1) droppedReply = frame[1]
      }
      server.send(message)
    })
    server.onMessage(message => {
      if (typeof message === 'string') {
        const frame = JSON.parse(message)
        if (frame[2] === topic) {
          // A missing committed broadcast makes the next real batch request replay.
          if (frame[3] === 'changes' && !missedChange) {
            missedChange = true
            return
          }
          if (frame[3] === 'phx_reply' && frame[1] === droppedReply) return
        }
      }
      socket.send(message)
    })
  })
  const owner = await a.newPage(),
    member = await b.newPage()
  let id: string | undefined
  try {
    id = await create(owner, 'Recover a sync reply', '<page><p>Start</p></page>')
    await member.goto(state.base_url + pageRoute(id))
    const people = owner.locator('[data-document-presence]').getByRole('button', { name: '2 人在线', exact: true })
    await expect(people).toBeVisible()
    topic = `page:${id}`
    await editor(member).locator('p').click()
    await member.keyboard.press('End')
    await member.keyboard.insertText(' FIRST')
    await expect.poll(async () => (await stored(member, id!)).content.plain_text).toBe('Start FIRST')
    await expect.poll(() => missedChange).toBe(true)
    await expect(member.locator('[data-sync-status=saved]')).toBeVisible()
    await member.keyboard.insertText(' SECOND')
    await expect.poll(() => syncRequests).toBe(1)
    const retry = owner.getByRole('button', { name: '重试', exact: true })
    await expect(retry).toBeVisible({ timeout: 25_000 })
    await expect(people).toBeVisible()
    await expect(owner.locator('[data-sync-status=offline]')).toHaveCount(0)
    await retry.click()
    await expect(editor(owner)).toHaveText('Start FIRST SECOND')
    await expect(owner.locator('[data-sync-status=saved]')).toBeVisible()
    await expect(people).toBeVisible()
    await member.keyboard.press('Home')
    await member.keyboard.press('Shift+ArrowRight')
    await expect(owner.locator('.editor-remote-selection')).toBeVisible()
    await expect(owner.locator('.editor-remote-caret')).toBeVisible()
    await owner.screenshot({ path: info.outputPath('sync-retry-keeps-presence.png') })
    expect(syncRequests).toBe(2)
  } finally {
    topic = ''
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await a.close()
    await b.close()
  }
})

test('an edit rejection offers draft export and reload without an ineffective retry', async ({ browser }, info) => {
  const a = await browser.newContext(),
    b = await browser.newContext()
  await a.addCookies(state.owner.cookies)
  await b.addCookies(state.member.cookies)
  const gate = await documentGate(b)
  const owner = await a.newPage(),
    member = await b.newPage()
  let rejected = false
  member.on('websocket', socket => {
    socket.on('framereceived', ({ payload }) => {
      const frame = JSON.parse(String(payload))
      if (frame[3] === 'phx_reply' && frame[4]?.status === 'error' && frame[4]?.response?.reason === 'forbidden') {
        rejected = true
      }
    })
  })
  let id: string | undefined
  try {
    id = await create(owner, 'Edit permission removed', '<page><p>Start</p></page>')
    await member.goto(state.base_url + pageRoute(id))
    await expect(editor(member)).toHaveText('Start')
    gate.hold()
    await editor(member).locator('p').click()
    await member.keyboard.press('End')
    await member.keyboard.insertText(' UNSAVED')
    await expect.poll(gate.count).toBeGreaterThan(0)
    await requestWithSharingVersion(owner, `/pages/${id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'view' }
      ]
    })
    gate.release()
    await expect.poll(() => rejected).toBe(true)
    await expect(member.getByRole('button', { name: '重试', exact: true })).toHaveCount(0)
    const exportDraft = member.getByRole('button', { name: '导出草稿', exact: true })
    await expect(exportDraft).toBeVisible()
    await expect(editor(member)).toHaveText('Start UNSAVED')
    const downloading = member.waitForEvent('download')
    await exportDraft.click()
    const downloaded = await (await downloading).path()
    expect(await readFile(downloaded!, 'utf8')).toContain('Start UNSAVED')
    await member.screenshot({ path: info.outputPath('rejected-edit-recovery-actions.png') })
    await member.getByRole('button', { name: '重新读取文档', exact: true }).click()
    await expect(editor(member)).toHaveText('Start')
    await expect(editor(member)).toHaveAttribute('contenteditable', 'false')
    await expect(member.getByRole('button', { name: '重试', exact: true })).toHaveCount(0)
    expect((await stored(owner, id)).content.plain_text).toBe('Start')
  } finally {
    gate.release()
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await a.close()
    await b.close()
  }
})
