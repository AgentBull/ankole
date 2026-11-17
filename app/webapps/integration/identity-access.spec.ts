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

const tenant = {
  id: 'tenant-one',
  type: 'tenant',
  attributes: {
    slug: 'harbor',
    display_name: 'Harbor Space',
    status: 'active',
    pod_origin: 'https://harbor.pod.example'
  }
}

test('the Console identity page shows read-only audit state, links to Pod Settings, and reflects fresh refetches', async ({
  page
}) => {
  let current = structuredClone(provider)
  await page.route('**/api/v2/site/**', route => {
    const path = new URL(route.request().url()).pathname
    if (path.endsWith('/privileged-tenant')) return route.fulfill({ json: { data: tenant } })
    if (path.endsWith('/tenants')) return route.fulfill({ json: { data: [tenant] } })
    return route.fulfill({ json: { data: [] } })
  })
  await page.route('**/api/v2/principals**', route => route.fulfill({ json: { data: [principal] } }))
  await page.route('**/api/v2/connectors/catalog', route => route.fulfill({ json: { connectors: [] } }))
  await page.route('**/api/v2/connector-auth-configs', route => route.fulfill({ json: { connections: [] } }))
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
  await page.route('**/api/v2/identity-providers**', route => {
    const path = new URL(route.request().url()).pathname
    if (path.endsWith('/directory')) {
      return route.fulfill({
        json: {
          snapshot: {
            provider_id: 'directory',
            status: 'review_required',
            snapshot_fingerprint: 'snapshot-one',
            missing_uids: ['missing-person'],
            member_uids: ['human-one'],
            last_success_at: '2026-10-23T00:00:00Z'
          },
          events: [
            {
              id: 'ev-1',
              event_id: 'ext-ev-1',
              event_type: 'user.removed',
              status: 'dismissed',
              external_ids: ['ext-user-99'],
              reason: 'Directory webhook removal',
              review_reason: 'Reviewed in Pod Settings',
              reviewed_by: { tenant_id: 'tenant-one', uid: 'human-one' },
              inserted_at: '2026-10-23T00:05:00Z'
            }
          ]
        }
      })
    }
    return route.fulfill({ json: { identity_providers: [current] } })
  })

  await page.goto('/identity/directory')
  const podSettingsLink = page.getByRole('link', { name: 'Open in Pod Settings ↗', exact: true })
  await expect(podSettingsLink).toHaveAttribute('href', 'https://harbor.pod.example/settings?section=providers')

  const appID = page.getByRole('textbox', { name: 'Application ID (required)', exact: true })
  await expect(appID).toHaveValue('before')
  await expect(appID).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Save', exact: true })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Approve snapshot', exact: true })).toHaveCount(0)
  await expect(page.getByText('Review required', { exact: true })).toBeVisible()
  await expect(page.getByText('missing-person', { exact: true })).toBeVisible()
  await expect(page.getByText(/Reviewed in Pod Settings/)).toBeVisible()

  // Simulate an update committed in Pod Settings, then re-enter the detail page and verify no frozen Signal draft lags.
  current = { ...current, config: { ...current.config, appID: 'updated-in-pod' } }
  await page.getByRole('link', { name: 'Back', exact: true }).click()
  await page.getByRole('link', { name: 'directory', exact: true }).click()
  await expect(appID).toHaveValue('updated-in-pod')
})

test('Human access exposes break-glass Pod administrator recovery and account restoration while linking routine actions to Pod Settings', async ({
  page
}) => {
  let state = access()
  const recoveredAdminReasons: string[] = []
  await page.route('**/api/v2/site/**', route => {
    const path = new URL(route.request().url()).pathname
    if (path.endsWith('/privileged-tenant')) return route.fulfill({ json: { data: tenant } })
    if (path.endsWith('/tenants')) return route.fulfill({ json: { data: [tenant] } })
    return route.fulfill({ json: { data: [] } })
  })
  await page.route(
    url => url.pathname.startsWith('/api/v2/') && !url.pathname.startsWith('/api/v2/site/'),
    async route => {
      const path = new URL(route.request().url()).pathname
      const data = route.request().postDataJSON()?.data
      if (path.endsWith('/identity-providers')) {
        return route.fulfill({ json: { identity_providers: [] } })
      }
      if (path.endsWith('/human-one/pod-admin-recoveries')) {
        expect(data.reason).toBe('All Pod admins locked out')
        expect(data.operation_id).toBeTruthy()
        recoveredAdminReasons.push(data.reason)
        // Simulate subsequent Pod Settings offboarding so we can also exercise break-glass account restoration.
        state = {
          ...state,
          status: 'disabled',
          access_version: 2,
          restrictions: [
            {
              id: 'restriction-one',
              source: 'manual',
              disposition: 'offboarded',
              reason: 'Reviewed departure',
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
  const podSettingsLink = page.getByRole('link', { name: 'Open in Pod Settings ↗', exact: true })
  await expect(podSettingsLink).toHaveAttribute('href', 'https://harbor.pod.example/settings?section=members')
  await expect(page.getByRole('button', { name: 'Offboard member', exact: true })).toHaveCount(0)

  const recoverForm = page.getByRole('form', { name: 'Emergency grant Pod administrator', exact: true })
  const recoverButton = recoverForm.getByRole('button', { name: 'Emergency grant Pod administrator', exact: true })
  await expect(recoverButton).toBeDisabled()
  await recoverForm.getByRole('textbox').fill('All Pod admins locked out')
  await expect(recoverButton).toBeEnabled()
  await recoverButton.click()
  expect(recoveredAdminReasons).toEqual(['All Pod admins locked out'])

  await expect(page.getByText('Reviewed departure', { exact: true })).toBeVisible()
  const restoreForm = page.getByRole('form', { name: 'Restore account', exact: true })
  const restoreButton = restoreForm.getByRole('button', { name: 'Restore account', exact: true })
  await expect(restoreButton).toBeDisabled()
  await restoreForm.getByRole('textbox').fill('Approved return')
  await expect(restoreButton).toBeEnabled()
  await restoreButton.click()
  await expect(restoreButton).toHaveCount(0)
  await expect(page.getByRole('form', { name: 'Emergency grant Pod administrator', exact: true })).toBeVisible()
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
