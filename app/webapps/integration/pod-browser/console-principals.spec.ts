import { expect, test, type Page } from '@playwright/test'
import type { GetHumanAccessResponse, GetPrincipalResponse } from '../../console/api/v2/generated/types.gen'
import type { CreatePodMemberResponse } from '../../pod/api/generated/types.gen'
import { state } from './fixtures'

// The fixture serves Pod and Console in their default zh-Hans-CN locale.
const podRoles = { guest: '外部访客', member: '正式成员' } as const
const podConvert = { guest: '改为外部访客', member: '改为正式成员' } as const
const consoleLabels = { guest: '访客', member: '成员' } as const

// Match the whole encoded uid segment, so `<uid>_assistant` rows stay out.
const rowLink = (page: Page, uid: string) => {
  const path = `/${encodeURIComponent(uid)}`
  return page.locator(`a[data-row-link][href$="${path}"], a[data-row-link][href*="${path}?"]`)
}

for (const membership of ['guest', 'member'] as const) {
  test(`Pod Settings manages ${membership} lifecycle while Site Console audits state and runs break-glass recovery`, async ({
    browser
  }, testInfo) => {
    expect(state.site_admin.tenant_id).not.toBe(state.tenant_id)
    const consoleContext = await browser.newContext()
    const podContext = await browser.newContext({ baseURL: state.base_url })
    await consoleContext.addCookies(state.site_admin.cookies)
    await podContext.addCookies(state.owner.cookies)
    const consolePage = await consoleContext.newPage()
    const podPage = await podContext.newPage()
    const podRoleLabel = podRoles[membership]
    const nextMembership = membership === 'guest' ? 'member' : 'guest'
    const nextPodRoleLabel = podRoles[nextMembership]
    const nextConsoleLabel = consoleLabels[nextMembership]
    const name = `Browser Console ${membership} ${Date.now()}`
    const email = `console-${membership}-${Date.now()}@example.com`
    const expectedPodSettingsHref = `${state.base_url.replace(/\/+$/, '')}/settings?section=members`

    try {
      // 1. Site Console scopes reads by data_tenant, omits routine creation actions, and links to Pod Settings.
      await consolePage.goto(`${state.console_url}/access/principals`)
      await expect(rowLink(consolePage, state.site_admin.uid)).toBeVisible()
      await consolePage.goto(`${state.console_url}/access/principals?data_tenant=${state.tenant_id}`)
      await expect(rowLink(consolePage, state.owner.uid)).toContainText('Browser owner')
      await expect(rowLink(consolePage, state.site_admin.uid)).toHaveCount(0)
      await expect(consolePage.getByRole('link', { name: '添加用户', exact: true })).toHaveCount(0)
      await expect(consolePage.getByRole('link', { name: '前往 Pod 设置 ↗', exact: true })).toHaveAttribute(
        'href',
        expectedPodSettingsHref
      )

      // 2. Pod Settings pre-creates the member, flips membership, and suspends access.
      await podPage.goto('/settings?section=members')
      await podPage.getByRole('button', { name: '预建待加入成员', exact: true }).click()
      await podPage.getByLabel('个人显示名', { exact: true }).fill(name)
      await podPage.getByLabel('邮箱地址', { exact: true }).fill(email)
      await podPage.getByRole('combobox', { name: '成员身份', exact: true }).click()
      await podPage.getByRole('option', { name: podRoleLabel, exact: true }).click()

      const createdResponse = podPage.waitForResponse(
        response =>
          new URL(response.url()).pathname === '/api/v2/pod/admin/members' && response.request().method() === 'POST'
      )
      await podPage.locator('form').getByRole('button', { name: '预建待加入成员', exact: true }).click()
      const createdHTTP = await createdResponse
      expect(createdHTTP.status()).toBe(201)
      const created = (await createdHTTP.json()) as CreatePodMemberResponse
      expect(created.uid).toEqual(expect.any(String))
      const uid = created.uid

      const memberCard = podPage.locator('[data-slot="card"]').filter({
        has: podPage.getByRole('heading', { name, exact: true })
      })
      await expect(memberCard).toContainText(podRoleLabel)

      const changedMembershipResponse = podPage.waitForResponse(
        response =>
          new URL(response.url()).pathname === `/api/v2/pod/admin/members/${encodeURIComponent(uid)}` &&
          response.request().method() === 'PATCH'
      )
      await memberCard.getByRole('button', { name: podConvert[nextMembership], exact: true }).click()
      expect((await changedMembershipResponse).status()).toBe(200)
      await expect(memberCard).toContainText(nextPodRoleLabel)

      await memberCard.getByRole('button', { name: '暂停访问', exact: true }).click()
      const suspendDialog = podPage.getByRole('dialog', { name: '暂停访问', exact: true })
      await suspendDialog.getByLabel('操作原因', { exact: true }).fill('Routine temporary suspension')
      const suspendedResponse = podPage.waitForResponse(
        response =>
          new URL(response.url()).pathname === `/api/v2/pod/admin/members/${encodeURIComponent(uid)}/restrictions` &&
          response.request().method() === 'POST'
      )
      await suspendDialog.getByRole('button', { name: '暂停访问', exact: true }).click()
      expect((await suspendedResponse).status()).toBe(201)
      await expect(suspendDialog).toHaveCount(0)

      // 3. Site Console audits the updated membership & restriction, then restores access via break-glass recovery.
      const detailPath = `/api/v2/principals/${encodeURIComponent(uid)}`
      const detailResponse = consolePage.waitForResponse(
        response => new URL(response.url()).pathname === detailPath && response.request().method() === 'GET'
      )
      const accessResponse = consolePage.waitForResponse(
        response => new URL(response.url()).pathname === `${detailPath}/access` && response.request().method() === 'GET'
      )
      await consolePage.goto(
        `${state.console_url}/access/principals/${encodeURIComponent(uid)}?data_tenant=${state.tenant_id}`
      )
      const detailHTTP = await detailResponse
      expect(detailHTTP.status()).toBe(200)
      expect(detailHTTP.request().headers()['x-ankole-tenant']).toBe(state.tenant_id)
      const detail = (await detailHTTP.json()) as GetPrincipalResponse
      expect(detail.data?.attributes).toMatchObject({
        display_name: name,
        email,
        membership: nextMembership,
        type: 'human',
        status: 'disabled'
      })
      const accessHTTP = await accessResponse
      expect(accessHTTP.status()).toBe(200)
      const access = (await accessHTTP.json()) as GetHumanAccessResponse
      expect(access.uid).toBe(uid)
      expect(access.status).toBe('disabled')

      await expect(consolePage.getByRole('heading', { name, exact: true })).toBeVisible()
      await expect(consolePage.getByText(nextConsoleLabel, { exact: true })).toBeVisible()
      await expect(consolePage.getByRole('link', { name: '前往 Pod 设置 ↗', exact: true })).toHaveAttribute(
        'href',
        expectedPodSettingsHref
      )
      await expect(consolePage.getByText('Routine temporary suspension', { exact: true })).toBeVisible()

      const restoreForm = consolePage.getByRole('form', { name: '恢复账户', exact: true })
      await restoreForm.getByRole('textbox').fill('Break-glass operator restoration')
      const restoredResponse = consolePage.waitForResponse(
        response =>
          new URL(response.url()).pathname === `${detailPath}/access-restorations` &&
          response.request().method() === 'POST'
      )
      await restoreForm.getByRole('button', { name: '恢复账户', exact: true }).click()
      const restoredHTTP = await restoredResponse
      expect(restoredHTTP.status()).toBe(201)
      expect(restoredHTTP.request().headers()['x-ankole-tenant']).toBe(state.tenant_id)
      await expect(consolePage.getByRole('form', { name: '应急授予 Pod 管理员', exact: true })).toBeVisible()
      await consolePage.screenshot({
        path: testInfo.outputPath(`console-${membership}-membership.png`),
        fullPage: true
      })
    } finally {
      await Promise.all([consoleContext.close(), podContext.close()])
    }
  })
}
