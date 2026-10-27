import { expect, test } from '@playwright/test'
import type {
  ChangeHumanMembershipResponse,
  CreateMemberResponse,
  GetHumanAccessResponse,
  GetPrincipalResponse
} from '../../console/api/v2/generated/types.gen'
import { state } from './fixtures'

for (const membership of ['guest', 'member'] as const) {
  test(`a site administrator creates a ${membership} in another data tenant and changes its membership`, async ({
    browser
  }, testInfo) => {
    expect(state.site_admin.tenant_id).not.toBe(state.tenant_id)
    const context = await browser.newContext()
    await context.addCookies(state.site_admin.cookies)
    const page = await context.newPage()
    const label = membership === 'guest' ? '访客' : '成员'
    const nextMembership = membership === 'guest' ? 'member' : 'guest'
    const nextLabel = nextMembership === 'member' ? '成员' : '访客'
    const name = `Browser Console ${membership} ${Date.now()}`
    const email = `console-${membership}-${Date.now()}@example.com`
    try {
      await page.goto(`${state.console_url}/access/principals`)
      await expect(page.locator(`a[data-row-link][href$="/${state.site_admin.uid}"]`)).toBeVisible()
      await page.goto(`${state.console_url}/access/principals?data_tenant=${state.tenant_id}`)
      await expect(page.locator(`a[data-row-link][href$="/${state.owner.uid}"]`)).toContainText('Browser owner')
      await expect(page.locator(`a[data-row-link][href$="/${state.site_admin.uid}"]`)).toHaveCount(0)

      await page.getByRole('link', { name: '添加用户', exact: true }).click()
      await page.getByRole('textbox', { name: /^显示名称/ }).fill(name)
      await page.getByRole('textbox', { name: /^邮箱/ }).fill(email)
      await page.getByRole('combobox', { name: '成员身份', exact: true }).click()
      await page.getByRole('option', { name: label, exact: true }).click()
      const createdResponse = page.waitForResponse(
        response => new URL(response.url()).pathname === '/api/v2/principals' && response.request().method() === 'POST'
      )
      const detailResponse = page.waitForResponse(
        response =>
          /^\/api\/v2\/principals\/[^/]+$/.test(new URL(response.url()).pathname) &&
          response.request().method() === 'GET'
      )
      const accessResponse = page.waitForResponse(
        response =>
          /^\/api\/v2\/principals\/[^/]+\/access$/.test(new URL(response.url()).pathname) &&
          response.request().method() === 'GET'
      )
      await page.getByRole('button', { name: '创建用户', exact: true }).click()
      const createdHTTP = await createdResponse
      expect(createdHTTP.status()).toBe(201)
      expect(createdHTTP.request().headers()['x-ankole-tenant']).toBe(state.tenant_id)
      const created = (await createdHTTP.json()) as CreateMemberResponse
      expect(created).toEqual({ uid: expect.any(String), email })
      const uid = created.uid
      const detailPath = `/api/v2/principals/${uid}`
      const detailHTTP = await detailResponse
      expect(new URL(detailHTTP.url()).pathname).toBe(detailPath)
      expect(detailHTTP.status()).toBe(200)
      const detail = (await detailHTTP.json()) as GetPrincipalResponse
      expect(detail.data?.attributes).toMatchObject({
        display_name: name,
        email,
        membership,
        type: 'human',
        status: 'active'
      })
      const accessHTTP = await accessResponse
      expect(new URL(accessHTTP.url()).pathname).toBe(`${detailPath}/access`)
      expect(accessHTTP.status()).toBe(200)
      const access = (await accessHTTP.json()) as GetHumanAccessResponse
      expect(access.uid).toBe(uid)
      expect(access.access_version).toBe(1)
      await expect(page.getByRole('heading', { name, exact: true })).toBeVisible()
      const section = page.locator('section').filter({
        has: page.getByRole('heading', { name: '成员身份', exact: true })
      })
      await expect(section.getByText(label, { exact: true })).toBeVisible()
      await section.getByRole('button', { name: `转为${nextLabel}`, exact: true }).click()
      const changedResponse = page.waitForResponse(
        response =>
          new URL(response.url()).pathname === `${detailPath}/membership` && response.request().method() === 'PATCH'
      )
      const changedAccessResponse = page.waitForResponse(
        response => new URL(response.url()).pathname === `${detailPath}/access` && response.request().method() === 'GET'
      )
      await page
        .getByRole('dialog')
        .getByRole('button', { name: `转为${nextLabel}`, exact: true })
        .click()
      const changedHTTP = await changedResponse
      expect(changedHTTP.status()).toBe(200)
      expect(changedHTTP.request().headers()['x-ankole-tenant']).toBe(state.tenant_id)
      const changed = (await changedHTTP.json()) as ChangeHumanMembershipResponse
      expect(changed.data?.attributes?.membership).toBe(nextMembership)
      const changedAccessHTTP = await changedAccessResponse
      expect(changedAccessHTTP.status()).toBe(200)
      const changedAccess = (await changedAccessHTTP.json()) as GetHumanAccessResponse
      expect(changedAccess.access_version).toBe(access.access_version + 1)
      await expect(section.getByText(nextLabel, { exact: true })).toBeVisible()

      const persistedResponse = page.waitForResponse(
        response => new URL(response.url()).pathname === detailPath && response.request().method() === 'GET'
      )
      const persistedAccessResponse = page.waitForResponse(
        response => new URL(response.url()).pathname === `${detailPath}/access` && response.request().method() === 'GET'
      )
      await page.reload()
      const persistedHTTP = await persistedResponse
      expect(persistedHTTP.status()).toBe(200)
      expect(persistedHTTP.request().headers()['x-ankole-tenant']).toBe(state.tenant_id)
      const persisted = (await persistedHTTP.json()) as GetPrincipalResponse
      expect(persisted.data?.attributes).toMatchObject({
        display_name: name,
        email,
        membership: nextMembership
      })
      const persistedAccessHTTP = await persistedAccessResponse
      expect(persistedAccessHTTP.status()).toBe(200)
      const persistedAccess = (await persistedAccessHTTP.json()) as GetHumanAccessResponse
      expect(persistedAccess.access_version).toBe(changedAccess.access_version)
      await expect(section.getByText(nextLabel, { exact: true })).toBeVisible()
      await expect(section.getByRole('button', { name: `转为${label}`, exact: true })).toBeVisible()
      await page.screenshot({ path: testInfo.outputPath(`console-${membership}-membership.png`), fullPage: true })
    } finally {
      await context.close()
    }
  })
}
