import { expect, test, type Page } from '@playwright/test'
import { login, request, state } from './fixtures'
import { pageRoute } from './routes'

test('self rename keeps this tab identity and self-management restrictions current', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const renamed = `rename-${Date.now()}@example.com`
  try {
    await page.goto(`${state.base_url}/settings`)
    await page.getByRole('tab', { name: '成员与管理员', exact: true }).click()
    const self = page
      .locator('[data-slot="card"]')
      .filter({ has: page.getByRole('heading', { name: 'Browser owner', exact: true }) })
    await expect(self.getByRole('button', { name: '暂停访问', exact: true })).toBeDisabled()
    await self.getByRole('button', { name: '更改 UID', exact: true }).click()
    const dialog = page.getByRole('dialog')
    await dialog.getByLabel('新 UID', { exact: true }).fill(renamed)
    await dialog.getByRole('button', { name: '更改 UID', exact: true }).click()
    await expect(dialog).toBeHidden()
    await expect(page.locator('meta[name="ankole-principal"]')).toHaveAttribute('content', renamed)
    expect((await identity(page)).principalUID).toBe(renamed)
    await expect(self.getByRole('button', { name: '暂停访问', exact: true })).toBeDisabled()
    await expect(self.getByRole('button', { name: '办理离职', exact: true })).toBeDisabled()
  } finally {
    try {
      if ((await identity(page)).principalUID === renamed) {
        await request(page, `/admin/members/${encodeURIComponent(renamed)}/rename`, 'POST', {
          new_uid: state.owner.uid
        })
      }
    } finally {
      await context.close()
    }
  }
})

async function identity(page: Page) {
  return page.evaluate(async () => {
    const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)!.content
    const response = await fetch('/api/v2/browser/session', {
      headers: {
        'x-ankole-authentication': meta('ankole-authentication'),
        'x-ankole-pod': meta('ankole-pod')
      }
    })
    if (!response.ok) throw new Error(`Pinned identity: ${response.status}`)
    return (await response.json()) as { principalUID: string }
  })
}

test('account and Pod settings keep this tab identity after another tab signs in as a different member', async ({
  browser
}) => {
  const context = await browser.newContext()
  const owner = await context.newPage()
  const member = await context.newPage()
  try {
    const original = state.base_url + pageRoute(state.report_id)
    await owner.goto(original)
    await login(owner, state.owner)
    await expect(owner.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()

    await member.goto(original)
    await member.getByRole('button', { name: /^账户菜单/ }).click()
    await member.getByRole('menuitem', { name: '切换或添加账户', exact: true }).click()
    await login(member, state.member)
    await expect(member.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()
    expect((await identity(member)).principalUID).toBe(state.member.uid)

    await owner.getByRole('button', { name: /^账户菜单/ }).click()
    await owner.getByRole('menuitem', { name: '个人账号设置', exact: true }).click()
    await expect(owner).toHaveURL(new URL('/me', state.base_url).href)
    await expect(owner.getByRole('heading', { name: '个人账号设置', exact: true })).toBeVisible()
    expect((await identity(owner)).principalUID).toBe(state.owner.uid)
    expect((await request<{ displayName: string }>(owner, '/me')).displayName).toBe('Browser owner')

    await owner.getByRole('link', { name: '空间设置', exact: true }).click()
    await expect(owner).toHaveURL(new URL('/settings', state.base_url).href)
    await expect(owner.getByRole('heading', { name: '空间设置', exact: true })).toBeVisible()
    const settings = await request<{ displayName: string }>(owner, '/admin/settings')
    await expect(owner.locator('#space-name')).toHaveValue(settings.displayName)
    expect((await identity(owner)).principalUID).toBe(state.owner.uid)
    expect((await identity(member)).principalUID).toBe(state.member.uid)
  } finally {
    await context.close()
  }
})
