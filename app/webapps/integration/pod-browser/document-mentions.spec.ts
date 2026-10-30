import { expect, test, type Page } from '@playwright/test'
import { state, requestWithSharingVersion as request } from './fixtures'
import { pageIDFromURL, pageRoute } from './routes'

async function createDocument(page: Page, title?: string) {
  await page.goto(state.base_url + pageRoute(state.report_id))
  await page.locator('.pod-sidebar-top').getByRole('button', { name: '新建页面', exact: true }).click()
  const created = page.waitForResponse(
    response => response.request().method() === 'POST' && new URL(response.url()).pathname === '/api/v2/pod/pages'
  )
  await page.getByRole('menuitem', { name: '文档', exact: true }).click()
  const response = await created
  expect(response.status()).toBe(201)
  const { page: document } = (await response.json()) as { page: { id: string } }
  await expect(page).toHaveURL(state.base_url + pageRoute(document.id))
  const titleInput = page.getByRole('textbox', { name: '页面标题', exact: true })
  await expect(titleInput).toBeVisible()
  if (title) {
    await titleInput.fill(title)
    await titleInput.press('Enter')
  }
  return document.id
}

test('inline @ mentions replace block page references, render hover/click cards, sync renames, and convert pasted Pod URLs without side effects', async ({
  browser
}) => {
  const ownerContext = await browser.newContext({ permissions: ['clipboard-read', 'clipboard-write'] })
  await ownerContext.addCookies(state.owner.cookies)
  const owner = await ownerContext.newPage()
  const createdIDs: string[] = []

  try {
    const targetTitle = `Mention target ${Date.now()}`
    const targetID = await createDocument(owner, targetTitle)
    createdIDs.push(targetID)

    const editor = owner.locator('.pod-document .editor-content')
    await editor.click()
    await owner.keyboard.type('Quarterly revenue grew 42% across enterprise accounts.')
    await expect
      .poll(
        async () => (await request<{ content: { plain_text: string } }>(owner, `/pages/${targetID}`)).content.plain_text
      )
      .toContain('Quarterly revenue grew 42%')

    const docID = await createDocument(owner, 'Mention authoring')
    createdIDs.push(docID)

    // An empty paragraph offers 添加 Block; 在下方添加 Block belongs to the block actions menu.
    await editor.locator(':scope > p').first().hover()
    await owner.getByRole('button', { name: '添加 Block', exact: true }).click()
    await expect(owner.getByRole('menuitem', { name: '引用已有页面', exact: true })).toHaveCount(0)
    await expect(owner.getByRole('menuitem', { name: '提及或引用', exact: true })).toBeVisible()
    await expect(owner.getByRole('menuitem', { name: '嵌入多维表或应用', exact: true })).toBeVisible()
    await owner.keyboard.press('Escape')
    await expect(editor.locator(':scope > p')).toHaveCount(1)

    // Type @ to open the picker; verify grouped first-screen sections (<= 6 items) and zero notification controls.
    await editor.locator(':scope > p').first().click()
    await owner.keyboard.type('@')
    const menu = owner.locator('.mention-menu')
    await expect(menu).toBeVisible()
    await expect(menu.getByText('同时发送通知')).toHaveCount(0)
    await expect(menu.getByRole('button', { name: '提及', exact: true })).toHaveCount(0)
    await expect(menu.locator('.mention-group-label')).toHaveText(['页面', '主体'])
    expect(await menu.getByRole('option').count()).toBeLessThanOrEqual(6)

    // Mention target page via keyboard query + Enter.
    await owner.keyboard.type(targetTitle)
    await expect(menu.getByRole('option').filter({ hasText: targetTitle })).toBeVisible()
    await owner.keyboard.press('Enter')
    const pageChip = editor.locator(`[data-mention-page="${targetID}"] a.pod-mention-page`)
    await expect(pageChip).toHaveText(targetTitle)

    // Mention self (@Browser owner) -> highlighted with data-mention-self="true".
    await owner.keyboard.type(' @Browser owner')
    await expect(menu.getByRole('option').filter({ hasText: 'Browser owner' })).toBeVisible()
    await owner.keyboard.press('Enter')
    const selfChip = editor.locator(`[data-mention-principal="${state.owner.uid}"] button.pod-mention-principal`)
    await expect(selfChip).toHaveText(/Browser owner/)
    await expect(selfChip).toHaveAttribute('data-mention-self', 'true')

    // Mention colleague (@Browser member) and AI Agent (@Browser content Agent).
    await owner.keyboard.type(' @Browser member')
    await expect(menu.getByRole('option').filter({ hasText: 'Browser member' })).toBeVisible()
    await owner.keyboard.press('Enter')
    const memberChip = editor.locator(`[data-mention-principal="${state.member.uid}"] button.pod-mention-principal`)
    await expect(memberChip).toHaveText(/Browser member/)
    await expect(memberChip).not.toHaveAttribute('data-mention-self', 'true')

    await owner.keyboard.type(' @Browser content Agent')
    await expect(menu.getByRole('option').filter({ hasText: 'Browser content Agent' })).toBeVisible()
    await owner.keyboard.press('Enter')
    const agentChip = editor.locator(`[data-mention-principal="${state.agent_uid}"] button.pod-mention-principal`)
    await expect(agentChip).toHaveText(/Browser content Agent/)

    await expect
      .poll(async () => (await request<{ content: { content: string } }>(owner, `/pages/${docID}`)).content.content)
      .toContain(`<mention principal="${state.agent_uid}" />`)

    // Hovering a Principal chip does NOT open a card; clicking opens the Principal Card Popover.
    await memberChip.hover()
    await owner.waitForTimeout(350)
    await expect(owner.getByRole('dialog', { name: 'Browser member', exact: true })).toHaveCount(0)
    await memberChip.click()
    const memberPopover = owner.locator('[data-slot="popover-content"][aria-label="Browser member"]')
    await expect(memberPopover).toBeVisible()
    await expect(memberPopover).toContainText('成员')
    await expect(memberPopover).toContainText(state.member.email)
    await owner.keyboard.press('Escape')
    await expect(memberPopover).toBeHidden()

    // Hovering a Page mention opens the Alumina Ceramic Page Hover Preview Card with excerpt.
    await pageChip.hover()
    const hoverCard = owner.locator(`[data-slot="hover-card-content"][aria-label="${targetTitle}"]`)
    await expect(hoverCard).toBeVisible()
    await expect(hoverCard).toContainText('Quarterly revenue grew 42% across enterprise accounts.')
    await owner.mouse.move(0, 0)
    await expect(hoverCard).toBeHidden()

    // Renaming the referenced page updates the inline mention title live in the SPA session without mutating canonical XML.
    const renamedTitle = `Renamed target ${Date.now()}`
    await pageChip.click()
    await expect(owner).toHaveURL(state.base_url + pageRoute(targetID))
    const targetTitleInput = owner.getByRole('textbox', { name: '页面标题', exact: true })
    await expect(targetTitleInput).toHaveValue(targetTitle)
    await targetTitleInput.fill(renamedTitle)
    await targetTitleInput.blur()
    await expect
      .poll(async () => (await request<{ page: { title: string } }>(owner, `/pages/${targetID}`)).page.title)
      .toBe(renamedTitle)

    await owner.goBack()
    await expect(owner).toHaveURL(state.base_url + pageRoute(docID))
    await expect(editor.locator(`[data-mention-page="${targetID}"] a.pod-mention-page`)).toHaveText(renamedTitle)

    // In-editor selection copy (mentionPlainText) reads shared pageMetadata and reflects the renamed title immediately.
    await editor.locator(':scope > p').first().click()
    await owner.keyboard.press('ControlOrMeta+a')
    await owner.keyboard.press('ControlOrMeta+c')
    await expect.poll(() => owner.evaluate(() => navigator.clipboard.readText())).toContain(renamedTitle)

    // Pasting a bare current-origin Pod Page URL converts into an inline <mention page="..." /> chip.
    await editor.locator(':scope > p').last().click()
    await owner.keyboard.press('End')
    await owner.keyboard.press('Enter')
    const reportURL = state.base_url + pageRoute(state.report_id)
    await editor.evaluate((element, url) => {
      const event = new ClipboardEvent('paste', { clipboardData: new DataTransfer(), bubbles: true, cancelable: true })
      event.clipboardData!.setData('text/plain', url)
      element.dispatchEvent(event)
    }, reportURL)
    const reportChip = editor.locator(`[data-mention-page="${state.report_id}"] a.pod-mention-page`)
    await expect(reportChip).toHaveText('Browser report')

    await expect
      .poll(async () => (await request<{ content: { content: string } }>(owner, `/pages/${docID}`)).content.content)
      .toContain(`<mention page="${state.report_id}" />`)

    // Portable copy resolves page mentions to links/titles and principal mentions to @DisplayName without raw <mention> tags.
    const moreActions = owner.locator('.pod-page-header').getByRole('button', { name: '更多操作', exact: true })
    await moreActions.click()
    await owner.getByRole('menuitem', { name: '复制', exact: true }).hover()
    await owner.getByRole('menuitem', { name: '复制为 Markdown', exact: true }).click()
    await expect
      .poll(() => owner.evaluate(() => navigator.clipboard.readText()))
      .toContain(`[Browser report](${reportURL})`)
    const copiedMarkdown = await owner.evaluate(() => navigator.clipboard.readText())
    expect(copiedMarkdown).toContain('@Browser owner')
    expect(copiedMarkdown).toContain('@Browser content Agent')
    expect(copiedMarkdown).not.toContain('<mention')

    await moreActions.click()
    await owner.getByRole('menuitem', { name: '复制', exact: true }).hover()
    await owner.getByRole('menuitem', { name: '复制为纯文本', exact: true }).click()
    await expect.poll(() => owner.evaluate(() => navigator.clipboard.readText())).toContain('Browser report')
    const copiedPlain = await owner.evaluate(() => navigator.clipboard.readText())
    expect(copiedPlain).toContain('@Browser member')
    expect(copiedPlain).not.toContain('<mention')

    // Left-clicking a page mention navigates via SPA router.
    await reportChip.click()
    await expect(owner).toHaveURL(reportURL)

    // 嵌入多维表或应用 embeds an existing Base while strictly excluding Document pages.
    await owner.goto(state.base_url + pageRoute(docID))
    await expect(editor).toBeVisible()
    await editor.locator(':scope > p').first().hover()
    await owner.getByRole('button', { name: 'Block 菜单', exact: true }).click()
    await owner.getByRole('menuitem', { name: '在下方添加 Block', exact: true }).click()
    await owner.getByRole('menuitem', { name: '嵌入多维表或应用', exact: true }).click()
    const embedDialog = owner.getByRole('dialog', { name: '嵌入多维表或应用', exact: true })
    await expect(embedDialog).toBeVisible()
    await expect(embedDialog.getByRole('option', { name: /Browser sales/ })).toBeVisible()
    await expect(
      embedDialog.getByRole('option').filter({ has: owner.getByText('Browser report', { exact: true }) })
    ).toHaveCount(0)
    await expect(embedDialog.getByRole('option', { name: /Mention authoring/ })).toHaveCount(0)
    await embedDialog.getByRole('option', { name: /Browser sales/ }).click()
    await expect(embedDialog).toBeHidden()
    await expect(owner.locator('.pod-inline-page[data-page-type="base"]')).toContainText('Browser sales')

    // Creating a child doc via 新建页面 -> 文档 inserts <mention page="..." /> in parent XML.
    await editor.locator(':scope > p').first().hover()
    await owner.getByRole('button', { name: 'Block 菜单', exact: true }).click()
    await owner.getByRole('menuitem', { name: '在下方添加 Block', exact: true }).click()
    await owner.getByRole('menuitem', { name: '新建页面', exact: true }).hover()
    await owner.getByRole('menuitem', { name: '文档', exact: true }).click()
    await expect(owner).not.toHaveURL(state.base_url + pageRoute(docID))
    const childDocID = pageIDFromURL(owner.url())
    createdIDs.push(childDocID)
    const savedParent = await request<{ content: { content: string } }>(owner, `/pages/${docID}`)
    expect(savedParent.content.content).toContain(`<embed ref="${state.base_id}" />`)
    expect(savedParent.content.content).toContain(`<mention page="${childDocID}" />`)
    expect(savedParent.content.content).not.toContain(`<embed ref="${childDocID}"`)
  } finally {
    for (const id of createdIDs.reverse()) {
      await request(owner, `/pages/${id}`, 'DELETE').catch(() => {})
    }
    await ownerContext.close()
  }
})

test('restricted page mentions render 受限页面 without leaking private titles or icons to unauthorized readers', async ({
  browser
}) => {
  const ownerContext = await browser.newContext()
  const viewerContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await viewerContext.addCookies(state.viewer.cookies)
  const owner = await ownerContext.newPage()
  const viewer = await viewerContext.newPage()
  const createdIDs: string[] = []

  try {
    await owner.goto(state.base_url + pageRoute(state.report_id))
    const secretTitle = `TopSecret Acquisition ${Date.now()}`
    const { page: privatePage } = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      type: 'doc',
      title: secretTitle,
      icon: '🕵️',
      private_owner_uid: state.owner.uid
    })
    createdIDs.push(privatePage.id)

    const { page: sharedDoc } = await request<{ page: { id: string } }>(owner, '/pages', 'POST', {
      type: 'doc',
      title: 'Shared status update'
    })
    createdIDs.push(sharedDoc.id)

    await request(owner, `/pages/${sharedDoc.id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.viewer.uid, role: 'view' }
      ]
    })

    await request(owner, `/pages/${sharedDoc.id}/content`, 'PUT', {
      base_revision: 0,
      xml: `<page><p>Context: <mention page="${privatePage.id}"/> and <mention page="${state.report_id}"/></p></page>`
    })

    let resolvePayloadText = ''
    viewer.on('response', async response => {
      if (new URL(response.url()).pathname === '/api/v2/pod/mentions/resolve') {
        resolvePayloadText += await response.text().catch(() => '')
      }
    })

    await viewer.goto(state.base_url + pageRoute(sharedDoc.id))
    const viewerEditor = viewer.locator('.pod-document .editor-content')
    await expect(viewerEditor).toBeVisible()

    const restrictedChip = viewerEditor.locator(
      `[data-mention-page="${privatePage.id}"] [data-mention-access="restricted"]`
    )
    await expect(restrictedChip).toBeVisible()
    await expect(restrictedChip).toHaveText('受限页面')
    await expect(viewerEditor.locator(`[data-mention-page="${state.report_id}"] a.pod-mention-page`)).toHaveText(
      'Browser report'
    )

    const bodyText = await viewer.locator('body').innerText()
    expect(bodyText).not.toContain(secretTitle)
    expect(bodyText).not.toContain('🕵️')
    expect(resolvePayloadText).not.toContain(secretTitle)
    expect(resolvePayloadText).not.toContain('🕵️')
  } finally {
    for (const id of createdIDs.reverse()) {
      await request(owner, `/pages/${id}`, 'DELETE').catch(() => {})
    }
    await ownerContext.close()
    await viewerContext.close()
  }
})
