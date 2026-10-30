import { readFileSync } from 'node:fs'
import { expect, test, type Page, type Locator } from '@playwright/test'
import { unzipSync, strFromU8 } from 'fflate'
import { parseMarkdown } from '@ankole/block-editor/document'
import { state, request } from './fixtures'
import { pageRoute } from './routes'

const actions = (page: Page) => page.locator('.pod-page-header').getByRole('button', { name: '更多操作', exact: true })

async function createDocument(page: Page) {
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
  await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()
  return document.id
}

async function expectStats(stats: Locator, labels: string[]) {
  await expect
    .poll(async () => (await stats.locator('span').allTextContents()).map(text => text.replace(/[\u2066-\u2069]/g, '')))
    .toEqual(labels)
}

async function submenu(page: Page, name: string) {
  await actions(page).click()
  await page.getByRole('menuitem', { name, exact: true }).hover()
}

async function expectDocumentMenuAlignment(page: Page) {
  const insights = page.getByRole('menuitem', { name: /^文档信息/ })
  const stats = page.getByRole('menuitemcheckbox', { name: /^显示编辑统计/ })
  const exports = page.getByRole('menuitem', { name: '导出', exact: true })
  const copies = page.getByRole('menuitem', { name: '复制', exact: true })
  const geometry = await Promise.all(
    [insights, stats, exports, copies].map(item =>
      item.evaluate(element => {
        const icon = element.querySelector(':scope > svg')!.getBoundingClientRect()
        const label = Array.from(element.childNodes).find(
          node => node.nodeType === Node.TEXT_NODE && node.textContent?.trim()
        )!
        const range = document.createRange()
        range.selectNode(label)
        const shortcut = element.querySelector('[data-slot="dropdown-menu-shortcut"]')?.getBoundingClientRect()
        const chevron = element.querySelector(':scope > svg:last-child path')?.getBoundingClientRect()
        const check = element
          .querySelector('[data-slot="dropdown-menu-checkbox-item-indicator"] path')
          ?.getBoundingClientRect()
        return {
          iconLeft: icon.left,
          labelLeft: range.getBoundingClientRect().left,
          shortcutLeft: shortcut?.left,
          trailingRight: (shortcut ?? chevron)!.right,
          checkRight: check?.right
        }
      })
    )
  )
  expect(Math.abs(geometry[0]!.trailingRight - geometry[1]!.trailingRight)).toBeLessThan(1)
  expect(Math.abs(geometry[2]!.trailingRight - geometry[3]!.trailingRight)).toBeLessThan(1)
  for (const row of geometry) {
    expect(Math.abs(row.iconLeft - geometry[0]!.iconLeft)).toBeLessThan(1)
    expect(Math.abs(row.labelLeft - geometry[0]!.labelLeft)).toBeLessThan(1)
    expect(Math.abs(row.trailingRight - geometry[0]!.trailingRight)).toBeLessThanOrEqual(2.5)
  }
  if (geometry[1]!.checkRight !== undefined) {
    expect(geometry[1]!.checkRight).toBeLessThan(geometry[1]!.shortcutLeft!)
  }
  return geometry[0]!.trailingRight
}

test('a new document copies and exports its current title and body through the real menu', async ({
  browser
}, info) => {
  const context = await browser.newContext({ permissions: ['clipboard-read', 'clipboard-write'] })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    id = await createDocument(page)
    const title = page.getByRole('textbox', { name: '页面标题', exact: true })
    const editor = page.locator('.pod-document .editor-content')
    await title.fill('Initial document title')
    await title.press('Enter')
    await expect(editor).toBeFocused()
    await page.keyboard.insertText('Alpha beta')
    await page.keyboard.press('Enter')
    await page.keyboard.insertText('Current document body')
    await expect(editor).toHaveText('Alpha betaCurrent document body')
    await title.fill('Current document title')

    await submenu(page, '复制')
    await page.getByRole('menuitem', { name: '复制为 Markdown', exact: true }).click()
    const markdown = '# Current document title\n\nAlpha beta\n\nCurrent document body'
    await expect.poll(() => page.evaluate(() => navigator.clipboard.readText())).toBe(markdown)
    await expect(page.getByText('已复制为 Markdown', { exact: true })).toBeVisible()

    await submenu(page, '复制')
    await page.getByRole('menuitem', { name: '复制为纯文本', exact: true }).click()
    await expect
      .poll(() => page.evaluate(() => navigator.clipboard.readText()))
      .toBe('Alpha beta\nCurrent document body')
    await expect(page.getByText('已复制为纯文本', { exact: true })).toBeVisible()

    await submenu(page, '导出')
    await expect(page.getByRole('menuitem', { name: 'Markdown', exact: true })).toBeVisible()
    await page.screenshot({ path: info.outputPath('document-export-menu.png') })
    const downloaded = page.waitForEvent('download')
    await page.getByRole('menuitem', { name: 'Markdown', exact: true }).click()
    const download = await downloaded
    expect(download.suggestedFilename()).toBe('Current-document-title.md')
    const path = await download.path()
    expect(path).not.toBeNull()
    expect(readFileSync(path!, 'utf8')).toBe(markdown)
    await info.attach('exported-document.md', { path: path!, contentType: 'text/markdown' })

    await expect
      .poll(async () => {
        const saved = await request<{ page: { title: string }; content: { plain_text: string } }>(page, `/pages/${id}`)
        return { title: saved.page.title, body: saved.content.plain_text }
      })
      .toEqual({ title: 'Current document title', body: 'Alpha beta\nCurrent document body' })
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('editing statistics follow live text and selection, persist their toggle, and Insights shows the creator', async ({
  browser
}, info) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let id: string | undefined
  try {
    id = await createDocument(page)
    const title = page.getByRole('textbox', { name: '页面标题', exact: true })
    const editor = page.locator('.pod-document .editor-content')
    const stats = page.locator('footer[aria-label="编辑统计"]')
    await title.fill('The title is excluded from body statistics')
    await title.press('Enter')
    await page.keyboard.insertText('Alpha beta')
    await expect(stats).toBeHidden()
    await actions(page).click()
    const toggle = page.getByRole('menuitemcheckbox', { name: /^显示编辑统计/ })
    await expect(toggle).not.toBeChecked()
    const shortcutRight = await expectDocumentMenuAlignment(page)
    await page.screenshot({ path: info.outputPath('document-tools-menu-unchecked.png'), caret: 'initial' })
    await page.keyboard.press('Home')
    for (
      let index = 0;
      index < 10 && !(await toggle.evaluate(element => element === document.activeElement));
      index++
    ) {
      await page.keyboard.press('ArrowDown')
    }
    await expect(toggle).toBeFocused()
    await page.keyboard.press('Space')
    await expect(toggle).toBeChecked()
    expect(Math.abs((await expectDocumentMenuAlignment(page)) - shortcutRight)).toBeLessThan(1)
    await page.screenshot({ path: info.outputPath('document-tools-menu-checked.png'), caret: 'initial' })
    await page.keyboard.press('ArrowDown')
    await expect(page.getByRole('menuitem', { name: '导出', exact: true })).toBeFocused()
    await page.keyboard.press('ArrowRight')
    await expect(page.getByRole('menuitem', { name: 'Markdown', exact: true })).toBeFocused()
    await page.keyboard.press('ArrowLeft')
    await expect(page.getByRole('menuitem', { name: '导出', exact: true })).toBeFocused()
    await page.keyboard.press('Escape')
    await expect(actions(page)).toBeFocused()
    await expect(stats).toBeVisible()
    await expectStats(stats, ['2 个词', '10 个字符', '1 个段落', '约 1 分钟阅读'])

    await editor.locator(':scope > p').first().click()
    await page.keyboard.press('ControlOrMeta+End')
    await page.keyboard.insertText(' gamma')
    await expectStats(stats, ['3 个词', '16 个字符', '1 个段落', '约 1 分钟阅读'])
    await expect(stats).toHaveCSS('opacity', '1')
    await expect(editor).toBeFocused()
    await page.keyboard.press('ControlOrMeta+Home')
    for (let index = 0; index < 5; index++) await page.keyboard.press('Shift+ArrowRight')
    await expectStats(stats, ['已选 1 个词', '已选 5 个字符'])
    await page.keyboard.press('ArrowRight')
    await expectStats(stats, ['3 个词', '16 个字符', '1 个段落', '约 1 分钟阅读'])

    await page.keyboard.press('ControlOrMeta+Shift+G')
    await expect(stats).toBeHidden()
    await expect
      .poll(async () => (await request<{ content: { plain_text: string } }>(page, `/pages/${id}`)).content.plain_text)
      .toBe('Alpha beta gamma')
    await page.reload()
    await expect(editor).toHaveText('Alpha beta gamma')
    await expect(stats).toBeHidden()
    await page.keyboard.press('ControlOrMeta+Shift+G')
    await expect(stats).toBeVisible()
    await page.reload()
    await expectStats(stats, ['3 个词', '16 个字符', '1 个段落', '约 1 分钟阅读'])
    await editor.locator(':scope > p').first().click()
    await page.keyboard.press('ControlOrMeta+End')
    await page.keyboard.press('Enter')
    await page.keyboard.insertText('我们一起阅读文档。'.repeat(100))
    await expect
      .poll(async () => {
        const label = (await stats.locator('span').first().innerText()).replace(/[\u2066-\u2069,]/g, '')
        return Number.parseInt(label, 10)
      })
      .toBeGreaterThan(200)
    await expect
      .poll(async () => {
        const label = (await stats.locator('span').last().innerText()).replace(/[\u2066-\u2069,]/g, '')
        return Number(label.match(/\d+/)?.[0])
      })
      .toBeGreaterThan(1)
    await expect(stats).toHaveCSS('opacity', '1')
    await page.screenshot({ path: info.outputPath('document-editing-stats.png') })

    await page.keyboard.press('ControlOrMeta+Shift+I')
    const insights = page.getByRole('dialog', { name: '文档信息', exact: true })
    await expect(insights).toBeVisible()
    await expect(insights.getByRole('heading', { name: '贡献者', exact: true })).toBeVisible()
    const creator = insights
      .locator('.pod-document-contributors')
      .getByRole('listitem')
      .filter({ hasText: 'Browser owner' })
    await expect(creator).toHaveCount(1)
    await expect(creator.getByText('创建者', { exact: true })).toBeVisible()
    await expect(insights.locator('time')).toHaveCount(2)
    for (const time of await insights.locator('time').all()) {
      expect(Number.isNaN(Date.parse((await time.getAttribute('datetime'))!))).toBe(false)
    }
    await page.screenshot({ path: info.outputPath('document-insights.png') })
    await page.keyboard.press('Escape')
    await expect(insights).toBeHidden()
    await expect(actions(page)).toBeFocused()
    await actions(page).click()
    await expect(page.getByRole('menuitem', { name: /^文档信息/ })).toBeVisible()
    await page.screenshot({ path: info.outputPath('document-tools-menu.png') })
    await page.getByRole('menuitem', { name: /^文档信息/ }).click()
    await expect(insights).toBeVisible()
    await insights.getByRole('button', { name: '关闭', exact: true }).click()
    await expect(actions(page)).toBeFocused()
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('portable copies name embedded pages and an exported archive contains uploaded image and file bytes', async ({
  browser
}, info) => {
  const context = await browser.newContext({ permissions: ['clipboard-read', 'clipboard-write'] })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const imageBytes = readFileSync(new URL('../../../control_plane/test/fixtures/sessions/rgba.png', import.meta.url))
  const fileText = 'This attachment remains readable outside Ankole.\n'
  let id: string | undefined
  try {
    id = await createDocument(page)
    const editor = page.locator('.pod-document .editor-content')
    const title = page.getByRole('textbox', { name: '页面标题', exact: true })
    await title.fill('Portable resources')
    await title.press('Enter')
    await page.keyboard.insertText('Resources to keep')
    await page.keyboard.press('Enter')
    await page.keyboard.insertText('/媒体')
    await page.getByRole('option', { name: '媒体', exact: true }).click()
    await page.getByLabel('上传文件', { exact: true }).setInputFiles({
      name: 'chart 中文 #1.png',
      mimeType: 'image/png',
      buffer: imageBytes
    })
    await expect
      .poll(() =>
        editor
          .getByRole('img', { name: 'chart 中文 #1.png', exact: true })
          .evaluate((image: HTMLImageElement) => image.naturalWidth)
      )
      .toBeGreaterThan(0)

    await editor.locator(':scope > p').first().hover()
    await page.getByRole('button', { name: 'Block 菜单', exact: true }).click()
    await page.getByRole('menuitem', { name: '在下方添加 Block', exact: true }).click()
    await page.getByRole('menuitem', { name: '提及或引用', exact: true }).click()
    const picker = page.locator('.mention-menu')
    await expect(picker).toBeVisible()
    await page.keyboard.type('Browser report')
    await picker.getByRole('option').filter({ hasText: 'Browser report' }).first().click()
    await expect(editor.getByRole('link', { name: 'Browser report', exact: true })).toBeVisible()

    await editor.locator(':scope > p').first().click()
    await page.evaluate(text => {
      const transfer = new DataTransfer()
      transfer.items.add(new File([text], 'notes 中文 #1.txt', { type: 'text/plain' }))
      document
        .querySelector('.pod-document .editor-content')!
        .dispatchEvent(new ClipboardEvent('paste', { clipboardData: transfer, bubbles: true, cancelable: true }))
    }, fileText)
    await expect(
      page
        .getByRole('region', { name: '子页面', exact: true })
        .getByRole('link', { name: 'notes 中文 #1.txt', exact: true })
    ).toBeVisible()
    await editor.locator(':scope > p').first().hover()
    await page.getByRole('button', { name: 'Block 菜单', exact: true }).click()
    await page.getByRole('menuitem', { name: '在下方添加 Block', exact: true }).click()
    await page.getByRole('menuitem', { name: '嵌入多维表或应用', exact: true }).click()
    const embedDialog = page.getByRole('dialog', { name: '嵌入多维表或应用', exact: true })
    await embedDialog.getByRole('combobox', { name: '选择页面', exact: true }).fill('notes 中文 #1.txt')
    await embedDialog
      .getByRole('option')
      .filter({ has: page.getByText('notes 中文 #1.txt', { exact: true }) })
      .click()
    await expect(editor.getByRole('button', { name: 'notes 中文 #1.txt', exact: true })).toBeVisible()

    await submenu(page, '复制')
    await page.getByRole('menuitem', { name: '复制为 Markdown', exact: true }).click()
    await expect.poll(() => page.evaluate(() => navigator.clipboard.readText())).toContain('Resources to keep')
    const copied = await page.evaluate(() => navigator.clipboard.readText())
    expect(copied).toContain('Browser report')
    expect(copied).toContain(state.base_url + pageRoute(state.report_id))
    expect(copied).toContain('notes 中文 #1.txt')
    expect(copied).not.toContain('<embed')
    expect(copied).not.toContain('<mention')
    expect(copied).not.toContain('authentication_ref')

    await submenu(page, '复制')
    await page.getByRole('menuitem', { name: '复制为纯文本', exact: true }).click()
    await expect.poll(() => page.evaluate(() => navigator.clipboard.readText())).toContain('notes 中文 #1.txt (http')
    const plain = await page.evaluate(() => navigator.clipboard.readText())
    expect(plain).toContain('Browser report')
    expect(plain).not.toContain('[Browser report]')
    expect(plain).not.toContain('<mention')

    await submenu(page, '导出')
    const downloaded = page.waitForEvent('download')
    await page.getByRole('menuitem', { name: 'Markdown', exact: true }).click()
    const download = await downloaded
    expect(download.suggestedFilename()).toBe('Portable-resources.zip')
    const path = (await download.path())!
    const files = unzipSync(readFileSync(path))
    const markdown = strFromU8(files['Portable-resources.md']!)
    const tree = parseMarkdown(markdown)
    const destinations: string[] = []
    const visit = (node: typeof tree | (typeof tree.children)[number]) => {
      if (node.type === 'text') return
      if (node.name === 'img') destinations.push(node.attrs.src!)
      if (node.name === 'a') destinations.push(node.attrs.href!)
      node.children.forEach(visit)
    }
    visit(tree)
    const imagePath = destinations.find(path => path.startsWith('assets/') && path.endsWith('.png'))!
    const filePath = destinations.find(path => path.startsWith('assets/') && path.endsWith('.txt'))!
    expect(files[decodeURIComponent(imagePath)]).toEqual(new Uint8Array(imageBytes))
    expect(strFromU8(files[decodeURIComponent(filePath)]!)).toBe(fileText)
    expect(markdown).toContain(state.base_url + pageRoute(state.report_id))
    expect(markdown).not.toContain('/files/content?')
    expect(Object.keys(files)).toHaveLength(3)
    await info.attach('portable-resources.zip', { path, contentType: 'application/zip' })
    await expect(page.getByText('正在准备导出…', { exact: true })).toBeHidden()
    await expect(editor.getByRole('link', { name: 'Browser report', exact: true })).toBeVisible()
    await expect(editor.getByRole('button', { name: 'notes 中文 #1.txt', exact: true })).toBeVisible()
    await editor.getByRole('button', { name: 'notes 中文 #1.txt', exact: true }).scrollIntoViewIfNeeded()
    await expect(editor.getByRole('button', { name: 'notes 中文 #1.txt', exact: true })).toBeInViewport()
    // Hiding the caret mutates the editor's contenteditable widgets while the screenshot is taken.
    await page.screenshot({ path: info.outputPath('document-portable-resources.png'), caret: 'initial' })
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('Insights lists real readers, preserves anonymous counts, and limits reader names to editors', async ({
  browser
}, info) => {
  const ownerContext = await browser.newContext({ viewport: { width: 1280, height: 900 } })
  const memberContext = await browser.newContext()
  const viewerContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  await viewerContext.addCookies(state.viewer.cookies)
  const owner = await ownerContext.newPage()
  const member = await memberContext.newPage()
  const viewer = await viewerContext.newPage()
  let id: string | undefined
  const insights = (page: Page) => page.getByRole('dialog', { name: '文档信息', exact: true })
  try {
    id = await createDocument(owner)
    const sharing = await request<{ sharing_version: string }>(owner, `/pages/${id}/sharing`)
    await request(owner, `/pages/${id}/sharing`, 'PUT', {
      sharing_version: sharing.sharing_version,
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'edit' },
        { principal_uid: state.viewer.uid, role: 'view' }
      ]
    })
    for (const reader of [member, viewer]) {
      const recorded = reader.waitForResponse(
        response => response.request().method() === 'PUT' && response.url().endsWith(`/pages/${id}/user-state`)
      )
      await reader.goto(state.base_url + pageRoute(id))
      await expect(reader.locator('.pod-document .editor-content')).toBeVisible()
      expect((await recorded).status()).toBe(200)
    }
    await viewer.keyboard.press('ControlOrMeta+Shift+I')
    await expect(insights(viewer).getByText('仅文档编辑者和管理者可查看访问者名单。')).toBeVisible()
    await expect(insights(viewer).getByRole('list', { name: '访问者', exact: true })).toHaveCount(0)
    const visibility = insights(viewer).getByRole('switch', { name: /显示我的访问记录/ })
    await expect(visibility).toBeChecked()
    const savedPrivacy = viewer.waitForResponse(
      response => response.request().method() === 'PUT' && response.url().endsWith(`/pages/${id}/user-state`)
    )
    await visibility.click()
    await expect(visibility).not.toBeChecked()
    expect((await savedPrivacy).status()).toBe(200)
    await owner.keyboard.press('ControlOrMeta+Shift+I')
    await expect(insights(owner).getByRole('img', { name: '过去 30 天的活动' })).toBeVisible()
    const readers = insights(owner).getByRole('list', { name: '访问者', exact: true })
    await expect(readers.getByRole('listitem')).toHaveCount(2)
    await expect(readers.getByText('Browser member', { exact: true })).toBeVisible()
    await expect(readers.getByText('Browser viewer', { exact: true })).toHaveCount(0)
    await expect(readers.getByText(/最近访问：.*\d{4}/)).toHaveCount(2)
    await expect(insights(owner).getByText(/可见访问者：.*2.*人/)).toBeVisible()
    const activity = await request<{ daily: { views: number }[] }>(owner, `/pages/${id}/insights`)
    expect(activity.daily.reduce((sum, day) => sum + day.views, 0)).toBe(3)
    await owner.screenshot({ path: info.outputPath('insights-readers-desktop.png'), caret: 'initial' })
    await owner.setViewportSize({ width: 390, height: 844 })
    await expect(insights(owner)).toBeVisible()
    expect(await insights(owner).evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true)
    await owner.screenshot({ path: info.outputPath('insights-readers-mobile.png'), caret: 'initial' })
    await viewer.reload()
    await expect(viewer.locator('.pod-document .editor-content')).toBeVisible()
    await viewer.keyboard.press('ControlOrMeta+Shift+I')
    await expect(insights(viewer).getByRole('switch')).not.toBeChecked()
    const repeated = await request<{ daily: { views: number }[] }>(owner, `/pages/${id}/insights`)
    expect(repeated.daily.reduce((sum, day) => sum + day.views, 0)).toBe(3)
  } finally {
    if (id) await request(owner, `/pages/${id}`, 'DELETE')
    await Promise.all([ownerContext.close(), memberContext.close(), viewerContext.close()])
  }
})
