import { afterEach, expect, test } from 'bun:test'
import i18next from 'i18next'
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import { normalizeSeriesPoints } from './charts'
import { DeclarativeFields } from './fields'
import {
  resetDeclarativeVisibilityStoreForTests,
  seedDeclarativeVisibilityForTests,
  serializeDeclarativeFields,
  serializeNullablePatchPayload
} from './transport'
import type { DeclarativeConsoleManifest, DeclarativeFieldDescriptor, DeclarativeRuleSection } from './types'
import { createDeclarativeConsoleModule } from './index'

afterEach(() => {
  resetDeclarativeVisibilityStoreForTests()
})

const FIXTURE_MANIFEST: DeclarativeConsoleManifest = {
  id: 'widget_ops',
  pluginId: 'widget_plugin',
  visibilityEndpoint: '/api/v2/saas-site/widgets/console-visible-ids',
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
      endpoint: '/api/v2/saas-site/widgets/metrics',
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
      endpoint: '/api/v2/saas-site/widgets/items',
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

test('createDeclarativeConsoleModule builds EditionWebappModule with reactive nav visibility', () => {
  const mod = createDeclarativeConsoleModule(FIXTURE_MANIFEST)
  expect(mod.id).toBe('widget_ops')
  expect(mod.console?.routes).toHaveLength(2)
  expect(mod.console?.navSections?.[0]?.items).toHaveLength(2)

  const navItems = mod.console?.navSections?.[0]?.items ?? []
  seedDeclarativeVisibilityForTests('/api/v2/saas-site/widgets/console-visible-ids', ['widget-overview'], 'ssr')

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

test('declarative console engine contains zero domain-specific module names', () => {
  const dir = import.meta.dir
  const files = readdirSync(dir).filter(name => /\.(ts|tsx)$/.test(name) && name !== 'declarative.test.tsx')
  for (const file of files) {
    const source = readFileSync(path.join(dir, file), 'utf8')
    expect(source).not.toMatch(/relay_saas|AccountSnapshot|StrategyDocument|PrincipalPolicy/i)
  }
})
