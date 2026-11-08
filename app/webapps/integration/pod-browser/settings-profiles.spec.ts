import { expect, test } from '@playwright/test'
import { request, state } from './fixtures'

const pixel = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jB1kAAAAASUVORK5CYII=',
  'base64'
)

const picture = { name: 'profile.png', mimeType: 'image/png', buffer: pixel }

test('member and space avatars upload, persist after reload, and fit a narrow viewport', async ({ browser }) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto('/me')
    await expect(page.getByRole('heading', { name: '个人账号设置', exact: true })).toBeVisible()
    await page.getByLabel('上传新头像', { exact: true }).setInputFiles(picture)
    await expect(page.getByText('头像已更新。', { exact: true })).toBeVisible()

    const profile = await request<{ avatarURL: string }>(page, '/me')
    expect(profile.avatarURL).toContain('/api/v2/pod/avatars/member%3A')
    await page.reload()
    const memberImage = page.locator('img[data-slot="avatar-image"]')
    await expect(memberImage).toBeVisible()
    await expect(memberImage).toHaveAttribute('src', /authentication_ref=/)

    await page.goto('/settings')
    await expect(page.getByRole('heading', { name: '空间设置', exact: true })).toBeVisible()
    await page.getByLabel('上传新头像', { exact: true }).setInputFiles(picture)
    await expect(page.getByText('头像已更新。', { exact: true })).toBeVisible()

    const settings = await request<{ avatarURL: string }>(page, '/admin/settings')
    expect(settings.avatarURL).toContain('/api/v2/pod/avatars/space?v=')
    await page.reload()
    const spaceImage = page.locator('img[data-slot="avatar-image"]')
    await expect(spaceImage).toBeVisible()
    await expect(spaceImage).toHaveAttribute('src', /authentication_ref=/)
    await expect(page.locator('#space-name')).toHaveValue(state.tenant_name)

    await page.setViewportSize({ width: 390, height: 844 })
    await expect(page.getByRole('tab', { name: '常规与登录策略', exact: true })).toBeVisible()
    await expect(page.getByRole('button', { name: '上传新头像', exact: true })).toBeVisible()
    await expect(page.getByRole('tablist', { name: '空间设置分区', exact: true })).toHaveCSS('flex-direction', 'row')
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true)
  } finally {
    await context.close()
  }
})
