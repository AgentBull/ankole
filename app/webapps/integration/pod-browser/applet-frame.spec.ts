import { expect, test, type Locator } from '@playwright/test'
import { login, state, request, requestWithSharingVersion } from './fixtures'
import { pageRoute } from './routes'
import { PageSharingModel } from '../../pod/state/page-sharing'
import type { PageSharing } from '../../pod/content-api'
import type { PodPageSharingResponse } from '../../pod/api/generated/types.gen'

const draftStorage = (body: Locator) =>
  body.evaluate(() =>
    [localStorage, sessionStorage].map(storage => ({
      value: storage.getItem('layout'),
      property: storage.layout,
      keys: Object.keys(storage).sort(),
      length: storage.length,
      native: storage instanceof Storage,
      serialized: JSON.parse(JSON.stringify(storage))
    }))
  )

test('ESM chunks and Web Workers retain the original tab identity when another account becomes the browser default', async ({
  browser
}) => {
  const context = await browser.newContext()
  const original = await context.newPage()
  let id: string | undefined
  let title: string | undefined
  let submitted: { id: string; versions: Record<string, number> } | undefined
  try {
    await original.goto(state.base_url + pageRoute(state.report_id))
    await login(original, state.owner)
    await expect(original.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()
    id = state.applet_id
    await requestWithSharingVersion(original, `/pages/${id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'view' }
      ]
    })
    await original.goto(state.base_url + pageRoute(id))
    const frame = original.frameLocator('iframe')
    await expect(frame.getByRole('heading', { name: /Tracker v[12]/ })).toBeVisible()
    await expect
      .poll(() => frame.getByAltText('Applet logo').evaluate((image: HTMLImageElement) => image.naturalWidth))
      .toBe(16)
    const previousTheme = await original.evaluate(() => document.documentElement.dataset.theme)
    await original.evaluate(() => {
      document.documentElement.dataset.theme = 'dark'
    })
    await expect(frame.locator('html')).toHaveAttribute('data-theme', 'dark')
    await original.evaluate(theme => {
      if (theme) document.documentElement.dataset.theme = theme
      else delete document.documentElement.dataset.theme
    }, previousTheme)
    const auth = await original.locator('meta[name="ankole-authentication"]').getAttribute('content')
    const source = await original.locator('iframe').getAttribute('src')
    expect(source).toContain(`/pod/applet-frame/${auth}/${id}/`)
    const framePath = new URL(source!, state.base_url).pathname.replace(/index\.html$/, '')
    expect(await original.locator('meta[name="ankole-principal"]').getAttribute('content')).toBe(state.owner.uid)
    await frame.locator('body').evaluate(() => {
      for (const storage of [localStorage, sessionStorage]) {
        storage.clear()
        storage.layout = 'owner'
        storage.setItem('removed', 'discard')
        delete storage.removed
      }
    })
    expect(await draftStorage(frame.locator('body'))).toEqual(
      Array.from({ length: 2 }, () => ({
        value: 'owner',
        property: 'owner',
        keys: ['layout'],
        length: 1,
        native: true,
        serialized: { layout: 'owner' }
      }))
    )
    await frame.getByRole('button', { name: 'Local counter 0', exact: true }).click()
    await frame.getByRole('textbox', { name: 'Draft evaluation', exact: true }).fill('Unsubmitted owner evaluation')
    const titleInput = original.getByRole('textbox', { name: '页面标题', exact: true })
    title = await titleInput.inputValue()
    const refreshed = original.waitForResponse(
      response =>
        response.request().method() === 'GET' && new URL(response.url()).pathname === `/api/v2/pod/pages/${id}`
    )
    await titleInput.fill(`${title} refreshed`)
    await titleInput.press('Enter')
    expect((await (await refreshed).json()).page.title).toBe(`${title} refreshed`)
    await expect(frame.getByRole('button', { name: 'Local counter 1', exact: true })).toBeVisible()
    await expect(frame.getByRole('textbox', { name: 'Draft evaluation', exact: true })).toHaveValue(
      'Unsubmitted owner evaluation'
    )
    const loaded: string[] = []
    const apiAuthentications: (string | undefined)[] = []
    original.on('request', request => {
      if (request.url().includes('/pod/applet-frame/')) loaded.push(request.url())
      if (new URL(request.url()).pathname.startsWith('/api/v2/pod/tables/')) {
        apiAuthentications.push(request.headers()['x-ankole-authentication'])
      }
    })

    const second = await context.newPage()
    await second.goto(state.base_url + pageRoute(id))
    await expect(second.frameLocator('iframe').getByRole('heading', { name: /Tracker v[12]/ })).toBeVisible()
    await second
      .frameLocator('iframe')
      .locator('body')
      .evaluate(() => {
        sessionStorage.layout = 'second-tab-owner'
      })
    await second.getByRole('button', { name: /^账户菜单/ }).click()
    await second.getByRole('menuitem', { name: '切换或添加账户', exact: true }).click()
    await login(second, state.member)
    await expect(second.frameLocator('iframe').getByRole('heading', { name: /Tracker v[12]/ })).toBeVisible()
    const otherAuth = await second.locator('meta[name="ankole-authentication"]').getAttribute('content')
    expect(otherAuth).not.toBe(auth)
    expect(await second.locator('meta[name="ankole-principal"]').getAttribute('content')).toBe(state.member.uid)
    await expect(second.frameLocator('iframe').getByRole('heading', { name: /Tracker v[12]/ })).toBeVisible()
    expect(
      (await draftStorage(second.frameLocator('iframe').locator('body'))).every(value => value.value === null)
    ).toBe(true)
    await second
      .frameLocator('iframe')
      .locator('body')
      .evaluate(() => {
        localStorage.layout = 'member'
        sessionStorage.layout = 'member'
      })
    await second.reload()
    await expect(second.frameLocator('iframe').getByRole('heading', { name: /Tracker v[12]/ })).toBeVisible()
    expect((await draftStorage(second.frameLocator('iframe').locator('body'))).map(value => value.value)).toEqual([
      'member',
      'member'
    ])
    await second.goto(state.base_url + pageRoute(state.runtime_test_applet_id))
    await expect(second.frameLocator('iframe').getByRole('heading', { name: /Tracker v[12]/ })).toBeVisible()
    expect(
      (await draftStorage(second.frameLocator('iframe').locator('body'))).every(value => value.value === null)
    ).toBe(true)
    await second
      .frameLocator('iframe')
      .locator('body')
      .evaluate(() => {
        localStorage.layout = 'other-applet'
        sessionStorage.layout = 'other-applet'
      })
    await second.goto(state.base_url + pageRoute(id))
    await expect(second.frameLocator('iframe').getByRole('heading', { name: /Tracker v[12]/ })).toBeVisible()
    expect((await draftStorage(second.frameLocator('iframe').locator('body'))).map(value => value.value)).toEqual([
      'member',
      'member'
    ])
    await original.bringToFront()
    expect((await draftStorage(frame.locator('body'))).map(value => value.value)).toEqual(['owner', 'owner'])
    await frame.getByRole('button', { name: 'Load details', exact: true }).click()
    await expect(frame.locator('.applet-details')).toHaveText('Details module loaded')
    await frame.getByRole('button', { name: 'Run worker', exact: true }).click()
    await expect(frame.locator('.applet-worker')).toContainText(framePath)
    await expect(frame.locator('.applet-worker')).toHaveText(/\/assets\/calculation\.worker-[^/]+\.js:5$/)
    await frame.getByRole('button', { name: 'Run WASM', exact: true }).click()
    await expect(frame.locator('.applet-wasm')).toHaveText('5')
    expect(loaded.length).toBeGreaterThanOrEqual(3)
    const saved = original.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/v2/pod/tables/${state.table_id}/records`
    )
    await frame.getByRole('button', { name: 'Add sample', exact: true }).click()
    const response = await saved
    expect(response.status()).toBe(201)
    const record = (await response.json()).records[0] as {
      id: string
      versions: Record<string, number>
      created_by: string
    }
    submitted = record
    expect(record.created_by).toBe(`ankole:${state.tenant_id}:principal/${state.owner.uid}`)
    expect(apiAuthentications.length).toBeGreaterThan(0)
    expect(apiAuthentications.every(reference => reference === auth)).toBe(true)
    expect(loaded.every(url => new URL(url).pathname.startsWith(framePath))).toBe(true)
    await expect(frame.getByRole('button', { name: 'Local counter 1', exact: true })).toBeVisible()
    await expect(frame.getByRole('textbox', { name: 'Draft evaluation', exact: true })).toHaveValue(
      'Unsubmitted owner evaluation'
    )
    expect(await original.locator('iframe').getAttribute('sandbox')).toBeNull()

    const denied = await second.evaluate(async id => {
      const auth = document.querySelector<HTMLMetaElement>('meta[name="ankole-authentication"]')!.content
      const response = await fetch(`/api/v2/pod/pages/${id}/files/content?path=src%2Fmain.tsx`, {
        headers: { 'x-ankole-authentication': auth },
        credentials: 'same-origin'
      })
      return response.status
    }, id)
    expect(denied).toBe(403)
  } finally {
    if (id && title !== undefined) await request(original, `/pages/${id}`, 'PATCH', { title })
    if (submitted) {
      await request(original, `/tables/${state.table_id}/records`, 'POST', {
        deletes: [{ id: submitted.id, expected_versions: submitted.versions }]
      })
    }
    if (id) {
      await requestWithSharingVersion(original, `/pages/${id}/sharing`, 'PUT', {
        inherit_permissions: true,
        grants: []
      })
    }
    await context.close()
  }
})

test('an Applet viewer submits according to target permissions without losing local form state', async ({
  browser
}) => {
  const ownerContext = await browser.newContext()
  const memberContext = await browser.newContext()
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const owner = await ownerContext.newPage()
  const member = await memberContext.newPage()
  let submitted: { id: string; versions: Record<string, number> } | undefined
  let restoreReport: PageSharing | undefined
  let restoreBase: PageSharing | undefined
  try {
    await owner.goto(state.base_url + pageRoute(state.applet_id))
    await member.goto(state.base_url + pageRoute(state.base_id))
    const base = await request<{ actions: string[] }>(member, `/pages/${state.base_id}`)
    expect(base.actions).toContain('page_write_records')
    const originalBase = new PageSharingModel()
    originalBase.initialize(await request<PodPageSharingResponse>(owner, `/pages/${state.base_id}/sharing`))
    restoreBase = originalBase.body()
    const share = (role: 'view' | 'contribute') =>
      requestWithSharingVersion(owner, `/pages/${state.base_id}/sharing`, 'PUT', {
        inherit_permissions: false,
        grants: [
          { principal_uid: state.owner.uid, role: 'manage' },
          { principal_uid: state.member.uid, role }
        ]
      })
    await requestWithSharingVersion(owner, `/pages/${state.applet_id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'view' }
      ]
    })
    await share('contribute')
    await member.goto(state.base_url + pageRoute(state.applet_id))
    const button = member.frameLocator('iframe').getByRole('button', { name: 'Add sample', exact: true })
    const restricted = await request<{ role: string; actions: string[] }>(member, `/pages/${state.applet_id}`)
    expect(restricted.role).toBe('view')
    expect(restricted.actions).not.toContain('page_write_records')
    await expect(button).toBeEnabled()
    const frame = member.frameLocator('iframe')
    const draft = frame.getByRole('textbox', { name: 'Draft evaluation', exact: true })
    await draft.fill('Unsubmitted member evaluation')
    await frame.getByRole('button', { name: 'Local counter 0', exact: true }).click()
    await frame.locator('body').evaluate(() => {
      localStorage.layout = 'permission-draft'
      sessionStorage.layout = 'permission-draft'
    })
    await share('view')
    const rejected = member.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/v2/pod/tables/${state.table_id}/records`
    )
    await button.click()
    expect((await rejected).status()).toBe(403)
    await expect(frame.getByRole('alert')).toHaveText('Write rejected')
    await expect(draft).toBeEditable()
    await expect(draft).toHaveValue('Unsubmitted member evaluation')
    await expect(frame.getByRole('button', { name: 'Local counter 1', exact: true })).toBeVisible()
    await share('contribute')
    await expect(button).toBeEnabled()
    await expect(draft).toBeEditable()
    await expect(draft).toHaveValue('Unsubmitted member evaluation')
    await expect(frame.getByRole('button', { name: 'Local counter 1', exact: true })).toBeVisible()
    const saved = member.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/v2/pod/tables/${state.table_id}/records`
    )
    await button.click()
    const response = await saved
    expect(response.status()).toBe(201)
    submitted = (await response.json()).records[0] as { id: string; versions: Record<string, number> }
    await share('view')
    await expect(draft).toHaveValue('Unsubmitted member evaluation')
    await expect(frame.getByRole('button', { name: 'Local counter 1', exact: true })).toBeVisible()
    const ancestor = new PageSharingModel()
    ancestor.initialize(await request<PodPageSharingResponse>(owner, `/pages/${state.report_id}/sharing`))
    restoreReport = ancestor.body()
    const memberIndex = ancestor.draft.value!.grants.findIndex(
      grant => grant.principal_uid === state.member.uid && (grant.condition ?? 'true') === 'true'
    )
    expect(memberIndex).toBeGreaterThanOrEqual(0)
    await requestWithSharingVersion(owner, `/pages/${state.base_id}/sharing`, 'PUT', {
      inherit_permissions: true,
      grants: []
    })
    ancestor.update(memberIndex, { role: 'view' })
    await requestWithSharingVersion(owner, `/pages/${state.report_id}/sharing`, 'PUT', ancestor.body())
    const target = await request<{ actions: string[] }>(member, `/pages/${state.base_id}`)
    expect(target.actions).not.toContain('page_write_records')
    await expect(draft).toBeEditable()
    await expect(draft).toHaveValue('Unsubmitted member evaluation')
    await expect(frame.getByRole('button', { name: 'Local counter 1', exact: true })).toBeVisible()
    ancestor.update(memberIndex, { role: 'contribute' })
    await requestWithSharingVersion(owner, `/pages/${state.report_id}/sharing`, 'PUT', ancestor.body())
    await expect(button).toBeEnabled()
    await expect(draft).toBeEditable()
    await expect(draft).toHaveValue('Unsubmitted member evaluation')
    await expect(frame.getByRole('button', { name: 'Local counter 1', exact: true })).toBeVisible()
    expect((await draftStorage(frame.locator('body'))).every(value => value.value === 'permission-draft')).toBe(true)
  } finally {
    if (restoreReport) {
      await requestWithSharingVersion(owner, `/pages/${state.report_id}/sharing`, 'PUT', restoreReport)
    }
    if (submitted) {
      await request(owner, `/tables/${state.table_id}/records`, 'POST', {
        deletes: [{ id: submitted.id, expected_versions: submitted.versions }]
      })
    }
    if (restoreBase) {
      await requestWithSharingVersion(owner, `/pages/${state.base_id}/sharing`, 'PUT', restoreBase)
    }
    await requestWithSharingVersion(owner, `/pages/${state.applet_id}/sharing`, 'PUT', {
      inherit_permissions: true,
      grants: []
    })
    await Promise.all([ownerContext.close(), memberContext.close()])
  }
})

test('a rejected table write preserves the Applet draft until Page access is revoked', async ({ browser }) => {
  const ownerContext = await browser.newContext({ baseURL: state.base_url })
  const memberContext = await browser.newContext({ baseURL: state.base_url })
  await ownerContext.addCookies(state.owner.cookies)
  await memberContext.addCookies(state.member.cookies)
  const owner = await ownerContext.newPage()
  const member = await memberContext.newPage()
  const appletSharing = new PageSharingModel()
  const baseSharing = new PageSharingModel()
  try {
    await owner.goto(pageRoute(state.applet_id))
    appletSharing.initialize(await request<PodPageSharingResponse>(owner, `/pages/${state.applet_id}/sharing`))
    baseSharing.initialize(await request<PodPageSharingResponse>(owner, `/pages/${state.base_id}/sharing`))
    await requestWithSharingVersion(owner, `/pages/${state.base_id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'view' }
      ]
    })
    await requestWithSharingVersion(owner, `/pages/${state.applet_id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [
        { principal_uid: state.owner.uid, role: 'manage' },
        { principal_uid: state.member.uid, role: 'view' }
      ]
    })
    await member.goto(pageRoute(state.applet_id))
    const frame = member.frameLocator('iframe')
    const draft = frame.getByRole('textbox', { name: 'Draft evaluation', exact: true })
    await draft.fill('Keep this evaluation after a rejected write')
    await frame.getByRole('button', { name: 'Local counter 0', exact: true }).click()
    const rejected = member.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === `/api/v2/pod/tables/${state.table_id}/records`
    )
    await frame.getByRole('button', { name: 'Submit sample', exact: true }).click()
    expect((await rejected).status()).toBe(403)
    await expect(member.getByRole('button', { name: '重新加载小程序', exact: true })).toBeVisible()
    await expect(member.locator('iframe')).toHaveCount(1)
    await expect(frame.getByText('Write rejected', { exact: true })).toBeVisible()
    await expect(draft).toHaveValue('Keep this evaluation after a rejected write')
    await expect(frame.getByRole('button', { name: 'Local counter 1', exact: true })).toBeVisible()

    await requestWithSharingVersion(owner, `/pages/${state.applet_id}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [{ principal_uid: state.owner.uid, role: 'manage' }]
    })
    await expect(member.locator('iframe')).toHaveCount(0)
    await expect(member.getByRole('button', { name: '重新加载小程序', exact: true })).toHaveCount(0)
  } finally {
    if (appletSharing.body()) {
      await requestWithSharingVersion(owner, `/pages/${state.applet_id}/sharing`, 'PUT', appletSharing.body())
    }
    if (baseSharing.body()) {
      await requestWithSharingVersion(owner, `/pages/${state.base_id}/sharing`, 'PUT', baseSharing.body())
    }
    await Promise.all([ownerContext.close(), memberContext.close()])
  }
})
