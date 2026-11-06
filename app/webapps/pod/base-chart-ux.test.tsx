import { t } from 'i18next'
import { beforeAll, describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToReadableStream } from 'react-dom/server'
import type {
  AggregateQuery,
  AggregateResult,
  BaseAPI,
  BaseField,
  BaseTable,
  BaseView,
  TableSchema
} from '@ankole/applet-sdk/types'
import { loadLocale } from '../common/i18n'
import { baseSchemaQuery, baseTablesQuery } from './base-api'
import { buildAggregateQueryFromSpec, deriveDefaultChartSpec } from './state/chart-view'
import { BasePage, sanitizeViewConfig } from './base-page'
import { contentKeys, type PageDetail } from './content-api'
import { ContentScope } from './content-context'
import type { PodRealtime } from './realtime'
import { pageHrefFor } from './use-page-metadata'
import { parseViewConfig, resolveChartSpec, type ViewConfig } from './state/view-config'

beforeAll(() => loadLocale('en-US'))

const baseID = '11111111-2222-4333-8444-555555555555'
const tableID = '22222222-3333-4444-8555-666666666666'
const chartViewID = '33333333-4444-4555-8666-777777777777'

const table: BaseTable = {
  id: tableID,
  page_id: baseID,
  name: 'Orders',
  data_version: 5,
  record_count: 18,
  unique_field_ids: [],
  emit_changes: false
}

const fields: BaseField[] = [
  { id: 'f_title', name: 'Deal', type: 'text', config: {}, version: 1, is_primary: true },
  {
    id: 'f_stage',
    name: 'Stage',
    type: 'select',
    config: { options: [{ name: 'Lead' }, { name: 'Qualified' }, { name: 'Won' }] },
    version: 1,
    is_primary: false
  },
  { id: 'f_date', name: 'Closed Month', type: 'datetime', config: {}, version: 1, is_primary: false },
  {
    id: 'f_amount',
    name: 'Amount',
    type: 'number',
    config: { format: 'currency', currency: 'USD', precision: 2 },
    version: 1,
    is_primary: false
  }
]

const savedChartView: BaseView = {
  id: chartViewID,
  name: 'Monthly Revenue',
  type: 'chart',
  version: 2,
  config: {
    chart: {
      chart_type: 'column',
      query: {
        group_by: [{ field_id: 'f_stage' }],
        metrics: [{ alias: 'y', operation: 'sum', field_id: 'f_amount' }]
      },
      display: {
        sort_mode: 'metric_desc',
        show_legend: true
      }
    }
  }
}

const savedStatView: BaseView = {
  id: '44444444-5555-4666-8777-888888888888',
  name: 'MRR KPI',
  type: 'chart',
  version: 1,
  config: {
    chart: {
      chart_type: 'stat',
      query: {
        group_by: [{ field_id: 'f_date', bucket: 'month' }],
        metrics: [{ alias: 'y', operation: 'sum', field_id: 'f_amount' }]
      },
      display: {
        caption: 'Monthly Recurring Revenue'
      }
    }
  }
}

function makeBaseDetail(actions: PageDetail['actions']): PageDetail {
  return {
    page: {
      id: baseID,
      name: 'Sales Pipeline',
      title: 'Sales Pipeline',
      icon: '📊',
      type: 'base',
      position: 'a0',
      inherit_permissions: true,
      metadata: {},
      revision: 4,
      children_view: {},
      created_at: '2026-10-30T10:00:00Z',
      updated_at: '2026-10-30T11:00:00Z',
      deleted_at: null,
      actions,
      role: actions.includes('node_edit') ? 'edit' : 'view'
    },
    ancestors: [],
    actions,
    role: actions.includes('node_edit') ? 'edit' : 'view',
    child_count: 0
  }
}

async function renderBaseChart(options: {
  actions: PageDetail['actions']
  views?: BaseView[]
  viewID?: string
  inlineConfig?: ViewConfig
  configureInline?: (config: ViewConfig, table?: string) => void
  bindSavedView?: (viewID: string, table?: string) => void
  embedded?: boolean
  aggregateHandler?: (query: AggregateQuery) => AggregateResult
  scalarStatus?: 'pending' | 'error'
}): Promise<string> {
  const client = new QueryClient({
    defaultOptions: {
      queries: {
        gcTime: Infinity,
        staleTime: Infinity,
        retry: false,
        retryOnMount: false
      }
    }
  })
  const realtime = {
    principal: undefined,
    channel: () => ({
      broadcast: async () => {},
      on: () => () => {},
      presence: () => [],
      subscribe: () => () => {},
      close: () => {}
    }),
    dispose: () => {}
  } as unknown as PodRealtime

  const views = options.views ?? [savedChartView, savedStatView]
  const schema: TableSchema = {
    table,
    fields,
    views,
    mode: 'remote',
    timezone: 'UTC'
  }
  client.setQueryData(baseTablesQuery(baseID).queryKey, { tables: [table] })
  client.setQueryData(baseSchemaQuery(tableID).queryKey, schema)

  const defaultAggregate = (query: AggregateQuery): AggregateResult =>
    options.aggregateHandler
      ? options.aggregateHandler(query)
      : {
          data_version: table.data_version,
          groups: [
            { values: ['Won'], value_json: ['"Won"'], metrics: { y: 1200 }, metrics_text: { y: '1200' } },
            { values: ['Lead'], value_json: ['"Lead"'], metrics: { y: 400 }, metrics_text: { y: '400' } }
          ]
        }

  const tableBaseKey = [...contentKeys.all, 'table', tableID]
  for (const v of views) {
    if (v.type !== 'chart') continue
    const parsed = parseViewConfig(v.config)
    const config = parsed.success ? sanitizeViewConfig(parsed.data, fields, 'chart') : {}
    const resolved = deriveDefaultChartSpec(fields, resolveChartSpec(config))
    const aggQuery = buildAggregateQueryFromSpec(resolved, fields, config.filter)
    client.setQueryData([...tableBaseKey, 'aggregate', aggQuery], defaultAggregate(aggQuery))
    if (resolved.chartType === 'stat') {
      const primary = resolved.metrics[0] ?? { operation: 'count' as const, alias: 'count' }
      const scalarQuery: AggregateQuery = {
        ...(config.filter ? { filter: config.filter } : {}),
        metrics: [
          {
            operation: primary.operation,
            ...(primary.field_id ? { field_id: primary.field_id } : {}),
            alias: primary.alias
          }
        ]
      }
      const queryKey = [...tableBaseKey, 'aggregate', scalarQuery]
      if (options.scalarStatus) {
        const query = client.getQueryCache().build(client, { queryKey })
        if (options.scalarStatus === 'error') {
          query.setState({ status: 'error', error: new Error('Could not load total') })
        }
      } else {
        client.setQueryData(queryKey, defaultAggregate(scalarQuery))
      }
    }
  }

  const base: BaseAPI = {
    schema: async () => schema,
    records: async () => ({ records: [], data_version: table.data_version, complete: true }),
    aggregate: async (_id, query) => defaultAggregate(query),
    write: async () => ({ records: [], deleted_ids: [], data_version: table.data_version }),
    subscribe: () => () => {},
    key: (id: string) => [...contentKeys.all, 'table', id]
  }

  try {
    const stream = await renderToReadableStream(
      <QueryClientProvider client={client}>
        <ContentScope
          value={{
            realtime,
            base,
            readDenial: () => undefined,
            dispose: () => realtime.dispose(),
            pageHref: (id, title) => pageHrefFor(client, id, title)
          }}>
          <BasePage
            detail={makeBaseDetail(options.actions)}
            tableID={tableID}
            viewID={options.viewID}
            inlineConfig={options.inlineConfig}
            configureInline={options.configureInline}
            bindSavedView={options.bindSavedView}
            embedded={options.embedded}
          />
        </ContentScope>
      </QueryClientProvider>
    )
    await stream.allReady
    return await new Response(stream).text()
  } finally {
    realtime.dispose()
    client.clear()
  }
}

describe('Notion-aligned Base chart & doc embed UX', () => {
  test('a KPI never presents a single period as the total while its total is pending or failed', async () => {
    for (const scalarStatus of ['pending', 'error'] as const) {
      const html = await renderBaseChart({
        actions: ['node_view'],
        viewID: savedStatView.id,
        embedded: true,
        scalarStatus
      })
      expect(html).not.toContain('data-slot="stat-drilldown-trigger"')
      expect(html).not.toContain('$1,200.00')
      if (scalarStatus === 'error') expect(html).toContain('Could not load total')
    }
  })

  test('linked saved chart view embedded in doc renders quiet single-chart card with collapsed Configure disclosure', async () => {
    const html = await renderBaseChart({
      actions: ['node_view', 'node_edit'],
      viewID: chartViewID,
      configureInline: () => {},
      bindSavedView: () => {},
      embedded: true
    })

    expect(html).toContain('data-quiet-chart="true"')
    expect(html).toContain('data-slot="linked-chart-badge"')
    expect(html).toContain(t('pod.content.linked_view_badge', { name: 'Monthly Revenue' }))
    expect(html).toContain('aria-expanded="false"')
    expect(html).not.toContain('class="pod-base-sources"')
    expect(html).not.toContain('data-slot="chart-capsule-bar"')
  })

  test('newly inserted unconfigured inline chart in doc opens Configure capsule bar immediately', async () => {
    const html = await renderBaseChart({
      actions: ['node_view'],
      inlineConfig: { type: 'chart' },
      configureInline: () => {},
      bindSavedView: () => {},
      embedded: true
    })

    expect(html).toContain('data-quiet-chart="true"')
    expect(html).toContain('aria-expanded="true"')
    expect(html).toContain('data-slot="chart-capsule-bar"')
  })

  test('read-only viewer on embedded chart sees zero-noise card without toolbar or capsule bar while keeping PNG/SVG export', async () => {
    const html = await renderBaseChart({
      actions: ['node_view'],
      viewID: chartViewID,
      embedded: true
    })

    expect(html).toContain('data-quiet-chart="true"')
    expect(html).not.toContain('class="pod-base-toolbar"')
    expect(html).not.toContain('data-slot="chart-capsule-bar"')
    expect(html).toContain('data-slot="chart-export-png"')
    expect(html).toContain('data-slot="chart-export-svg"')
  })

  test('KPI stat chart renders period-over-period delta, baseline comparison, and drilldown trigger button', async () => {
    const html = await renderBaseChart({
      actions: ['node_view'],
      viewID: savedStatView.id,
      embedded: true,
      aggregateHandler: query => {
        if (query.group_by && query.group_by.length > 0) {
          return {
            data_version: table.data_version,
            groups: [
              { values: ['2026-10'], value_json: ['"2026-10"'], metrics: { y: 1000 }, metrics_text: { y: '1000' } },
              { values: ['2026-11'], value_json: ['"2026-11"'], metrics: { y: 1200 }, metrics_text: { y: '1200' } }
            ]
          }
        }
        return {
          data_version: table.data_version,
          groups: [{ values: [], metrics: { y: 2200 }, metrics_text: { y: '2200' } }]
        }
      }
    })

    expect(html).toContain('SUM · Amount')
    expect(html).toContain('Monthly Recurring Revenue')
    expect(html).toContain('$2,200.00')
    expect(html).toContain('data-slot="stat-drilldown-trigger"')
    expect(html).toContain('data-slot="stat-delta"')
    expect(html).toContain('+20%')
    expect(html).toContain('data-slot="stat-baseline"')
    expect(html).toContain(
      t('pod.content.stat_period_comparison', {
        currentLabel: '2026-11',
        currentValue: '$1,200.00',
        previousLabel: '2026-10',
        previousValue: '$1,000.00'
      })
    )
  })
})
