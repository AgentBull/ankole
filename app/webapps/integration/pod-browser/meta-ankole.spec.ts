import { readFileSync } from 'node:fs'
import { zipSync, strToU8 } from 'fflate'
import { expect, test, type Page } from '@playwright/test'
import { request, requestResponse, state } from './fixtures'

const metaSection = (page: Page) => page.getByRole('region', { name: 'Meta Ankole', exact: true })
const metaToggle = (page: Page) => metaSection(page).getByRole('button', { name: 'Meta Ankole', exact: true })

test('Brain creates an object in its ontology category and opens it from the filtered graph', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const title = `Graph acceptance ${Date.now()}`
  let id: string | undefined
  try {
    await page.goto(`${state.base_url}/meta/brain`)
    await page.getByRole('combobox', { name: '本体分类', exact: true }).click()
    await page.getByRole('option', { name: 'notes', exact: true }).click()
    const created = page.waitForResponse(
      response => response.request().method() === 'POST' && new URL(response.url()).pathname.endsWith('/pod/pages')
    )
    await page.getByRole('button', { name: '新建知识条目', exact: true }).click()
    const response = await created
    expect(response.status()).toBe(201)
    id = (await response.json()).page.id
    await expect(page).toHaveURL(`${state.base_url}/meta/brain/${id}`)
    const input = page.getByRole('textbox', { name: '页面标题', exact: true })
    await input.fill(title)
    await input.press('Enter')
    await expect
      .poll(async () => (await request<{ page: { title: string } }>(page, `/pages/${id}`)).page.title)
      .toBe(title)
    await expect(metaToggle(page)).toHaveAttribute('aria-expanded', 'false')
    await metaToggle(page).click()
    await metaSection(page).getByRole('link', { name: '组织知识库', exact: true }).click()
    await page.getByRole('textbox', { name: '查找知识条目', exact: true }).fill(title)
    const graph = page.getByRole('group', { name: '知识图谱', exact: true })
    await expect(graph.getByRole('link')).toHaveCount(1)
    const popup = context.waitForEvent('page')
    await graph.getByRole('link', { name: title, exact: true }).click({ modifiers: ['ControlOrMeta'] })
    const opened = await popup
    await expect(opened).toHaveURL(`${state.base_url}/meta/brain/${id}`)
    await expect(page).toHaveURL(`${state.base_url}/meta/brain`)
    await opened.close()
    await graph.getByRole('link', { name: title, exact: true }).click()
    await expect(page).toHaveURL(`${state.base_url}/meta/brain/${id}`)
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(title)
    await expect(metaSection(page).getByRole('button', { name: '组织知识库', exact: true })).toHaveAttribute(
      'aria-expanded',
      'false'
    )
  } finally {
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})

test('Meta branches stay collapsed while an administrator creates, edits and binds a complete Skill', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let slug = `browser-meta-${Date.now()}`
  let created = false
  try {
    await page.goto(`${state.base_url}/meta/skills`)
    const navigation = metaSection(page)
    await expect(metaToggle(page)).toHaveAttribute('aria-expanded', 'false')
    await metaToggle(page).click()
    for (const name of ['组织知识库', '技能', '智能体']) {
      await expect(navigation.getByRole('button', { name, exact: true })).toHaveAttribute('aria-expanded', 'false')
    }
    await page.getByRole('button', { name: '新建技能', exact: true }).click()
    await page.getByRole('textbox', { name: '技能包标识', exact: true }).fill(slug)
    await page.getByRole('textbox', { name: '名称', exact: true }).fill('Browser acceptance Skill')
    await page.getByRole('textbox', { name: '描述', exact: true }).fill('Read the package reference when needed.')
    await page.getByRole('button', { name: '创建', exact: true }).click()
    await expect(page).toHaveURL(`${state.base_url}/meta/skills/${slug}`)
    created = true
    await expect(navigation.getByRole('button', { name: '技能', exact: true })).toHaveAttribute(
      'aria-expanded',
      'false'
    )

    await page.getByRole('button', { name: '编辑', exact: true }).click()
    await page.getByRole('textbox', { name: '文档编辑器', exact: true }).fill('Read scripts/run.sh before starting.')
    await page.getByRole('button', { name: '保存', exact: true }).click()
    await expect(page.getByRole('button', { name: '编辑', exact: true })).toBeVisible()
    await page.getByLabel('上传文件', { exact: true }).setInputFiles({
      name: 'run.sh',
      mimeType: 'text/x-shellscript',
      buffer: Buffer.from('#!/bin/sh\nprintf acceptance')
    })
    await page.getByRole('textbox', { name: '包内路径', exact: true }).fill('scripts/run.sh')
    await page.getByRole('switch', { name: '可执行脚本', exact: true }).check()
    await page.getByRole('button', { name: '上传或替换', exact: true }).click()
    await expect(page.getByRole('link', { name: 'scripts/run.sh', exact: true })).toBeVisible()

    const assistant = page.getByRole('switch', { name: '我的助理', exact: true })
    const colleagues = page.getByRole('combobox', { name: 'AI 同事', exact: true })
    const all = page.getByRole('switch', { name: '为所有 Agent 开启', exact: true })
    await assistant.click()
    await expect(assistant).toBeChecked()
    await expect(assistant).toBeEnabled()
    await all.click()
    await expect(assistant).toBeDisabled()
    await expect(colleagues).toBeDisabled()
    await expect(all).toBeEnabled()
    await all.click()
    await expect(assistant).toBeEnabled()
    await expect(assistant).toBeChecked()
    await expect(colleagues).toBeEnabled()

    await navigation.getByRole('button', { name: '技能', exact: true }).click()
    const branch = navigation.getByRole('button', { name: slug, exact: true })
    await expect(branch).toHaveAttribute('aria-expanded', 'false')
    await branch.click()
    const folder = navigation.getByRole('button', { name: 'scripts', exact: true }).first()
    await expect(folder).toHaveAttribute('aria-expanded', 'false')
    await folder.first().click()
    await navigation.getByRole('link', { name: 'run.sh', exact: true }).click()
    await expect(navigation.locator('a[aria-current="page"]')).toHaveCount(1)
    await expect(page.getByRole('textbox', { name: 'scripts/run.sh', exact: true })).toHaveValue(
      '#!/bin/sh\nprintf acceptance'
    )
    const fileSection = page
      .locator('section')
      .filter({ has: page.getByRole('heading', { name: 'scripts/run.sh', exact: true }) })
    const script = fileSection.getByRole('textbox')
    await script.fill('#!/bin/sh\nprintf local-draft')
    const beforeConflict = await request<{ skill: { revision: number } }>(page, `/meta/skills/${slug}`)
    await request(page, `/meta/skills/${slug}/file`, 'PUT', {
      path: 'scripts/run.sh',
      content_base64: Buffer.from('#!/bin/sh\nprintf remote-edit').toString('base64'),
      content_type: 'text/x-shellscript',
      mode: 365,
      base_revision: beforeConflict.skill.revision
    })
    await fileSection.getByRole('button', { name: '保存', exact: true }).click()
    await expect(fileSection.getByRole('button', { name: '放弃草稿并加载最新内容', exact: true })).toBeVisible()
    await expect(script).toHaveValue('#!/bin/sh\nprintf local-draft')
    await fileSection.getByRole('button', { name: '加载最新版本用于对比', exact: true }).click()
    await expect(script).toHaveValue('#!/bin/sh\nprintf local-draft')
    await fileSection.getByRole('button', { name: '保存', exact: true }).click()
    await expect(fileSection.getByRole('status')).toHaveText('已保存。')
    await page.reload()
    await expect(navigation.getByRole('button', { name: '技能', exact: true })).toHaveAttribute(
      'aria-expanded',
      'false'
    )
    await expect(page.getByRole('link', { name: 'SKILL.md', exact: true }).first()).toBeVisible()
    await expect(page.getByRole('textbox', { name: 'scripts/run.sh', exact: true })).toHaveValue(
      '#!/bin/sh\nprintf local-draft'
    )
    await page.screenshot({ path: test.info().outputPath('meta-skill-collapsed.png') })
    await page.getByRole('link', { name: 'SKILL.md', exact: true }).first().click()
    await page.getByRole('button', { name: '编辑', exact: true }).click()
    const renamed = `${slug}-renamed`
    await page.getByRole('textbox', { name: '技能包标识', exact: true }).fill(renamed)
    const missing: string[] = []
    page.on('response', response => {
      if (response.status() === 404) missing.push(response.url())
    })
    await page.getByRole('button', { name: '保存', exact: true }).click()
    await expect(page).toHaveURL(`${state.base_url}/meta/skills/${renamed}`)
    slug = renamed
    await expect(page.getByRole('button', { name: '编辑', exact: true })).toBeVisible()
    expect(missing).toEqual([])
  } finally {
    if (created) {
      const detail = await request<{ skill: { revision: number } }>(page, `/meta/skills/${slug}`)
      await request(page, `/meta/skills/${slug}?base_revision=${detail.skill.revision}`, 'DELETE')
    }
    await context.close()
  }
})

test('switching between cached Skills does not carry an editor draft into another package', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const slugs = [`draft-a-${Date.now()}`, `draft-b-${Date.now()}`]
  try {
    await page.goto(`${state.base_url}/meta/skills`)
    for (const slug of slugs) {
      await request(page, '/meta/skills', 'POST', {
        slug,
        manifest_xml: `<page><p>Original ${slug}</p></page>`,
        metadata: { name: slug, description: 'A separate Skill package' }
      })
    }
    await page.reload()
    const navigation = metaSection(page)
    await expect(metaToggle(page)).toHaveAttribute('aria-expanded', 'false')
    await metaToggle(page).click()
    await navigation.getByRole('button', { name: '技能', exact: true }).click()
    const open = async (slug: string) => {
      await navigation.getByRole('link', { name: slug, exact: true }).click()
      await expect(page.getByRole('heading', { name: slug, exact: true })).toBeVisible()
    }
    await open(slugs[1])
    await open(slugs[0])
    await page.getByRole('textbox', { name: '包内路径', exact: true }).fill('references/package-a.md')
    await page.getByRole('button', { name: '编辑', exact: true }).click()
    await page.getByRole('textbox', { name: '文档编辑器', exact: true }).fill('Unsaved draft from package A')
    await page.getByRole('textbox', { name: '技能包标识', exact: true }).fill('unsaved-slug-a')
    await navigation.getByRole('link', { name: slugs[1], exact: true }).click()
    await page.getByRole('button', { name: '放弃修改并离开', exact: true }).click()
    await expect(page.getByRole('heading', { name: slugs[1], exact: true })).toBeVisible()
    await expect(page.getByRole('textbox', { name: '包内路径', exact: true })).toHaveValue('')
    await expect(page.getByRole('button', { name: '编辑', exact: true })).toBeVisible({ timeout: 5000 })
    await expect(page.getByText(`Original ${slugs[1]}`, { exact: true })).toBeVisible()
    await page.getByRole('button', { name: '编辑', exact: true }).click()
    await expect(page.getByRole('textbox', { name: '技能包标识', exact: true })).toHaveValue('')
    await expect(page.getByRole('textbox', { name: '技能包标识', exact: true })).toHaveAttribute(
      'placeholder',
      slugs[1]
    )
    await page.getByRole('textbox', { name: '文档编辑器', exact: true }).fill('Updated package B')
    await page.getByRole('button', { name: '保存', exact: true }).click()
    await expect(page.getByRole('button', { name: '编辑', exact: true })).toBeVisible()
    const first = await request<{ skill: { manifest_markdown: string } }>(page, `/meta/skills/${slugs[0]}`)
    expect(first.skill.manifest_markdown).toContain(`Original ${slugs[0]}`)
    const second = await request<{ skill: { metadata: { name: string }; manifest_markdown: string } }>(
      page,
      `/meta/skills/${slugs[1]}`
    )
    expect(second.skill.metadata.name).toBe(slugs[1])
    expect(second.skill.manifest_markdown).toContain('Updated package B')
    await page.screenshot({ path: test.info().outputPath('meta-skill-draft-isolation.png') })
  } finally {
    for (const slug of slugs) {
      const detail = await request<{ skill: { revision: number } }>(page, `/meta/skills/${slug}`)
      await request(page, `/meta/skills/${slug}?base_revision=${detail.skill.revision}`, 'DELETE')
    }
    await context.close()
  }
})

test('Agent contracts save through the Pod editor and retain the selected mode', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(`${state.base_url}/meta/agents/assistant`)
    const contract = page
      .locator('section')
      .filter({ has: page.getByRole('heading', { name: 'DESIGN.md', exact: true }) })
    await contract.getByRole('button', { name: '编辑', exact: true }).click()
    await contract.getByRole('combobox').click()
    await page.getByRole('option', { name: '在全局基础上追加', exact: true }).click()
    await contract.getByRole('textbox', { name: '文档编辑器', exact: true }).fill('Use clear diagrams when they help.')
    await contract.getByRole('button', { name: '保存', exact: true }).click()
    await expect(contract.getByRole('button', { name: '编辑', exact: true })).toBeVisible()
    await page.reload()
    await expect(contract.getByRole('combobox')).toContainText('在全局基础上追加')
    await expect(contract.getByText('Use clear diagrams when they help.', { exact: true })).toBeVisible()
    await expect(metaToggle(page)).toHaveAttribute('aria-expanded', 'false')
    await metaToggle(page).click()
    await expect(metaSection(page).getByRole('button', { name: '智能体', exact: true })).toHaveAttribute(
      'aria-expanded',
      'false'
    )
    await contract.getByRole('button', { name: '编辑', exact: true }).click()
    await contract.getByRole('combobox').click()
    await page.getByRole('option', { name: '完全覆盖全局', exact: true }).click()
    await contract.getByRole('button', { name: '取消', exact: true }).click()
    await expect(contract.getByRole('combobox')).toContainText('在全局基础上追加')
  } finally {
    await context.close()
  }
})

test('a new member imports a package, edits its files without expanding the sidebar and configures their own assistant', async ({
  browser
}) => {
  const context = await browser.newContext()
  await context.addCookies(state.member.cookies)
  const page = await context.newPage()
  const slug = `member-package-${Date.now()}`
  const binary = Uint8Array.from([0, 255, 42, 128, 1])
  let created = false
  try {
    await page.goto(`${state.base_url}/meta/skills`)
    await page.getByRole('button', { name: '导入技能包', exact: true }).click()
    await expect(page.getByRole('textbox', { name: '名称', exact: true })).toHaveCount(0)
    await page.getByRole('textbox', { name: '技能包标识', exact: true }).fill(slug)
    await page.getByLabel('技能包（.zip）', { exact: true }).setInputFiles({
      name: `${slug}.zip`,
      mimeType: 'application/zip',
      buffer: Buffer.from(
        zipSync({
          'package/SKILL.md': strToU8(
            '---\nname: Member package\ndescription: Read references/rules.md when needed.\n---\nUse the package reference.'
          ),
          'package/references/rules.md': strToU8('Original package rule.'),
          'package/assets/sample.bin': binary
        })
      )
    })
    await page.getByRole('button', { name: '创建', exact: true }).click()
    await expect(page).toHaveURL(`${state.base_url}/meta/skills/${slug}`)
    created = true
    await expect(metaToggle(page)).toHaveAttribute('aria-expanded', 'false')
    await expect(page.getByRole('switch', { name: '为所有 Agent 开启', exact: true })).toBeDisabled()
    const assistant = page.getByRole('switch', { name: '我的助理', exact: true })
    await expect(assistant).not.toBeChecked()
    await assistant.click()
    await expect(assistant).toBeChecked()

    await page.getByRole('link', { name: 'references/rules.md', exact: true }).click()
    const editor = page.getByRole('textbox', { name: 'references/rules.md', exact: true })
    await editor.fill('Updated by a member in the main workspace.')
    await page.getByRole('button', { name: '保存', exact: true }).click()
    await expect(page.getByRole('status')).toHaveText('已保存。')
    await page.reload()
    await expect(editor).toHaveValue('Updated by a member in the main workspace.')
    await expect(assistant).toBeChecked()
    await expect(metaToggle(page)).toHaveAttribute('aria-expanded', 'false')

    const binaryRow = page
      .locator('li')
      .filter({ has: page.getByRole('link', { name: 'assets/sample.bin', exact: true }) })
    const downloading = page.waitForEvent('download')
    await binaryRow.getByRole('button', { name: '下载', exact: true }).click()
    const download = await downloading
    expect(readFileSync((await download.path())!)).toEqual(Buffer.from(binary))

    const referenceRow = page
      .locator('li')
      .filter({ has: page.getByRole('link', { name: 'references/rules.md', exact: true }) })
    await referenceRow.getByRole('button', { name: '重命名', exact: true }).click()
    await referenceRow.getByRole('textbox').fill('references/team.md')
    await referenceRow.getByRole('button', { name: '保存', exact: true }).click()
    await expect(page.getByRole('textbox', { name: 'references/team.md', exact: true })).toHaveValue(
      'Updated by a member in the main workspace.'
    )
    await page
      .locator('li')
      .filter({ has: page.getByRole('link', { name: 'references/team.md', exact: true }) })
      .getByRole('button', { name: '删除', exact: true })
      .click()
    await page.getByRole('dialog').getByRole('button', { name: '删除', exact: true }).click()
    await expect(page.getByRole('heading', { name: 'SKILL.md', exact: true })).toBeVisible()
    await expect(page.getByRole('alert')).toHaveCount(0)

    await page.goto(`${state.base_url}/meta/skills`)
    await page.getByRole('searchbox', { name: '查找技能', exact: true }).fill(slug)
    await expect(page.locator('article')).toHaveCount(1)
    await page.getByRole('link', { name: 'Member package', exact: true }).click()
    await expect(page).toHaveURL(`${state.base_url}/meta/skills/${slug}`)

    await page.goto(`${state.base_url}/meta/agents/assistant`)
    await expect(page.getByRole('textbox', { name: '显示名称', exact: true })).toBeVisible()
    await page.getByRole('textbox', { name: '显示名称', exact: true }).fill('My configured assistant')
    await page.getByRole('button', { name: '保存', exact: true }).click()
    await expect(page.getByRole('status')).toHaveText('已保存。')
    await page
      .locator('summary')
      .filter({ hasText: /当前生效的.*DESIGN\.md/ })
      .click()
    await expect(page.locator('details[open] > div')).toContainText(/\S/)
    await page.reload()
    await expect(page.getByRole('textbox', { name: '显示名称', exact: true })).toHaveValue('My configured assistant')
    await page.setViewportSize({ width: 390, height: 844 })
    await expect(page.getByRole('textbox', { name: '显示名称', exact: true })).toBeVisible()
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)
    await expect(page.getByRole('button', { name: '展开侧栏', exact: true })).toHaveCount(1)
    await page.screenshot({ path: test.info().outputPath('member-assistant-mobile.png') })
    await page.mouse.move(190, 650)
    await page.mouse.wheel(0, 2400)
    await expect(page.locator('summary').filter({ hasText: /当前生效的.*DESIGN\.md/ })).toBeInViewport()
    await page.screenshot({ path: test.info().outputPath('member-assistant-mobile-scrolled.png') })

    const own = await request<{ uid: string }>(page, '/personal-assistant', 'POST')
    const otherContext = await browser.newContext()
    try {
      await otherContext.addCookies(state.viewer.cookies)
      const other = await otherContext.newPage()
      await other.goto(`${state.base_url}/meta/skills/${slug}`)
      await expect(other.getByRole('switch', { name: '我的助理', exact: true })).not.toBeChecked()
      expect((await requestResponse(other, `/meta/agents/${own.uid}`)).status).toBe(403)
    } finally {
      await otherContext.close()
    }
  } finally {
    if (created) {
      const detail = await request<{ skill: { revision: number } }>(page, `/meta/skills/${slug}`)
      await request(page, `/meta/skills/${slug}?base_revision=${detail.skill.revision}`, 'DELETE')
    }
    await context.close()
  }
})

test('an administrator creates an AI colleague entirely inside Meta Ankole', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const uid = `meta-colleague-${Date.now()}`
  try {
    await page.goto(`${state.base_url}/meta/agents`)
    await page.getByRole('button', { name: '创建 AI 同事', exact: true }).click()
    await page.getByRole('textbox', { name: '唯一名称', exact: true }).fill(uid)
    await page.getByRole('textbox', { name: '显示名称', exact: true }).fill('采购顾问')
    await page.getByRole('textbox', { name: '角色职责', exact: true }).fill('比较供应商报价并维护采购知识')
    await page.getByRole('button', { name: '创建', exact: true }).click()
    await expect(page).toHaveURL(`${state.base_url}/meta/agents/colleagues/${uid}`)
    await expect(page.getByRole('heading', { name: '采购顾问', exact: true })).toBeVisible()
    await expect(page.getByRole('combobox', { name: '指令模式', exact: true })).toHaveCount(2)
    const actual = await request<{ uid: string; role: string }>(page, `/meta/agents/${uid}`)
    expect(actual.uid).toBe(uid)
    expect(actual.role).toBe('比较供应商报价并维护采购知识')
    await page.getByRole('textbox', { name: '显示名称', exact: true }).fill('采购助手')
    await page.getByRole('button', { name: '保存', exact: true }).click()
    await expect(page.getByRole('heading', { name: '采购助手', exact: true })).toBeVisible()
    await page.reload()
    await expect(page.getByRole('textbox', { name: '显示名称', exact: true })).toHaveValue('采购助手')
    await expect(metaToggle(page)).toHaveAttribute('aria-expanded', 'false')
    await metaToggle(page).click()
    await expect(metaSection(page).getByRole('button', { name: '智能体', exact: true })).toHaveAttribute(
      'aria-expanded',
      'false'
    )
  } finally {
    await context.close()
  }
})

for (const uid of ['assistant', 'global']) {
  test(`a colleague named ${uid} has its own identity and contracts`, async ({ browser }) => {
    const context = await browser.newContext()
    await context.addCookies(state.owner.cookies)
    const page = await context.newPage()
    const displayName = `Literal ${uid} colleague`
    try {
      await page.goto(`${state.base_url}/meta/agents`)
      const existing = await requestResponse(page, `/meta/agents/${uid}`)
      if (existing.status === 404) {
        await page.getByRole('button', { name: '创建 AI 同事', exact: true }).click()
        await page.getByRole('textbox', { name: '唯一名称', exact: true }).fill(uid)
        await page.getByRole('textbox', { name: '显示名称', exact: true }).fill(displayName)
        await page.getByRole('textbox', { name: '角色职责', exact: true }).fill('Review the package')
        await page.getByRole('button', { name: '创建', exact: true }).click()
      } else {
        expect(existing.status).toBe(200)
        await page.getByRole('link', { name: new RegExp(displayName) }).click()
      }
      await expect(page).toHaveURL(`${state.base_url}/meta/agents/colleagues/${uid}`)
      await expect(page.getByRole('heading', { name: displayName, exact: true })).toBeVisible()
      await page
        .getByRole('navigation', { name: 'Meta Ankole 模块', exact: true })
        .getByRole('link', { name: '智能体', exact: true })
        .click()
      await page.getByRole('link', { name: new RegExp(displayName) }).click()
      await expect(page).toHaveURL(`${state.base_url}/meta/agents/colleagues/${uid}`)
      const baseline = await request(page, '/meta/contracts')
      const contract = page
        .locator('section')
        .filter({ has: page.getByRole('heading', { name: 'AGENTS.md', exact: true }) })
      await contract.getByRole('button', { name: '编辑', exact: true }).click()
      await contract.getByRole('combobox').click()
      await page.getByRole('option', { name: '完全覆盖全局', exact: true }).click()
      await contract.getByRole('textbox', { name: '文档编辑器', exact: true }).fill(`Only the literal ${uid} colleague`)
      await contract.getByRole('button', { name: '保存', exact: true }).click()
      await expect(contract.getByRole('button', { name: '编辑', exact: true })).toBeVisible()
      expect(await request(page, '/meta/contracts')).toEqual(baseline)
      await page.reload()
      await expect(contract).toContainText(`Only the literal ${uid} colleague`)
      const navigation = metaSection(page)
      await expect(metaToggle(page)).toHaveAttribute('aria-expanded', 'false')
      await metaToggle(page).click()
      await expect(navigation.getByRole('button', { name: '智能体', exact: true })).toHaveAttribute(
        'aria-expanded',
        'false'
      )
      await navigation.getByRole('button', { name: '智能体', exact: true }).click()
      await navigation.getByRole('link', { name: uid === 'global' ? '全局设置' : '我的助理', exact: true }).click()
      await expect(page).toHaveURL(`${state.base_url}/meta/agents/${uid}`)
      await expect(
        page.getByRole('heading', { name: uid === 'global' ? '全局设置' : '我的助理', exact: true })
      ).toBeVisible()
      await expect(page.getByText(`Only the literal ${uid} colleague`, { exact: true })).toHaveCount(0)
      await page
        .getByRole('navigation', { name: 'Meta Ankole 模块', exact: true })
        .getByRole('link', { name: '智能体', exact: true })
        .click()
      await expect(page.getByRole('heading', { name: '智能体', exact: true })).toBeVisible()
      await page.screenshot({ path: test.info().outputPath('meta-agents-list.png') })
      await page
        .getByRole('main')
        .getByRole('link', { name: uid === 'global' ? '全局设置' : '我的助理', exact: true })
        .click()
      await expect(page).toHaveURL(`${state.base_url}/meta/agents/${uid}`)
    } finally {
      await context.close()
    }
  })
}
