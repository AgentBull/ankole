import { safeJsonParse } from '@agentbull/active-support'
import type { BaseView } from '@ankole/applet-sdk/types'
import { z } from 'zod'

const value = z.union([
  z.string(),
  z.number(),
  z.boolean(),
  z.null(),
  z.array(z.unknown()),
  z.record(z.string(), z.unknown())
])

export const CHART_VIEW_TYPES = [
  'column',
  'bar',
  'line',
  'area',
  'combo',
  'pie',
  'donut',
  'funnel',
  'scatter',
  'stat'
] as const

export type ChartViewType = (typeof CHART_VIEW_TYPES)[number]

export const CHART_SORT_MODES = ['metric_desc', 'metric_asc', 'key_asc', 'key_desc', 'option_order'] as const

export type ChartSortMode = (typeof CHART_SORT_MODES)[number]

export const CHART_HEIGHT_PRESETS = ['sm', 'md', 'lg', 'xl'] as const

export type ChartHeightPreset = (typeof CHART_HEIGHT_PRESETS)[number]

const chartFieldRefSchema = z.looseObject({
  field_id: z.string().nullable().optional(),
  missing_field_id: z.string().optional()
})

const chartGroupBySchema = z.looseObject({
  field_id: z.string().nullable().optional(),
  missing_field_id: z.string().optional(),
  bucket: z.enum(['day', 'week', 'month', 'quarter', 'year']).optional()
})

const chartMetricSchema = z.looseObject({
  operation: z.enum(['count', 'count_distinct', 'sum', 'avg', 'min', 'max']),
  field_id: z.string().nullable().optional(),
  missing_field_id: z.string().optional(),
  alias: z.string()
})

const chartOrderBySchema = z.looseObject({
  metric_alias: z.string().optional(),
  metric: z.string().optional(),
  group_index: z.number().int().min(0).max(1).optional(),
  direction: z.enum(['asc', 'desc'])
})

const chartTopNSchema = z.looseObject({
  target_group_index: z.number().int().min(0).max(1).optional(),
  group_index: z.number().int().min(0).max(1).optional(),
  limit: z.number().int().min(1).max(100),
  by: z.string().optional(),
  direction: z.enum(['asc', 'desc']).optional(),
  include_other: z.boolean().optional()
})

const chartQuerySchema = z.looseObject({
  group_by: z.array(chartGroupBySchema).max(2).optional(),
  metrics: z.array(chartMetricSchema).optional(),
  order_by: z.array(chartOrderBySchema).optional(),
  top_n: chartTopNSchema.nullable().optional(),
  omit_empty: z.boolean().optional()
})

const chartEncodingSchema = z.looseObject({
  x: chartFieldRefSchema.optional(),
  y: chartFieldRefSchema.optional(),
  size: chartFieldRefSchema.optional(),
  color: chartFieldRefSchema.optional(),
  secondary_metric_aliases: z.array(z.string()).optional()
})

const chartReferenceLineSchema = z.object({
  value: z.number(),
  label: z.string().optional(),
  color: z.string().optional()
})

const chartDisplaySchema = z.looseObject({
  sort_mode: z.enum(CHART_SORT_MODES).optional(),
  stack_mode: z.enum(['grouped', 'stacked', 'percent']).optional(),
  cumulative: z.boolean().optional(),
  fill_missing_buckets: z.boolean().optional(),
  omit_zero: z.boolean().optional(),
  show_data_labels: z.boolean().optional(),
  smooth: z.boolean().optional(),
  show_legend: z.boolean().optional(),
  height: z.enum(CHART_HEIGHT_PRESETS).optional(),
  reference_lines: z.array(chartReferenceLineSchema).optional(),
  caption: z.string().optional()
})

export const chartViewSpecSchema = z.looseObject({
  chart_type: z.enum(CHART_VIEW_TYPES).optional(),
  query: chartQuerySchema.optional(),
  encoding: chartEncodingSchema.optional(),
  display: chartDisplaySchema.optional()
})

const configSchema = z.looseObject({
  type: z.enum(['grid', 'kanban', 'gallery', 'chart']).optional(),
  visible_fields: z.array(z.string()).optional(),
  group_field_id: z.string().optional(),
  cover_field_id: z.string().optional(),
  chart: chartViewSpecSchema.optional(),
  chart_type: z.enum(CHART_VIEW_TYPES).optional(),
  group_by: z.array(chartGroupBySchema).max(2).optional(),
  metrics: z.array(chartMetricSchema).optional(),
  order_by: z.array(chartOrderBySchema).optional(),
  top_n: chartTopNSchema.nullable().optional(),
  omit_empty: z.boolean().optional(),
  encoding: chartEncodingSchema.optional(),
  display: chartDisplaySchema.optional(),
  filter: z
    .object({
      conjunction: z.enum(['and', 'or']),
      conditions: z.array(
        z.object({
          field_id: z.string(),
          operator: z.enum([
            'is',
            'not_is',
            'in',
            'contains',
            'is_empty',
            'is_not_empty',
            'gt',
            'gte',
            'lt',
            'lte',
            'text_contains'
          ]),
          value: value.optional()
        })
      )
    })
    .optional(),
  sort: z.array(z.object({ field_id: z.string(), direction: z.enum(['asc', 'desc']) })).optional()
})

export type ChartFieldRef = z.infer<typeof chartFieldRefSchema>
export type ChartGroupBy = z.infer<typeof chartGroupBySchema>
export type ChartMetric = z.infer<typeof chartMetricSchema>
export type ChartTopN = z.infer<typeof chartTopNSchema>
export type ChartReferenceLine = z.infer<typeof chartReferenceLineSchema>
export type ChartViewSpec = z.infer<typeof chartViewSpecSchema>
export type ViewConfig = z.infer<typeof configSchema>
export type ConfiguredView = Omit<BaseView, 'config'> & { config: ViewConfig }
export const parseViewConfig = (input: unknown) => configSchema.safeParse(input)

/** Returns true when a `chart` ViewConfig was newly inserted (`{"type":"chart"}`) without materialized chart settings yet. */
export function isUnconfiguredChartSpec(config: ViewConfig): boolean {
  return !config.chart?.chart_type && !config.chart_type
}

/** Extracts normalized chart settings from either nested `config.chart` or flat chart keys. */
export function resolveChartSpec(config: ViewConfig): ChartViewSpec {
  const nested = config.chart
  return {
    chart_type: nested?.chart_type ?? config.chart_type,
    query: nested?.query ?? {
      ...(config.group_by ? { group_by: config.group_by } : {}),
      ...(config.metrics ? { metrics: config.metrics } : {}),
      ...(config.order_by ? { order_by: config.order_by } : {}),
      ...(config.top_n !== undefined ? { top_n: config.top_n } : {}),
      ...(config.omit_empty !== undefined ? { omit_empty: config.omit_empty } : {})
    },
    encoding: nested?.encoding ?? config.encoding,
    display: nested?.display ?? config.display
  }
}

/** Detects whether a raw embed `view` string intended to render a `chart` view even if partially malformed. */
export function looksLikeChartEmbedView(raw?: string): boolean {
  if (!raw?.trim().startsWith('{')) return false
  return /"type"\s*:\s*"chart"|"chart_type"\s*:|"chart"\s*:\s*\{/.test(raw)
}

export type EmbedView = { kind: 'saved'; id?: string } | { kind: 'inline'; config: ViewConfig } | { kind: 'invalid' }

/** The document stores either a saved view ID or a JSON configuration. */
export function parseEmbedView(raw?: string): EmbedView {
  if (!raw?.trim()) return { kind: 'saved' }
  const text = raw.trim()
  if (!text.startsWith('{') && !text.startsWith('[')) return { kind: 'saved', id: text }
  const parsed = safeJsonParse(text)
  if (parsed.isErr()) return { kind: 'invalid' }
  const result = parseViewConfig(parsed.value)
  return result.success ? { kind: 'inline', config: result.data } : { kind: 'invalid' }
}
