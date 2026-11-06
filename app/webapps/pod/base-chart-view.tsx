import { useId, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button, Checkbox, Input, Popover, PopoverContent, PopoverTitle, PopoverTrigger } from '@ankole/uikit'
import type { BaseField, MetricOperation, TimeBucket } from '@ankole/applet-sdk/types'
import { RiAlertLine, RiEqualizerLine } from '@remixicon/react'
import { Choice } from './content-primitives'
import { AggregateChartBody, ScatterChartBody, type ChartViewProps } from './base-chart-body'
import {
  resolveChartSpec,
  type ChartGroupBy,
  type ChartReferenceLine,
  type ChartMetric,
  type ChartSortMode,
  type ChartViewType
} from './state/view-config'
import {
  STACKABLE_TYPES,
  ONE_DIM_ONLY_TYPES,
  canUseCumulative,
  collectMissingChartSlots,
  compatibleMetricFields,
  deriveDefaultChartSpec,
  isDatetimeField,
  isNumericField,
  serializeResolvedToViewConfig,
  type MissingChartSlotKind,
  type ResolvedChartConfig
} from './state/chart-view'

const METRIC_OPERATIONS: readonly MetricOperation[] = ['count', 'count_distinct', 'sum', 'avg', 'min', 'max']
const SMOOTHABLE_TYPES = new Set<ChartViewType>(['line', 'area', 'combo'])

export function ChartView(props: ChartViewProps) {
  const { t } = useTranslation()
  const rawSpec = useMemo(() => resolveChartSpec(props.view.config), [props.view.config])
  const resolved = useMemo(() => deriveDefaultChartSpec(props.fields, rawSpec), [props.fields, rawSpec])
  const missingSlots = useMemo(() => collectMissingChartSlots(resolved, props.fields), [resolved, props.fields])
  const hasRequiredMissing = missingSlots.some(slot => slot.required)

  const canConfigure = props.canConfigureChart ?? props.schemaEditable
  const controlsOpen = canConfigure && ((props.chartControlsOpen ?? true) || missingSlots.length > 0)

  const commitResolved = (patch: Partial<ResolvedChartConfig>) => {
    const merged: ResolvedChartConfig = { ...resolved, ...patch }
    if (!canUseCumulative(merged.metrics)) {
      merged.cumulative = false
    }
    props.configure(serializeResolvedToViewConfig(props.view.config, merged))
  }

  const chartTypeLabels: Record<ChartViewType, string> = {
    column: t('pod.content.chart_type_column', { defaultValue: 'Column' }),
    bar: t('pod.content.chart_type_bar', { defaultValue: 'Bar' }),
    line: t('pod.content.chart_type_line', { defaultValue: 'Line' }),
    area: t('pod.content.chart_type_area', { defaultValue: 'Area' }),
    combo: t('pod.content.chart_type_combo', { defaultValue: 'Dual-axis combo' }),
    pie: t('pod.content.chart_type_pie', { defaultValue: 'Pie' }),
    donut: t('pod.content.chart_type_donut', { defaultValue: 'Donut' }),
    funnel: t('pod.content.chart_type_funnel', { defaultValue: 'Funnel' }),
    scatter: t('pod.content.chart_type_scatter', { defaultValue: 'Scatter' }),
    stat: t('pod.content.chart_type_stat', { defaultValue: 'KPI stat' })
  }

  const bucketLabels: Record<TimeBucket, string> = {
    day: t('pod.content.bucket_day', { defaultValue: 'Day' }),
    week: t('pod.content.bucket_week', { defaultValue: 'Week' }),
    month: t('pod.content.bucket_month', { defaultValue: 'Month' }),
    quarter: t('pod.content.bucket_quarter', { defaultValue: 'Quarter' }),
    year: t('pod.content.bucket_year', { defaultValue: 'Year' })
  }

  const operationLabels: Record<MetricOperation, string> = {
    count: t('pod.content.metric_count', { defaultValue: 'Count' }),
    count_distinct: t('pod.content.metric_count_distinct', { defaultValue: 'Count distinct' }),
    sum: t('pod.content.metric_sum', { defaultValue: 'Sum' }),
    avg: t('pod.content.metric_avg', { defaultValue: 'Average' }),
    min: t('pod.content.metric_min', { defaultValue: 'Min' }),
    max: t('pod.content.metric_max', { defaultValue: 'Max' })
  }

  const isMissingKind = (kind: MissingChartSlotKind) => missingSlots.some(slot => slot.kind === kind)

  const g0Field = resolved.groupBy[0]?.field_id
    ? props.fields.find(f => f.id === resolved.groupBy[0]!.field_id)
    : undefined

  const handleChartTypeChange = (nextType: ChartViewType) => {
    const preserveSortMode: ChartSortMode | undefined =
      rawSpec.display?.sort_mode !== undefined
        ? resolved.sortMode
        : nextType === 'funnel' && g0Field?.type === 'select'
          ? 'option_order'
          : undefined
    const rederived = deriveDefaultChartSpec(props.fields, {
      ...rawSpec,
      chart_type: nextType,
      query: {
        group_by: ONE_DIM_ONLY_TYPES.has(nextType) ? resolved.groupBy.slice(0, 1) : resolved.groupBy,
        metrics: resolved.metrics,
        top_n: resolved.topN,
        omit_empty: resolved.omitEmpty
      },
      encoding: {
        x: resolved.scatterX,
        y: resolved.scatterY,
        size: resolved.scatterSize,
        color: resolved.scatterColor
      },
      display: {
        ...(preserveSortMode ? { sort_mode: preserveSortMode } : {}),
        stack_mode: resolved.stackMode,
        cumulative: resolved.cumulative,
        fill_missing_buckets: resolved.fillMissingBuckets,
        omit_zero: resolved.omitZero,
        show_data_labels: resolved.showDataLabels,
        smooth: resolved.smooth,
        show_legend: resolved.showLegend,
        height: resolved.height,
        reference_lines: resolved.referenceLines,
        caption: resolved.caption
      }
    })
    props.configure(serializeResolvedToViewConfig(props.view.config, rederived))
  }

  const primaryMetric = resolved.metrics[0] ?? { operation: 'count' as const, alias: 'count' }
  const secondaryMetric = resolved.metrics[1] ?? { operation: 'count' as const, alias: 'm1' }
  const numericFields = props.fields.filter(isNumericField)

  const sortOptions: Partial<Record<ChartSortMode, string>> = {
    metric_desc: t('pod.content.sort_metric_desc', { defaultValue: 'Sort: High → Low' }),
    metric_asc: t('pod.content.sort_metric_asc', { defaultValue: 'Sort: Low → High' }),
    key_asc: t('pod.content.sort_key_asc', { defaultValue: 'Sort: A → Z / Old → New' }),
    key_desc: t('pod.content.sort_key_desc', { defaultValue: 'Sort: Z → A / New → Old' }),
    ...(g0Field?.type === 'select'
      ? { option_order: t('pod.content.sort_option_order', { defaultValue: 'Sort: Option order' }) }
      : {})
  }

  return (
    <div className="space-y-3 py-2" data-slot="base-chart-view">
      {/* Linear-style single-row capsule controls (hidden for read-only viewers and collapsed embeds) */}
      {controlsOpen && (
        <div
          id={props.chartControlsId}
          data-slot="chart-capsule-bar"
          className="flex flex-wrap items-center gap-2 rounded-control border border-border bg-layer-01/60 px-2.5 py-2 text-xs">
          <Choice
            label={t('pod.content.chart_type', { defaultValue: 'Chart type' })}
            disabled={props.configuring}
            value={resolved.chartType}
            onChange={handleChartTypeChange}
            options={chartTypeLabels}
          />

          {resolved.chartType === 'scatter' ? (
            <>
              <div className={isMissingKind('scatter_x') ? 'rounded-control ring-2 ring-warning' : undefined}>
                <Choice
                  label={t('pod.content.chart_x_axis', { defaultValue: 'X axis' })}
                  disabled={props.configuring}
                  value={resolved.scatterX?.field_id ?? ''}
                  onChange={fieldId => commitResolved({ scatterX: fieldId ? { field_id: fieldId } : undefined })}
                  options={{
                    '': t('pod.content.select_x_field', { defaultValue: 'Select X field' }),
                    ...Object.fromEntries(numericFields.map(f => [f.id, `X: ${f.name}`]))
                  }}
                />
              </div>
              <div className={isMissingKind('scatter_y') ? 'rounded-control ring-2 ring-warning' : undefined}>
                <Choice
                  label={t('pod.content.chart_y_axis', { defaultValue: 'Y axis' })}
                  disabled={props.configuring}
                  value={resolved.scatterY?.field_id ?? ''}
                  onChange={fieldId => commitResolved({ scatterY: fieldId ? { field_id: fieldId } : undefined })}
                  options={{
                    '': t('pod.content.select_y_field', { defaultValue: 'Select Y field' }),
                    ...Object.fromEntries(numericFields.map(f => [f.id, `Y: ${f.name}`]))
                  }}
                />
              </div>
              <div className={isMissingKind('scatter_size') ? 'rounded-control ring-2 ring-warning' : undefined}>
                <Choice
                  label={t('pod.content.chart_size_field', { defaultValue: 'Bubble size' })}
                  disabled={props.configuring}
                  value={resolved.scatterSize?.field_id ?? ''}
                  onChange={fieldId => commitResolved({ scatterSize: fieldId ? { field_id: fieldId } : undefined })}
                  options={{
                    '': t('pod.content.no_size_field', { defaultValue: 'Size: Fixed' }),
                    ...Object.fromEntries(numericFields.map(f => [f.id, `Size: ${f.name}`]))
                  }}
                />
              </div>
              <div className={isMissingKind('scatter_color') ? 'rounded-control ring-2 ring-warning' : undefined}>
                <Choice
                  label={t('pod.content.chart_color_field', { defaultValue: 'Series color' })}
                  disabled={props.configuring}
                  value={resolved.scatterColor?.field_id ?? ''}
                  onChange={fieldId => commitResolved({ scatterColor: fieldId ? { field_id: fieldId } : undefined })}
                  options={{
                    '': t('pod.content.no_series_split', { defaultValue: 'Split: None' }),
                    ...Object.fromEntries(props.fields.map(f => [f.id, `Split: ${f.name}`]))
                  }}
                />
              </div>
            </>
          ) : (
            <>
              {/* X / Category / Trend Dimension */}
              {props.fields.length > 0 && (
                <div className={isMissingKind('group_0') ? 'rounded-control ring-2 ring-warning' : undefined}>
                  <Choice
                    label={t('pod.content.chart_group_by', { defaultValue: 'Group by' })}
                    disabled={props.configuring}
                    value={resolved.groupBy[0]?.field_id ?? ''}
                    onChange={fieldId => {
                      if (!fieldId) {
                        commitResolved({ groupBy: [] })
                        return
                      }
                      const nextField = props.fields.find(f => f.id === fieldId)
                      const nextIsTime = Boolean(nextField && isDatetimeField(nextField))
                      const nextG0: ChartGroupBy = {
                        field_id: fieldId,
                        ...(nextIsTime ? { bucket: 'month' } : {})
                      }
                      const nextSortMode: ChartSortMode =
                        rawSpec.display?.sort_mode !== undefined
                          ? nextField?.type !== 'select' && resolved.sortMode === 'option_order'
                            ? nextIsTime
                              ? 'key_asc'
                              : 'metric_desc'
                            : resolved.sortMode
                          : nextIsTime
                            ? 'key_asc'
                            : nextField?.type === 'select' && resolved.chartType === 'funnel'
                              ? 'option_order'
                              : 'metric_desc'
                      commitResolved({
                        groupBy: resolved.groupBy[1] ? [nextG0, resolved.groupBy[1]] : [nextG0],
                        sortMode: nextSortMode
                      })
                    }}
                    options={{
                      ...(resolved.chartType === 'stat'
                        ? { '': t('pod.content.no_trend_dimension', { defaultValue: 'Trend: None' }) }
                        : isMissingKind('group_0')
                          ? {
                              '': t('pod.content.missing_field_placeholder', {
                                defaultValue: 'Deleted field — choose replacement'
                              })
                            }
                          : {}),
                      ...Object.fromEntries(
                        (resolved.chartType === 'stat' ? props.fields.filter(isDatetimeField) : props.fields).map(f => [
                          f.id,
                          `${resolved.chartType === 'stat' ? t('pod.content.trend_prefix', { defaultValue: 'Trend' }) : t('pod.content.dimension_prefix', { defaultValue: 'By' })}: ${f.name}`
                        ])
                      )
                    }}
                  />
                </div>
              )}

              {/* Time Bucket Selector when group_by[0] is datetime */}
              {g0Field && isDatetimeField(g0Field) && (
                <Choice
                  label={t('pod.content.time_bucket', { defaultValue: 'Time bucket' })}
                  disabled={props.configuring}
                  value={resolved.groupBy[0]?.bucket ?? 'month'}
                  onChange={bucket => {
                    const nextG0: ChartGroupBy = { field_id: g0Field.id, bucket }
                    commitResolved({
                      groupBy: resolved.groupBy[1] ? [nextG0, resolved.groupBy[1]] : [nextG0]
                    })
                  }}
                  options={bucketLabels}
                />
              )}

              {/* Series / Split Dimension for 2D charts */}
              {!ONE_DIM_ONLY_TYPES.has(resolved.chartType) &&
                resolved.chartType !== 'stat' &&
                resolved.chartType !== 'combo' &&
                props.fields.length > 1 &&
                Boolean(resolved.groupBy[0]?.field_id) && (
                  <div className={isMissingKind('group_1') ? 'rounded-control ring-2 ring-warning' : undefined}>
                    <Choice
                      label={t('pod.content.chart_series_split', { defaultValue: 'Split series' })}
                      disabled={props.configuring}
                      value={resolved.groupBy[1]?.field_id ?? ''}
                      onChange={fieldId => {
                        if (!fieldId) {
                          commitResolved({ groupBy: resolved.groupBy.slice(0, 1) })
                          return
                        }
                        const nextField = props.fields.find(f => f.id === fieldId)
                        const nextG1: ChartGroupBy = {
                          field_id: fieldId,
                          ...(nextField && isDatetimeField(nextField) ? { bucket: 'month' } : {})
                        }
                        commitResolved({ groupBy: [resolved.groupBy[0]!, nextG1] })
                      }}
                      options={{
                        '': isMissingKind('group_1')
                          ? t('pod.content.missing_field_placeholder', {
                              defaultValue: 'Deleted field — choose replacement'
                            })
                          : t('pod.content.no_series_split', { defaultValue: 'Split: None' }),
                        ...Object.fromEntries(
                          props.fields
                            .filter(f => f.id !== resolved.groupBy[0]?.field_id)
                            .map(f => [f.id, `${t('pod.content.split_prefix', { defaultValue: 'Split' })}: ${f.name}`])
                        )
                      }}
                    />
                  </div>
                )}

              {/* Primary Metric Selector */}
              <MetricCapsule
                labelPrefix={t('pod.content.metric_prefix', { defaultValue: 'Metric' })}
                metric={primaryMetric}
                fields={props.fields}
                operationLabels={operationLabels}
                missing={isMissingKind('metric_0')}
                disabled={props.configuring}
                onChange={nextM0 => {
                  const nextMetrics = resolved.chartType === 'combo' ? [nextM0, secondaryMetric] : [nextM0]
                  commitResolved({ metrics: nextMetrics })
                }}
              />

              {/* Secondary Metric Selector for Dual-Axis Combo */}
              {resolved.chartType === 'combo' && (
                <MetricCapsule
                  labelPrefix={t('pod.content.right_axis_prefix', { defaultValue: 'Right axis' })}
                  metric={secondaryMetric}
                  fields={props.fields}
                  operationLabels={operationLabels}
                  missing={isMissingKind('metric_1')}
                  disabled={props.configuring}
                  onChange={nextM1 => commitResolved({ metrics: [primaryMetric, nextM1] })}
                />
              )}

              {/* Group Sort Selector */}
              {resolved.chartType !== 'stat' && resolved.groupBy.length > 0 && (
                <Choice
                  label={t('pod.content.sort', { defaultValue: 'Sort' })}
                  disabled={props.configuring}
                  value={resolved.sortMode}
                  onChange={nextSortMode => {
                    commitResolved({
                      sortMode: nextSortMode,
                      ...(resolved.topN && (nextSortMode === 'metric_asc' || nextSortMode === 'metric_desc')
                        ? {
                            topN: {
                              ...resolved.topN,
                              direction: nextSortMode === 'metric_asc' ? 'asc' : 'desc'
                            }
                          }
                        : {})
                    })
                  }}
                  options={sortOptions}
                />
              )}
            </>
          )}

          {/* Display Options Popover */}
          <ChartDisplayOptionsPopover
            resolved={resolved}
            hasTimeBucket={Boolean(g0Field && isDatetimeField(g0Field))}
            disabled={props.configuring}
            onChange={commitResolved}
          />
        </div>
      )}

      {/* Missing-field in-place repair callout */}
      {missingSlots.length > 0 && (
        <div
          role="alert"
          data-slot="chart-missing-fields"
          className="flex items-start gap-2 rounded-control border border-warning/60 bg-warning/10 px-3 py-2 text-xs text-foreground">
          <RiAlertLine aria-hidden="true" className="mt-0.5 size-4 shrink-0 text-warning" />
          <div className="space-y-1">
            <p className="font-medium">
              {t('pod.content.chart_missing_field_title', {
                defaultValue: 'A field used by this chart was deleted.'
              })}
            </p>
            {canConfigure && (
              <p className="text-fg-secondary">
                {t('pod.content.chart_missing_field_hint', {
                  defaultValue:
                    'Choose a replacement field in the highlighted control above to update this chart without losing its layout or filters.'
                })}
              </p>
            )}
          </div>
        </div>
      )}

      {/* Body execution */}
      {hasRequiredMissing ? null : resolved.chartType === 'scatter' ? (
        <ScatterChartBody {...props} resolved={resolved} />
      ) : (
        <AggregateChartBody {...props} resolved={resolved} onCommitPatch={commitResolved} />
      )}
    </div>
  )
}

function MetricCapsule({
  labelPrefix,
  metric,
  fields,
  operationLabels,
  missing,
  disabled,
  onChange
}: {
  labelPrefix: string
  metric: ChartMetric
  fields: readonly BaseField[]
  operationLabels: Record<MetricOperation, string>
  missing: boolean
  disabled?: boolean
  onChange(next: ChartMetric): void
}) {
  const { t } = useTranslation()
  const compatible = compatibleMetricFields(fields, metric.operation)
  const availableOps = METRIC_OPERATIONS.filter(op => op === 'count' || compatibleMetricFields(fields, op).length > 0)

  return (
    <div className={`inline-flex flex-wrap items-center gap-1 ${missing ? 'rounded-control ring-2 ring-warning' : ''}`}>
      <Choice
        label={`${labelPrefix} operation`}
        disabled={disabled}
        value={metric.operation}
        onChange={nextOp => {
          if (nextOp === 'count') {
            onChange({ operation: 'count', alias: metric.alias })
            return
          }
          const nextCompatible = compatibleMetricFields(fields, nextOp)
          const preserved = nextCompatible.find(f => f.id === metric.field_id) ?? nextCompatible[0]
          onChange({
            operation: nextOp,
            ...(preserved ? { field_id: preserved.id } : {}),
            alias: metric.alias
          })
        }}
        options={
          Object.fromEntries(availableOps.map(op => [op, `${labelPrefix}: ${operationLabels[op]}`])) as Record<
            MetricOperation,
            string
          >
        }
      />
      {(metric.operation !== 'count' || missing || Boolean(metric.field_id)) && compatible.length > 0 && (
        <Choice
          label={`${labelPrefix} field`}
          disabled={disabled}
          value={metric.field_id ?? ''}
          onChange={fieldId => {
            if (!fieldId && metric.operation === 'count') {
              onChange({ operation: 'count', alias: metric.alias })
              return
            }
            if (fieldId) {
              onChange({ operation: metric.operation, field_id: fieldId, alias: metric.alias })
            }
          }}
          options={{
            ...(metric.operation === 'count' && !missing
              ? { '': t('pod.content.all_records', { defaultValue: 'All records' }) }
              : missing
                ? {
                    '': t('pod.content.missing_field_placeholder', {
                      defaultValue: 'Deleted field — choose replacement'
                    })
                  }
                : {}),
            ...Object.fromEntries(compatible.map(f => [f.id, f.name]))
          }}
        />
      )}
    </div>
  )
}

function CommitTextInput({
  id,
  label,
  value,
  placeholder,
  inputMode,
  onCommit
}: {
  id: string
  label: string
  value: string
  placeholder?: string
  inputMode?: 'text' | 'decimal'
  onCommit(next: string): void
}) {
  const [draft, setDraft] = useState(value)
  return (
    <div className="grid gap-1">
      <label htmlFor={id} className="text-fg-secondary">
        {label}
      </label>
      <Input
        id={id}
        value={draft}
        placeholder={placeholder}
        inputMode={inputMode}
        onChange={event => setDraft(event.target.value)}
        onBlur={() => {
          if (draft !== value) onCommit(draft)
        }}
        onKeyDown={event => {
          if (event.key === 'Enter' && !event.nativeEvent.isComposing) {
            event.preventDefault()
            if (draft !== value) onCommit(draft)
          }
        }}
      />
    </div>
  )
}

function ChartDisplayOptionsPopover({
  resolved,
  hasTimeBucket,
  disabled,
  onChange
}: {
  resolved: ResolvedChartConfig
  hasTimeBucket: boolean
  disabled?: boolean
  onChange(patch: Partial<ResolvedChartConfig>): void
}) {
  const { t } = useTranslation()
  const refValueId = useId()
  const refLabelId = useId()
  const captionId = useId()

  const isStat = resolved.chartType === 'stat'
  const isScatter = resolved.chartType === 'scatter'
  const cumulativeAllowed = canUseCumulative(resolved.metrics)
  const stackAllowed = STACKABLE_TYPES.has(resolved.chartType) && resolved.groupBy.length > 1
  const smoothAllowed = SMOOTHABLE_TYPES.has(resolved.chartType)
  const referenceLineAllowed = !isStat && !ONE_DIM_ONLY_TYPES.has(resolved.chartType)
  const currentLimit = resolved.topN ? String(resolved.topN.limit) : 'off'
  const primaryRefLine = resolved.referenceLines[0]

  return (
    <Popover>
      <PopoverTrigger render={<Button size="sm" variant="outline" disabled={disabled} />}>
        <RiEqualizerLine aria-hidden="true" />
        <span>{t('pod.content.chart_options', { defaultValue: 'Options' })}</span>
      </PopoverTrigger>
      <PopoverContent
        align="end"
        collisionPadding={16}
        className="max-h-[75vh] w-80 space-y-3 overflow-y-auto p-3 text-xs">
        <PopoverTitle>{t('pod.content.chart_display_options', { defaultValue: 'Display & ranking' })}</PopoverTitle>

        {stackAllowed && (
          <div className="grid gap-1">
            <span className="text-fg-secondary">{t('pod.content.stack_mode', { defaultValue: 'Series layout' })}</span>
            <Choice
              label={t('pod.content.stack_mode', { defaultValue: 'Series layout' })}
              value={resolved.stackMode}
              onChange={stackMode => onChange({ stackMode })}
              options={{
                grouped: t('pod.content.stack_grouped', { defaultValue: 'Grouped' }),
                stacked: t('pod.content.stack_stacked', { defaultValue: 'Stacked' }),
                percent: t('pod.content.stack_percent', { defaultValue: '100% stacked' })
              }}
            />
          </div>
        )}

        {!isStat && (
          <div className="grid gap-1">
            <span className="text-fg-secondary">
              {t('pod.content.chart_height', { defaultValue: 'Canvas height' })}
            </span>
            <Choice
              label={t('pod.content.chart_height', { defaultValue: 'Canvas height' })}
              value={resolved.height}
              onChange={height => onChange({ height })}
              options={{
                sm: t('pod.content.height_sm', { defaultValue: 'Compact (240px)' }),
                md: t('pod.content.height_md', { defaultValue: 'Standard (320px)' }),
                lg: t('pod.content.height_lg', { defaultValue: 'Tall (420px)' }),
                xl: t('pod.content.height_xl', { defaultValue: 'Extra tall (520px)' })
              }}
            />
          </div>
        )}

        {!isStat && !isScatter && resolved.groupBy.length > 0 && (
          <>
            <div className="grid gap-1">
              <span className="text-fg-secondary">
                {t('pod.content.top_n_limit', { defaultValue: 'Top categories' })}
              </span>
              <Choice
                label={t('pod.content.top_n_limit', { defaultValue: 'Top categories' })}
                value={currentLimit}
                onChange={val => {
                  if (val === 'off') {
                    onChange({ topN: null })
                    return
                  }
                  const limit = Number(val)
                  const targetIdx = resolved.groupBy.length === 2 ? 1 : 0
                  onChange({
                    topN: {
                      target_group_index: targetIdx,
                      limit,
                      by: resolved.metrics[0]?.alias ?? 'count',
                      direction: resolved.sortMode === 'metric_asc' ? 'asc' : 'desc',
                      include_other: resolved.topN?.include_other ?? true
                    }
                  })
                }}
                options={{
                  off: t('pod.content.top_n_off', { defaultValue: 'Show all groups' }),
                  '5': 'Top 5',
                  '10': 'Top 10',
                  '20': 'Top 20',
                  '50': 'Top 50'
                }}
              />
            </div>

            {resolved.topN && (
              <label className="flex cursor-pointer items-center gap-2">
                <Checkbox
                  checked={resolved.topN.include_other !== false}
                  onCheckedChange={checked =>
                    onChange({
                      topN: {
                        ...resolved.topN!,
                        include_other: Boolean(checked)
                      }
                    })
                  }
                />
                <span>{t('pod.content.include_other_bucket', { defaultValue: 'Fold remaining into "Other"' })}</span>
              </label>
            )}
          </>
        )}

        {!isStat && !isScatter && (
          <label className="flex cursor-pointer items-center gap-2">
            <Checkbox
              checked={resolved.showDataLabels}
              onCheckedChange={checked => onChange({ showDataLabels: Boolean(checked) })}
            />
            <span>{t('pod.content.show_data_labels', { defaultValue: 'Show data labels' })}</span>
          </label>
        )}

        {smoothAllowed && (
          <label className="flex cursor-pointer items-center gap-2">
            <Checkbox checked={resolved.smooth} onCheckedChange={checked => onChange({ smooth: Boolean(checked) })} />
            <span>{t('pod.content.smooth_curve', { defaultValue: 'Smooth curve' })}</span>
          </label>
        )}

        {!isStat && (
          <label className="flex cursor-pointer items-center gap-2">
            <Checkbox
              checked={resolved.showLegend !== false}
              onCheckedChange={checked => onChange({ showLegend: Boolean(checked) })}
            />
            <span>{t('pod.content.show_legend', { defaultValue: 'Show legend' })}</span>
          </label>
        )}

        {!isStat && !isScatter && hasTimeBucket && !resolved.omitZero && (
          <label className="flex cursor-pointer items-center gap-2">
            <Checkbox
              checked={resolved.fillMissingBuckets !== false}
              onCheckedChange={checked => onChange({ fillMissingBuckets: Boolean(checked) })}
            />
            <span>{t('pod.content.fill_missing_buckets', { defaultValue: 'Fill empty dates on timeline' })}</span>
          </label>
        )}

        {!isStat && !isScatter && resolved.groupBy.length > 0 && (
          <div className="space-y-1">
            <label className={`flex items-center gap-2 ${cumulativeAllowed ? 'cursor-pointer' : 'opacity-60'}`}>
              <Checkbox
                checked={cumulativeAllowed && resolved.cumulative}
                disabled={!cumulativeAllowed}
                onCheckedChange={checked => onChange({ cumulative: Boolean(checked) })}
              />
              <span>{t('pod.content.cumulative_total', { defaultValue: 'Cumulative running total' })}</span>
            </label>
            {!cumulativeAllowed && (
              <p className="text-[11px] text-fg-tertiary">
                {t('pod.content.cumulative_sum_count_only', {
                  defaultValue: 'Available for Count and Sum metrics.'
                })}
              </p>
            )}
          </div>
        )}

        {!isScatter && resolved.groupBy.length > 0 && (
          <label className="flex cursor-pointer items-center gap-2">
            <Checkbox
              checked={resolved.omitEmpty}
              onCheckedChange={checked => onChange({ omitEmpty: Boolean(checked) })}
            />
            <span>{t('pod.content.omit_empty_groups', { defaultValue: 'Hide empty / ungrouped values' })}</span>
          </label>
        )}

        {!isStat && !isScatter && (
          <label className="flex cursor-pointer items-center gap-2">
            <Checkbox
              checked={resolved.omitZero}
              onCheckedChange={checked => onChange({ omitZero: Boolean(checked) })}
            />
            <span>{t('pod.content.omit_zero_values', { defaultValue: 'Omit zero values' })}</span>
          </label>
        )}

        {referenceLineAllowed && (
          <div className="space-y-2 border-t border-border pt-2">
            <CommitTextInput
              key={`ref-val:${primaryRefLine?.value ?? ''}`}
              id={refValueId}
              label={t('pod.content.reference_line_value', { defaultValue: 'Target reference line' })}
              value={primaryRefLine ? String(primaryRefLine.value) : ''}
              placeholder="0"
              inputMode="decimal"
              onCommit={raw => {
                const trimmed = raw.trim()
                if (!trimmed) {
                  onChange({ referenceLines: resolved.referenceLines.slice(1) })
                  return
                }
                const parsed = Number(trimmed)
                if (!Number.isFinite(parsed)) return
                const updated: ChartReferenceLine = {
                  ...primaryRefLine,
                  value: parsed
                }
                onChange({ referenceLines: [updated, ...resolved.referenceLines.slice(1)] })
              }}
            />
            {primaryRefLine && (
              <div className="space-y-1.5">
                <CommitTextInput
                  key={`ref-lbl:${primaryRefLine.label ?? ''}`}
                  id={refLabelId}
                  label={t('pod.content.reference_line_label', { defaultValue: 'Reference line label' })}
                  value={primaryRefLine.label ?? ''}
                  onCommit={raw => {
                    const trimmed = raw.trim()
                    const updated: ChartReferenceLine = {
                      ...primaryRefLine,
                      ...(trimmed ? { label: trimmed } : {})
                    }
                    if (!trimmed) delete updated.label
                    onChange({ referenceLines: [updated, ...resolved.referenceLines.slice(1)] })
                  }}
                />
                <Button
                  size="xs"
                  variant="ghost"
                  onClick={() => onChange({ referenceLines: resolved.referenceLines.slice(1) })}>
                  {t('pod.content.clear_reference_line', { defaultValue: 'Remove reference line' })}
                </Button>
              </div>
            )}
          </div>
        )}

        <div className="border-t border-border pt-2">
          <CommitTextInput
            key={`caption:${resolved.caption ?? ''}`}
            id={captionId}
            label={t('pod.content.chart_caption', { defaultValue: 'Caption' })}
            value={resolved.caption ?? ''}
            onCommit={raw => {
              const trimmed = raw.trim()
              onChange({ caption: trimmed || undefined })
            }}
          />
        </div>
      </PopoverContent>
    </Popover>
  )
}
