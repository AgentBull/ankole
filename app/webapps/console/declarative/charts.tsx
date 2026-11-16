import { AnkoleChart, Button } from '@ankole/uikit'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { isRecord } from './transport'

export interface DeclarativeSeriesPoint {
  readonly bucket: string
  readonly value: number | null
  readonly noData: boolean
}

export interface DeclarativeDrilldownSelection {
  readonly bucket: string
  readonly dateKey: string
  readonly timezone: string
}

const UTC_TIME_SUFFIX = /(?:Z|[+-]\d{2}:\d{2})$/i

export function normalizeSeriesPoints(rawSeries: unknown, metricKey = 'requests'): DeclarativeSeriesPoint[] {
  const rows = Array.isArray(rawSeries) ? rawSeries : []
  return rows.flatMap(entry => {
    if (!isRecord(entry) || typeof entry.bucket !== 'string') return []
    const noData = entry.no_data === true
    const rawValue = entry[metricKey] ?? entry.value
    const value = noData || rawValue === null || rawValue === undefined ? null : Number(rawValue)
    return [
      {
        bucket: entry.bucket,
        value: value !== null && Number.isFinite(value) ? value : null,
        noData: noData || value === null || !Number.isFinite(value)
      }
    ]
  })
}

export function bucketDateInTimezone(bucket: string, timezone = 'UTC'): string {
  const trimmed = bucket.trim()
  if (/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) return trimmed
  const isoInput = trimmed.includes('T')
    ? UTC_TIME_SUFFIX.test(trimmed)
      ? trimmed
      : `${trimmed}Z`
    : `${trimmed.replace(' ', 'T')}Z`
  const date = new Date(isoInput)
  if (Number.isNaN(date.getTime())) return trimmed.slice(0, 10)
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone || 'UTC',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit'
  }).format(date)
}

export function DeclarativeSeriesChart({
  title,
  timezone = 'UTC',
  series,
  seriesOptions = ['requests', 'cost'],
  labelPrefix = 'console.field',
  onDrilldown
}: {
  title: string
  timezone?: string
  series: unknown
  seriesOptions?: readonly string[]
  labelPrefix?: string
  onDrilldown?: (selection: DeclarativeDrilldownSelection) => void
}) {
  const { t, i18n } = useTranslation()
  const [selectedMetric, setSelectedMetric] = useState(seriesOptions[0] ?? 'requests')
  const points = normalizeSeriesPoints(series, selectedMetric)
  const metricLabel = t(`${labelPrefix}.${selectedMetric}`, { defaultValue: selectedMetric })

  const chartData = points.map(point => ({
    bucket: point.bucket,
    [selectedMetric]: point.noData ? null : point.value
  }))

  return (
    <section className="grid gap-3 border border-border bg-card p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="title-section">{title}</h3>
        {seriesOptions.length > 1 ? (
          <div className="flex flex-wrap gap-1.5" role="group" aria-label={title}>
            {seriesOptions.map(option => (
              <Button
                key={option}
                size="xs"
                type="button"
                variant={selectedMetric === option ? 'default' : 'outline'}
                onClick={() => setSelectedMetric(option)}>
                {t(`${labelPrefix}.${option}`, { defaultValue: option })}
              </Button>
            ))}
          </div>
        ) : null}
      </div>

      <AnkoleChart
        ariaLabel={title}
        emptyState={
          <p className="text-sm text-muted-foreground">{t('console.empty.title', { defaultValue: 'No data' })}</p>
        }
        spec={{
          type: 'line',
          data: chartData,
          xField: 'bucket',
          yField: selectedMetric,
          yTitle: metricLabel
        }}
        summaryTable={{
          columns: ['Bucket', metricLabel],
          rows: points.map(point => [
            point.bucket,
            point.noData || point.value === null
              ? t('console.empty.title', { defaultValue: 'No data' })
              : new Intl.NumberFormat(i18n.language).format(point.value)
          ])
        }}
        onSummaryRowActivate={rowIndex => {
          const point = points[rowIndex]
          if (!point) return
          onDrilldown?.({
            bucket: point.bucket,
            dateKey: bucketDateInTimezone(point.bucket, timezone),
            timezone
          })
        }}
      />

      {onDrilldown && points.length > 0 ? (
        <div className="flex flex-wrap gap-1.5">
          {points.map(point => (
            <Button
              key={point.bucket}
              size="xs"
              type="button"
              variant="outline"
              onClick={() =>
                onDrilldown({
                  bucket: point.bucket,
                  dateKey: bucketDateInTimezone(point.bucket, timezone),
                  timezone
                })
              }>
              {point.bucket}
            </Button>
          ))}
        </div>
      ) : null}
    </section>
  )
}
