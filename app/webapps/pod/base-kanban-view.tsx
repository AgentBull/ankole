import { useTranslation } from 'react-i18next'
import { Button } from '@ankole/uikit'
import { useMemo, useRef, useState } from 'react'
import { useAggregate } from '@ankole/applet-sdk'
import type { BaseField, FieldType, RecordData, Value } from '@ankole/applet-sdk/types'
import { AddRegular } from '@ankole/uikit/icons'
import {
  InfiniteScrollSentinel,
  RecordCard,
  commitRecordDrag,
  readRecordDrag,
  useRetainedDetailRecord,
  type CardViewProps
} from './base-card-views'
import { ReferenceLabelsProvider } from './base-field-value'
import { FieldValue, fieldOptions, writableField } from './base-fields'
import type { ViewProps } from './base-views'
import { Choice, ContentError } from './content-primitives'
import { fieldValue } from './state/table-query'
import type { ViewConfig } from './state/view-config'
import { useInfiniteBaseRecords } from './use-infinite-base-records'

const kanbanGroupTypes = new Set<FieldType>(['select', 'user', 'created_by', 'updated_by', 'checkbox', 'link', 'text'])
const kanbanColumnPageSize = 20

function GroupField({
  props,
  attribute,
  label,
  datetime = false
}: {
  props: ViewProps
  attribute: string
  label: string
  datetime?: boolean
}) {
  const current = String(props.view.config[attribute] ?? '')
  const fields = props.fields.filter(field =>
    datetime ? field.type === 'datetime' : kanbanGroupTypes.has(field.type) || field.id === current
  )
  return (
    <Choice
      label={label}
      value={current}
      disabled={props.configuring}
      onChange={value => {
        const next: ViewConfig = { ...props.view.config }
        if (value) next[attribute] = value
        else delete next[attribute]
        props.configure(next)
      }}
      options={{ '': label, ...Object.fromEntries(fields.map(field => [field.id, field.name])) }}
    />
  )
}

export function KanbanView(props: CardViewProps) {
  const { t } = useTranslation()
  const [offset, setOffset] = useState(0)
  const field = props.fields.find(field => field.id === props.view.config.group_field_id)
  const counts = useAggregate(props.tableID, {
    filter: props.view.config.filter,
    group_by: field ? [{ field_id: field.id }] : [],
    metrics: [{ operation: 'count', alias: 'count' }]
  })
  const groups = new Map<string, { value: Value; valueJSON?: string | null; count: number }>()
  if (field) {
    for (const option of fieldOptions(field)) groups.set(JSON.stringify(option.id), { value: option.id, count: 0 })
    groups.set('null', { value: null, count: 0 })
    for (const group of counts.data?.groups ?? []) {
      groups.set(group.value_json?.[0] ?? JSON.stringify(group.values[0]), {
        value: group.values[0] ?? null,
        valueJSON: group.value_json?.[0],
        count: Number(group.metrics.count)
      })
    }
  }
  // Every option keeps its column, even when empty, so a card can be dragged into it; the Ungrouped column shows
  // only while some records have no value.
  const ungrouped = groups.get('null')
  if (ungrouped && ungrouped.count <= 0) groups.delete('null')
  const columns = [...groups.entries()]
  const start = Math.min(offset, Math.max(0, columns.length - 1))
  return (
    <div className="space-y-4">
      <GroupField props={props} attribute="group_field_id" label={t('pod.content.choose_a_grouping_field')} />
      <ContentError error={counts.error} />
      {!field ? (
        <p className="text-sm text-fg-tertiary">{t('pod.content.choose_a_field_to_organize_the_board')}</p>
      ) : columns.length === 0 ? (
        <p className="text-sm text-fg-tertiary">{t('pod.content.this_view_has_no_records_adjust_the_filters')}</p>
      ) : (
        <>
          <div className="flex min-h-64 gap-4 overflow-auto pb-4">
            {columns.slice(start, start + kanbanColumnPageSize).map(([key, group]) => (
              <KanbanColumn key={`${field.id}:${key}`} props={props} field={field} group={group} />
            ))}
          </div>
          {columns.length > kanbanColumnPageSize && (
            <div className="flex gap-2">
              <Button
                size="sm"
                variant="outline"
                disabled={!start}
                onClick={() => setOffset(Math.max(0, start - kanbanColumnPageSize))}>
                {t('pod.content.previous_group')}
              </Button>
              <Button
                size="sm"
                variant="outline"
                disabled={start + kanbanColumnPageSize >= columns.length}
                onClick={() => setOffset(start + kanbanColumnPageSize)}>
                {t('pod.content.next_group')}
              </Button>
            </div>
          )}
        </>
      )}
    </div>
  )
}

function KanbanColumn({
  props,
  field,
  group
}: {
  props: CardViewProps
  field: BaseField
  group: { value: Value; valueJSON?: string | null; count: number }
}) {
  const { RecordDetailsDialog } = props
  const { t } = useTranslation()
  const columnScrollRef = useRef<HTMLDivElement>(null)
  const [error, setError] = useState<unknown>()
  const [dragOver, setDragOver] = useState(false)
  const [creating, setCreating] = useState(false)
  const columnQuery = useMemo(
    () => ({
      filter: props.view.config.filter,
      sort: props.view.config.sort,
      group: {
        field_id: field.id,
        ...(group.valueJSON !== undefined ? { value_json: group.valueJSON } : { value: group.value })
      }
    }),
    [props.view.config.filter, props.view.config.sort, field.id, group.valueJSON, group.value]
  )
  const rows = useInfiniteBaseRecords(props.tableID, columnQuery, 100)
  const detail = useRetainedDetailRecord(rows.records, rows.update, rows.remove)
  return (
    <ReferenceLabelsProvider fields={props.fields} records={rows.records}>
      <section
        className={`w-64 shrink-0 space-y-3 rounded-control bg-layer-03/40 p-3 transition-colors ${dragOver ? 'bg-layer-hover/60 ring-2 ring-primary/40' : ''}`}
        onDragOver={event => {
          if (props.editable && writableField(field)) {
            event.preventDefault()
            if (!dragOver) setDragOver(true)
          }
        }}
        onDragLeave={event => {
          if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setDragOver(false)
        }}
        onDrop={event => {
          event.preventDefault()
          setDragOver(false)
          try {
            const dragged = readRecordDrag(event)
            const record = dragged.record
            if (!record || !props.editable || !writableField(field)) return
            const previous = fieldValue(record, field)
            const next =
              Array.isArray(previous) || field.config.multiple
                ? [
                    ...(Array.isArray(previous) ? previous : []).filter(value => value !== dragged.from),
                    ...(group.value === null ? [] : [group.value])
                  ]
                : group.value
            const data = { [field.id]: next }
            void commitRecordDrag(rows.update, record, data).catch(setError)
          } catch (error) {
            setError(error)
          }
        }}>
        <div className="flex items-center justify-between gap-2">
          <h3 className="min-w-0 truncate text-sm font-semibold">
            {group.value === null ? (
              t('pod.content.ungrouped')
            ) : (
              <FieldValue field={field} value={group.value} pageID={props.pageID} />
            )}{' '}
            <span className="text-fg-tertiary">{group.count}</span>
          </h3>
          {props.editable && (
            <Button
              size="icon-xs"
              variant="ghost"
              disabled={creating || rows.write.isPending}
              title={t('pod.content.add_record_in_group', { defaultValue: 'Add record to group' })}
              aria-label={t('pod.content.add_record_in_group', { defaultValue: 'Add record to group' })}
              onClick={() => {
                if (creating) return
                setCreating(true)
                setError(undefined)
                const initialValue =
                  ['user', 'link'].includes(field.type) || (field.type === 'select' && field.config.multiple)
                    ? [group.value]
                    : group.value
                const initialData: RecordData =
                  writableField(field) && group.value !== null ? { [field.id]: initialValue } : {}
                void rows
                  .create(initialData)
                  .then(result => {
                    const created = result.records[0]
                    if (created) detail.open(created)
                  })
                  .catch(setError)
                  .finally(() => setCreating(false))
              }}>
              <AddRegular aria-hidden="true" />
            </Button>
          )}
        </div>
        <ContentError error={rows.error || error} retry={() => void rows.refetch()} />
        <div ref={columnScrollRef} className="max-h-[70vh] space-y-3 overflow-y-auto pr-0.5">
          {rows.records.map(record => (
            <RecordCard
              key={record.id}
              {...props}
              create={rows.create}
              update={rows.update}
              remove={rows.remove}
              record={record}
              onOpenDetail={detail.open}
              draggable={props.editable && writableField(field)}
              dragFrom={group.value}
            />
          ))}
          <InfiniteScrollSentinel
            hasNextPage={rows.hasNextPage}
            isFetchingNextPage={rows.isFetchingNextPage}
            error={rows.fetchNextError}
            onLoadMore={rows.fetchNextPage}
            rootRef={columnScrollRef}
          />
        </div>
        {detail.record && (
          <RecordDetailsDialog
            open
            onOpenChange={next => {
              if (!next) detail.close()
            }}
            record={detail.record}
            fields={props.fields}
            pageID={props.pageID}
            editable={props.editable}
            pending={rows.write.isPending}
            update={detail.update}
            remove={detail.remove}
          />
        )}
      </section>
    </ReferenceLabelsProvider>
  )
}
