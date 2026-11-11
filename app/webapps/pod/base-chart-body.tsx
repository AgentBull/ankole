import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  AnkoleChart,
  AnkoleStatCard,
  Button,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
  type SeriesColorDescriptor,
  type StatisticalChartSpec
} from '@ankole/uikit'
import { formatMetricValue, useAggregate, useRecords } from '@ankole/applet-sdk'
import type { AggregateGroup, BaseRecord } from '@ankole/applet-sdk/types'
import { ArrowClockwiseRegular, ArrowMaximizeRegular } from '@ankole/uikit/icons'
import { InternalAPIError } from '../common/internal-api-client'
import { requestErrorCode } from '../common/request-errors'
import { ContentError, ContentSkeleton } from './content-primitives'
import { FieldValue, RecordTitle } from './base-fields'
import { ReferenceLabelsProvider } from './base-field-value'
import type { RecordDetailsDialogComponent, ViewProps } from './base-views'
import { fieldValue } from './state/table-query'
import type { ChartGroupBy } from './state/view-config'
import {
  STACKABLE_TYPES,
  canUseCumulative,
  formatDimensionBucketLabel,
  buildAggregateQueryFromSpec,
  buildChartDataset,
  buildDrilldownGroupSlices,
  CHART_HEIGHT_PX,
  ONE_DIM_ONLY_TYPES,
  formatMetricHeader,
  toChartNumeric,
  type BuiltChartDataset,
  type DrilldownPeriodMode,
  type ResolvedChartConfig
} from './state/chart-view'

const SCATTER_MAX_RECORDS = 1000

export type ChartViewProps = ViewProps & {
  RecordDetailsDialog: RecordDetailsDialogComponent
}

function extractApiErrorCode(error: unknown): string | undefined {
  if (error instanceof InternalAPIError) return requestErrorCode(error.payload)
  return requestErrorCode(error)
}

export function AggregateChartBody(
  props: ChartViewProps & {
    resolved: ResolvedChartConfig
    onCommitPatch(patch: Partial<ResolvedChartConfig>): void
  }
) {
  const { t } = useTranslation()
  const { resolved } = props
  const [drilldownGroup, setDrilldownGroup] = useState<{
    group: AggregateGroup
    label: string
  } | null>(null)

  const aggregateQuery = useMemo(
    () => buildAggregateQueryFromSpec(resolved, props.fields, props.view.config.filter),
    [resolved, props.fields, props.view.config.filter]
  )

  const aggregate = useAggregate(props.tableID, aggregateQuery)
  const errorCode = extractApiErrorCode(aggregate.error)

  const labels = useMemo(
    () => ({
      empty: t('pod.content.ungrouped', { defaultValue: 'Empty' }),
      other: t('pod.content.other', { defaultValue: 'Other' }),
      categoryFallback: t('pod.content.all_records', { defaultValue: 'All records' })
    }),
    [t]
  )

  const dataset = useMemo(
    () => buildChartDataset(aggregate.data?.groups ?? [], resolved, props.fields, labels),
    [aggregate.data?.groups, resolved, props.fields, labels]
  )

  if (errorCode === 'group_limit') {
    return (
      <div
        role="alert"
        data-slot="chart-group-limit-notice"
        className="space-y-2 rounded-control border border-border bg-layer-01 p-4 text-sm">
        <p className="font-medium text-foreground">
          {t('pod.content.chart_group_limit_title', {
            defaultValue: 'This chart exceeds the 1,000-group limit.'
          })}
        </p>
        <p className="text-xs text-fg-secondary">
          {t('pod.content.chart_group_limit_hint', {
            defaultValue:
              'Choose a coarser time bucket (such as Month or Quarter), enable Top 10 ranking, or narrow the view filter.'
          })}
        </p>
        <div className="flex flex-wrap gap-2 pt-1">
          {resolved.groupBy[0]?.bucket === 'day' && (
            <Button
              size="sm"
              variant="outline"
              onClick={() =>
                props.onCommitPatch({
                  groupBy: [{ ...resolved.groupBy[0]!, bucket: 'month' }, ...resolved.groupBy.slice(1)]
                })
              }>
              {t('pod.content.switch_to_monthly', { defaultValue: 'Switch to Monthly' })}
            </Button>
          )}
          {!resolved.topN && resolved.groupBy.length > 0 && (
            <Button
              size="sm"
              variant="outline"
              onClick={() =>
                props.onCommitPatch({
                  topN: {
                    target_group_index: resolved.groupBy.length === 2 ? 1 : 0,
                    limit: 10,
                    by: resolved.metrics[0]?.alias ?? 'count',
                    direction: 'desc',
                    include_other: true
                  }
                })
              }>
              {t('pod.content.enable_top_10', { defaultValue: 'Show Top 10 + Other' })}
            </Button>
          )}
        </div>
      </div>
    )
  }

  if (aggregate.error) {
    return <ContentError error={aggregate.error} retry={() => void aggregate.refetch()} />
  }

  if (aggregate.isPending && !aggregate.data) {
    return <ContentSkeleton variant="block" label={t('pod.content.loading_records')} className="h-[280px]" />
  }

  if (resolved.chartType === 'stat') {
    return (
      <StatChartContent
        {...props}
        resolved={resolved}
        dataset={dataset}
        onRefreshParentAggregate={() => void aggregate.refetch()}
      />
    )
  }

  const g0Field = resolved.groupBy[0]?.field_id
    ? props.fields.find(f => f.id === resolved.groupBy[0]!.field_id)
    : undefined
  const g1Field = resolved.groupBy[1]?.field_id
    ? props.fields.find(f => f.id === resolved.groupBy[1]!.field_id)
    : undefined
  const primaryMetric = resolved.metrics[0]
  const secondaryMetric = resolved.chartType === 'combo' ? resolved.metrics[1] : undefined
  const primaryField = primaryMetric?.field_id ? props.fields.find(f => f.id === primaryMetric.field_id) : undefined
  const secondaryField = secondaryMetric?.field_id
    ? props.fields.find(f => f.id === secondaryMetric.field_id)
    : undefined

  const hasSeries = resolved.groupBy.length > 1 && resolved.chartType !== 'combo'
  const spec: StatisticalChartSpec = {
    type: resolved.chartType,
    data: dataset.rows,
    xField: 'x',
    yField: 'y',
    xTitle: g0Field?.name ?? labels.categoryFallback,
    yTitle: primaryMetric ? formatMetricHeader(primaryMetric, primaryField) : 'Count',
    formattedYField: '__formattedY',
    ...(resolved.chartType === 'combo'
      ? {
          secondaryYField: 'y2',
          secondaryYTitle: secondaryMetric ? formatMetricHeader(secondaryMetric, secondaryField) : 'Count',
          formattedSecondaryYField: '__formattedY2'
        }
      : {}),
    ...(hasSeries ? { seriesField: 'series', ...(g1Field ? { seriesTitle: g1Field.name } : {}) } : {}),
    ...(ONE_DIM_ONLY_TYPES.has(resolved.chartType) ? { valueField: 'y' } : {}),
    seriesMeta: dataset.seriesMeta,
    ...(STACKABLE_TYPES.has(resolved.chartType) && hasSeries ? { stackMode: resolved.stackMode } : {}),
    showDataLabels: resolved.showDataLabels,
    smooth: resolved.smooth,
    ...(resolved.showLegend !== undefined ? { showLegend: resolved.showLegend } : {}),
    ...(dataset.donutCenterLabel ? { donutCenterLabel: dataset.donutCenterLabel } : {}),
    ...(resolved.referenceLines.length > 0 ? { referenceLines: resolved.referenceLines } : {}),
    height: CHART_HEIGHT_PX[resolved.height],
    onElementClick: datum => {
      const idx = typeof datum.__groupIndex === 'number' ? datum.__groupIndex : -1
      const clicked = idx >= 0 ? dataset.processedGroups[idx] : undefined
      if (!clicked) return
      const labelParts = [String(datum.x ?? '')]
      if (datum.series !== undefined) labelParts.push(String(datum.series))
      setDrilldownGroup({ group: clicked, label: labelParts.filter(Boolean).join(' · ') })
    }
  }

  return (
    <>
      <AnkoleChart
        spec={spec}
        ariaLabel={props.view.name}
        caption={resolved.caption}
        summaryTable={dataset.summaryTable}
        tableToggleLabel={t('pod.content.data_table', { defaultValue: 'Data table' })}
        allowExport
        exportFilename={props.view.name}
        exportPngLabel={t('pod.content.export_png', { defaultValue: 'Export PNG' })}
        exportSvgLabel={t('pod.content.export_svg', { defaultValue: 'Export SVG' })}
        emptyState={t('pod.content.this_view_has_no_records_adjust_the_filters')}
      />
      {drilldownGroup && (
        <ChartDrilldownDialog
          {...props}
          title={drilldownGroup.label}
          clickedGroup={drilldownGroup.group}
          allGroups={dataset.processedGroups}
          groupBy={resolved.groupBy}
          isCumulative={resolved.cumulative && canUseCumulative(resolved.metrics)}
          firstChronologicalBucketJson={dataset.firstChronologicalBucketJson}
          aggregateDataVersion={aggregate.data?.data_version}
          onRefreshAggregate={() => void aggregate.refetch()}
          onClose={() => setDrilldownGroup(null)}
        />
      )}
    </>
  )
}

function StatChartContent(
  props: ChartViewProps & {
    resolved: ResolvedChartConfig
    dataset: BuiltChartDataset
    onRefreshParentAggregate(): void
  }
) {
  const { t } = useTranslation()
  const [drilldownOpen, setDrilldownOpen] = useState(false)
  const primaryMetric = props.resolved.metrics[0] ?? { operation: 'count' as const, alias: 'count' }
  const metricField = primaryMetric.field_id ? props.fields.find(f => f.id === primaryMetric.field_id) : undefined

  // Fetch scalar headline total across the whole filtered table so KPI value is exact even when sparkline groups exist
  const totalAggregate = useAggregate(props.tableID, {
    ...(props.view.config.filter ? { filter: props.view.config.filter } : {}),
    metrics: [
      {
        operation: primaryMetric.operation,
        ...(metricField ? { field_id: metricField.id } : {}),
        alias: primaryMetric.alias
      }
    ]
  })

  const totalGroup = totalAggregate.data?.groups[0]
  const formattedHeadline = totalGroup
    ? formatMetricValue(
        totalGroup.metrics[primaryMetric.alias],
        totalGroup.metrics_text?.[primaryMetric.alias],
        metricField
      )
    : '0'

  const periodStats = useMemo(() => {
    if (props.resolved.groupBy.length === 0) {
      return { sparklineValues: undefined, delta: undefined, baseline: undefined }
    }
    const valid = props.dataset.processedGroups
      .filter(g => !g.other?.[0] && g.values[0] !== null && g.values[0] !== undefined)
      .map(g => {
        const num = toChartNumeric(g.metrics[primaryMetric.alias], g.metrics_text?.[primaryMetric.alias])
        return num === null
          ? null
          : {
              label: String(g.values[0]),
              num,
              formatted: formatMetricValue(
                g.metrics[primaryMetric.alias],
                g.metrics_text?.[primaryMetric.alias],
                metricField
              )
            }
      })
      .filter((entry): entry is { label: string; num: number; formatted: string } => entry !== null)

    if (valid.length < 2) {
      return { sparklineValues: undefined, delta: undefined, baseline: undefined }
    }

    const prev = valid[valid.length - 2]!
    const curr = valid[valid.length - 1]!
    let delta: string
    if (prev.num !== 0) {
      const pct = ((curr.num - prev.num) / Math.abs(prev.num)) * 100
      const rounded = Math.round(pct * 10) / 10
      delta = rounded === 0 ? '0%' : `${rounded > 0 ? '+' : ''}${rounded}%`
    } else if (curr.num === 0) {
      delta = '0%'
    } else {
      delta = curr.num > 0 ? `+${curr.formatted}` : curr.formatted
    }

    const baseline = t('pod.content.stat_period_comparison', {
      defaultValue: '{$currentLabel}: {$currentValue} vs. {$previousLabel}: {$previousValue}',
      currentLabel: curr.label,
      currentValue: curr.formatted,
      previousLabel: prev.label,
      previousValue: prev.formatted
    })

    return {
      sparklineValues: valid.map(v => v.num),
      delta,
      baseline
    }
  }, [props.dataset.processedGroups, props.resolved.groupBy.length, primaryMetric.alias, metricField, t])

  if (totalAggregate.error) {
    return <ContentError error={totalAggregate.error} retry={() => void totalAggregate.refetch()} />
  }
  if (totalAggregate.isPending) {
    return <ContentSkeleton variant="block" className="h-24" />
  }

  const label = metricField
    ? `${primaryMetric.operation.toUpperCase()} · ${metricField.name}`
    : t('pod.content.total_records', { defaultValue: 'Total records' })

  return (
    <>
      <button
        type="button"
        data-slot="stat-drilldown-trigger"
        onClick={() => setDrilldownOpen(true)}
        className="block w-full max-w-md cursor-pointer rounded-control text-left transition hover:ring-2 hover:ring-ring/40 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring">
        <AnkoleStatCard
          label={label}
          value={formattedHeadline}
          delta={periodStats.delta}
          baseline={periodStats.baseline}
          sparklineValues={periodStats.sparklineValues}
          caption={props.resolved.caption}
        />
      </button>
      {drilldownOpen && (
        <ChartDrilldownDialog
          {...props}
          title={typeof label === 'string' ? label : props.view.name}
          clickedGroup={{ values: [], other: [], metrics: {} }}
          allGroups={[]}
          groupBy={[]}
          isCumulative={false}
          firstChronologicalBucketJson={null}
          aggregateDataVersion={totalAggregate.data?.data_version}
          onRefreshAggregate={() => {
            void totalAggregate.refetch()
            props.onRefreshParentAggregate()
          }}
          onClose={() => setDrilldownOpen(false)}
        />
      )}
    </>
  )
}

export function ScatterChartBody(props: ChartViewProps & { resolved: ResolvedChartConfig }) {
  const { t } = useTranslation()
  const { resolved, RecordDetailsDialog } = props
  const [detailRecord, setDetailRecord] = useState<BaseRecord | null>(null)

  const xField = resolved.scatterX?.field_id ? props.fields.find(f => f.id === resolved.scatterX!.field_id) : undefined
  const yField = resolved.scatterY?.field_id ? props.fields.find(f => f.id === resolved.scatterY!.field_id) : undefined
  const sizeField = resolved.scatterSize?.field_id
    ? props.fields.find(f => f.id === resolved.scatterSize!.field_id)
    : undefined
  const colorField = resolved.scatterColor?.field_id
    ? props.fields.find(f => f.id === resolved.scatterColor!.field_id)
    : undefined

  const records = useRecords(props.tableID, {
    filter: props.view.config.filter,
    sort: props.view.config.sort,
    page_size: SCATTER_MAX_RECORDS
  })

  const emptyLabel = t('pod.content.ungrouped', { defaultValue: 'Empty' })

  const { rows, seriesMeta, summaryTable } = useMemo(() => {
    const rawRecords = records.data?.records ?? []
    const pts: Record<string, unknown>[] = []
    const metaMap = new Map<string, SeriesColorDescriptor>()

    if (xField && yField) {
      for (const rec of rawRecords) {
        const rawX = fieldValue(rec, xField)
        const rawY = fieldValue(rec, yField)
        const xNum = toChartNumeric(rawX)
        const yNum = toChartNumeric(rawY)
        if (xNum === null || yNum === null) continue
        const sizeNum = sizeField ? toChartNumeric(fieldValue(rec, sizeField)) : null

        let seriesKey: string | undefined
        if (colorField) {
          const rawC = fieldValue(rec, colorField)
          const formatted = formatDimensionBucketLabel(rawC, false, colorField, undefined, {
            empty: emptyLabel,
            other: 'Other'
          })
          seriesKey = formatted.key
          if (!metaMap.has(seriesKey)) {
            metaMap.set(seriesKey, {
              key: seriesKey,
              isEmpty: formatted.isEmpty,
              optionColor: formatted.optionColor
            })
          }
        }

        pts.push({
          x: xNum,
          y: yNum,
          __formattedY: formatMetricValue(rawY, String(yNum), yField),
          ...(sizeNum !== null ? { size: sizeNum } : {}),
          ...(seriesKey !== undefined ? { series: seriesKey } : {}),
          __recordId: rec.id
        })
      }
    }

    const cols = [
      xField?.name ?? 'X',
      yField?.name ?? 'Y',
      ...(sizeField ? [sizeField.name] : []),
      ...(colorField ? [colorField.name] : [])
    ]
    const sRows = pts
      .slice(0, 200)
      .map(p => [
        p.x as number,
        p.y as number,
        ...(sizeField ? [(p.size as number | undefined) ?? null] : []),
        ...(colorField ? [String(p.series ?? '')] : [])
      ])

    return {
      rows: pts,
      seriesMeta: [...metaMap.values()],
      summaryTable: { columns: cols, rows: sRows }
    }
  }, [records.data?.records, xField, yField, sizeField, colorField, emptyLabel])

  if (records.error) {
    return <ContentError error={records.error} retry={() => void records.refetch()} />
  }

  if (!xField || !yField) {
    return (
      <p className="py-6 text-sm text-fg-tertiary">
        {t('pod.content.scatter_requires_numeric_axes', {
          defaultValue: 'Select numeric X and Y fields above to plot a scatter chart.'
        })}
      </p>
    )
  }

  const truncated = Boolean(records.data?.page_token)

  const spec: StatisticalChartSpec = {
    type: 'scatter',
    data: rows,
    xField: 'x',
    yField: 'y',
    xTitle: xField.name,
    yTitle: yField.name,
    formattedYField: '__formattedY',
    ...(sizeField ? { sizeField: 'size', sizeTitle: sizeField.name } : {}),
    ...(colorField ? { seriesField: 'series', seriesTitle: colorField.name, seriesMeta } : {}),
    ...(resolved.showLegend !== undefined ? { showLegend: resolved.showLegend } : {}),
    ...(resolved.referenceLines.length > 0 ? { referenceLines: resolved.referenceLines } : {}),
    height: CHART_HEIGHT_PX[resolved.height],
    onElementClick: datum => {
      const id = typeof datum.__recordId === 'string' ? datum.__recordId : undefined
      if (!id) return
      const found = records.data?.records.find(r => r.id === id)
      if (found) setDetailRecord(found)
    }
  }

  return (
    <div className="space-y-2">
      {truncated && (
        <p
          role="status"
          data-slot="scatter-truncation-notice"
          className="rounded-control border border-border bg-layer-01 px-3 py-1.5 text-xs text-fg-secondary">
          {t('pod.content.scatter_first_1000_notice', {
            defaultValue:
              'Showing the first 1,000 records ordered by the current sort (deterministic prefix, not a random sample).'
          })}
        </p>
      )}
      <AnkoleChart
        spec={spec}
        ariaLabel={props.view.name}
        caption={resolved.caption}
        summaryTable={summaryTable}
        tableToggleLabel={t('pod.content.data_table', { defaultValue: 'Data table' })}
        allowExport
        exportFilename={props.view.name}
        exportPngLabel={t('pod.content.export_png', { defaultValue: 'Export PNG' })}
        exportSvgLabel={t('pod.content.export_svg', { defaultValue: 'Export SVG' })}
        emptyState={t('pod.content.this_view_has_no_records_adjust_the_filters')}
      />
      {detailRecord && (
        <RecordDetailsDialog
          open
          onOpenChange={open => !open && setDetailRecord(null)}
          record={detailRecord}
          fields={props.fields}
          pageID={props.pageID}
          editable={props.editable}
          pending={records.write.isPending}
          update={records.update}
          remove={records.remove}
        />
      )}
    </div>
  )
}

function ChartDrilldownDialog(
  props: ChartViewProps & {
    title: string
    clickedGroup: AggregateGroup
    allGroups: readonly AggregateGroup[]
    groupBy: readonly ChartGroupBy[]
    isCumulative: boolean
    firstChronologicalBucketJson: string | null
    aggregateDataVersion: number | undefined
    onRefreshAggregate(): void
    onClose(): void
  }
) {
  const { RecordDetailsDialog } = props
  const { t } = useTranslation()
  const [periodMode, setPeriodMode] = useState<DrilldownPeriodMode>(
    props.isCumulative ? 'through_period' : 'single_period'
  )
  const [token, setToken] = useState<string | undefined>(undefined)
  const [history, setHistory] = useState<(string | undefined)[]>([])
  const [selectedRecordId, setSelectedRecordId] = useState<string | undefined>(undefined)

  const slices = useMemo(
    () =>
      buildDrilldownGroupSlices({
        clickedGroup: props.clickedGroup,
        allGroups: props.allGroups,
        groupBy: props.groupBy,
        periodMode,
        firstChronologicalBucketJson: props.firstChronologicalBucketJson
      }),
    [props.clickedGroup, props.allGroups, props.groupBy, periodMode, props.firstChronologicalBucketJson]
  )

  const rows = useRecords(props.tableID, {
    filter: props.view.config.filter,
    sort: props.view.config.sort,
    group: slices,
    page_size: 50,
    page_token: token
  })

  const versionDrifted =
    rows.data?.data_version !== undefined &&
    props.aggregateDataVersion !== undefined &&
    rows.data.data_version !== props.aggregateDataVersion

  const primaryField = props.fields.find(f => f.is_primary) ?? props.fields[0]
  const previewFields = props.fields.filter(f => f !== primaryField).slice(0, 4)
  const selectedRecord = selectedRecordId ? rows.data?.records.find(r => r.id === selectedRecordId) : undefined

  return (
    <Dialog open onOpenChange={open => !open && props.onClose()}>
      <DialogContent className="pod-dialog max-w-2xl" closeLabel={t('common.close')}>
        <DialogTitle>
          {props.title || t('pod.content.drilldown_records', { defaultValue: 'Matching records' })}
        </DialogTitle>

        {props.isCumulative &&
          typeof props.firstChronologicalBucketJson === 'string' &&
          !props.clickedGroup.other?.[0] && (
            <div className="flex flex-wrap items-center gap-1.5 text-xs" data-slot="drilldown-cumulative-toggle">
              <Button
                size="xs"
                variant={periodMode === 'through_period' ? 'default' : 'outline'}
                onClick={() => {
                  setPeriodMode('through_period')
                  setToken(undefined)
                  setHistory([])
                }}>
                {t('pod.content.drilldown_cumulative_through', { defaultValue: 'Cumulative through period' })}
              </Button>
              <Button
                size="xs"
                variant={periodMode === 'single_period' ? 'default' : 'outline'}
                onClick={() => {
                  setPeriodMode('single_period')
                  setToken(undefined)
                  setHistory([])
                }}>
                {t('pod.content.drilldown_single_period', { defaultValue: 'Current period only' })}
              </Button>
            </div>
          )}

        {versionDrifted && (
          <div
            role="status"
            data-slot="drilldown-version-sync"
            className="flex items-center justify-between gap-2 rounded-control border border-border bg-layer-01 px-3 py-1.5 text-xs text-fg-secondary">
            <span>
              {t('pod.content.drilldown_version_updated', {
                defaultValue: 'Table records changed since this chart loaded.'
              })}
            </span>
            <Button size="xs" variant="ghost" onClick={props.onRefreshAggregate}>
              <ArrowClockwiseRegular aria-hidden="true" />
              {t('pod.content.refresh_chart', { defaultValue: 'Refresh chart' })}
            </Button>
          </div>
        )}

        <ContentError error={rows.error} retry={() => void rows.refetch()} />

        <ReferenceLabelsProvider fields={props.fields} records={rows.data?.records ?? []}>
          <div className="pod-dialog-body max-h-96 divide-y divide-border overflow-y-auto">
            {rows.isPending && !rows.data ? (
              <ContentSkeleton variant="list" label={t('pod.content.loading_records')} className="py-3" />
            ) : !rows.data ? null : !rows.data.records.length ? (
              <p className="py-6 text-sm text-fg-tertiary">
                {t('pod.content.this_view_has_no_records_adjust_the_filters')}
              </p>
            ) : (
              rows.data.records.map(record => (
                <div
                  key={record.id}
                  className="flex items-center justify-between gap-3 py-2.5 text-sm hover:bg-layer-01/60">
                  <div className="min-w-0 flex-1 space-y-0.5">
                    <div className="truncate font-medium text-foreground">
                      <RecordTitle record={record} primary={primaryField} />
                    </div>
                    {previewFields.length > 0 && (
                      <div className="flex flex-wrap gap-x-3 gap-y-0.5 text-xs text-fg-tertiary">
                        {previewFields.map(field => (
                          <span key={field.id} className="truncate">
                            {field.name}:{' '}
                            <FieldValue field={field} value={fieldValue(record, field)} pageID={props.pageID} />
                          </span>
                        ))}
                      </div>
                    )}
                  </div>
                  <Button
                    size="icon-xs"
                    variant="ghost"
                    aria-label={t('pod.content.record_details')}
                    title={t('pod.content.record_details')}
                    onClick={() => setSelectedRecordId(record.id)}>
                    <ArrowMaximizeRegular aria-hidden="true" />
                  </Button>
                </div>
              ))
            )}
          </div>
        </ReferenceLabelsProvider>

        <DialogFooter className="flex items-center justify-between gap-2">
          <div className="flex gap-2">
            {(history.length > 0 || rows.data?.page_token) && (
              <>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={!history.length || rows.isFetching}
                  onClick={() => {
                    setToken(history.at(-1))
                    setHistory(history.slice(0, -1))
                  }}>
                  {t('pod.content.previous_page')}
                </Button>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={!rows.data?.page_token || rows.isFetching}
                  onClick={() => {
                    setHistory([...history, token])
                    setToken(rows.data?.page_token ?? undefined)
                  }}>
                  {t('pod.content.next_page')}
                </Button>
              </>
            )}
          </div>
          <Button variant="ghost" onClick={props.onClose}>
            {t('common.close')}
          </Button>
        </DialogFooter>

        {selectedRecord && (
          <RecordDetailsDialog
            open
            onOpenChange={open => !open && setSelectedRecordId(undefined)}
            record={selectedRecord}
            fields={props.fields}
            pageID={props.pageID}
            editable={props.editable}
            pending={rows.write.isPending}
            update={rows.update}
            remove={rows.remove}
          />
        )}
      </DialogContent>
    </Dialog>
  )
}
