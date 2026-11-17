import { expect, spyOn, test } from 'bun:test'
import i18next from 'i18next'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import { normalizeSeriesPoints } from './charts'
import { buildKeyValueRecord, DeclarativeFields, formatKeyValueEntry } from './fields'
import { resolveRouteTabSelection } from './resources'
import {
  applyWizardPreview,
  executeWizardStep,
  parseBatchLine,
  redactBatchLine,
  redactUrlCredentials,
  toggleWizardPreviewRow,
  WizardActionTable
} from './wizard'
import {
  executeDeclarativeAction,
  normalizeDeclarativeResponse,
  useDeclarativeVisibility,
  serializeDeclarativeFields,
  serializeNullablePatchPayload
} from './transport'
import type {
  DeclarativeConsoleManifest,
  DeclarativeFieldDescriptor,
  DeclarativeRuleSection,
  DeclarativeSurfaceDescriptor
} from './types'
import { createDeclarativeConsoleModule } from './index'

async function loadVisibility(endpoint: string, ids: readonly string[]) {
  const fetchSpy = spyOn(globalThis, 'fetch').mockResolvedValue(Response.json({ visible_ids: ids }))
  const originalWindow = Object.getOwnPropertyDescriptor(globalThis, 'window')
  let visibility!: ReturnType<typeof useDeclarativeVisibility>
  function Harness() {
    visibility = useDeclarativeVisibility(endpoint)
    return null
  }
  try {
    Object.defineProperty(globalThis, 'window', { configurable: true, value: {} })
    renderToStaticMarkup(<Harness />)
    visibility.refresh()
    await new Promise(resolve => setTimeout(resolve, 0))
    renderToStaticMarkup(<Harness />)
    expect(visibility.loading).toBe(false)
    expect(visibility.error).toBeNull()
  } finally {
    fetchSpy.mockRestore()
    if (originalWindow) Object.defineProperty(globalThis, 'window', originalWindow)
    else Reflect.deleteProperty(globalThis, 'window')
  }
}

const FIXTURE_MANIFEST: DeclarativeConsoleManifest = {
  id: 'widget_ops',
  pluginId: 'widget_plugin',
  visibilityEndpoint: '/api/v2/fixture-site/widgets/console-visible-ids',
  navSections: [
    {
      id: 'widgets',
      labelKey: 'widgets.nav.section',
      items: [
        {
          id: 'widget-overview',
          to: '/widgets/overview',
          labelKey: 'widgets.nav.overview',
          icon: 'board',
          surfaceId: 'widget-overview'
        },
        {
          id: 'widget-items',
          to: '/widgets/items',
          labelKey: 'widgets.nav.items',
          icon: 'server',
          surfaceId: 'widget-items'
        }
      ]
    }
  ],
  routes: [
    {
      id: 'widget-overview',
      path: '/widgets/overview',
      scope: 'site',
      surfaceId: 'widget-overview',
      titleKey: 'widgets.nav.overview'
    },
    {
      id: 'widget-items',
      path: '/widgets/items',
      scope: 'site',
      surfaceId: 'widget-items',
      titleKey: 'widgets.nav.items'
    }
  ],
  surfaces: [
    {
      id: 'widget-overview',
      surface: 'console:dashboard:widget-overview',
      kind: 'dashboard',
      domain: 'Widget.SiteDomain',
      actor: 'operator',
      operationKind: 'view',
      subject: 'WidgetMetrics',
      permission: 'site_console:widgets:read',
      audit: 'none',
      endpoint: '/api/v2/fixture-site/widgets/metrics',
      method: 'GET',
      resourceType: null,
      payloadEnvelope: 'flat',
      responseEnvelope: 'flat',
      titleKey: 'widgets.overview.title',
      columns: [],
      filters: [],
      nullableFields: [],
      fields: [],
      stepSchemas: []
    },
    {
      id: 'widget-items',
      surface: 'console:resource:widget-items',
      kind: 'resource',
      domain: 'Widget.SiteDomain',
      actor: 'operator',
      operationKind: 'list',
      subject: 'WidgetItem',
      permission: 'site_console:widgets:read',
      audit: 'none',
      endpoint: '/api/v2/fixture-site/widgets/items',
      method: 'GET',
      resourceType: 'widget_item',
      payloadEnvelope: 'jsonapi',
      responseEnvelope: 'jsonapi',
      titleKey: 'widgets.items.title',
      columns: ['id', 'name', 'status'],
      filters: ['search', 'status'],
      nullableFields: ['notes'],
      fields: [],
      stepSchemas: []
    }
  ]
}

test('createDeclarativeConsoleModule builds EditionWebappModule with reactive nav visibility', async () => {
  const mod = createDeclarativeConsoleModule(FIXTURE_MANIFEST)
  expect(mod.id).toBe('widget_ops')
  expect(mod.console?.routes).toHaveLength(2)
  expect(mod.console?.navSections?.[0]?.items).toHaveLength(2)

  const navItems = mod.console?.navSections?.[0]?.items ?? []
  await loadVisibility(FIXTURE_MANIFEST.visibilityEndpoint, ['widget-overview'])

  function Harness({ index }: { index: number }) {
    const visible = navItems[index]?.useVisible?.() ?? false
    return <span>{visible ? 'visible' : 'hidden'}</span>
  }

  expect(renderToStaticMarkup(<Harness index={0} />)).toBe('<span>visible</span>')
  expect(renderToStaticMarkup(<Harness index={1} />)).toBe('<span>hidden</span>')
})

test('serializeNullablePatchPayload preserves cleared null and array fields', () => {
  const result = serializeNullablePatchPayload(
    { name: 'alpha', notes: '', tags: '' },
    { nullableFields: ['notes', 'endpoint_url', 'tags'], arrayFields: ['tags'] }
  )
  expect(result).toEqual({
    name: 'alpha',
    notes: null,
    endpoint_url: null,
    tags: []
  })

  const full = serializeDeclarativeFields(
    {
      method: 'PATCH',
      nullableFields: ['notes'],
      fields: [
        { name: 'name', type: 'string', labelKey: 'name', required: true, readOnly: false },
        { name: 'notes', type: 'string', labelKey: 'notes', required: false, readOnly: false },
        {
          name: 'params',
          type: 'object',
          labelKey: 'params',
          required: false,
          readOnly: false,
          fields: [{ name: 'max_retries', type: 'integer', labelKey: 'max_retries', required: false, readOnly: false }]
        }
      ],
      ruleSchema: null
    },
    { name: 'alpha', notes: '', params: { max_retries: '3' } },
    'wid-1'
  )
  expect(full).toEqual({ id: 'wid-1', name: 'alpha', notes: null, params: { max_retries: 3 } })
})

test('normalizeSeriesPoints distinguishes no_data gaps from zero values', () => {
  const points = normalizeSeriesPoints(
    [
      { bucket: '2026-11-16T00:00:00Z', requests: 0, no_data: false },
      { bucket: '2026-11-16T01:00:00Z', requests: 0, no_data: true }
    ],
    'requests'
  )
  expect(points).toEqual([
    { bucket: '2026-11-16T00:00:00Z', value: 0, noData: false },
    { bucket: '2026-11-16T01:00:00Z', value: null, noData: true }
  ])
})

test('DeclarativeFields renders recursive object, key_value, and rule_tree controls without textareas', async () => {
  const fields: DeclarativeFieldDescriptor[] = [
    {
      name: 'params',
      type: 'object',
      labelKey: 'params',
      required: false,
      readOnly: false,
      fields: [{ name: 'timeout_ms', type: 'integer', labelKey: 'timeout_ms', required: false, readOnly: false }]
    },
    {
      name: 'mappings',
      type: 'key_value',
      labelKey: 'mappings',
      required: false,
      readOnly: false
    },
    {
      name: 'rules',
      type: 'rule_tree',
      labelKey: 'rules',
      required: false,
      readOnly: false
    }
  ]

  const ruleSchema: DeclarativeRuleSection[] = [
    {
      id: 'weights',
      path: ['rules', 'weights'],
      kind: 'fields',
      fields: [{ name: 'latency', type: 'number', labelKey: 'latency', required: false, readOnly: false }]
    },
    {
      id: 'trace',
      path: [],
      kind: 'fields',
      fields: [
        {
          name: 'trace_retention_days',
          type: 'integer',
          labelKey: 'trace_retention_days',
          required: false,
          readOnly: false
        }
      ]
    },
    {
      id: 'signal_tree',
      path: ['rules', 'signal_tree'],
      kind: 'tree',
      treeConfig: {
        operatorField: 'op',
        leafOperator: 'signal',
        leafValueField: 'signal',
        unaryOperators: ['not'],
        unaryChildField: 'child',
        branchOperators: ['and', 'or'],
        branchChildrenField: 'children'
      },
      fields: [
        {
          name: 'op',
          type: 'enum',
          enumValues: ['and', 'or', 'not', 'signal'],
          labelKey: 'op',
          required: false,
          readOnly: false
        },
        {
          name: 'signal',
          type: 'string',
          labelKey: 'signal',
          required: false,
          readOnly: false
        }
      ]
    }
  ]

  const allFields: DeclarativeFieldDescriptor[] = [
    ...fields,
    {
      name: 'trace_retention_days',
      type: 'integer',
      labelKey: 'trace_retention_days',
      required: false,
      readOnly: false
    }
  ]

  const testI18n = i18next.createInstance()
  await testI18n.init({
    lng: 'en-US',
    resources: { 'en-US': { translation: {} } },
    react: { useSuspense: false }
  })

  const html = renderToStaticMarkup(
    <I18nextProvider i18n={testI18n}>
      <DeclarativeFields
        draft={{
          params: { timeout_ms: 500 },
          mappings: { primary: 'model-a' },
          trace_retention_days: 7,
          rules: {
            weights: { latency: 1.5 },
            signal_tree: {
              op: 'and',
              children: [{ op: 'not', child: { op: 'signal', signal: 'safety_guard' } }]
            }
          }
        }}
        fields={allFields}
        ruleSchema={ruleSchema}
        onChange={() => {}}
      />
    </I18nextProvider>
  )

  expect(html).not.toContain('<textarea')
  expect(html).toContain('model-a')
  expect(html).toContain('safety_guard')

  const emptyDraftHtml = renderToStaticMarkup(
    <I18nextProvider i18n={testI18n}>
      <DeclarativeFields
        draft={{}}
        fields={allFields}
        ruleSchema={[
          ...ruleSchema,
          {
            id: 'filters',
            labelKey: 'filters',
            kind: 'fields',
            path: ['rules'],
            fields: [
              {
                name: 'filter_chain',
                type: 'string',
                labelKey: 'filter_chain',
                required: false,
                readOnly: false
              }
            ]
          }
        ]}
        onChange={() => {}}
      />
    </I18nextProvider>
  )
  expect(emptyDraftHtml).not.toContain('<textarea')

  const serializedRule = serializeDeclarativeFields(
    {
      method: 'POST',
      nullableFields: [],
      fields: allFields,
      ruleSchema
    },
    {
      trace_retention_days: '14',
      rules: {
        weights: { latency: '2.5' },
        signal_tree: { op: 'signal', signal: 'safety_guard' }
      }
    }
  )
  expect(serializedRule).toEqual({
    trace_retention_days: 14,
    rules: {
      weights: { latency: 2.5 },
      signal_tree: { op: 'signal', signal: 'safety_guard' }
    }
  })
})

test('normalizeSeriesPoints supports status=no_data and explicit metric keys', () => {
  expect(
    normalizeSeriesPoints(
      [
        { bucket: '2026-11-16T00:00:00Z', status: 'no_data', requests: 0, cost_micros: 0 },
        { bucket: '2026-11-16T01:00:00Z', status: 'has_usage', requests: 2, cost_micros: 1250 }
      ],
      'cost_micros'
    )
  ).toEqual([
    { bucket: '2026-11-16T00:00:00Z', value: null, noData: true },
    { bucket: '2026-11-16T01:00:00Z', value: 1250, noData: false }
  ])
})

test('redactUrlCredentials strips userinfo and buildKeyValueRecord preserves untouched nested types', () => {
  expect(redactUrlCredentials('http://user:secret@127.0.0.1:8080/path?x=1')).toBe('http://***@127.0.0.1:8080/path?x=1')
  expect(redactUrlCredentials('http://')).toBe('http://')
  const original = { nested: { a: [1, 2] }, enabled: true, count: 3, tag: 'old' }
  expect(formatKeyValueEntry(original.nested)).toBe('{"a":[1,2]}')
  const updated = buildKeyValueRecord(
    [
      ['nested', formatKeyValueEntry(original.nested)],
      ['enabled', formatKeyValueEntry(original.enabled)],
      ['count', formatKeyValueEntry(original.count)],
      ['tag', 'new']
    ],
    original,
    { type: 'json' }
  )
  expect(updated).toEqual({ nested: { a: [1, 2] }, enabled: true, count: 3, tag: 'new' })
})

test('serializeDeclarativeFields coerces nested ruleSchema paths beyond 2 segments and arbitrary root keys', () => {
  const serialized = serializeDeclarativeFields(
    {
      method: 'POST',
      nullableFields: [],
      fields: [],
      ruleSchema: [
        {
          id: 'nested',
          path: ['policy', 'limits', 'window'],
          kind: 'fields',
          fields: [{ name: 'max_rps', type: 'integer', labelKey: 'max_rps', required: false, readOnly: false }]
        }
      ]
    },
    { policy: { limits: { window: { max_rps: '42' } } } }
  )
  expect(serialized).toEqual({ policy: { limits: { window: { max_rps: 42 } } } })
})

const PREVIEW_ACTION: DeclarativeSurfaceDescriptor = {
  ...FIXTURE_MANIFEST.surfaces[1]!,
  id: 'preview-widgets',
  surface: 'console:action:preview-widgets',
  kind: 'action',
  operationKind: 'action',
  method: 'POST',
  responseEnvelope: 'flat',
  columns: ['widget_name', 'details', 'access_key'],
  fields: [
    { name: 'source', type: 'string', labelKey: 'source', required: true, readOnly: false },
    { name: 'access_key', type: 'secret', labelKey: 'access_key', required: false, readOnly: true }
  ]
}

test('wizard step executes the visible action and renders the preview table shared by confirmation', async () => {
  const i18n = i18next.createInstance()
  await i18n.init({ lng: 'en', resources: { en: { translation: { 'widgets.field.widget_name': 'Widget' } } } })
  const preview = await executeWizardStep(
    {
      surfaceById: new Map([[PREVIEW_ACTION.id, PREVIEW_ACTION]]),
      visibleIds: new Set([PREVIEW_ACTION.surface]),
      onExecute: async (action, payload) => {
        expect(action).toBe(PREVIEW_ACTION)
        expect(payload).toEqual({ source: 'widget input' })
        return [
          {
            id: 'internal-id',
            widget_name: 'Blue widget',
            details: 'https://demo:synthetic@example.test/',
            access_key: 'private key',
            private_value: 'private'
          }
        ]
      }
    },
    PREVIEW_ACTION.id,
    { source: 'widget input', unrelated: 'draft only' }
  )
  expect(preview.columns).toEqual(['widget_name', 'details'])
  expect(preview.rows.map(row => row.cells)).toEqual([
    { widget_name: 'Blue widget', details: 'https://***@example.test/' }
  ])
  const html = renderToStaticMarkup(
    <I18nextProvider i18n={i18n}>
      <WizardActionTable i18nPrefix="widgets" preview={preview} />
    </I18nextProvider>
  )
  expect(html).toContain('>Widget</th>')
  expect(html).toContain('>Details</th>')
  expect(html).toContain('>Blue widget</td>')
  expect(html).toContain('>https://***@example.test/</td>')
  expect(html).not.toContain('private')
})

test('wizard step rejects unknown and hidden actions before execution and reports request failures', async () => {
  let calls = 0
  const scope = {
    surfaceById: new Map([[PREVIEW_ACTION.id, PREVIEW_ACTION]]),
    visibleIds: new Set<string>(),
    onExecute: async () => {
      calls++
      throw new Error('Preview unavailable')
    }
  }
  await expect(executeWizardStep(scope, 'missing', {})).rejects.toThrow('Unknown wizard action')
  await expect(executeWizardStep(scope, PREVIEW_ACTION.id, {})).rejects.toThrow('Unauthorized')
  expect(calls).toBe(0)

  scope.visibleIds.add(PREVIEW_ACTION.surface)
  await expect(executeWizardStep(scope, PREVIEW_ACTION.id, {})).rejects.toThrow('Preview unavailable')
  expect(calls).toBe(1)
})

test('wizard preview unwraps flat result envelopes while preserving regular action rows', async () => {
  const entries = [{ widget_name: 'Blue widget' }, { widget_name: 'Red widget' }]
  const preview = (result: unknown, itemsField?: string, action = PREVIEW_ACTION) =>
    executeWizardStep(
      {
        surfaceById: new Map([[action.id, action]]),
        visibleIds: new Set([action.surface]),
        onExecute: async () => normalizeDeclarativeResponse(result, action.responseEnvelope)
      },
      action.id,
      { source: 'widgets' },
      { config: itemsField ? { itemsField } : undefined }
    )
  for (const result of [entries, { items: entries }]) {
    expect((await preview(result)).rows.map(row => row.cells.widget_name)).toEqual(['Blue widget', 'Red widget'])
  }
  expect((await preview(entries[0])).rows[0]?.cells.widget_name).toBe('Blue widget')
  expect((await preview({ items: [] })).rows).toEqual([])
  expect((await preview({ entries }, 'entries')).rows).toHaveLength(2)
  const resource = { data: { id: 'batch-1', attributes: { widget_name: 'Widget batch', items: entries } } }
  const jsonapi = { ...PREVIEW_ACTION, responseEnvelope: 'jsonapi' } satisfies DeclarativeSurfaceDescriptor
  expect((await preview(resource, undefined, jsonapi)).rows.map(row => row.cells.widget_name)).toEqual(['Widget batch'])
})

test('wizard form preview carries declared metadata and commits only checked widget rows', async () => {
  const fields: DeclarativeFieldDescriptor[] = [
    { name: 'source', type: 'secret', labelKey: 'source', required: true, readOnly: false, multiline: true },
    { name: 'revision', type: 'string', labelKey: 'revision', required: true, readOnly: false },
    { name: 'count', type: 'integer', labelKey: 'count', required: true, readOnly: false },
    { name: 'verified', type: 'boolean', labelKey: 'verified', required: true, readOnly: false },
    { name: 'operator', type: 'string', labelKey: 'operator', required: false, readOnly: true },
    { name: 'chosen_widgets', type: 'string_array', labelKey: 'chosen_widgets', required: true, readOnly: false }
  ]
  const action = { ...PREVIEW_ACTION, fields: fields.slice(0, 1) }
  const wizard: DeclarativeSurfaceDescriptor = {
    ...action,
    id: 'import-widgets',
    kind: 'wizard',
    endpoint: '/api/v2/fixture-site/widgets/import',
    payloadEnvelope: 'data',
    fields,
    stepSchemas: [
      {
        id: 'enter_widgets',
        labelKey: 'enter_widgets',
        kind: 'form',
        fields: action.fields,
        actionSurfaceId: action.id,
        actionPreview: { selection: { field: 'chosen_widgets', rowKeyField: 'id' } }
      },
      { id: 'choose_widgets', labelKey: 'choose_widgets', kind: 'preview_items', fields: [] },
      { id: 'confirm_widgets', labelKey: 'confirm_widgets', kind: 'confirm', fields: [] }
    ]
  }
  const step = wizard.stepSchemas[0]
  if (step?.kind !== 'form' || !step.actionSurfaceId) throw new Error('Missing form preview action')
  const source = 'widget: first\nwidget: second\n'
  const result = {
    items: [
      { id: 'first', widget_name: 'Same Name', selectable: true },
      { id: 'second', widget_name: 'Same Name', selectable: true },
      { id: 'invalid', widget_name: 'Invalid widget', selectable: false }
    ],
    revision: 'rev-a',
    count: 0,
    verified: false,
    source: 'secret response',
    operator: 'read only',
    unknown: 'undeclared'
  }
  const preview = await executeWizardStep(
    {
      surfaceById: new Map([[action.id, action]]),
      visibleIds: new Set([action.surface]),
      onExecute: async (target, payload) => {
        expect(target).toBe(action)
        expect(payload).toEqual({ source })
        return normalizeDeclarativeResponse(result, 'flat')
      }
    },
    step.actionSurfaceId,
    { source },
    { config: step.actionPreview, fields: wizard.fields }
  )
  expect(preview.carryForward).toEqual({ revision: 'rev-a', count: 0, verified: false })
  expect(preview.rows.map(({ id, selectable }) => [id, selectable])).toEqual([
    ['first', true],
    ['second', true],
    ['invalid', false]
  ])
  let draft = applyWizardPreview({ source }, preview)
  draft = toggleWizardPreviewRow(draft, preview, 'first', true)
  draft = toggleWizardPreviewRow(draft, preview, 'second', true)
  draft = toggleWizardPreviewRow(draft, preview, 'first', false)
  draft = toggleWizardPreviewRow(draft, preview, 'invalid', true)
  expect(draft.chosen_widgets).toEqual(['second'])

  const i18n = i18next.createInstance()
  await i18n.init({ lng: 'en', resources: { en: { translation: {} } } })
  const render = (selecting: boolean) =>
    renderToStaticMarkup(
      <I18nextProvider i18n={i18n}>
        <WizardActionTable
          i18nPrefix="widgets"
          preview={preview}
          selectedIds={['second']}
          onToggle={selecting ? () => {} : undefined}
        />
      </I18nextProvider>
    )
  const previewHtml = render(true)
  expect(previewHtml.match(/role="checkbox"/g)).toHaveLength(3)
  expect(previewHtml).toMatch(/<button(?=[^>]*aria-label="Select row 3")(?=[^>]*aria-disabled="true")/)
  expect(render(false).match(/>Same Name<\/td>/g)).toHaveLength(1)
  expect(render(false)).not.toContain('Invalid widget')

  const fetchSpy = spyOn(globalThis, 'fetch').mockResolvedValue(Response.json({ imported: 1 }))
  try {
    await executeDeclarativeAction(wizard, serializeDeclarativeFields(wizard, draft))
    const [endpoint, options] = fetchSpy.mock.calls[0] ?? []
    expect(endpoint).toBe(wizard.endpoint)
    expect(JSON.parse(String(options?.body))).toEqual({
      data: { source, revision: 'rev-a', count: 0, verified: false, chosen_widgets: ['second'] }
    })
  } finally {
    fetchSpy.mockRestore()
  }
  expect(
    applyWizardPreview(
      { ...draft, source: 'new widget input' },
      {
        ...preview,
        carryForward: { revision: 'rev-b' }
      }
    )
  ).toMatchObject({ source: 'new widget input', revision: 'rev-b', chosen_widgets: [] })
})

test('parseBatchLine keeps the name and scheme while sending the original endpoint', () => {
  const cfg = { urlField: 'endpoint_url', nameField: 'name', schemeField: 'protocol', schemes: ['http', 'https'] }
  const row = parseBatchLine('Widget|demo:synthetic@example.test:8080', 'https', cfg)
  expect(row).toEqual({
    name: 'Widget',
    protocol: 'https',
    endpoint_url: 'https://demo:synthetic@example.test:8080/'
  })
  expect(redactUrlCredentials(row.endpoint_url!)).toBe('https://***@example.test:8080/')
})

test('parseBatchLine redacts embedded credentials on invalid schemes and malformed URLs', () => {
  const cfg = { urlField: 'endpoint_url', nameField: 'name', schemeField: 'protocol', schemes: ['http', 'https'] }
  expect(() => parseBatchLine('ftp://alice:s3cr3t@proxy.internal:8080', 'http', cfg)).toThrow(
    'Invalid entry: ftp://***@proxy.internal:8080'
  )
  expect(() => parseBatchLine('edge|http://alice:s3cr3t@[broken', 'http', cfg)).toThrow(
    'Invalid entry: edge|http://***@[broken'
  )
  expect(redactBatchLine('edge|alice:s3cr3t@bad host')).toBe('edge|***@bad host')
})

test('tabbed routes surface secondary permitted tabs and fall back from unauthorized tab params', async () => {
  const tabbedManifest: DeclarativeConsoleManifest = {
    ...FIXTURE_MANIFEST,
    navSections: [
      {
        id: 'widgets',
        labelKey: 'widgets.nav.section',
        items: [
          {
            id: 'widget-tabbed',
            to: '/widgets/tabbed',
            labelKey: 'widgets.nav.tabbed',
            icon: 'board',
            surfaceId: 'tab-primary'
          }
        ]
      }
    ],
    routes: [
      {
        id: 'widget-tabbed',
        path: '/widgets/tabbed',
        scope: 'site',
        surfaceId: 'tab-primary',
        tabs: [
          { id: 'primary', labelKey: 'tab.primary', surfaceId: 'tab-primary' },
          { id: 'secondary', labelKey: 'tab.secondary', surfaceId: 'tab-secondary' }
        ]
      }
    ],
    surfaces: [
      { ...FIXTURE_MANIFEST.surfaces[1]!, id: 'tab-primary', surface: 'console:resource:tab-primary' },
      { ...FIXTURE_MANIFEST.surfaces[1]!, id: 'tab-secondary', surface: 'console:action:tab-secondary' }
    ]
  }
  const mod = createDeclarativeConsoleModule(tabbedManifest)
  await loadVisibility(FIXTURE_MANIFEST.visibilityEndpoint, ['console:action:tab-secondary'])

  function NavHarness() {
    return <span>{mod.console?.navSections?.[0]?.items?.[0]?.useVisible?.() ? 'visible' : 'hidden'}</span>
  }
  expect(renderToStaticMarkup(<NavHarness />)).toBe('<span>visible</span>')

  const surfaceById = new Map(tabbedManifest.surfaces.map(item => [item.id, item]))
  const selection = resolveRouteTabSelection(
    tabbedManifest.routes[0]!.tabs!,
    surfaceById,
    (_id, full) => full === 'console:action:tab-secondary',
    'primary'
  )
  expect(selection.visibleTabs.map(tab => tab.id)).toEqual(['secondary'])
  expect(selection.activeTabId).toBe('secondary')
})

test('executeDeclarativeAction sends custom id in attributes for collection POST without data.id', async () => {
  const originalFetch = globalThis.fetch
  const calls: Array<{ url: string; body: unknown }> = []
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({ url: String(input), body: init?.body ? JSON.parse(String(init.body)) : null })
    return new Response(JSON.stringify({ data: { id: 'custom-strat', type: 'widget_item', attributes: {} } }), {
      status: 201,
      headers: { 'content-type': 'application/vnd.api+json' }
    })
  }) as typeof fetch

  try {
    await executeDeclarativeAction(
      {
        ...FIXTURE_MANIFEST.surfaces[1]!,
        id: 'widget-create',
        surface: 'console:action:widget-create',
        kind: 'action',
        operationKind: 'create',
        method: 'POST',
        endpoint: '/api/v2/fixture-site/widgets/items'
      },
      { id: 'custom-strat', name: 'Strat A' }
    )
    await executeDeclarativeAction(
      {
        ...FIXTURE_MANIFEST.surfaces[1]!,
        id: 'widget-create',
        surface: 'console:action:widget-create',
        kind: 'action',
        operationKind: 'create',
        method: 'POST',
        endpoint: '/api/v2/fixture-site/widgets/items'
      },
      { id: '  ', name: 'Strat B' }
    )
  } finally {
    globalThis.fetch = originalFetch
  }

  expect(calls).toEqual([
    {
      url: '/api/v2/fixture-site/widgets/items',
      body: { data: { type: 'widget_item', attributes: { id: 'custom-strat', name: 'Strat A' } } }
    },
    {
      url: '/api/v2/fixture-site/widgets/items',
      body: { data: { type: 'widget_item', attributes: { name: 'Strat B' } } }
    }
  ])
})
