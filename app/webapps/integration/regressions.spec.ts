import { expect, test, type Page, type Route } from '@playwright/test'

test('selecting either Agent in a compiled Pod enables sending and retains the selection', async ({ page }) => {
  await page.route('**/.internal-apis/pod/**', route =>
    route.fulfill({
      json: route.request().url().endsWith('/agents')
        ? {
            agents: [
              { uid: 'agent-one', displayName: 'First Agent' },
              { uid: 'agent-two', displayName: 'Second Agent' }
            ]
          }
        : { conversations: [] }
    })
  )
  await page.goto('/pod')
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('Draft only')
  for (const name of ['Second Agent', 'First Agent']) {
    await page.getByRole('combobox').click()
    await page.getByRole('option', { name, exact: true }).click()
    await expect(page.getByRole('combobox')).toContainText(name)
    await expect(page.getByRole('button', { name: 'Send message', exact: true })).toBeEnabled()
  }
})

test('tenant slugs use browser validation before a request', async ({ page }) => {
  const writes: Route[] = []
  await page.route('**/api/v1/**', route => {
    if (route.request().method() !== 'GET') {
      writes.push(route)
      return route.fulfill({ status: 422, json: {} })
    }
    return route.fulfill({
      json: route.request().url().includes('privileged')
        ? { tenant: { id: 'privileged' } }
        : { tenants: [], brain_packs: [] }
    })
  })
  await page.goto('/tenants/new')
  const slug = page.locator('input[pattern]')
  for (const [value, valid] of [
    ['qa-one', true],
    ['a', true],
    ['Bad_Name', false],
    ['with space', false],
    ['-leading', false]
  ] as const) {
    await slug.fill(value)
    expect(await slug.evaluate(input => (input as HTMLInputElement).checkValidity())).toBe(valid)
  }
  expect(writes).toHaveLength(0)
})

test('the first Webhook result survives the list switching from empty to populated', async ({ page }) => {
  const rows: object[] = []
  await page.route('**/api/v1/webhook-endpoints**', async route => {
    if (route.request().method() === 'GET') return route.fulfill({ json: { webhook_endpoints: rows } })
    const item = {
      id: 'endpoint-one',
      label: 'Fixture',
      mode: 'standing',
      status: 'active',
      event_format: 'cloudevents',
      agent_uid: null,
      binding_name: null,
      session_id: null,
      conversation_id: null,
      created_at: '2026-10-18T00:00:00Z',
      updated_at: '2026-10-18T00:00:00Z',
      expires_at: '2030-01-01T00:00:00Z'
    }
    rows.push(item)
    return route.fulfill({ status: 201, json: { webhook_endpoint: item, token: 'synthetic-capability' } })
  })
  await page.route('**/api/v1/agents', route => route.fulfill({ json: { agents: [] } }))
  await page.goto('/webhooks')
  await page.getByRole('button', { name: 'Create CloudEvents endpoint', exact: true }).click()
  await page.getByLabel('Label', { exact: true }).fill('Fixture')
  await page.getByLabel('Expires', { exact: true }).fill('2030-01-01T12:00')
  await page.getByRole('dialog').getByRole('button', { name: 'Create CloudEvents endpoint', exact: true }).click()
  await expect(page.getByLabel('Capability URL (shown once)', { exact: true })).toHaveValue(
    'http://127.0.0.1:3198/signals/v1/cloudevents/synthetic-capability'
  )
  await expect(page.getByLabel('Endpoint ID', { exact: true })).toHaveValue('endpoint-one')
  await expect(page.getByRole('row').filter({ hasText: 'Fixture' })).toHaveCount(1)
})

async function files(page: Page) {
  await page.route('**/api/v1/agents/agent-one', route =>
    route.fulfill({ json: { agent: { uid: 'agent-one', display_name: 'Files Agent' } } })
  )
  await page.route('**/api/v1/agents/agent-one/files**', route =>
    route.fulfill({
      json: {
        file_listing: { folders: [{ name: 'Folder', path: 'Folder' }], files: [], truncated: false }
      }
    })
  )
  await page.goto('/files/agent-one')
}

test('a folder portal action opens its dialog without navigating the row', async ({ page }) => {
  await files(page)
  await page.getByRole('button', { name: 'More actions', exact: true }).click()
  await page.getByRole('menuitem', { name: 'Move or rename', exact: true }).click()
  await expect(page.getByRole('dialog')).toBeVisible()
  await expect(page).toHaveURL(/\/files\/agent-one$/)
})

test('a long upload preview keeps its actions inside a mobile viewport', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 640 })
  await files(page)
  await page.getByRole('button', { name: 'Upload', exact: true }).click()
  await page.getByLabel('Upload', { exact: true }).setInputFiles(
    Array.from({ length: 24 }, (_, i) => ({
      name: `file-${i}.txt`,
      mimeType: 'text/plain',
      buffer: Buffer.from('fixture')
    }))
  )
  const dialog = page.getByRole('dialog')
  await expect(dialog).toBeVisible()
  const box = await dialog.boundingBox()
  expect(box!.y).toBeGreaterThanOrEqual(0)
  expect(box!.y + box!.height).toBeLessThanOrEqual(640)
  const cancel = dialog.getByRole('button', { name: 'Cancel', exact: true })
  await expect(cancel).toBeInViewport()
  await cancel.click()
  await expect(dialog).toHaveCount(0)
})

const compaction = {
  threshold: 0.9,
  max_threshold_tokens: 400000,
  tail_rows: 4,
  user_message_budget_tokens: 20000,
  upstream: false
}
const setting = (key: string, value: unknown) => ({
  key,
  scope: 'global',
  kind: 'exact',
  source: 'global',
  editable: true,
  encrypted: false,
  present: true,
  default_present: true,
  overridden: true,
  value
})

test('a rejected save notification does not cover the corrected Save action', async ({ page }) => {
  let attempts = 0
  await page.route(/\/api\/v1\/(?:site\/)?app-configurations/, route => {
    const item = setting('worker.test_limit', 10)
    if (route.request().method() === 'PUT') {
      attempts++
      return attempts === 1
        ? route.fulfill({ status: 422, json: { error: { code: 'invalid', message: 'Fixture rejected' } } })
        : route.fulfill({ json: { app_configuration: setting(item.key, 20) } })
    }
    return route.fulfill({
      json: new URL(route.request().url()).pathname.endsWith(item.key)
        ? { app_configuration: item }
        : { app_configurations: [item] }
    })
  })
  await page.goto('/settings/worker.test_limit?scope=global')
  await page.getByRole('spinbutton').fill('15')
  const save = page.getByRole('dialog').getByRole('button', { name: 'Save', exact: true })
  await save.click()
  await expect(page.locator('[data-sonner-toast]')).toBeVisible()
  await page.getByRole('spinbutton').fill('20')
  const box = await save.boundingBox()
  expect(
    await save.evaluate((button, point) => button.contains(document.elementFromPoint(point.x, point.y)), {
      x: box!.x + box!.width / 2,
      y: box!.y + box!.height / 2
    })
  ).toBe(true)
  await save.click()
  await expect.poll(() => attempts).toBe(2)
})

test('a library save completed after leaving the editor supplies the next visit and CAS hash', async ({ page }) => {
  const documents = Object.fromEntries(
    ['mission', 'soul', 'design', 'confidentiality_policy'].map(kind => [
      kind,
      { kind, content: `Initial ${kind}`, content_hash: `hash-${kind}` }
    ])
  )
  const writes: Route[] = []
  await page.route('**/api/v1/agents/agent-one/library-documents**', route => {
    if (route.request().method() === 'PUT') {
      writes.push(route)
      return
    }
    return route.fulfill({ json: { library_documents: documents } })
  })
  await page.route(/\/api\/v1\/(?:site\/)?app-configurations/, route =>
    route.fulfill({ json: { app_configurations: [] } })
  )
  await page.goto('/library/agent-one')
  const panel = page.getByRole('tabpanel', { name: 'MISSION', exact: true })
  await panel.getByRole('button', { name: 'Edit', exact: true }).click()
  await panel.getByRole('textbox').fill('Saved mission')
  await panel.getByRole('button', { name: 'Save', exact: true }).click()
  await expect.poll(() => writes.length).toBe(1)
  await page
    .getByRole('navigation', { name: 'Regression navigation' })
    .getByRole('link', { name: 'Settings', exact: true })
    .click()
  documents.mission = { kind: 'mission', content: 'Saved mission', content_hash: 'saved-hash' }
  await writes[0]!.fulfill({ json: { library_document: documents.mission } })
  await page.getByRole('link', { name: 'Library', exact: true }).click()
  await expect(panel.getByText('Saved mission', { exact: true })).toBeVisible()
  await panel.getByRole('button', { name: 'Edit', exact: true }).click()
  await panel.getByRole('textbox').fill('Next revision')
  await panel.getByRole('button', { name: 'Save', exact: true }).click()
  await expect.poll(() => writes.length).toBe(2)
  expect(writes[1]!.request().postDataJSON()).toEqual({ content: 'Next revision', expected_content_hash: 'saved-hash' })
  await writes[1]!.fulfill({ status: 503, json: { error: { code: 'unavailable', message: 'Fixture stopped' } } })
})

test('saving a revealed Agent secret masks the old value and a later reveal loads the replacement', async ({
  page
}) => {
  let value = 'old-fixture'
  const item = { name: 'QA_SECRET', source: 'agent', secret: true, value: null }
  await page.route('**/api/v1/agents/agent-one/worker-envs**', route => {
    const method = route.request().method()
    if (method === 'GET') return route.fulfill({ json: { worker_envs: [item] } })
    if (method === 'POST') return route.fulfill({ json: { decrypted_value: { name: item.name, value } } })
    value = route.request().postDataJSON().value
    return route.fulfill({ json: { worker_env: item } })
  })
  await page.goto('/worker-env')
  const row = page.getByRole('row').filter({ hasText: 'QA_SECRET' })
  await row.getByRole('button', { name: 'Reveal', exact: true }).click()
  await expect(row).toContainText('old-fixture')
  await row.getByRole('button', { name: 'Edit', exact: true }).click()
  await row.getByLabel('Value', { exact: true }).fill('new-fixture')
  await row.getByRole('button', { name: 'Save', exact: true }).click()
  await expect(row.getByRole('button', { name: 'Reveal', exact: true })).toBeVisible()
  await expect(row).not.toContainText('old-fixture')
  await row.getByRole('button', { name: 'Reveal', exact: true }).click()
  await expect(row).toContainText('new-fixture')
})

test('compaction accepts domain-valid decimals and large integers, and rejects invalid boundaries', async ({
  page
}) => {
  const writes: unknown[] = []
  await page.route(/\/api\/v1\/(?:site\/)?app-configurations/, route => {
    const item = setting('ai_gateway.compaction', compaction)
    if (route.request().method() === 'PUT') {
      const value = route.request().postDataJSON().value
      writes.push(value)
      return route.fulfill({ json: { app_configuration: setting(item.key, value) } })
    }
    return route.fulfill({
      json: new URL(route.request().url()).pathname.endsWith(item.key)
        ? { app_configuration: item }
        : { app_configurations: [item] }
    })
  })
  for (const [index, value, valid] of [
    [0, '0.905', true],
    [1, '10000001', true],
    [2, '0', true],
    [0, '0', false],
    [0, '1.01', false],
    [2, '1.5', false],
    [1, '9007199254740992', false]
  ] as const) {
    await page.goto('/settings/ai_gateway.compaction?scope=global')
    const dialog = page.getByRole('dialog')
    const input = dialog.getByRole('spinbutton').nth(index)
    await input.fill(value)
    const count = writes.length
    await dialog.getByRole('button', { name: 'Save', exact: true }).click()
    if (valid) {
      await expect.poll(() => writes.length).toBe(count + 1)
      expect(writes.at(-1)).toEqual({ ...compaction, [Object.keys(compaction)[index]!]: Number(value) })
    } else {
      await expect(input).toHaveAttribute('aria-invalid', 'true')
      expect(writes).toHaveLength(count)
    }
  }
})

test('a setting reopened during a save waits for the persisted value', async ({ page }) => {
  let value = 10
  const writes: Route[] = []
  await page.route(/\/api\/v1\/(?:site\/)?app-configurations/, route => {
    if (route.request().method() === 'PUT') {
      writes.push(route)
      return
    }
    const item = setting('worker.test_limit', value)
    return route.fulfill({
      json: new URL(route.request().url()).pathname.endsWith(item.key)
        ? { app_configuration: item }
        : { app_configurations: [item] }
    })
  })
  await page.goto('/settings')
  const edit = page.locator('a[href="/settings/worker.test_limit?scope=global"]')
  await edit.click()
  await page.getByRole('spinbutton').fill('20')
  await page.getByRole('dialog').getByRole('button', { name: 'Save', exact: true }).click()
  await expect.poll(() => writes.length).toBe(1)
  await page.goBack()
  const discard = page.getByRole('button', { name: 'Discard changes', exact: true })
  await expect.poll(async () => new URL(page.url()).pathname === '/settings' || (await discard.isVisible())).toBe(true)
  if (await discard.isVisible()) await discard.click()
  await edit.click()
  value = 20
  await writes[0]!.fulfill({ json: { app_configuration: setting('worker.test_limit', value) } })
  await expect(page.getByRole('spinbutton')).toHaveValue('20')
})

test('schedule names reject whitespace and reopening waits for a completed update', async ({ page }) => {
  let cron = {
    id: 'cron-one',
    agent_uid: 'agent-one',
    name: 'Original',
    status: 'active',
    binding_name: null,
    owner_session_id: 'owner',
    execution_session_id: 'cron:cron-one',
    schedule: { kind: 'cron', expression: '0 9 * * *', timezone: 'UTC' },
    timezone: 'UTC',
    payload: { task: 'Report' },
    delivery: { targets: [{ conversation_id: 'conversation-one' }] },
    automation_job_id: null,
    created_by: {},
    idempotency_key: 'fixture',
    next_fire_at: null,
    last_fire_at: null,
    inserted_at: '2026-10-18T00:00:00Z',
    updated_at: '2026-10-18T00:00:00Z'
  }
  const writes: Route[] = []
  const reads: Route[] = []
  let holdReads = false
  await page.route('**/api/v1/**', route => {
    const path = new URL(route.request().url()).pathname
    if (path.endsWith('/cron-one')) {
      if (route.request().method() === 'PATCH') {
        writes.push(route)
        return
      }
      if (holdReads) {
        reads.push(route)
        return
      }
      return route.fulfill({ json: { cron_schedule: cron } })
    }
    return route.fulfill({
      json: {
        agents: [{ uid: 'agent-one', display_name: 'Fixture', status: 'active' }],
        signal_bindings: [],
        schedule_runs: [],
        app_configurations: [],
        cron_schedules: [],
        schedule_events: []
      }
    })
  })
  await page.goto('/schedules/new?agent=agent-one&cron=cron-one')
  const name = page.getByRole('textbox', { name: /^Name/ })
  await expect(name).toHaveValue('Original')
  await name.fill('   ')
  await page.getByRole('button', { name: 'Save', exact: true }).click()
  await expect(name).toHaveAttribute('aria-invalid', 'true')
  expect(writes).toHaveLength(0)
  await name.press('ControlOrMeta+A')
  await name.pressSequentially('Persisted')
  expect(
    await name.evaluate(input => ({
      value: (input as HTMLInputElement).value,
      valid: (input as HTMLInputElement).checkValidity(),
      pattern: (input as HTMLInputElement).pattern
    }))
  ).toMatchObject({ value: 'Persisted', valid: true })
  await page.getByRole('button', { name: 'Save', exact: true }).click()
  await expect.poll(() => writes.length).toBe(1)
  cron = { ...cron, name: 'Persisted' }
  holdReads = true
  await writes[0]!.fulfill({ json: { cron_schedule: cron } })
  await expect(page).toHaveURL(/\/schedules\?agent=/)
  await page.getByRole('link', { name: 'Schedule', exact: true }).click()
  await expect.poll(() => reads.length).toBeGreaterThan(0)
  holdReads = false
  for (const read of reads) await read.fulfill({ json: { cron_schedule: cron } })
  await expect(name).toHaveValue('Persisted')
  await expect(page.getByRole('button', { name: 'Save', exact: true })).toBeDisabled()
})

test('a settings group reopened during a save does not reuse its old draft', async ({ page }) => {
  let endpoint = 'https://old.example.test'
  const writes: Route[] = []
  await page.route(/\/api\/v1\/(?:site\/)?app-configurations/, route => {
    if (route.request().method() === 'PUT') {
      writes.push(route)
      return
    }
    return route.fulfill({
      json: {
        app_configurations: [
          setting('observability.traces.enabled', false),
          setting('observability.traces.provider', 'langfuse'),
          setting('observability.traces.otlp_endpoint', endpoint),
          setting('observability.traces.otlp_headers', {})
        ]
      }
    })
  })
  await page.goto('/settings')
  const edit = page.locator('a[href="/settings/group/observability?scope=global"]')
  await edit.click()
  const input = page.locator('input[type=url]')
  await expect(input).toHaveValue(endpoint)
  await input.fill('https://new.example.test')
  await page.getByRole('dialog').getByRole('button', { name: 'Save', exact: true }).click()
  await expect.poll(() => writes.length).toBe(1)
  await page.goBack()
  const discard = page.getByRole('button', { name: 'Discard changes', exact: true })
  await expect.poll(async () => new URL(page.url()).pathname === '/settings' || (await discard.isVisible())).toBe(true)
  if (await discard.isVisible()) await discard.click()
  await edit.click()
  endpoint = 'https://new.example.test'
  await writes[0]!.fulfill({ json: { app_configuration: setting('observability.traces.otlp_endpoint', endpoint) } })
  await expect(input).toHaveValue(endpoint)
})
