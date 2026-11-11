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
  'rerank',
  'decision',
  'speech',
  'transcription',
  'ocr',
  'video',
  'music'
]

const TENANT_ID = '11111111-1111-4111-8111-111111111111'

async function fixture(page: Page, options: { initialURL?: string; unconfiguredSitePrimary?: boolean } = {}) {
  const overrides: Record<string, Record<string, Record<string, unknown>>> = { system: {}, ankole_brain: {} }
  const writes: { uid: string; slot: string; method: string }[] = []
  const defaultWrites: {
    scope: string | null
    slot: string
    method: string
    tenant: string | null
    attrs?: Record<string, unknown>
  }[] = []
  const defaultRequests: { scope: string | null; tenant: string | null }[] = []
  let systemPrincipalsRequests = 0
  const siteOverrides: Record<string, Record<string, unknown>> = Object.fromEntries(
    slots
      .filter(slot => !(options.unconfiguredSitePrimary && slot === 'primary'))
      .map(slot => [slot, { provider_id: 'service-models', model: `site-${slot}` }])
  )
  const podOverrides: Record<string, Record<string, unknown>> = Object.fromEntries(
    slots.filter(slot => slot !== 'rerank').map(slot => [slot, { provider_id: 'service-models', model: `pod-${slot}` }])
  )

  const siteConfiguration = () => {
    const effective = Object.fromEntries(
      slots.map(slot => [
        slot,
        siteOverrides[slot]
          ? { source: 'global', resolved_from_profile: slot, value: siteOverrides[slot] }
          : { source: 'default', resolved_from_profile: slot, value: null }
      ])
    )
    return {
      overrides: siteOverrides,
      inherited: {},
      effective,
      provider_hosted: { overrides: {}, inherited: {}, effective: {} }
    }
  }

  const podEffective = () =>
    Object.fromEntries(
      slots.map(slot => {
        if (podOverrides[slot]) {
          return [slot, { source: 'tenant', resolved_from_profile: slot, value: podOverrides[slot] }]
        }
        if (siteOverrides[slot]) {
          return [slot, { source: 'global', resolved_from_profile: slot, value: siteOverrides[slot] }]
        }
        return [slot, { source: 'default', resolved_from_profile: slot, value: null }]
      })
    )

  const podConfiguration = () => ({
    overrides: podOverrides,
    inherited: Object.fromEntries(
      slots
        .filter(slot => Boolean(siteOverrides[slot]))
        .map(slot => [slot, { source: 'global', resolved_from_profile: slot, value: siteOverrides[slot] }])
    ),
    effective: podEffective(),
    provider_hosted: { overrides: {}, inherited: {}, effective: {} }
  })

  const systemConfiguration = (uid: string) => {
    const inherited = podEffective()
    return {
      overrides: overrides[uid],
      inherited,
      effective: {
        ...inherited,
        ...Object.fromEntries(
          Object.entries(overrides[uid]!).map(([slot, value]) => [
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
    }
  }

  await page.route('**/api/v2/site/tenants', route =>
    route.fulfill({
      json: {
        data: [
          {
            id: TENANT_ID,
            type: 'tenant',
            attributes: {
              id: TENANT_ID,
              slug: 'acme',
              display_name: 'Acme',
              suspended_at: null,
              deleting_at: null
            }
          }
        ]
      }
    })
  )
  await page.route('**/api/v2/model-profiles**', route => {
    const url = new URL(route.request().url())
    const method = route.request().method()
    const tenant = route.request().headers()['x-ankole-tenant'] ?? null
    if (method === 'GET') {
      const scope = url.searchParams.get('defaults_scope')
      defaultRequests.push({ scope, tenant })
      return route.fulfill({ json: scope === 'global' ? siteConfiguration() : podConfiguration() })
    }
    const slot = url.pathname.split('/').at(-1)!
    const body = method === 'PUT' ? route.request().postDataJSON().data : undefined
    const scope = (body?.defaults_scope as string | undefined) ?? url.searchParams.get('defaults_scope')
    defaultWrites.push({ scope: scope ?? null, slot, method, tenant, attrs: body?.attrs })
    const store = scope === 'global' ? siteOverrides : podOverrides
    if (method === 'PUT') store[slot] = body.attrs
    if (method === 'DELETE') delete store[slot]
    return route.fulfill({ json: scope === 'global' ? siteConfiguration() : podConfiguration() })
  })
  await page.route('**/api/v2/system-principals', route => {
    systemPrincipalsRequests += 1
    return route.fulfill({
      json: {
        system_principals: [
          { uid: 'system', purpose: 'Applet' },
          { uid: 'ankole_brain', purpose: 'Brain' }
        ]
      }
    })
  })
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
    return route.fulfill({ json: systemConfiguration(uid!) })
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
          },
          {
            id: 'google_ai_studio_openai',
            type: 'ai_gateway_provider',
            attributes: {
              provider_id: 'google_ai_studio_openai',
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
            capabilities: [
              'llm',
              'web_search',
              'web_fetch',
              'image_generate',
              'rerank',
              'decision',
              'speech',
              'transcription',
              'ocr',
              'video',
              'music'
            ]
          }
        ]
      }
    })
  )
  await page.route('**/api/v2/site/ai-gateway/models', route => route.fulfill({ json: { models: [] } }))
  const initialURL =
    options.initialURL ?? `/model-profiles?defaults_scope=tenant&system_principal=ankole_brain&data_tenant=${TENANT_ID}`
  await page.goto(initialURL)
  if (initialURL.includes('system_principal=ankole_brain')) {
    await expect(page.getByRole('region', { name: 'ankole_brain', exact: true }).locator('form')).toHaveCount(15)
  }
  return {
    writes,
    overrides,
    defaultWrites,
    defaultRequests,
    getSystemPrincipalsRequests: () => systemPrincipalsRequests
  }
}

test('opens directly on Site defaults without a selected tenant and updates provider selection across edits', async ({
  page
}) => {
  const server = await fixture(page, { initialURL: '/model-profiles', unconfiguredSitePrimary: true })
  await expect(page.getByRole('tab', { name: 'Site defaults', exact: true })).toHaveAttribute('aria-selected', 'true')
  await expect(page.getByRole('combobox', { name: 'Tenant', exact: true })).toHaveCount(0)
  await expect(page.getByRole('region', { name: 'System Principals', exact: true })).toHaveCount(0)

  const primary = page.locator('form').filter({ has: page.getByRole('button', { name: /^Primary model/ }) })
  await primary.getByRole('button', { name: /^Primary model/ }).click()

  const modelInput = primary.getByRole('combobox', { name: 'Model', exact: true })
  const providerSelect = primary.getByRole('combobox', { name: /^Provider/ })
  await expect(modelInput).toBeDisabled()

  await providerSelect.click()
  await page.getByRole('option', { name: 'google_ai_studio_openai', exact: true }).click()
  await expect(providerSelect).toContainText('google_ai_studio_openai')
  await expect(modelInput).toBeEnabled()

  await modelInput.fill('gemini-2.5-pro')
  await page.getByRole('option', { name: /Use.*gemini-2.5-pro/ }).click()

  // Switching provider while the draft is already dirty must still re-render the controlled Select and clear the stale model.
  await providerSelect.click()
  await page.getByRole('option', { name: 'service-models', exact: true }).click()
  await expect(providerSelect).toContainText('service-models')
  await expect(modelInput).toHaveValue('')

  await modelInput.fill('site-primary-v2')
  await page.getByRole('option', { name: /Use.*site-primary-v2/ }).click()
  await primary.getByRole('button', { name: 'Save', exact: true }).click()

  await expect
    .poll(() => server.defaultWrites)
    .toEqual([
      {
        scope: 'global',
        slot: 'primary',
        method: 'PUT',
        tenant: null,
        attrs: { provider_id: 'service-models', model: 'site-primary-v2', provider_options: {} }
      }
    ])
})

// Saves the Site OCR profile against a fixture in which reading earlier scans is off and `unread` scans wait.
async function saveSiteOCRProfile(page: Page, unread: { files: number; pages: number; counting: boolean }) {
  await fixture(page, { initialURL: '/model-profiles' })
  const settingWrites: unknown[] = []
  await page.route('**/api/v2/site/app-configurations/pod.ocr_existing_scans', route => {
    if (route.request().method() !== 'GET') settingWrites.push(route.request().postDataJSON())
    return route.fulfill({
      json: {
        app_configuration: { key: 'pod.ocr_existing_scans', overridden: false, value: null, fallback_value: false }
      }
    })
  })
  await page.route('**/api/v2/site/unread-scans', route => route.fulfill({ json: unread }))

  const ocr = page.locator('form').filter({ has: page.getByRole('button', { name: /^OCR model/ }) })
  await ocr.getByRole('button', { name: /^OCR model/ }).click()
  await ocr.getByRole('combobox', { name: 'Model', exact: true }).fill('mistral-ocr-latest')
  await page.getByRole('option', { name: /Use.*mistral-ocr-latest/ }).click()
  const counted = page.waitForResponse(response => response.url().includes('/api/v2/site/unread-scans'))
  await ocr.getByRole('button', { name: 'Save', exact: true }).click()
  await counted
  return { settingWrites, dialog: page.getByRole('dialog', { name: 'Read the scanned PDFs uploaded earlier?' }) }
}

test('saving the OCR profile shows what reading the earlier scans would cost and waits for consent', async ({
  page
}) => {
  const { settingWrites, dialog } = await saveSiteOCRProfile(page, { files: 3, pages: 41, counting: false })

  await expect(dialog).toContainText('the OCR provider charges for each of those pages too')
  await expect(dialog).toContainText(
    'Unread scanned PDFs in the Pods that follow the Site setting: 3. Unread pages: 41.'
  )
  // Nothing is turned on until the administrator accepts the charges.
  expect(settingWrites).toEqual([])

  await dialog.getByRole('button', { name: 'Read them and accept the charges', exact: true }).click()
  await expect.poll(() => settingWrites).toEqual([{ data: { value: true } }])
  await expect(dialog).toHaveCount(0)
})

test('declining stores the refusal, and nothing is asked when no scan is waiting', async ({ page }) => {
  const { settingWrites, dialog } = await saveSiteOCRProfile(page, { files: 2, pages: 5, counting: false })
  await dialog.getByRole('button', { name: 'Not now', exact: true }).click()
  await expect.poll(() => settingWrites).toEqual([{ data: { value: false } }])
  await expect(dialog).toHaveCount(0)

  const quiet = await saveSiteOCRProfile(page, { files: 0, pages: 0, counting: false })
  await expect(quiet.dialog).toHaveCount(0)
  expect(quiet.settingWrites).toEqual([])
})

test('right after an upgrade the question still comes and says that the numbers are incomplete', async ({ page }) => {
  const { dialog } = await saveSiteOCRProfile(page, { files: 0, pages: 0, counting: true })
  await expect(dialog).toContainText(
    'Unread scanned PDFs in the Pods that follow the Site setting: 0. Unread pages: 0. Pod is still listing the PDFs uploaded earlier, so the final numbers will be higher.'
  )
})

test('Pod defaults tab keeps scope tabs mounted when no tenant is selected and binds the chosen tenant', async ({
  page
}) => {
  const server = await fixture(page, { initialURL: '/model-profiles' })
  await expect.poll(() => server.defaultRequests).toEqual([{ scope: 'global', tenant: null }])

  await page.getByRole('tab', { name: 'Pod defaults', exact: true }).click()
  await expect(page.getByRole('tab', { name: 'Site defaults', exact: true })).toBeVisible()
  await expect(page.getByRole('tab', { name: 'Pod defaults', exact: true })).toHaveAttribute('aria-selected', 'true')
  await expect(page.getByRole('status')).toContainText('Choose a tenant to view, create, or edit a record.')
  expect(server.defaultRequests).toEqual([{ scope: 'global', tenant: null }])
  expect(server.getSystemPrincipalsRequests()).toBe(0)

  await page.getByRole('combobox', { name: 'Tenant', exact: true }).click()
  await page.getByRole('option', { name: 'Acme (acme)', exact: true }).click()

  await expect(page).toHaveURL(/defaults_scope=tenant/)
  await expect(page.getByRole('tab', { name: 'Pod defaults', exact: true })).toHaveAttribute('aria-selected', 'true')
  await expect(page.getByRole('region', { name: 'ankole_brain', exact: true }).locator('form')).toHaveCount(15)
  expect(server.defaultRequests).toContainEqual({ scope: 'tenant', tenant: TENANT_ID })
})

test('system editors expose all fifteen slots, save independently, and restore inheritance', async ({ page }) => {
  const server = await fixture(page)
  const brain = page.getByRole('region', { name: 'ankole_brain', exact: true })
  const applet = page.getByRole('region', { name: 'system', exact: true })
  await expect(applet.locator('form')).toHaveCount(15)
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
  await page.getByRole('tab', { name: 'Site defaults', exact: true }).click()
  await expect(page.getByRole('region', { name: 'System Principals', exact: true })).toHaveCount(0)
  await expect(page).not.toHaveURL(/system_principal=/)
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
