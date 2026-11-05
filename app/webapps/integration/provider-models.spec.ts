import { expect, test, type Page } from '@playwright/test'
import type { AIGatewayCredentialPoolEntry } from '../console/state/provider-settings'

const revealField = (field: string) => `Reveal \u2068${field}\u2069`
const hideField = (field: string) => `Hide \u2068${field}\u2069`

async function providerPage(
  page: Page,
  kind = 'openai',
  options: {
    rejectInitialCredential?: boolean
  } = {}
) {
  const entries: AIGatewayCredentialPoolEntry[] = []
  const storedSecrets = new Map<string, Record<string, unknown>>()
  let strategy = 'fill_first'
  let rejectCredential = options.rejectInitialCredential ?? true
  let rejectCallback = true
  let rejectDecryptError: string | undefined
  let pendingDecryptGate: (() => Promise<void>) | undefined
  const credentialPatches: Array<Record<string, unknown>> = []
  const settings =
    kind === 'chatgpt_subscription'
      ? [
          {
            key: 'access_token',
            type: 'string',
            default: null,
            options: [],
            required: true,
            encrypted: true,
            advanced: false,
            scope: 'credential'
          },
          {
            key: 'refresh_token',
            type: 'string',
            default: null,
            options: [],
            required: false,
            encrypted: true,
            advanced: false,
            scope: 'credential'
          },
          {
            key: 'id_token',
            type: 'string',
            default: null,
            options: [],
            required: false,
            encrypted: true,
            advanced: false,
            scope: 'credential'
          },
          {
            key: 'account_id',
            type: 'string',
            default: null,
            options: [],
            required: false,
            encrypted: true,
            advanced: false,
            scope: 'credential'
          },
          {
            key: 'plan_type',
            type: 'string',
            default: null,
            options: [],
            required: false,
            encrypted: true,
            advanced: false,
            scope: 'credential'
          },
          {
            key: 'email',
            type: 'string',
            default: null,
            options: [],
            required: false,
            encrypted: true,
            advanced: false,
            scope: 'credential'
          },
          {
            key: 'auth_type',
            type: 'select',
            default: null,
            options: ['oauth', 'enterprise_access_token'],
            required: false,
            encrypted: true,
            advanced: false,
            scope: 'credential'
          }
        ]
      : [
          {
            key: 'api_key',
            type: 'string',
            default: null,
            options: [],
            required: true,
            encrypted: true,
            advanced: false,
            scope: 'credential'
          }
        ]
  const document = () => ({
    data: {
      id: 'provider-row',
      type: 'ai_gateway_provider',
      attributes: {
        provider_id: 'fixture',
        provider_kind: kind,
        base_url: null,
        connection_options: {},
        disabled_at: null,
        credential_pool: { strategy, entries },
        provider_metadata: {}
      }
    }
  })
  await page.route('**/api/v2/site/ai-gateway/provider-kinds', route =>
    route.fulfill({
      json: {
        provider_kinds: [
          {
            provider_kind: kind,
            label: { default: 'Fixture provider' },
            capabilities: ['llm'],
            default_base_url: null,
            settings
          }
        ]
      }
    })
  )
  await page.route('**/api/v2/site/ai-gateway/providers**', async route => {
    const request = route.request()
    const path = new URL(request.url()).pathname
    if (request.method() === 'GET') {
      return route.fulfill({ json: path.endsWith('/providers') ? { data: [document().data] } : document() })
    }
    const decryptMatch = path.match(/\/credentials\/([^/]+)\/decryptions$/)
    if (decryptMatch && request.method() === 'POST') {
      const credentialID = decodeURIComponent(decryptMatch[1]!)
      if (pendingDecryptGate) {
        const wait = pendingDecryptGate
        pendingDecryptGate = undefined
        await wait()
      }
      if (rejectDecryptError) {
        const detail = rejectDecryptError
        rejectDecryptError = undefined
        return route.fulfill({
          status: 403,
          json: { errors: [{ code: 'forbidden', detail }] }
        })
      }
      return route.fulfill({
        status: 201,
        json: {
          decrypted_credential: {
            provider_id: 'fixture',
            credential_id: credentialID,
            values: storedSecrets.get(credentialID) ?? {}
          }
        }
      })
    }
    const body = request.postDataJSON()?.data
    if (path.endsWith('/chatgpt-login')) {
      return route.fulfill({
        status: 201,
        json: {
          mode: 'browser_paste',
          authorization_url: 'https://auth.example.test/authorize',
          login_context: { mode: 'browser_paste', state: 'fixture-state' }
        }
      })
    }
    if (path.endsWith('/browser-callback')) {
      expect(body.callback_url).toContain('code=')
      if (rejectCallback) {
        rejectCallback = false
        return route.fulfill({
          status: 422,
          json: {
            errors: [{ code: 'chatgpt_login_invalid', detail: 'The callback belongs to a different sign-in attempt.' }]
          }
        })
      }
      storedSecrets.set('account-one', {
        access_token: 'oauth-access-secret',
        refresh_token: 'oauth-refresh-secret',
        id_token: 'oauth-id-secret',
        account_id: 'account-one',
        email: 'browser@example.test',
        auth_type: 'oauth'
      })
      entries.push({
        disabled_at: null,
        request_count: 0,
        rate_limits: {},
        usage: {},
        last_selected_at: null,
        id: 'account-one',
        label: 'Browser account',
        source: 'browser_oauth',
        status: 'ok',
        credential_present: true,
        present_fields: ['access_token', 'account_id', 'auth_type', 'email', 'id_token', 'refresh_token'],
        priority: 0,
        account_id: 'account-one',
        email: 'browser@example.test',
        auth_type: 'oauth'
      })
      return route.fulfill({ status: 201, json: { status: 'complete' } })
    }
    if (path.endsWith('/chatgpt-enterprise-credentials')) {
      const id = body.credential.id ?? 'enterprise-one'
      const normalizedToken = String(body.credential.access_token).replace(/^Bearer\s+/i, '')
      storedSecrets.set(id, {
        access_token: normalizedToken,
        account_id: body.credential.account_id,
        email: body.credential.email,
        plan_type: body.credential.plan_type,
        auth_type: 'enterprise_access_token'
      })
      const entry: AIGatewayCredentialPoolEntry = {
        disabled_at: null,
        request_count: 0,
        rate_limits: {},
        usage: {},
        last_selected_at: null,
        id,
        label: body.credential.label ?? id,
        priority: body.credential.priority ?? 0,
        source: 'enterprise_access_token',
        status: 'ok',
        credential_present: true,
        present_fields: [
          'access_token',
          'account_id',
          'auth_type',
          ...(body.credential.email ? ['email'] : []),
          ...(body.credential.plan_type ? ['plan_type'] : [])
        ],
        account_id: body.credential.account_id,
        email: body.credential.email ?? null,
        plan_type: body.credential.plan_type ?? null,
        auth_type: 'enterprise_access_token'
      }
      const existingIndex = entries.findIndex(item => item.id === id)
      if (existingIndex >= 0) entries[existingIndex] = entry
      else entries.push(entry)
      return route.fulfill({ status: 201, json: { ai_gateway_provider: document().data.attributes } })
    }
    if (path.endsWith('/credential-pool/strategy')) {
      strategy = body.attributes.strategy
      return route.fulfill({ json: document() })
    }
    if (request.method() === 'POST') {
      if (rejectCredential) {
        rejectCredential = false
        return route.fulfill({
          status: 422,
          json: {
            errors: [{ code: 'credential_fields_required', detail: 'The credential was rejected; check the API key.' }]
          }
        })
      }
      storedSecrets.set('key-one', { api_key: body.attributes.credential.api_key })
      entries.push({
        disabled_at: null,
        request_count: 0,
        rate_limits: {},
        usage: {},
        last_selected_at: null,
        id: 'key-one',
        label: body.attributes.credential.label,
        priority: body.attributes.credential.priority ?? 0,
        source: 'manual',
        status: 'ok',
        credential_present: true,
        present_fields: ['api_key']
      })
      return route.fulfill({ status: 201, json: document() })
    }
    if (request.method() === 'PATCH') {
      expect(body.id).toBe('provider-row')
      const patch = body.attributes.credential as Record<string, unknown>
      credentialPatches.push(patch)
      const credentialMatch = path.match(/\/credentials\/([^/]+)$/)
      const targetID = credentialMatch ? decodeURIComponent(credentialMatch[1]!) : entries[0]?.id
      const target = entries.find(item => item.id === targetID) ?? entries[0]!
      if (typeof patch.api_key === 'string') {
        storedSecrets.set(target.id, { ...storedSecrets.get(target.id), api_key: patch.api_key })
      }
      const { api_key: _ignoredApiKey, ...entryMetadata } = patch
      Object.assign(target, entryMetadata, {
        status: 'disabled_at' in patch ? (patch.disabled_at ? 'disabled' : 'ok') : target.status
      })
      return route.fulfill({ json: document() })
    }
    entries.length = 0
    return route.fulfill({ json: document() })
  })
  await page.goto('/providers/fixture')
  await expect(page.getByRole('heading', { name: 'Credential pool', exact: true })).toBeVisible()
  return {
    credentialPatches,
    failNextDecrypt(detail: string) {
      rejectDecryptError = detail
    },
    holdNextDecrypt() {
      let release!: () => void
      const gate = new Promise<void>(resolve => {
        release = resolve
      })
      pendingDecryptGate = () => gate
      return release
    }
  }
}

test('credential writes retain rejected input and update the visible pool, strategy and availability', async ({
  page
}) => {
  await providerPage(page)
  await page.getByRole('button', { name: 'Add credential', exact: true }).click()
  const dialog = page.getByRole('dialog')
  await dialog.getByRole('textbox', { name: 'Label (required)', exact: true }).fill('Primary key')
  await dialog.getByRole('textbox', { name: 'API key (required)', exact: true }).fill('local-test-secret')
  await dialog.getByRole('button', { name: 'Save', exact: true }).click()
  await expect(dialog.getByText('The credential was rejected; check the API key.', { exact: true })).toBeVisible()
  await expect(dialog.getByRole('textbox', { name: 'Label (required)', exact: true })).toHaveValue('Primary key')
  await expect(dialog.getByRole('textbox', { name: 'API key (required)', exact: true })).toHaveValue(
    'local-test-secret'
  )
  await dialog.getByRole('button', { name: 'Save', exact: true }).click()
  await expect(dialog).not.toBeVisible()
  const entry = page.locator('article').filter({ hasText: 'Primary key' })
  await expect(entry.getByText('Available', { exact: true })).toBeVisible()
  await expect(page.getByText('local-test-secret', { exact: true })).not.toBeVisible()
  await entry.getByRole('button', { name: revealField('API key'), exact: true }).click()
  await expect(entry.getByText('local-test-secret', { exact: true })).toBeVisible()
  await entry.getByRole('button', { name: hideField('API key'), exact: true }).click()
  await expect(page.getByText('local-test-secret', { exact: true })).not.toBeVisible()
  await entry.getByRole('button', { name: 'Disable', exact: true }).click()
  await expect(entry.getByText('Disabled', { exact: true })).toBeVisible()
  await entry.getByRole('button', { name: 'Enable', exact: true }).click()
  await expect(entry.getByText('Available', { exact: true })).toBeVisible()
  await page.getByRole('combobox').click()
  await page.getByRole('option', { name: 'Round robin', exact: true }).click()
  await expect(page.getByRole('combobox')).toContainText('Round robin')
  await entry.getByRole('button', { name: 'Delete', exact: true }).click()
  await page.getByRole('dialog').getByRole('button', { name: 'Delete', exact: true }).click()
  await expect(entry).not.toBeVisible()
})

test('browser-paste sign-in shows a rejection, keeps the callback, and reveals multiple fields concurrently without dropping earlier requests', async ({
  page
}) => {
  const fixture = await providerPage(page, 'chatgpt_subscription')
  await page.getByRole('button', { name: 'Add ChatGPT account', exact: true }).click()
  const dialog = page.getByRole('dialog')
  await dialog.getByRole('textbox', { name: 'Label (required)', exact: true }).fill('Browser account')
  await dialog.getByRole('button', { name: 'Start login', exact: true }).click()
  await expect(dialog.getByRole('link', { name: 'Open authorization page', exact: true })).toHaveAttribute(
    'href',
    'https://auth.example.test/authorize'
  )
  const callback = dialog.getByRole('textbox', { name: 'Callback URL (required)', exact: true })
  await callback.fill('http://localhost:1455/auth/callback?code=fixture&state=fixture-state')
  await dialog.getByRole('button', { name: 'Complete login', exact: true }).click()
  await expect(dialog.locator('[aria-live="assertive"]')).toBeVisible()
  await expect(callback).toHaveValue('http://localhost:1455/auth/callback?code=fixture&state=fixture-state')
  await dialog.getByRole('button', { name: 'Complete login', exact: true }).click()
  await expect(dialog).not.toBeVisible()
  await expect(page.getByText('browser@example.test', { exact: true })).toBeVisible()
  await expect(page.getByText('oauth-access-secret', { exact: true })).not.toBeVisible()

  const account = page.locator('article').filter({ hasText: 'Browser account' })
  const releaseCardDecrypt = fixture.holdNextDecrypt()
  await account.getByRole('button', { name: revealField('Access token'), exact: true }).click()
  await expect(account.getByRole('button', { name: revealField('Access token'), exact: true })).toBeDisabled()
  await account.getByRole('button', { name: revealField('Refresh token'), exact: true }).click()
  await expect(account.getByText('oauth-refresh-secret', { exact: true })).toBeVisible()
  await expect(account.getByRole('button', { name: revealField('Access token'), exact: true })).toBeDisabled()
  releaseCardDecrypt()
  await expect(account.getByText('oauth-access-secret', { exact: true })).toBeVisible()
  await expect(account.getByText('oauth-refresh-secret', { exact: true })).toBeVisible()

  await account.getByRole('button', { name: 'Edit', exact: true }).click()
  const editDialog = page.getByRole('dialog')
  const releaseDialogDecrypt = fixture.holdNextDecrypt()
  await editDialog.getByRole('button', { name: revealField('Access token'), exact: true }).click()
  await expect(editDialog.getByRole('button', { name: revealField('Access token'), exact: true })).toBeDisabled()
  await editDialog.getByRole('button', { name: revealField('Refresh token'), exact: true }).click()
  await expect(editDialog.getByRole('textbox', { name: 'Refresh token', exact: true })).toHaveValue(
    'oauth-refresh-secret'
  )
  releaseDialogDecrypt()
  await expect(editDialog.getByRole('textbox', { name: 'Access token', exact: true })).toHaveValue(
    'oauth-access-secret'
  )
  await expect(editDialog.getByRole('textbox', { name: 'Refresh token', exact: true })).toHaveValue(
    'oauth-refresh-secret'
  )
  await editDialog.getByRole('button', { name: 'Cancel', exact: true }).click()
  await expect(editDialog).not.toBeVisible()
})

test('credential editor reveals stored secrets, omits unchanged secrets on metadata edits, and ignores stale reveals', async ({
  page
}) => {
  const fixture = await providerPage(page, 'openai', { rejectInitialCredential: false })
  await page.getByRole('button', { name: 'Add credential', exact: true }).click()
  const addDialog = page.getByRole('dialog')
  await addDialog.getByRole('textbox', { name: 'Label (required)', exact: true }).fill('Primary key')
  await addDialog.getByRole('textbox', { name: 'API key (required)', exact: true }).fill('sk-initial-secret')
  await addDialog.getByRole('button', { name: 'Save', exact: true }).click()
  await expect(addDialog).not.toBeVisible()

  const entry = page.locator('article').filter({ hasText: 'Primary key' })
  await entry.getByRole('button', { name: 'Edit', exact: true }).click()
  const dialog = page.getByRole('dialog')
  fixture.failNextDecrypt('Decrypt permission is required for this provider.')
  await dialog.getByRole('button', { name: revealField('API key'), exact: true }).click()
  await expect(dialog.getByText('Decrypt permission is required for this provider.', { exact: true })).toBeVisible()

  await dialog.getByRole('button', { name: revealField('API key'), exact: true }).click()
  const apiKeyInput = dialog.getByRole('textbox', { name: 'API key (required)', exact: true })
  await expect(apiKeyInput).toHaveValue('sk-initial-secret')
  await dialog.getByRole('textbox', { name: 'Label (required)', exact: true }).fill('Renamed key')
  await dialog.getByRole('button', { name: 'Save', exact: true }).click()
  await expect(dialog).not.toBeVisible()
  expect(fixture.credentialPatches).toEqual([{ label: 'Renamed key', priority: 0 }])

  const renamedEntry = page.locator('article').filter({ hasText: 'Renamed key' })
  await renamedEntry.getByRole('button', { name: 'Edit', exact: true }).click()
  const replaceDialog = page.getByRole('dialog')
  const releaseDecrypt = fixture.holdNextDecrypt()
  await replaceDialog.getByRole('button', { name: revealField('API key'), exact: true }).click()
  await replaceDialog.getByRole('textbox', { name: 'API key (required)', exact: true }).fill('sk-replacement-secret')
  releaseDecrypt()
  await expect(replaceDialog.getByRole('textbox', { name: 'API key (required)', exact: true })).toHaveValue(
    'sk-replacement-secret'
  )
  await replaceDialog.getByRole('button', { name: 'Save', exact: true }).click()
  await expect(replaceDialog).not.toBeVisible()
  expect(fixture.credentialPatches.at(-1)).toEqual({
    label: 'Renamed key',
    priority: 0,
    api_key: 'sk-replacement-secret'
  })

  await renamedEntry.getByRole('button', { name: revealField('API key'), exact: true }).click()
  await expect(renamedEntry.getByText('sk-replacement-secret', { exact: true })).toBeVisible()
})

test('enterprise credential dialog reveals stored access tokens and preserves them during metadata edits', async ({
  page
}) => {
  const fixture = await providerPage(page, 'chatgpt_subscription', { rejectInitialCredential: false })
  await page.getByRole('button', { name: 'Add enterprise token', exact: true }).click()
  const addDialog = page.getByRole('dialog')
  await addDialog.getByRole('textbox', { name: 'Label (required)', exact: true }).fill('Enterprise token')
  await addDialog.getByRole('textbox', { name: 'Access token (required)', exact: true }).fill('Bearer ent-token-live')
  await addDialog.getByRole('textbox', { name: 'Account ID (required)', exact: true }).fill('acct_ent_1')
  await addDialog.getByRole('button', { name: 'Save', exact: true }).click()
  await expect(addDialog).not.toBeVisible()

  const entry = page.locator('article').filter({ hasText: 'Enterprise token' })
  await expect(page.getByText('ent-token-live', { exact: true })).not.toBeVisible()
  await entry.getByRole('button', { name: 'Edit', exact: true }).click()
  const editDialog = page.getByRole('dialog')
  await expect(editDialog.getByRole('heading', { name: 'Edit credential', exact: true })).toBeVisible()
  await editDialog.getByRole('button', { name: revealField('Access token'), exact: true }).click()
  await expect(editDialog.getByRole('textbox', { name: 'Access token (required)', exact: true })).toHaveValue(
    'ent-token-live'
  )
  await editDialog.getByRole('textbox', { name: 'Label (required)', exact: true }).fill('Enterprise primary')
  await editDialog.getByRole('button', { name: 'Save', exact: true }).click()
  await expect(editDialog).not.toBeVisible()
  expect(fixture.credentialPatches).toEqual([{ label: 'Enterprise primary', priority: 0 }])

  const updatedEntry = page.locator('article').filter({ hasText: 'Enterprise primary' })
  await updatedEntry.getByRole('button', { name: revealField('Access token'), exact: true }).click()
  await expect(updatedEntry.getByText('ent-token-live', { exact: true })).toBeVisible()
})
