import { expect, test, type Route } from '@playwright/test'

// A Worker provider record as the site JSON:API sends it.
function workerProvider(attributes: { provider_id: string }) {
  return { id: `row-${attributes.provider_id}`, type: 'worker_provider', attributes }
}

test('a provider response preserves edits made while saving and the navigation guard', async ({ page }) => {
  let item = {
    provider_id: 'fixture',
    kind: 'docker',
    display_name: 'Fixture',
    config: 'before',
    stored_credentials: [],
    is_default: false,
    agent_count: 0,
    selectable: true
  }
  const writes: Route[] = []
  await page.route('**/api/v1/site/worker-provider-kinds', route =>
    route.fulfill({
      json: {
        worker_provider_kinds: [{ kind: 'docker', example: 'before', credentials: { token: { required: false } } }]
      }
    })
  )
  await page.route('**/api/v2/site/worker-providers**', route => {
    if (route.request().method() === 'PATCH') {
      writes.push(route)
      return
    }
    return route.fulfill({ json: { data: [workerProvider(item)] } })
  })
  await page.route('**/api/v1/site/app-configurations**', route => route.fulfill({ json: { app_configurations: [] } }))
  await page.goto('/worker-providers/fixture')
  const config = page.locator('textarea')
  await config.fill('sent')
  await page.getByLabel('token', { exact: true }).fill('sent-token')
  await page.getByRole('button', { name: 'Save', exact: true }).click()
  await expect.poll(() => writes.length).toBe(1)
  await config.fill('next')
  await page.getByLabel('token', { exact: true }).fill('next-token')
  await page
    .getByRole('navigation', { name: 'Regression navigation' })
    .getByRole('link', { name: 'Settings', exact: true })
    .click()
  const dialog = page.getByRole('dialog')
  await expect(dialog).toBeVisible()
  await dialog.getByRole('button', { name: /keep editing/i }).click()
  item = { ...item, config: 'sent' }
  await writes[0]!.fulfill({ json: { data: workerProvider(item) } })
  await expect(config).toHaveValue('next')
  await expect(page.getByLabel('token', { exact: true })).toHaveValue('next-token')
  await expect(page.getByRole('button', { name: 'Save', exact: true })).toBeEnabled()
})

test('suspending a tenant leaves its unsaved name dirty', async ({ page }) => {
  let tenant = {
    id: 'one',
    slug: 'one',
    display_name: 'Before',
    suspended_at: null as string | null,
    deleting_at: null
  }
  const document = (record: typeof tenant) => {
    const { id, ...attributes } = record
    return { id, type: 'tenant', attributes }
  }
  await page.route('**/api/v2/site/privileged-tenant', route =>
    route.fulfill({ json: { data: { id: 'other', type: 'tenant', attributes: {} } } })
  )
  await page.route('**/api/v2/site/tenants**', route => {
    if (route.request().method() === 'POST') {
      tenant = { ...tenant, suspended_at: '2026-10-19T00:00:00Z' }
      return route.fulfill({ status: 201, json: { data: document(tenant) } })
    }
    return route.fulfill({ json: { data: [document(tenant)] } })
  })
  await page.goto('/tenants/one')
  const input = page.locator('input').first()
  await input.fill('Unsaved')
  await page.getByRole('button', { name: 'Suspend new work', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Resume', exact: true })).toBeVisible()
  await expect(input).toHaveValue('Unsaved')
  await expect(page.getByRole('button', { name: 'Save', exact: true })).toBeEnabled()
})

test('an old reveal does not replace a new Agent environment draft', async ({ page }) => {
  let reveal: Route | undefined
  const item = { name: 'QA_SECRET', source: 'agent', secret: true, value: null }
  await page.route('**/api/v1/agents/agent-one/worker-envs**', route => {
    if (route.request().method() === 'POST') {
      reveal = route
      return
    }
    return route.fulfill({ json: { worker_envs: [item] } })
  })
  await page.goto('/worker-env')
  const row = page.getByRole('row').filter({ hasText: item.name })
  await row.getByRole('button', { name: 'Edit', exact: true }).click()
  await row.getByRole('button', { name: 'Reveal', exact: true }).click()
  await expect.poll(() => Boolean(reveal)).toBe(true)
  await row.getByLabel('Value', { exact: true }).fill('replacement')
  await reveal!.fulfill({ json: { decrypted_value: { name: item.name, value: 'old value' } } })
  await expect(row.getByLabel('Value', { exact: true })).toHaveValue('replacement')
})

test('a delayed delete acknowledgement cannot navigate away from the next editor route', async ({ page }) => {
  let deletion: Route | undefined
  let deleted = false
  const item = {
    provider_id: 'fixture',
    kind: 'docker',
    display_name: 'Fixture',
    config: 'before',
    stored_credentials: [],
    is_default: false,
    agent_count: 0,
    selectable: true
  }
  await page.route('**/api/v1/site/worker-provider-kinds', route =>
    route.fulfill({ json: { worker_provider_kinds: [{ kind: 'docker', example: 'before', credentials: {} }] } })
  )
  await page.route('**/api/v2/site/worker-providers**', route => {
    if (route.request().method() === 'DELETE') {
      deletion = route
      return
    }
    return route.fulfill({ json: { data: deleted ? [] : [workerProvider(item)] } })
  })
  await page.route('**/api/v1/site/app-configurations**', route => route.fulfill({ json: { app_configurations: [] } }))
  await page.goto('/worker-providers/fixture')
  await page.getByRole('button', { name: 'Delete', exact: true }).click()
  await page.getByRole('dialog').getByRole('button', { name: 'Delete', exact: true }).click()
  await expect.poll(() => Boolean(deletion)).toBe(true)
  await page
    .getByRole('navigation', { name: 'Regression navigation' })
    .getByRole('link', { name: 'Settings', exact: true })
    .click()
  await expect(page).toHaveURL(/\/settings$/)
  deleted = true
  await deletion!.fulfill({ json: { data: workerProvider(item) } })
  await expect
    .poll(() => page.evaluate(() => (window as unknown as { testMutationStatuses(): string[] }).testMutationStatuses()))
    .toContain('success')
  await expect(page).toHaveURL(/\/settings$/)
})
