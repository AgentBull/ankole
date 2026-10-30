import { expect, test } from '@playwright/test'
import { request, requestWithSharingVersion, state } from './fixtures'
import { pageRoute } from './routes'

const suffix = () => crypto.randomUUID().slice(0, 8)

test('a leaf Doc hides subpages UI, while a Hub Doc appends a Feishu-style collapsible subpages directory and persists its view metadata', async ({
  browser
}) => {
  const ownerContext = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1365, height: 900 } })
  await ownerContext.addCookies(state.owner.cookies)
  const page = await ownerContext.newPage()

  const viewerContext = await browser.newContext({ baseURL: state.base_url, viewport: { width: 1365, height: 900 } })
  await viewerContext.addCookies(state.viewer.cookies)
  const viewerPage = await viewerContext.newPage()

  try {
    await page.goto(pageRoute(state.report_id))
    const hubTitle = `Knowledge Hub ${suffix()}`
    const createdHub = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'doc',
      title: hubTitle,
      private_owner_uid: state.owner.uid
    })
    const hubID = createdHub.page.id

    const leafChildRequests: string[] = []
    page.on('request', req => {
      const url = new URL(req.url())
      if (url.pathname.endsWith('/pages/children') && url.searchParams.get('parent_id') === hubID) {
        leafChildRequests.push(req.url())
      }
    })

    await page.goto(pageRoute(hubID))
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(hubTitle)

    // Leaf Doc: no header subpages button, no bottom subpages region, and zero /pages/children requests.
    await expect(page.locator('.pod-page-header').getByRole('button', { name: '子页面' })).toHaveCount(0)
    await expect(page.locator('[data-pod-subpages]')).toHaveCount(0)
    expect(leafChildRequests).toHaveLength(0)

    // Grant viewer read-only access on the private Hub container so we can also verify viewer behavior.
    await requestWithSharingVersion(page, `/pages/${hubID}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.viewer.uid, role: 'view' }
      ]
    })

    // Create a child Doc with body text so Grid excerpt preview and List columns have real content.
    const specTitle = `Design Spec ${suffix()}`
    const childDoc = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'doc',
      parent_id: hubID,
      title: specTitle
    })
    await request(page, `/pages/${childDoc.page.id}/content`, 'PUT', {
      base_revision: 0,
      xml: '<page><p> Key architecture decisions and rollout milestones. </p></page>'
    })

    await page.reload()
    const subpages = page.locator('[data-pod-subpages]')
    await expect(subpages).toBeVisible()
    await expect(subpages.getByRole('button', { name: '子页面', exact: true })).toBeVisible()
    await expect(subpages.locator('[data-slot="badge"]')).toHaveCount(0)
    await expect(subpages.getByRole('link', { name: specTitle, exact: true })).toBeVisible()

    // Pure directory Doc for editors: 1-line compact body placeholder (no 420px void), and clicking below subpages does not focus the editor.
    const editorBox = (await page.locator('.pod-document .editor-content').boundingBox())!
    expect(editorBox.height).toBeLessThan(60)
    const subpagesBox = (await subpages.boundingBox())!
    await page.mouse.click(subpagesBox.x + 40, subpagesBox.y + subpagesBox.height + 40)
    await expect(page.locator('.pod-document .editor-content')).not.toBeFocused()

    // Upload a file directly from the subpages bar without leaving the current Doc.
    const uploadInput = subpages.locator('input[type="file"]')
    await uploadInput.setInputFiles({
      name: 'rollout-checklist.txt',
      mimeType: 'text/plain',
      buffer: Buffer.from('Step 1: ship control-plane contract\n')
    })
    await expect(subpages.getByRole('link', { name: 'rollout-checklist.txt', exact: true })).toBeVisible()
    await expect(page).toHaveURL(state.base_url + pageRoute(hubID))

    // Configure visible fields in Display Settings: enable Created time and move it above Modified time.
    await subpages.getByRole('button', { name: '显示设置', exact: true }).click()
    const popover = page.locator('[data-slot="popover-content"]')
    await expect(popover.getByText('显示字段列表', { exact: true })).toBeVisible()
    await popover.getByRole('button', { name: /^显示.*创建时间/ }).click()
    await popover.getByRole('button', { name: /^上移.*创建时间/ }).click()
    await page.keyboard.press('Escape')

    const headerCells = subpages.locator('thead th')
    await expect(headerCells.nth(0)).toContainText('名称')
    await expect(headerCells.nth(1)).toContainText('创建者')
    await expect(headerCells.nth(2)).toContainText('创建时间')
    await expect(headerCells.nth(3)).toContainText('修改时间')

    // Switch to Grid view and verify Doc excerpt + File badge cards render and persist across reload.
    await subpages.getByRole('button', { name: '切换视图', exact: true }).click()
    await page.getByRole('menuitemradio', { name: '宫格', exact: true }).click()
    await expect(subpages.getByText('Key architecture decisions and rollout milestones.')).toBeVisible()
    await expect(subpages.getByText('TXT', { exact: true })).toBeVisible()
    await expect(subpages.getByRole('button', { name: '显示设置', exact: true })).toBeDisabled()

    // Collapse the subpages bar: verify count badge, subtle reduced opacity, and persistence across reload with zero child fetches.
    const patchedCollapse = page.waitForResponse(
      res => res.request().method() === 'PATCH' && new URL(res.url()).pathname === `/api/v2/pod/pages/${hubID}`
    )
    await subpages.getByRole('button', { name: '子页面', exact: true }).click()
    expect((await patchedCollapse).status()).toBe(200)
    await expect(subpages).toHaveAttribute('data-collapsed', '')
    await expect(subpages).toHaveClass(/opacity-55/)
    await expect(subpages.locator('[data-slot="badge"]')).toHaveText('2')

    leafChildRequests.length = 0
    await page.reload()
    await expect(subpages).toHaveAttribute('data-collapsed', '')
    expect(leafChildRequests).toHaveLength(0)

    // Read-only viewer can expand and switch views locally in session memory without issuing PATCH requests.
    const viewerPatchRequests: string[] = []
    viewerPage.on('request', req => {
      if (req.method() === 'PATCH' && new URL(req.url()).pathname === `/api/v2/pod/pages/${hubID}`) {
        viewerPatchRequests.push(req.url())
      }
    })
    await viewerPage.goto(pageRoute(hubID))
    const viewerSubpages = viewerPage.locator('[data-pod-subpages]')
    await expect(viewerSubpages).toHaveAttribute('data-collapsed', '')
    // Read-only viewer on a blank pure-directory Doc hides the empty body and top divider.
    await expect(viewerPage.locator('.pod-document .editor-content')).toBeHidden()
    await expect(viewerSubpages).not.toHaveClass(/border-t/)
    await viewerSubpages.getByRole('button', { name: /子页面/ }).click()
    await expect(viewerSubpages).not.toHaveClass(/border-t/)
    await expect(viewerSubpages.getByRole('link', { name: specTitle, exact: true })).toBeVisible()
    await expect(viewerSubpages.getByRole('button', { name: '上传', exact: true })).toHaveCount(0)
    await expect(viewerSubpages.getByRole('button', { name: '新建', exact: true })).toHaveCount(0)

    await viewerSubpages.getByRole('button', { name: '切换视图', exact: true }).click()
    await viewerPage.getByRole('menuitemradio', { name: '列表', exact: true }).click()
    await expect(viewerSubpages.locator('table')).toBeVisible()

    // Column sort + reset directory order work locally without mutating server metadata.
    await viewerSubpages.locator('thead').getByRole('button', { name: '名称', exact: true }).click()
    await expect(viewerSubpages.getByRole('button', { name: '恢复目录顺序', exact: true })).toBeVisible()
    await viewerSubpages.getByRole('button', { name: '恢复目录顺序', exact: true }).click()
    await expect(viewerSubpages.getByRole('button', { name: '恢复目录顺序', exact: true })).toHaveCount(0)
    expect(viewerPatchRequests).toHaveLength(0)

    // Owner expands subpages and creates a new child Doc from [+ 新建], navigating into the new child.
    await subpages.getByRole('button', { name: /子页面/ }).click()
    await subpages.getByRole('button', { name: '新建', exact: true }).click()
    await page.getByRole('menuitem', { name: '文档', exact: true }).click()
    await expect(page).not.toHaveURL(state.base_url + pageRoute(hubID))
    await expect(page.locator('.pod-page-header').getByRole('link', { name: hubTitle, exact: true })).toBeVisible()
  } finally {
    await ownerContext.close()
    await viewerContext.close()
  }
})
