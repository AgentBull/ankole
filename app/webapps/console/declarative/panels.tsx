import {
  AnkoleStatCard,
  Badge,
  Button,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow
} from '@ankole/uikit'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ErrorBlock } from '../../common/error-block'
import { StatusIndicator } from '../console-form'
import { PageHeader, PageStack, RefreshButton } from '../console-page'
import { Link } from '../tenant-context'
import { DeclarativeSeriesChart, type DeclarativeDrilldownSelection } from './charts'
import { DeclarativeFields, DeclarativeSelect } from './fields'
import {
  withFieldDefaults,
  asRecord,
  useDeclarativeAction,
  formatIdentifierLabel,
  isRecord,
  serializeDeclarativeFields,
  surfaceQueryEndpoint,
  useDeclarativeRecords,
  type DeclarativeRecord
} from './transport'
import type {
  DeclarativeDashboardSchema,
  DeclarativeFieldFormat,
  DeclarativeResultSchema,
  DeclarativeSurfaceDescriptor
} from './types'

export function DeclarativeValue({
  value,
  field,
  fieldFormats,
  i18nPrefix = 'console'
}: {
  value: unknown
  field?: string
  fieldFormats?: Readonly<Record<string, DeclarativeFieldFormat>>
  i18nPrefix?: string
}) {
  const { t, i18n } = useTranslation()
  if (value === null || value === undefined) return <>—</>
  const explicitFormat = field ? fieldFormats?.[field] : undefined
  if (explicitFormat === 'usd_micros' && typeof value === 'number') {
    return (
      <>
        {new Intl.NumberFormat(i18n.language, { style: 'currency', currency: 'USD', maximumFractionDigits: 6 }).format(
          value / 1e6
        )}
      </>
    )
  }
  if (explicitFormat === 'percent' && typeof value === 'number') {
    return <>{new Intl.NumberFormat(i18n.language, { style: 'percent', maximumFractionDigits: 1 }).format(value)}</>
  }
  if (typeof value === 'boolean') {
    return (
      <Badge variant="secondary">
        {value ? t('common.yes', { defaultValue: 'Yes' }) : t('common.no', { defaultValue: 'No' })}
      </Badge>
    )
  }
  if (typeof value === 'number') return <>{new Intl.NumberFormat(i18n.language).format(value)}</>
  if (Array.isArray(value)) {
    if (value.length === 0) return <>—</>
    return (
      <ul className="grid gap-1">
        {value.map((item, idx) => (
          <li key={idx}>
            <DeclarativeValue field={field} fieldFormats={fieldFormats} i18nPrefix={i18nPrefix} value={item} />
          </li>
        ))}
      </ul>
    )
  }
  if (isRecord(value)) return <DeclarativeFacts fieldFormats={fieldFormats} i18nPrefix={i18nPrefix} record={value} />
  const text = String(value)
  if (field === 'status' || field === 'state' || field?.endsWith('_status') || field?.endsWith('_type')) {
    return <>{t(`${i18nPrefix}.value.${text}`, { defaultValue: formatIdentifierLabel(text) })}</>
  }
  return <>{text}</>
}

export function DeclarativeFacts({
  record,
  columns,
  fieldFormats,
  i18nPrefix = 'console'
}: {
  record: Readonly<Record<string, unknown>>
  columns?: readonly string[]
  fieldFormats?: Readonly<Record<string, DeclarativeFieldFormat>>
  i18nPrefix?: string
}) {
  const { t } = useTranslation()
  const keys = columns ?? Object.keys(record)
  return (
    <dl className="grid gap-x-4 gap-y-2 break-words text-sm sm:grid-cols-[minmax(8rem,1fr)_minmax(0,2fr)]">
      {keys
        .filter(col => record[col] != null && !['attributes', 'links', 'relationships', 'type'].includes(col))
        .map(col => (
          <div key={col} className="contents">
            <dt className="text-fg-secondary">
              {t(`${i18nPrefix}.field.${col}`, { defaultValue: formatIdentifierLabel(col) })}
            </dt>
            <dd>
              <DeclarativeValue field={col} fieldFormats={fieldFormats} i18nPrefix={i18nPrefix} value={record[col]} />
            </dd>
          </div>
        ))}
    </dl>
  )
}

export function DeclarativeStatsGrid({
  record,
  columns,
  fieldFormats,
  i18nPrefix = 'console'
}: {
  record: Readonly<Record<string, unknown>> | null
  columns?: readonly string[]
  fieldFormats?: Readonly<Record<string, DeclarativeFieldFormat>>
  i18nPrefix?: string
}) {
  const { t, i18n } = useTranslation()
  if (!record) return null
  const keys = columns ?? Object.keys(record)
  return (
    <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
      {keys.map(key => {
        const value = record[key]
        const fmt = fieldFormats?.[key]
        const usd = fmt === 'usd_micros'
        const pct = fmt === 'percent'
        const formatted =
          typeof value === 'number'
            ? new Intl.NumberFormat(
                i18n.language,
                usd ? { style: 'currency', currency: 'USD' } : pct ? { style: 'percent', maximumFractionDigits: 1 } : {}
              ).format(usd ? value / 1e6 : value)
            : value == null
              ? '—'
              : isRecord(value)
                ? String(
                    value.reason_code ??
                      value.reason ??
                      value.summary ??
                      value.label ??
                      value.code ??
                      JSON.stringify(value)
                  )
                : String(value)
        return (
          <AnkoleStatCard
            key={key}
            label={t(`${i18nPrefix}.field.${key}`, { defaultValue: formatIdentifierLabel(key) })}
            value={formatted}
          />
        )
      })}
    </div>
  )
}

export function DeclarativeDataTable({
  title,
  columns,
  rows,
  fieldFormats,
  i18nPrefix = 'console',
  linkTo
}: {
  title: string
  columns: readonly string[]
  rows: readonly Readonly<Record<string, unknown>>[]
  fieldFormats?: Readonly<Record<string, DeclarativeFieldFormat>>
  i18nPrefix?: string
  linkTo?: string
}) {
  const { t } = useTranslation()
  return (
    <section className="grid min-w-0 gap-2 border border-border-subtle bg-page p-4">
      <div className="flex items-center justify-between gap-2">
        <h3 className="title-section">{title}</h3>
        {linkTo ? (
          <Link className="link text-sm" to={linkTo}>
            {t('common.view', { defaultValue: 'View all' })}
          </Link>
        ) : null}
      </div>
      {rows.length === 0 ? (
        <p className="text-sm text-fg-secondary">{t('console.empty.title', { defaultValue: 'No data' })}</p>
      ) : (
        <div className="overflow-x-auto">
          <Table aria-label={title}>
            <TableHeader>
              <TableRow>
                {columns.map(col => (
                  <TableHead key={col}>
                    {t(`${i18nPrefix}.field.${col}`, { defaultValue: formatIdentifierLabel(col) })}
                  </TableHead>
                ))}
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row, idx) => (
                <TableRow key={String(row.id ?? idx)}>
                  {columns.map(col => (
                    <TableCell key={col}>
                      {col === 'status' || col === 'state' || col === 'severity' ? (
                        <StatusIndicator
                          tone={
                            ['healthy', 'available', 'active', 'ok'].includes(String(row[col]))
                              ? 'positive'
                              : ['critical', 'error', 'banned', 'failed'].includes(String(row[col]))
                                ? 'danger'
                                : 'neutral'
                          }>
                          <DeclarativeValue
                            field={col}
                            fieldFormats={fieldFormats}
                            i18nPrefix={i18nPrefix}
                            value={row[col]}
                          />
                        </StatusIndicator>
                      ) : (
                        <DeclarativeValue
                          field={col}
                          fieldFormats={fieldFormats}
                          i18nPrefix={i18nPrefix}
                          value={row[col]}
                        />
                      )}
                    </TableCell>
                  ))}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
    </section>
  )
}

function nestedValue(record: Readonly<Record<string, unknown>>, path: string): unknown {
  return path.split('.').reduce<unknown>((acc, seg) => asRecord(acc)[seg], record)
}

export function DeclarativeResultRenderer({
  schema,
  record,
  fieldFormats,
  i18nPrefix = 'console'
}: {
  schema: DeclarativeResultSchema
  record: Readonly<Record<string, unknown>>
  fieldFormats?: Readonly<Record<string, DeclarativeFieldFormat>>
  i18nPrefix?: string
}) {
  const { t } = useTranslation()
  const formats = schema.fieldFormats ?? fieldFormats
  return (
    <div className="grid gap-4">
      {schema.summaryFields.length > 0 ? (
        <DeclarativeStatsGrid
          columns={schema.summaryFields}
          fieldFormats={formats}
          i18nPrefix={i18nPrefix}
          record={record}
        />
      ) : null}

      {schema.latency ? (
        <div className="border border-border-subtle bg-page p-4">
          <h3 className="title-section mb-2">
            {t(`${i18nPrefix}.field.${schema.latency.field}`, {
              defaultValue: formatIdentifierLabel(schema.latency.field)
            })}
          </h3>
          <DeclarativeFacts
            columns={schema.latency.stages}
            fieldFormats={formats}
            i18nPrefix={i18nPrefix}
            record={asRecord(nestedValue(record, schema.latency.field))}
          />
        </div>
      ) : null}

      {schema.sections?.map(section => (
        <div key={section.field} className="border border-border-subtle bg-page p-4">
          <h3 className="title-section mb-2">
            {t(section.titleKey, { defaultValue: formatIdentifierLabel(section.field) })}
          </h3>
          <DeclarativeFacts
            fieldFormats={formats}
            i18nPrefix={i18nPrefix}
            record={asRecord(nestedValue(record, section.field))}
          />
        </div>
      ))}

      {schema.tables?.map(table => {
        const raw = nestedValue(record, table.field)
        const tableRows = Array.isArray(raw) ? raw.filter(isRecord) : []
        return (
          <DeclarativeDataTable
            key={table.field}
            columns={table.columns}
            fieldFormats={formats}
            i18nPrefix={i18nPrefix}
            rows={tableRows}
            title={t(table.titleKey, { defaultValue: formatIdentifierLabel(table.field) })}
          />
        )
      })}

      {schema.detailFields && schema.detailFields.length > 0 ? (
        <div className="border border-border-subtle bg-page p-4">
          <DeclarativeFacts
            columns={schema.detailFields}
            fieldFormats={formats}
            i18nPrefix={i18nPrefix}
            record={record}
          />
        </div>
      ) : null}
    </div>
  )
}

export function DeclarativePanelView({
  surface,
  recordId,
  i18nPrefix = 'console'
}: {
  surface: DeclarativeSurfaceDescriptor
  recordId?: string
  i18nPrefix?: string
}) {
  const { t } = useTranslation()
  const mutation = useDeclarativeAction()
  const [queryDraft, setQueryDraft] = useState<Record<string, unknown>>(() => withFieldDefaults(surface.fields))
  const [submittedFilters, setSubmittedFilters] = useState<Record<string, string> | null>(null)
  const [actionState, setActionState] = useState<{
    rows: readonly DeclarativeRecord[]
    loading: boolean
    error: string | null
    executed: boolean
  }>({ rows: [], loading: false, error: null, executed: false })

  const hasFields = surface.presentation === 'form' && surface.fields.length > 0
  const isActionForm = hasFields && surface.method !== 'GET'
  const isQueryForm = hasFields && surface.method === 'GET'
  const endpoint = isActionForm
    ? undefined
    : isQueryForm
      ? submittedFilters
        ? surfaceQueryEndpoint(surface, recordId, submittedFilters)
        : undefined
      : surfaceQueryEndpoint(surface, recordId)

  const query = useDeclarativeRecords(endpoint, surface.responseEnvelope ?? 'jsonapi')
  const rows = isActionForm ? actionState.rows : query.rows
  const loading = isActionForm ? actionState.loading : query.loading
  const error = isActionForm ? actionState.error : query.error
  const hasTriggered = isActionForm ? actionState.executed : Boolean(endpoint)
  const record = rows[0] ?? null
  const formats = surface.resultSchema?.fieldFormats ?? surface.dashboardSchema?.fieldFormats

  return (
    <div className="grid gap-4">
      {hasFields ? (
        <form
          className="grid gap-4 border border-border-subtle bg-page p-4"
          noValidate
          onSubmit={event => {
            event.preventDefault()
            if (!event.currentTarget.reportValidity()) return
            if (isActionForm) {
              setActionState({ rows: [], loading: true, error: null, executed: true })
              void mutation
                .mutateAsync({ surface, payload: serializeDeclarativeFields(surface, queryDraft, recordId) })
                .then(nextRows => setActionState({ rows: nextRows, loading: false, error: null, executed: true }))
                .catch((failure: unknown) =>
                  setActionState({
                    rows: [],
                    loading: false,
                    error: failure instanceof Error ? failure.message : String(failure),
                    executed: true
                  })
                )
              return
            }
            const nextFilters: Record<string, string> = {}
            for (const [key, val] of Object.entries(queryDraft)) {
              if (val !== undefined && val !== null && String(val).trim() !== '') {
                nextFilters[key] = String(val).trim()
              }
            }
            if (endpoint === surfaceQueryEndpoint(surface, recordId, nextFilters)) void query.refresh()
            setSubmittedFilters(nextFilters)
          }}>
          <DeclarativeFields
            draft={queryDraft}
            fields={surface.fields}
            i18nPrefix={i18nPrefix}
            onChange={setQueryDraft}
          />
          <div className="flex justify-end">
            <Button disabled={loading} size="sm" type="submit">
              {t(`${i18nPrefix}.ui.run_action`, { defaultValue: 'Run query' })}
            </Button>
          </div>
        </form>
      ) : null}

      <ErrorBlock error={error} />
      {loading ? (
        <p className="text-sm text-fg-secondary" role="status">
          {t('common.loading', { defaultValue: 'Loading...' })}
        </p>
      ) : null}

      {!hasFields && surface.presentation === 'table' && hasTriggered && !loading ? (
        <DeclarativeDataTable
          columns={surface.columns}
          fieldFormats={formats}
          i18nPrefix={i18nPrefix}
          rows={rows}
          title={t(surface.titleKey, { defaultValue: formatIdentifierLabel(surface.id) })}
        />
      ) : record ? (
        surface.resultSchema ? (
          <DeclarativeResultRenderer
            fieldFormats={formats}
            i18nPrefix={i18nPrefix}
            record={record}
            schema={surface.resultSchema}
          />
        ) : (
          <div className="border border-border-subtle bg-page p-4">
            <DeclarativeFacts
              columns={surface.columns.length > 0 ? surface.columns : undefined}
              fieldFormats={formats}
              i18nPrefix={i18nPrefix}
              record={record}
            />
          </div>
        )
      ) : !loading && hasTriggered ? (
        <p className="text-sm text-fg-secondary">{t('console.empty.title', { defaultValue: 'No data' })}</p>
      ) : null}
    </div>
  )
}

export function DeclarativeDashboardView({
  surface,
  schema,
  i18nPrefix = 'console',
  onRefreshVisibility
}: {
  surface: DeclarativeSurfaceDescriptor
  schema?: DeclarativeDashboardSchema | null
  i18nPrefix?: string
  onRefreshVisibility?: () => void
}) {
  const { t } = useTranslation()
  const localTimezone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'
  const timezoneChoices = Array.from(
    new Set(['UTC', localTimezone, 'America/New_York', 'Europe/London', 'Asia/Shanghai', 'Asia/Tokyo'])
  )

  const [windowValue, setWindowValue] = useState(schema?.defaultWindow ?? '')
  const [granularity, setGranularity] = useState(schema?.defaultGranularity ?? '')
  const [timezone, setTimezone] = useState('UTC')
  const [selectedDrilldown, setSelectedDrilldown] = useState<DeclarativeDrilldownSelection | null>(null)

  const queryParams = new URLSearchParams({
    window: windowValue,
    granularity,
    timezone,
    ...schema?.staticQueryParams
  })
  const endpoint = schema ? `${surface.endpoint}?${queryParams}` : undefined
  const report = useDeclarativeRecords(endpoint, surface.responseEnvelope ?? 'flat')

  if (!schema) {
    throw new Error(`Dashboard surface "${surface.id}" is missing dashboardSchema`)
  }

  const allowedGranularities = schema.granularitiesByWindow?.[windowValue] ?? schema.granularities
  const data = (report.rows[0] ?? null) as DeclarativeRecord | null
  const stats = isRecord(data?.stats) ? data.stats : null

  return (
    <PageStack>
      <PageHeader
        actions={
          <div className="flex flex-wrap items-center gap-2">
            <DeclarativeSelect
              label={t(`${i18nPrefix}.ui.window`, { defaultValue: 'Window' })}
              options={schema.windows.map(win => [win, t(`${i18nPrefix}.window.${win}`, { defaultValue: win })])}
              value={windowValue}
              onChange={nextWindow => {
                setWindowValue(nextWindow)
                const nextAllowed = schema.granularitiesByWindow?.[nextWindow] ?? schema.granularities
                if (!nextAllowed.includes(granularity)) {
                  setGranularity(nextAllowed[0] ?? schema.defaultGranularity)
                }
              }}
            />
            <DeclarativeSelect
              label={t(`${i18nPrefix}.ui.granularity`, { defaultValue: 'Granularity' })}
              options={allowedGranularities.map(gran => [
                gran,
                t(`${i18nPrefix}.ui.${gran}`, { defaultValue: formatIdentifierLabel(gran) })
              ])}
              value={granularity}
              onChange={setGranularity}
            />
            <DeclarativeSelect
              label={t(`${i18nPrefix}.ui.timezone`, { defaultValue: 'Timezone' })}
              options={timezoneChoices.map(zone => [zone, zone])}
              value={timezone}
              onChange={setTimezone}
            />
            <Button
              size="sm"
              type="button"
              variant="outline"
              onClick={() => {
                onRefreshVisibility?.()
                report.refresh()
              }}>
              {t('console.aria.refresh', { defaultValue: 'Refresh' })}
            </Button>
          </div>
        }
        description={schema.descriptionKey ? t(schema.descriptionKey) : undefined}
        title={t(schema.titleKey, { defaultValue: formatIdentifierLabel(surface.id) })}
      />

      <ErrorBlock error={report.error} />

      {report.loading ? (
        <p className="text-sm text-fg-secondary" role="status">
          {t('common.loading', { defaultValue: 'Loading...' })}
        </p>
      ) : null}

      {stats ? (
        <DeclarativeStatsGrid fieldFormats={schema.fieldFormats} i18nPrefix={i18nPrefix} record={stats} />
      ) : null}

      {data && 'series' in data ? (
        <DeclarativeSeriesChart
          fieldFormats={schema.fieldFormats}
          labelPrefix={`${i18nPrefix}.field`}
          series={data.series}
          seriesOptions={schema.seriesOptions ?? []}
          timezone={timezone}
          title={t(schema.titleKey, { defaultValue: formatIdentifierLabel(surface.id) })}
          onDrilldown={schema.drilldownRoute && schema.drilldownParams ? setSelectedDrilldown : undefined}
        />
      ) : null}

      {selectedDrilldown && schema.drilldownRoute && schema.drilldownParams ? (
        <div className="flex items-center justify-between border border-border-subtle bg-page px-4 py-3 text-sm">
          <span>
            {t(schema.drilldownParams.promptKey ?? `${i18nPrefix}.ui.drilldown`, {
              defaultValue: 'Inspect records for'
            })}{' '}
            <strong>{selectedDrilldown.dateKey}</strong> ({selectedDrilldown.timezone})
          </span>
          <Link
            className="link"
            to={schema.drilldownRoute}
            search={(() => {
              const drillParams: Record<string, string> = {
                [schema.drilldownParams.dateParam]: selectedDrilldown.dateKey
              }
              if (schema.drilldownParams.timezoneParam) {
                drillParams[schema.drilldownParams.timezoneParam] = selectedDrilldown.timezone
              }
              return drillParams
            })()}>
            {t(schema.drilldownParams.actionLabelKey ?? `${i18nPrefix}.ui.open_filtered`, {
              defaultValue: 'Open filtered view'
            })}
          </Link>
        </div>
      ) : null}

      {data && surface.resultSchema ? (
        <DeclarativeResultRenderer
          fieldFormats={schema.fieldFormats}
          i18nPrefix={i18nPrefix}
          record={data}
          schema={surface.resultSchema}
        />
      ) : null}

      {data
        ? schema.factsSections?.map(section => {
            const sectionData = data[section.sourceKey]
            if (!isRecord(sectionData)) return null
            return (
              <section key={section.sourceKey} className="grid gap-2 border border-border-subtle bg-page p-4">
                <h3 className="title-section">
                  {t(section.titleKey, { defaultValue: formatIdentifierLabel(section.sourceKey) })}
                </h3>
                <DeclarativeFacts
                  columns={section.columns}
                  fieldFormats={schema.fieldFormats}
                  i18nPrefix={i18nPrefix}
                  record={sectionData}
                />
              </section>
            )
          })
        : null}

      {data
        ? schema.tableSections?.map(section => {
            const rawRows = data[section.sourceKey]
            const rows = Array.isArray(rawRows) ? rawRows.filter(isRecord) : []
            return (
              <DeclarativeDataTable
                key={section.sourceKey}
                columns={section.columns}
                fieldFormats={schema.fieldFormats}
                i18nPrefix={i18nPrefix}
                linkTo={section.linkTo}
                rows={rows}
                title={t(section.titleKey, { defaultValue: formatIdentifierLabel(section.sourceKey) })}
              />
            )
          })
        : null}

      {data &&
      !stats &&
      !('series' in data) &&
      !surface.resultSchema &&
      !schema.factsSections &&
      !schema.tableSections ? (
        <div className="border border-border-subtle bg-page p-4">
          <RefreshButton />
          <DeclarativeFacts i18nPrefix={i18nPrefix} record={data} />
        </div>
      ) : null}
    </PageStack>
  )
}
