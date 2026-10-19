import { t } from 'i18next'
import { useAggregate } from '@ankole/applet-sdk'
import type { AggregateQuery, DatabaseField, Filter, GroupBy, Metric } from '@ankole/applet-sdk/types'
import { useState } from 'react'
import { Button, Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@ankole/uikit'
import { Choice, ContentError } from './content-primitives'
import { FieldValue } from './database-fields'
import { RiArrowDownSLine, RiBarChartLine } from '@remixicon/react'

export function DatabaseSummary({
  tableID,
  fields,
  filter
}: {
  tableID: string
  fields: DatabaseField[]
  filter?: Filter
}) {
  const [open, setOpen] = useState(false)
  return (
    <div className="pod-database-summary space-y-3">
      <Button size="xs" variant="ghost" aria-expanded={open} onClick={() => setOpen(!open)}>
        <RiBarChartLine aria-hidden="true" />
        {t('pod.content.grouped_statistics')}
        <RiArrowDownSLine aria-hidden="true" className={open ? 'rotate-180' : undefined} />
      </Button>
      {open && <Summary tableID={tableID} fields={fields} filter={filter} />}
    </div>
  )
}

function Summary({ tableID, fields, filter }: { tableID: string; fields: DatabaseField[]; filter?: Filter }) {
  const [operation, setOperation] = useState<Metric['operation']>('count')
  const [fieldID, setFieldID] = useState('')
  const [groupIDs, setGroupIDs] = useState(['', ''])
  const [bucket, setBucket] = useState<GroupBy['bucket']>('day')
  const candidates = fields.filter(
    field =>
      operation === 'count' ||
      (operation === 'sum' || operation === 'avg'
        ? ['number', 'auto_number'].includes(field.type) ||
          (field.type === 'formula' && field.config.result_type === 'number')
        : ['text', 'number', 'auto_number', 'datetime', 'created_at', 'updated_at'].includes(field.type) ||
          (field.type === 'formula' && ['number', 'text', 'datetime'].includes(String(field.config.result_type))))
  )
  const selected = candidates.find(field => field.id === fieldID)
  const groups = groupIDs
    .map(id => fields.find(field => field.id === id))
    .filter((field): field is DatabaseField => !!field)
  const invalid =
    ((operation !== 'count' || !!fieldID) && !selected) ||
    groupIDs.some(id => id && !fields.some(field => field.id === id))
  const query: AggregateQuery = {
    filter,
    group_by: groups.map(field => ({
      field_id: field.id,
      ...(['datetime', 'created_at', 'updated_at'].includes(field.type) ? { bucket } : {})
    })),
    metrics: [{ operation, ...(operation === 'count' && !fieldID ? {} : { field_id: fieldID }), alias: 'value' }]
  }
  return (
    <div className="space-y-3 rounded border border-border p-3">
      <div className="flex flex-wrap gap-2">
        <Choice<Metric['operation']>
          label={t('pod.content.calculation')}
          value={operation}
          onChange={setOperation}
          options={{
            count: t('pod.content.count'),
            sum: t('pod.content.sum'),
            avg: t('pod.content.average'),
            min: t('pod.content.minimum'),
            max: t('pod.content.maximum')
          }}
        />
        <Choice
          label={t('pod.content.calculation_field')}
          value={fieldID}
          onChange={setFieldID}
          options={{
            '': operation === 'count' ? t('pod.content.all_records') : t('pod.content.choose_a_calculation_field'),
            ...(fieldID && !selected
              ? { [fieldID]: t('pod.content.this_field_was_deleted_or_does_not_support_this_calculation') }
              : {}),
            ...Object.fromEntries(candidates.map(field => [field.id, field.name]))
          }}
        />
        {groupIDs.map((id, index) => (
          <Choice
            key={index}
            label={t('pod.content.grouping_field', { value1: index + 1 })}
            value={id}
            onChange={value => setGroupIDs(groupIDs.map((id, i) => (i === index ? value : id)))}
            options={{
              '': t('pod.content.no_grouping'),
              ...(id && !fields.some(field => field.id === id)
                ? { [id]: t('pod.content.this_grouping_field_was_deleted_choose_another_field') }
                : {}),
              ...Object.fromEntries(
                fields
                  .filter(field => !groupIDs.some((id, i) => i !== index && id === field.id))
                  .map(field => [field.id, field.name])
              )
            }}
          />
        ))}
        {groups.some(field => ['datetime', 'created_at', 'updated_at'].includes(field.type)) && (
          <Choice<NonNullable<GroupBy['bucket']>>
            label={t('pod.content.date_grouping')}
            value={bucket ?? 'day'}
            onChange={setBucket}
            options={{
              day: t('pod.content.day'),
              week: t('pod.content.week'),
              month: t('pod.content.month'),
              quarter: t('pod.content.quarter'),
              year: t('pod.content.year')
            }}
          />
        )}
      </div>
      {invalid ? (
        <p role="alert" className="text-sm">
          {t('pod.content.choose_valid_calculation_and_grouping_fields')}
        </p>
      ) : (
        <SummaryResult tableID={tableID} query={query} groups={groups} />
      )}
    </div>
  )
}

function SummaryResult({
  tableID,
  query,
  groups
}: {
  tableID: string
  query: AggregateQuery
  groups: DatabaseField[]
}) {
  const result = useAggregate(tableID, query)
  return (
    <>
      <ContentError error={result.error} />
      {result.isPending ? (
        <p role="status">{t('pod.content.calculating')}</p>
      ) : result.data?.groups.length === 0 ? (
        <p className="text-sm text-fg-tertiary">{t('pod.content.no_groups_match_the_current_filters')}</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              {groups.map(field => (
                <TableHead key={field.id}>{field.name}</TableHead>
              ))}
              <TableHead>{t('pod.content.calculation_results')}</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {result.data?.groups.map((group, index) => (
              <TableRow key={index}>
                {groups.map((field, i) => (
                  <TableCell key={field.id}>
                    {['datetime', 'created_at', 'updated_at'].includes(field.type) ? (
                      String(group.values[i] ?? '—')
                    ) : (
                      <FieldValue field={field} value={group.values[i] ?? null} />
                    )}
                  </TableCell>
                ))}
                <TableCell>{String(group.metrics.value ?? '—')}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </>
  )
}
