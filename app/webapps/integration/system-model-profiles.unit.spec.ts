import { expect, test, type Page } from '@playwright/test'

// Console component tests use HTTP fixtures; control-plane tests cover persistence and authorization.
const slots = [
  'primary',
  'light',
  'heavy',
  'coding',
  'vision_fallback',
  'web_search',
  'web_fetch',
  'image_generate',
  'rerank'
]

async function fixture(page: Page) {
  const overrides: Record<string, Record<string, Record<string, unknown>>> = { system: {}, ankole_brain: {} }
  const writes: { uid: string; slot: string; method: string }[] = []
  const defaultOverrides: Record<string, Record<string, unknown>> = {}
  const inherited = Object.fromEntries(
    slots.map(slot => [
      slot,
      {
        source: slot === 'rerank' ? 'global' : 'tenant',
        resolved_from_profile: slot,
        value: { provider_id: 'service-models', model: `pod-${slot}` }
      }
    ])
  )
  const configuration = (uid?: string) => ({
    overrides: uid ? overrides[uid] : defaultOverrides,
    inherited,
    effective: {
      ...inherited,
      ...Object.fromEntries(
        Object.entries(uid ? overrides[uid]! : {}).map(([slot, value]) => [
          slot,
          {
            value,
            source: 'system',
            resolved_from_profile: slot
          }
        ])
      )
    },
    provider_hosted: { overrides: {}, inherited: {}, effective: {} }
  })
  await page.route('**/api/v2/model-profiles**', route => {
    if (route.request().method() === 'PUT') {
      const slot = new URL(route.request().url()).pathname.split('/').at(-1)!
      const value = route.request().postDataJSON().data.attrs
      defaultOverrides[slot] = value
      inherited[slot] = { source: 'tenant', resolved_from_profile: slot, value }
    }
    return route.fulfill({ json: configuration() })
  })
  await page.route('**/api/v2/system-principals', route =>
    route.fulfill({
      json: {
        system_principals: [
          { uid: 'system', purpose: 'Applet' },
          { uid: 'ankole_brain', purpose: 'Brain' }
        ]
      }
    })
  )
  await page.route('**/api/v2/system-principals/**', route => {
    const [, uid, slot] = new URL(route.request().url()).pathname.match(
      /system-principals\/([^/]+)\/model-profiles(?:\/(.+))?/
    )!
    const method = route.request().method()
    if (slot) {
      writes.push({ uid: uid!, slot, method })
      if (method === 'PUT') overrides[uid!]![slot] = route.request().postDataJSON().data.attrs
      if (method === 'DELETE') delete overrides[uid!]![slot]
    }
    return route.fulfill({ json: configuration(uid) })
  })
  await page.route('**/api/v2/site/ai-gateway/providers', route =>
    route.fulfill({
      json: {
        data: [
          {
            id: 'service-models',
            type: 'ai_gateway_provider',
            attributes: {
              provider_id: 'service-models',
              provider_kind: 'openrouter',
              disabled_at: null,
              credential_pool: { entries: [] },
              provider_metadata: {}
            }
          }
        ]
      }
    })
  )
  await page.route('**/api/v2/site/ai-gateway/provider-kinds', route =>
    route.fulfill({
      json: {
        provider_kinds: [
          {
            provider_kind: 'openrouter',
            settings: [],
            capabilities: ['llm', 'web_search', 'web_fetch', 'image_generate', 'rerank']
          }
        ]
      }
    })
  )
  await page.route('**/api/v2/site/ai-gateway/models', route => route.fulfill({ json: { models: [] } }))
  await page.goto('/model-profiles?defaults_scope=tenant&system_principal=ankole_brain')
  await expect(page.getByRole('region', { name: 'ankole_brain', exact: true }).locator('form')).toHaveCount(9)
  return { writes, overrides }
}

test('system editors expose all nine slots, save independently, and restore inheritance', async ({ page }) => {
  const server = await fixture(page)
  const brain = page.getByRole('region', { name: 'ankole_brain', exact: true })
  const applet = page.getByRole('region', { name: 'system', exact: true })
  await expect(applet.locator('form')).toHaveCount(9)
  await expect(brain.getByRole('switch')).toHaveCount(0)
  await expect(applet.getByRole('switch')).toHaveCount(0)
  const light = brain.locator('form').filter({ has: page.getByRole('button', { name: /^Lightweight model/ }) })
  await light.getByRole('button', { name: /^Lightweight model/ }).click()
  await expect(light).toContainText(/Effective source:.*Pod/)
  await light.getByRole('combobox', { name: 'Model', exact: true }).fill('brain-light')
  await page.getByRole('option', { name: /Use.*brain-light/ }).click()
  await light.getByRole('button', { name: 'Save', exact: true }).click()
  await expect.poll(() => server.writes).toEqual([{ uid: 'ankole_brain', slot: 'light', method: 'PUT' }])
  await expect(light).toContainText(/Effective source:.*System Principal/)
  await expect(applet.getByRole('button', { name: /^Lightweight model/ })).toContainText('pod-light')
  expect(server.overrides.system).toEqual({})

  await light.getByRole('button', { name: 'Restore inheritance', exact: true }).click()
  await page.getByRole('dialog').getByRole('button', { name: 'Restore inheritance', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(2)
  expect(server.writes[1]).toEqual({ uid: 'ankole_brain', slot: 'light', method: 'DELETE' })
  await expect(light.getByRole('button', { name: /^Lightweight model/ })).toContainText('pod-light')
  expect(server.overrides.ankole_brain).toEqual({})

  const rerank = brain.locator('form').filter({ has: page.getByRole('button', { name: /^Rerank model/ }) })
  await rerank.getByRole('button', { name: /^Rerank model/ }).click()
  await expect(rerank).toContainText(/Effective source:.*Site/)
})

test('Site defaults do not show tenant system editors', async ({ page }) => {
  await fixture(page)
  await page.getByRole('combobox', { name: 'Defaults scope', exact: true }).click()
  await page.getByRole('option', { name: 'Site defaults', exact: true }).click()
  await expect(page.getByRole('region', { name: 'System Principals', exact: true })).toHaveCount(0)
})

test('changing Pod defaults refreshes untouched system slots and preserves pending edits', async ({ page }) => {
  await fixture(page)
  const brain = page.getByRole('region', { name: 'ankole_brain', exact: true })
  const applet = page.getByRole('region', { name: 'system', exact: true })
  const brainHeavy = brain.locator('form').filter({ has: page.getByRole('button', { name: /^Complex work model/ }) })
  await brainHeavy.getByRole('button', { name: /^Complex work model/ }).click()
  await brainHeavy.getByRole('combobox', { name: 'Model', exact: true }).fill('brain-heavy-draft')
  await page.getByRole('option', { name: /Use.*brain-heavy-draft/ }).click()

  for (const [label, model] of [
    [/^Lightweight model/, 'pod-light-v2'],
    [/^Complex work model/, 'pod-heavy-v2']
  ] as const) {
    const podSlot = page
      .locator('form')
      .filter({ has: page.getByRole('button', { name: label }) })
      .first()
    await podSlot.getByRole('button', { name: label }).click()
    await podSlot.getByRole('combobox', { name: 'Model', exact: true }).fill(model)
    await page.getByRole('option', { name: new RegExp(`Use.*${model}`) }).click()
    await podSlot.getByRole('button', { name: 'Save', exact: true }).click()
    await expect(applet.getByRole('button', { name: label })).toContainText(model)
  }

  await expect(brain.getByRole('button', { name: /^Lightweight model/ })).toContainText('pod-light-v2')
  await expect(brainHeavy.getByRole('combobox', { name: 'Model', exact: true })).toHaveValue('brain-heavy-draft')
})
