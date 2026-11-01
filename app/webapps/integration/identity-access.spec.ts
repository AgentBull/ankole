import { expect, test } from '@playwright/test'

const provider = {
  provider_id: 'directory',
  adapter_id: 'directory',
  plugin_id: 'fixture',
  config_key: 'fixture.directory',
  enabled: true,
  config: { appID: 'before', sync: { contacts: true } },
  stored_secret_paths: ['appSecret']
}

const principal = {
  id: 'human-one',
  type: 'principal',
  attributes: {
    type: 'human',
    status: 'active',
    display_name: 'Ada',
    email: 'ada@example.test'
  }
}

const access = () => ({
  uid: 'human-one',
  status: 'active',
  access_version: 1,
  access_revoked_at: null,
  restrictions: [] as Array<{
    id: string
    source: string
    disposition: string
    reason: string
    cleared_at: string | null
    recovery_verified_at: null
    inserted_at: string
  }>,
  history: [],
  work: [],
  cleanup_jobs: []
})

test('the identity editor saves v2 settings, keeps typed field errors, and reviews directory evidence', async ({
  page
}) => {
  let current = structuredClone(provider)
  let reviewed = false
  let writes = 0
  await page.route('**/api/v2/identity-provider-adapters', route =>
    route.fulfill({
      json: {
        identity_provider_adapters: [
          {
            adapter_id: 'directory',
            capabilities: ['directory_full_sync'],
            default_provider_id: 'directory',
            display_name: { default: 'Directory' },
            fields: [
              { path: 'appID', type: 'text', label: { default: 'Application ID' }, required: true },
              { path: 'appSecret', type: 'password', encrypted: true, label: { default: 'Application secret' } }
            ]
          }
        ]
      }
    })
  )
  await page.route('**/api/v2/identity-providers**', async route => {
    const path = new URL(route.request().url()).pathname
    if (route.request().method() === 'PUT') {
      writes++
      const data = route.request().postDataJSON().data
      expect(data.config.appID).toBe('updated')
      if (writes === 1) {
        return route.fulfill({
          status: 422,
          json: {
            errors: [
              { code: 'missing', detail: 'appID is required.', meta: { details: [{ path: 'appID', kind: 'missing' }] } }
            ]
          }
        })
      }
      current = { ...current, config: { ...current.config, appID: data.config.appID } }
      return route.fulfill({ json: { identity_provider: current } })
    }
    if (path.endsWith('/directory-reviews')) {
      expect(route.request().postDataJSON()).toEqual({
        data: { snapshot_fingerprint: 'snapshot-one', reason: 'Reviewed scope', confirm_removals: true }
      })
      reviewed = true
      return route.fulfill({ status: 201, json: { snapshot: null, events: [] } })
    }
    if (path.endsWith('/directory')) {
      return route.fulfill({
        json: {
          snapshot: {
            provider_id: 'directory',
            status: reviewed ? 'healthy' : 'review_required',
            snapshot_fingerprint: 'snapshot-one',
            missing_uids: reviewed ? [] : ['missing-person'],
            member_uids: ['present-person'],
            last_success_at: '2026-10-23T00:00:00Z'
          },
          events: []
        }
      })
    }
    return route.fulfill({ json: { identity_providers: [current] } })
  })
  await page.goto('/identity/directory')
  const appID = page.getByRole('textbox', { name: 'Application ID (required)', exact: true })
  await expect(appID).toHaveValue('before')
  await appID.fill('updated')
  await page.getByRole('button', { name: 'Save', exact: true }).click()
  await expect(page.getByRole('alert')).toContainText('Application ID')
  await expect(appID).toHaveValue('updated')
  await page.getByRole('button', { name: 'Save', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Save', exact: true })).toBeDisabled()
  await expect(page.getByText('missing-person', { exact: true })).toBeVisible()
  await page.getByLabel('Reason for this change (required)', { exact: true }).fill('Reviewed scope')
  await page
    .getByRole('checkbox', { name: 'I reviewed this snapshot and approve disabling the listed missing people.' })
    .check()
  await page.getByRole('button', { name: 'Approve snapshot', exact: true }).click()
  await expect(page.getByText('Healthy', { exact: true })).toBeVisible()
  await expect(page.getByText('missing-person', { exact: true })).toHaveCount(0)
})

test('Human access requires an explicit disposition and restores directly with a reason', async ({ page }) => {
  let state = access()
  await page.route(
    url => url.pathname.startsWith('/api/v2/'),
    async route => {
      const path = new URL(route.request().url()).pathname
      const data = route.request().postDataJSON()?.data
      if (path.endsWith('/identity-providers')) {
        return route.fulfill({ json: { identity_providers: [] } })
      }
      if (path.endsWith('/human-one/access-disables')) {
        expect(data.reason).toBe('Reviewed departure')
        expect(data.disposition).toBe('offboarded')
        expect(data.operation_id).toBeTruthy()
        state = {
          ...state,
          status: 'disabled',
          access_version: 2,
          restrictions: [
            {
              id: 'restriction-one',
              source: 'manual',
              disposition: data.disposition,
              reason: data.reason,
              cleared_at: null,
              recovery_verified_at: null,
              inserted_at: '2026-10-23T00:00:00Z'
            }
          ]
        }
        return route.fulfill({ status: 201, json: state })
      }
      if (path.endsWith('/access-restorations')) {
        expect(data.reason).toBe('Approved return')
        expect(Object.keys(data).sort()).toEqual(['operation_id', 'reason'])
        state = { ...state, status: 'active', restrictions: [] }
        return route.fulfill({ status: 201, json: state })
      }
      if (path.endsWith('/human-one/access')) return route.fulfill({ json: state })
      if (path.endsWith('/principals/human-one')) return route.fulfill({ json: { data: principal } })
      return route.fulfill({ json: { data: [] } })
    }
  )
  await page.goto('/access/principals/human-one')
  const offboardTrigger = page.getByRole('button', { name: 'Offboard member', exact: true })
  await offboardTrigger.click()
  const offboardDialog = page.getByRole('dialog', { name: 'Offboard member', exact: true })
  const confirmOffboard = offboardDialog.getByRole('button', { name: 'Offboard member', exact: true })
  await expect(confirmOffboard).toBeDisabled()
  await offboardDialog
    .getByRole('textbox', { name: 'Reason for this change (required)', exact: true })
    .fill('Reviewed departure')
  await offboardDialog
    .getByRole('checkbox', { name: 'I confirm this person should lose access and their future work should stop.' })
    .check()
  await confirmOffboard.click()
  await expect(offboardDialog).toHaveCount(0)
  const restore = page.getByRole('button', { name: 'Restore account', exact: true })
  await expect(restore).toBeEnabled()
  await page.getByRole('form', { name: 'Restore account' }).getByRole('textbox').fill('Approved return')
  await restore.click()
  await expect(restore).toHaveCount(0)
  await expect(offboardTrigger).toBeVisible()
})

test('the OIDC editor lists login sources and shows a rotated secret only in its result dialog', async ({ page }) => {
  await page.route(
    url => url.pathname.startsWith('/api/v2/'),
    route => {
      const path = new URL(route.request().url()).pathname
      if (path.endsWith('/login-sources')) {
        return route.fulfill({
          json: {
            sources: [
              { provider_id: 'email_otp', enabled: true },
              { provider_id: 'directory', enabled: false }
            ]
          }
        })
      }
      if (path.endsWith('/secret-rotations')) {
        return route.fulfill({ status: 201, json: { client_secret: 'rotated-client-secret' } })
      }
      if (path.endsWith('/oidc-clients/client-one')) {
        return route.fulfill({
          json: {
            data: {
              id: 'client-one',
              type: 'oidc_client',
              attributes: {
                name: 'Console client',
                client_type: 'confidential',
                enabled: true,
                redirect_uris: ['https://client.example.test/callback'],
                scopes: ['openid'],
                allowed_group_ids: [],
                model_aliases: {},
                allowed_identity_provider_ids: [],
                backchannel_logout_uri: null,
                backchannel_logout_session_required: true,
                post_logout_redirect_uris: [],
                allow_insecure_local_logout: false
              }
            }
          }
        })
      }
      return route.fulfill({ json: { data: [] } })
    }
  )
  await page.goto('/oidc-clients/client-one')
  await expect(page.getByText('email_otp', { exact: true })).toBeVisible()
  await expect(page.getByText('directory', { exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Rotate secret', exact: true }).click()
  const dialog = page.getByRole('dialog')
  await expect(dialog.getByText('rotated-client-secret', { exact: true })).toBeVisible()
  await dialog.getByRole('button', { name: 'Close', exact: true }).last().click()
  await expect(page.getByText('rotated-client-secret', { exact: true })).toHaveCount(0)
})
