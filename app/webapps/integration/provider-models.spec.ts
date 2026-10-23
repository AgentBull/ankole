import { expect, test, type Page } from '@playwright/test'
import type { AIGatewayCredentialPoolEntry } from '../console/state/provider-settings'

async function providerPage(page: Page, kind = 'openai') {
  const entries: AIGatewayCredentialPoolEntry[] = []
  let strategy = 'fill_first'
  let rejectCredential = true
  let rejectCallback = true
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
            settings: [
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
        priority: 0,
        account_id: 'account-one',
        email: 'browser@example.test'
      })
      return route.fulfill({ status: 201, json: { status: 'complete' } })
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
      expect(body.attributes.credential.api_key).toBe('local-test-secret')
      entries.push({
        disabled_at: null,
        request_count: 0,
        rate_limits: {},
        usage: {},
        last_selected_at: null,
        id: 'key-one',
        label: body.attributes.credential.label,
        priority: 0,
        source: 'manual',
        status: 'ok',
        credential_present: true
      })
      return route.fulfill({ status: 201, json: document() })
    }
    if (request.method() === 'PATCH') {
      expect(body.id).toBe('provider-row')
      Object.assign(entries[0]!, body.attributes.credential, {
        status: body.attributes.credential.disabled_at ? 'disabled' : 'ok'
      })
      return route.fulfill({ json: document() })
    }
    entries.length = 0
    return route.fulfill({ json: document() })
  })
  await page.goto('/providers/fixture')
  await expect(page.getByRole('heading', { name: 'Credential pool', exact: true })).toBeVisible()
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

test('browser-paste sign-in shows a rejection, keeps the callback, and displays the completed account', async ({
  page
}) => {
  await providerPage(page, 'chatgpt_subscription')
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
})
