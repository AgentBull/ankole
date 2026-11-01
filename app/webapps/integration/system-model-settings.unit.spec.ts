import { expect, test, type Page } from '@playwright/test'

// Browser component tests isolate the Console from HTTP. Control-plane tests
// cover the real persistence, authorization, migration, and Provider adapters.
const settings: Record<string, unknown> = {
  'brain.enabled': true,
  'brain.embedding_model': { provider_id: 'embedding-a', model: 'embed-v1', dimensions: 8 },
  'brain.search_tokenizer': 'icu',
  'brain.chunking': { chunk_size: 800, chunk_overlap: 100, max_chars: 100000, max_tokens: 30000 },
  'brain.forgetting': {
    event_halflife_days: 30,
    preference_halflife_days: 90,
    commitment_halflife_days: 60,
    belief_halflife_days: 180,
    fact_halflife_days: 365
  },
  'brain.soft_delete_retention_hours': 168,
  'brain.dreaming_task_cron': '0 2 * * *',
  'brain.self_healing_task_cron': '0 * * * *',
  'brain.signal_channel_batch_idle_time': 60,
  'brain.skill_learning_enabled': true,
  'brain.skill_learning_reflection_threshold': 2
}

async function fixture(page: Page) {
  const values = structuredClone(settings)
  const writes: Record<string, unknown>[] = []
  const rows = () =>
    Object.entries(values).map(([key, value]) => ({
      key,
      value,
      scope: 'global',
      kind: 'exact',
      source: 'global',
      editable: true,
      encrypted: false,
      present: true,
      default_present: true,
      overridden: true
    }))
  await page.route('**/api/v2/site/app-configurations**', route => {
    if (route.request().method() === 'PUT') {
      const update = route.request().postDataJSON().data.values
      writes.push(update)
      Object.assign(values, update)
    }
    return route.fulfill({ json: { app_configurations: rows() } })
  })
  await page.route('**/api/v2/site/ai-gateway/providers', route =>
    route.fulfill({
      json: {
        data: ['embedding-a', 'embedding-b', 'embedding-c'].map((id, index) => ({
          id,
          type: 'ai_gateway_provider',
          attributes: {
            provider_id: id,
            provider_kind: index === 2 ? 'other' : 'openai',
            disabled_at: null,
            credential_pool: { entries: [] },
            provider_metadata: {}
          }
        }))
      }
    })
  )
  await page.route('**/api/v2/site/ai-gateway/provider-kinds', route =>
    route.fulfill({
      json: {
        provider_kinds: ['openai', 'other'].map(provider_kind => ({
          provider_kind,
          capabilities: ['embedding', 'llm'],
          settings: []
        }))
      }
    })
  )
  await page.route('**/api/v2/site/ai-gateway/models', route => route.fulfill({ json: { models: [] } }))
  await page.goto('/settings/group/brain?scope=global')
  await expect(page.locator('input[data-setting-field="dimensions"]')).toHaveValue('8')
  return { writes }
}

const confirmation = (page: Page) => page.getByRole('dialog', { name: 'Change the embedding model?', exact: true })
const save = (page: Page) => page.getByRole('button', { name: 'Save', exact: true })

test('dimension changes require confirmation; Cancel and Escape preserve the draft without saving', async ({
  page
}) => {
  const server = await fixture(page)
  await page.locator('input[data-setting-field="dimensions"]').fill('16')
  await save(page).click()
  await expect(confirmation(page)).toBeVisible()
  await expect(confirmation(page)).toContainText('old vectors will not participate in recall')
  expect(server.writes).toHaveLength(0)
  await confirmation(page).getByRole('button', { name: 'Cancel', exact: true }).click()
  await expect(confirmation(page)).toBeHidden()
  await expect(page.locator('input[data-setting-field="dimensions"]')).toHaveValue('16')
  expect(server.writes).toHaveLength(0)
  await save(page).click()
  await confirmation(page).press('Escape')
  await expect(confirmation(page)).toBeHidden()
  expect(server.writes).toHaveLength(0)
  await save(page).click()
  await confirmation(page).getByRole('button', { name: 'Confirm and save', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(1)
  expect(server.writes[0]!['brain.embedding_model']).toMatchObject({ dimensions: 16 })
})

test('changing the embedding model asks before saving', async ({ page }) => {
  const server = await fixture(page)
  await page.getByRole('combobox', { name: 'Model', exact: true }).fill('embed-v2')
  await page.getByRole('option', { name: /Use.*embed-v2/ }).click()
  await save(page).click()
  await expect(confirmation(page)).toBeVisible()
  expect(server.writes).toHaveLength(0)
  await confirmation(page).getByRole('button', { name: 'Confirm and save', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(1)
  expect(server.writes[0]!['brain.embedding_model']).toMatchObject({ model: 'embed-v2' })
})

test('provider options save directly without a signature confirmation', async ({ page }) => {
  const server = await fixture(page)
  await page.locator('[data-setting-field="provider_options"] textarea').fill('{"batch_size":32}')
  await save(page).click()
  await expect.poll(() => server.writes.length).toBe(1)
  await expect(confirmation(page)).toBeHidden()
  expect(server.writes[0]!['brain.embedding_model']).toMatchObject({ provider_options: { batch_size: 32 } })
})

for (const [provider, needsConfirmation] of [
  ['embedding-b', false],
  ['embedding-c', true]
] as const) {
  test(`switching to ${provider} compares the Provider kind`, async ({ page }) => {
    const server = await fixture(page)
    await page.locator('[data-setting-field="provider_id"]').click()
    await page.getByRole('option', { name: provider, exact: true }).click()
    await page.getByRole('combobox', { name: 'Model', exact: true }).fill('embed-v1')
    await page.getByRole('option', { name: /Use.*embed-v1/ }).click()
    await save(page).click()
    if (needsConfirmation) {
      await expect(confirmation(page)).toBeVisible()
      expect(server.writes).toHaveLength(0)
      await confirmation(page).getByRole('button', { name: 'Confirm and save', exact: true }).click()
    }
    await expect.poll(() => server.writes.length).toBe(1)
    expect(server.writes[0]!['brain.embedding_model']).toMatchObject({ provider_id: provider })
  })
}

test('Brain model dependency links select the ankole_brain editor', async ({ page }) => {
  await fixture(page)
  const links = page.locator('a[href*="/model-profiles"]')
  await expect(links).toHaveCount(4)
  for (const link of await links.all()) await expect(link).toHaveAttribute('href', /system_principal=ankole_brain/)
})
