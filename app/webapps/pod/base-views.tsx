import { useTranslation } from 'react-i18next'
import {
  Button,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  toast
} from '@ankole/uikit'
import { useCallback, useEffect, useRef, useState, type DragEvent } from 'react'
import { defaultRangeExtractor, useVirtualizer } from '@tanstack/react-virtual'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { expectedVersions, useAggregate, useRecords } from '@ankole/applet-sdk'
import type {
  BaseField,
  BaseRecord,
  BaseTable,
  FieldType,
  RecordData,
  RecordWrite,
  Value,
  Versions,
  WriteResult
} from '@ankole/applet-sdk/types'
import { fileURL } from './content-api'
import { Choice, ContentError } from './content-primitives'
import { BaseCell, FieldEditorButton, FieldInput, FieldValue, fieldOptions, writableField } from './base-fields'
import { fieldValue } from './state/table-query'
import { ReferenceLabelsProvider } from './base-field-value'
import { RecordFormModel } from './state/record-form'
import type { ConfiguredView, ViewConfig } from './state/view-config'
import { requestErrorMessage } from '../common/request-errors'
import { contentError } from './content-errors'
import {
  RiAddLine,
  RiAttachmentLine,
  RiCalendarLine,
  RiCheckboxLine,
  RiDeleteBinLine,
  RiExpandDiagonalLine,
  RiFormula,
  RiHashtag,
  RiLink,
  RiListCheck,
  RiText,
  RiTimeLine,
  RiUserLine
} from '@remixicon/react'
import { fieldTypes } from './base-field-types'

export const fieldIcons = {
  text: RiText,
  number: RiHashtag,
  auto_number: RiHashtag,
  select: RiListCheck,
  datetime: RiCalendarLine,
  checkbox: RiCheckboxLine,
  user: RiUserLine,
  attachment: RiAttachmentLine,
  link: RiLink,
  formula: RiFormula,
  created_at: RiTimeLine,
  updated_at: RiTimeLine,
  created_by: RiUserLine,
  updated_by: RiUserLine
}

type RecordDrag = { record?: BaseRecord; from?: Value }
const recordDragType = 'application/ankole-record'
const readRecordDrag = (event: DragEvent): RecordDrag => JSON.parse(event.dataTransfer.getData(recordDragType))
const commitRecordDrag = (update: ViewProps['update'], record: BaseRecord, data: RecordData) =>
  update(record.id, data, expectedVersions(record, data))
const writeRecordDrag = (event: DragEvent, record: BaseRecord, from?: Value) =>
  event.dataTransfer.setData(recordDragType, JSON.stringify({ record, ...(from === undefined ? {} : { from }) }))

export type ViewProps = {
  pageID: string
  tableID: string
  tables: BaseTable[]
  fields: BaseField[]
  records: BaseRecord[]
  view: ConfiguredView
  editable: boolean
  schemaEditable: boolean
  pending?: boolean
  create(data: RecordData): Promise<WriteResult>
  update(id: string, data: RecordData, expected: Versions): Promise<unknown>
  remove(id: string, expected: Versions): Promise<unknown>
  configure(config: ViewConfig): void
  configuring?: boolean
  onFieldCreated?(fieldID: string): void
}

export function BaseViewContent(props: ViewProps) {
  return (
    <ReferenceLabelsProvider fields={props.fields} records={props.records}>
      <BaseView {...props} />
    </ReferenceLabelsProvider>
  )
}
function BaseView(props: ViewProps) {
  switch (props.view.type) {
    case 'grid':
      return <GridView {...props} />
    case 'kanban':
      return (
        <KanbanView
          key={JSON.stringify([props.view.config.group_field_id, props.view.config.filter, props.view.config.sort])}
          {...props}
        />
      )
    case 'gallery':
      return <GalleryView {...props} />
  }
}

function GridView(props: ViewProps) {
  const { t } = useTranslation()
  const visible = props.view.config.visible_fields
    ? props.fields.filter(field => field.is_primary || props.view.config.visible_fields!.includes(field.id))
    : props.fields
  const scroll = useRef<HTMLDivElement>(null)
  const [retained, setRetained] = useState<string[]>([])
  const [detailID, setDetailID] = useState<string>()
  const [addingRow, setAddingRow] = useState(false)
  const [pendingFocusID, setPendingFocusID] = useState<string>()
  useEffect(() => {
    const container = scroll.current!
    const sync = () => {
      const next = Array.from(container.querySelectorAll<HTMLTableRowElement>('[data-grid-record]'))
        .filter(row => row.contains(document.activeElement) || !!row.querySelector('[data-cell-retained="true"]'))
        .map(row => row.dataset.gridRecord!)
      setRetained(previous => (previous.join() === next.join() ? previous : next))
    }
    const focus = () => queueMicrotask(sync)
    const observer = new MutationObserver(sync)
    observer.observe(container, { subtree: true, attributes: true, attributeFilter: ['data-cell-retained'] })
    container.addEventListener('focusin', focus)
    container.addEventListener('focusout', focus)
    return () => {
      observer.disconnect()
      container.removeEventListener('focusin', focus)
      container.removeEventListener('focusout', focus)
    }
  }, [])
  const virtual = useVirtualizer({
    count: props.records.length,
    getScrollElement: () => scroll.current,
    getItemKey: index => props.records[index]!.id,
    estimateSize: () => 48,
    overscan: 8,
    rangeExtractor: useCallback(
      range => {
        const pinned = pendingFocusID ? [...retained, pendingFocusID] : retained
        return [
          ...new Set([
            ...defaultRangeExtractor(range),
            ...pinned.map(id => props.records.findIndex(record => record.id === id)).filter(index => index >= 0)
          ])
        ].sort((a, b) => a - b)
      },
      [pendingFocusID, retained, props.records]
    )
  })
  useEffect(() => {
    if (!pendingFocusID) return
    const index = props.records.findIndex(record => record.id === pendingFocusID)
    if (index < 0) return
    virtual.scrollToIndex(index, { align: 'auto' })
    const frame = requestAnimationFrame(() => {
      const row = scroll.current?.querySelector<HTMLElement>(`[data-grid-record="${CSS.escape(pendingFocusID)}"]`)
      const target = row?.querySelector<HTMLElement>('input, [role="combobox"], button')
      if (target) {
        target.focus()
        setPendingFocusID(undefined)
      }
    })
    return () => cancelAnimationFrame(frame)
  }, [pendingFocusID, props.records, virtual])
  const rows = virtual.getVirtualItems()
  const detailRecord = detailID ? props.records.find(record => record.id === detailID) : undefined
  return (
    <>
      <div
        ref={scroll}
        className="pod-base-grid max-h-[70vh] overflow-auto"
        role="region"
        aria-label={t('pod.content.table_records')}
        tabIndex={0}>
        <Table containerClassName="overflow-visible" aria-rowcount={props.records.length + 1}>
          <TableHeader className="sticky top-0 z-10 bg-background">
            <TableRow>
              {visible.map(field => {
                const Icon = fieldIcons[field.type]
                return (
                  <TableHead key={field.id} aria-description={fieldTypes[field.type]}>
                    <div className="pod-base-property" title={fieldTypes[field.type]}>
                      <Icon aria-hidden="true" />
                      <FieldEditorButton
                        field={field}
                        tableID={props.tableID}
                        pageID={props.pageID}
                        tables={props.tables}
                        canManage={props.schemaEditable}
                      />
                    </div>
                  </TableHead>
                )
              })}
              <TableHead className="pod-base-row-actions">
                <FieldEditorButton
                  tableID={props.tableID}
                  pageID={props.pageID}
                  tables={props.tables}
                  canManage={props.schemaEditable}
                  onCreated={props.onFieldCreated}
                />
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row, index) => {
              const record = props.records[row.index]!
              const gap = row.start - (rows[index - 1]?.end ?? 0)
              return (
                <GridRow key={record.id} gap={gap} columns={visible.length + 1}>
                  <TableRow
                    data-grid-record={record.id}
                    data-index={row.index}
                    ref={virtual.measureElement}
                    className="pod-base-row"
                    aria-rowindex={row.index + 2}>
                    {visible.map(field => (
                      <TableCell key={field.id} className={field.is_primary ? 'pod-base-primary' : undefined}>
                        {field.is_primary ? (
                          <div className="flex items-center gap-1">
                            <div className="min-w-0 flex-1">
                              <BaseCell
                                field={field}
                                record={record}
                                pageID={props.pageID}
                                editable={props.editable}
                                update={(data, expected) => props.update(record.id, data, expected)}
                              />
                            </div>
                            <Button
                              variant="ghost"
                              size="icon-xs"
                              className="pod-base-delete shrink-0"
                              title={t('pod.content.record_details')}
                              aria-label={t('pod.content.record_details')}
                              onClick={() => setDetailID(record.id)}>
                              <RiExpandDiagonalLine aria-hidden="true" />
                            </Button>
                          </div>
                        ) : (
                          <BaseCell
                            field={field}
                            record={record}
                            pageID={props.pageID}
                            editable={props.editable}
                            update={(data, expected) => props.update(record.id, data, expected)}
                          />
                        )}
                      </TableCell>
                    ))}
                    <TableCell className="pod-base-row-actions">
                      {props.editable && <RecordDeleteButton {...props} record={record} />}
                    </TableCell>
                  </TableRow>
                </GridRow>
              )
            })}
            <tr aria-hidden="true">
              <td
                colSpan={visible.length + 1}
                style={{ height: Math.max(0, virtual.getTotalSize() - (rows.at(-1)?.end ?? 0)), padding: 0, border: 0 }}
              />
            </tr>
            {props.editable && (
              <TableRow className="pod-base-add-row">
                <TableCell colSpan={visible.length + 1} className="border-r-0 p-1">
                  <Button
                    size="sm"
                    variant="ghost"
                    className="w-full justify-start text-fg-tertiary hover:text-foreground"
                    disabled={addingRow || props.pending}
                    onClick={() => {
                      if (addingRow) return
                      setAddingRow(true)
                      void props
                        .create({})
                        .then(result => {
                          const createdID = result.records[0]?.id
                          if (createdID) setPendingFocusID(createdID)
                        })
                        .catch(error => toast.error(requestErrorMessage(contentError(error))))
                        .finally(() => setAddingRow(false))
                    }}>
                    <RiAddLine aria-hidden="true" />
                    {t('pod.content.add_row', { defaultValue: 'New row' })}
                  </Button>
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </div>
      {detailRecord && (
        <RecordDetailsDialog
          open
          onOpenChange={next => {
            if (!next) setDetailID(undefined)
          }}
          record={detailRecord}
          fields={props.fields}
          pageID={props.pageID}
          editable={props.editable}
          pending={props.pending}
          update={props.update}
          remove={props.remove}
        />
      )}
    </>
  )
}

function GridRow({ gap, columns, children }: { gap: number; columns: number; children: React.ReactNode }) {
  return (
    <>
      {gap > 0 && (
        <tr aria-hidden="true">
          <td colSpan={columns} style={{ height: gap, padding: 0, border: 0 }} />
        </tr>
      )}
      {children}
    </>
  )
}

function RecordCard(
  props: ViewProps & {
    record: BaseRecord
    draggable?: boolean
    dragFrom?: Value
    coverImage?: { name: string; src: string }
  }
) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const primary = props.fields.find(field => field.is_primary) ?? props.fields[0]
  return (
    <>
      <article
        draggable={props.draggable}
        onDragStart={event => writeRecordDrag(event, props.record, props.dragFrom)}
        onClick={event => {
          const target = event.target as HTMLElement | null
          if (target?.closest('a, button, input, select, textarea')) return
          setOpen(true)
        }}
        className="cursor-pointer space-y-2 overflow-hidden rounded-control border border-border bg-card p-3 transition-colors hover:border-control-edge">
        {props.coverImage && (
          <img
            className="-mx-3 -mt-3 mb-2 h-36 w-[calc(100%+1.5rem)] max-w-none object-cover"
            alt={props.coverImage.name}
            src={props.coverImage.src}
          />
        )}
        <Button
          size="sm"
          variant="ghost"
          className="max-w-full justify-start px-0 font-semibold"
          onClick={() => setOpen(true)}>
          <span className="min-w-0 truncate">
            {primary ? (
              <FieldValue field={primary} value={fieldValue(props.record, primary)} pageID={props.pageID} />
            ) : (
              t('pod.content.record')
            )}
          </span>
        </Button>
        {props.fields
          .filter(
            field =>
              field !== primary &&
              (!props.view.config.visible_fields || props.view.config.visible_fields.includes(field.id))
          )
          .map(field => (
            <p key={field.id} className="text-xs text-fg-tertiary">
              <span>{field.name}: </span>
              <FieldValue field={field} value={fieldValue(props.record, field)} pageID={props.pageID} />
            </p>
          ))}
      </article>
      <RecordDetailsDialog
        open={open}
        onOpenChange={setOpen}
        record={props.record}
        fields={props.fields}
        pageID={props.pageID}
        editable={props.editable}
        pending={props.pending}
        update={props.update}
        remove={props.remove}
      />
    </>
  )
}

function RecordDetailsDialog({
  open,
  onOpenChange,
  record,
  fields,
  pageID,
  editable,
  pending,
  update,
  remove
}: Pick<ViewProps, 'fields' | 'pageID' | 'editable' | 'pending' | 'update' | 'remove'> & {
  open: boolean
  onOpenChange(open: boolean): void
  record: BaseRecord
}) {
  const { t } = useTranslation()
  return (
    <Dialog open={open} onOpenChange={next => !pending && onOpenChange(next)}>
      <DialogContent
        className="pod-dialog pod-record-dialog"
        closeLabel={t('common.close')}
        showCloseButton={!pending}
        aria-busy={pending}>
        <DialogTitle>{t('pod.content.record_details')}</DialogTitle>
        <div className="pod-dialog-body grid gap-4">
          {fields.map(field => (
            <div className="grid gap-2 text-sm" key={field.id}>
              <span>{field.name}</span>
              <BaseCell
                field={field}
                record={record}
                pageID={pageID}
                editable={editable}
                update={(data, expected) => update(record.id, data, expected)}
              />
            </div>
          ))}
        </div>
        <DialogFooter>
          {editable && (
            <RecordDeleteButton fields={fields} remove={remove} record={record} onDeleted={() => onOpenChange(false)} />
          )}
          <Button type="button" variant="ghost" disabled={pending} onClick={() => onOpenChange(false)}>
            {t('common.close')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function RecordDeleteButton({
  record,
  fields,
  remove,
  onDeleted
}: Pick<ViewProps, 'fields' | 'remove'> & { record: BaseRecord; onDeleted?(): void }) {
  const { t } = useTranslation()
  const [deleting, setDeleting] = useState<BaseRecord>()
  const open = !!deleting
  const setOpen = (next: boolean) => setDeleting(next ? record : undefined)
  const [pending, setPending] = useState(false)
  const saving = useRef(false)
  const cancel = useRef<HTMLButtonElement>(null)
  const [error, setError] = useState<unknown>()
  const primary = fields.find(field => field.is_primary) ?? fields[0]
  return (
    <Dialog
      open={open}
      onOpenChange={next => {
        if (!saving.current) setOpen(next)
      }}>
      <Button
        variant="ghost"
        size="icon-sm"
        className="pod-base-delete"
        data-cell-retained={open ? 'true' : undefined}
        title={t('pod.content.delete')}
        onClick={() => {
          setError(undefined)
          setOpen(true)
        }}>
        <RiDeleteBinLine aria-hidden="true" />
        <span className="sr-only">{t('pod.content.delete')}</span>
      </Button>
      <DialogContent
        className="pod-dialog"
        closeLabel={t('common.close')}
        showCloseButton={!pending}
        initialFocus={cancel}
        aria-busy={pending}>
        <DialogTitle>{t('pod.content.delete_record')}</DialogTitle>
        <p>
          {primary && <FieldValue field={primary} value={fieldValue(deleting ?? record, primary)} />}{' '}
          {t('pod.content.deleted_records_cannot_be_restored_from_page_trash')}
        </p>
        <ContentError error={error} />
        <DialogFooter>
          <Button ref={cancel} type="button" variant="outline" disabled={pending} onClick={() => setOpen(false)}>
            {t('pod.content.cancel')}
          </Button>
          <Button
            type="button"
            variant="destructive"
            disabled={pending}
            onClick={() => {
              if (saving.current || !deleting) return
              saving.current = true
              setPending(true)
              setError(undefined)
              void remove(deleting.id, deleting.versions)
                .then(() => {
                  setOpen(false)
                  onDeleted?.()
                })
                .catch(setError)
                .finally(() => {
                  saving.current = false
                  setPending(false)
                })
            }}>
            {pending ? t('pod.content.deleting') : t('pod.content.confirm_deletion')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

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

function KanbanView(props: ViewProps) {
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
  const columns = [...groups.entries()]
  const start = Math.min(offset, Math.max(0, columns.length - 1))
  return (
    <div className="space-y-4">
      <GroupField props={props} attribute="group_field_id" label={t('pod.content.choose_a_grouping_field')} />
      <ContentError error={counts.error} />
      {!field ? (
        <p className="text-sm text-fg-tertiary">{t('pod.content.choose_a_field_to_organize_the_board')}</p>
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
  props: ViewProps
  field: BaseField
  group: { value: Value; valueJSON?: string | null; count: number }
}) {
  const { t } = useTranslation()
  const [token, setToken] = useState<string>()
  const [history, setHistory] = useState<(string | undefined)[]>([])
  const [error, setError] = useState<unknown>()
  const [dragOver, setDragOver] = useState(false)
  const [creating, setCreating] = useState(false)
  const [createdRecord, setCreatedRecord] = useState<BaseRecord>()
  const rows = useRecords(props.tableID, {
    filter: props.view.config.filter,
    sort: props.view.config.sort,
    group: {
      field_id: field.id,
      ...(group.valueJSON !== undefined ? { value_json: group.valueJSON } : { value: group.value })
    },
    page_size: 100,
    page_token: token
  })
  const activeCreated = createdRecord
    ? (rows.data?.records.find(record => record.id === createdRecord.id) ?? createdRecord)
    : undefined
  return (
    <ReferenceLabelsProvider fields={props.fields} records={rows.data?.records ?? []}>
      <section
        className={`w-64 shrink-0 space-y-3 rounded-control bg-muted/40 p-3 transition-colors ${dragOver ? 'bg-accent/60 ring-2 ring-primary/40' : ''}`}
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
                    if (created) setCreatedRecord(created)
                  })
                  .catch(setError)
                  .finally(() => setCreating(false))
              }}>
              <RiAddLine aria-hidden="true" />
            </Button>
          )}
        </div>
        <ContentError error={rows.error || error} />
        {rows.data?.records.map(record => (
          <RecordCard
            key={record.id}
            {...props}
            create={rows.create}
            update={rows.update}
            remove={rows.remove}
            record={record}
            draggable={props.editable && writableField(field)}
            dragFrom={group.value}
          />
        ))}
        {(history.length > 0 || rows.data?.page_token) && (
          <div className="flex gap-2">
            <Button
              size="sm"
              variant="outline"
              disabled={!history.length}
              onClick={() => {
                setToken(history.at(-1))
                setHistory(history.slice(0, -1))
              }}>
              {t('pod.content.previous_page')}
            </Button>
            <Button
              size="sm"
              variant="outline"
              disabled={!rows.data?.page_token}
              onClick={() => {
                setHistory([...history, token])
                setToken(rows.data?.page_token ?? undefined)
              }}>
              {t('pod.content.next_page')}
            </Button>
          </div>
        )}
        {activeCreated && (
          <RecordDetailsDialog
            open
            onOpenChange={next => {
              if (!next) setCreatedRecord(undefined)
            }}
            record={activeCreated}
            fields={props.fields}
            pageID={props.pageID}
            editable={props.editable}
            pending={rows.write.isPending}
            update={rows.update}
            remove={rows.remove}
          />
        )}
      </section>
    </ReferenceLabelsProvider>
  )
}

function GalleryView(props: ViewProps) {
  const { t } = useTranslation()
  const attachmentFields = props.fields.filter(field => field.type === 'attachment')
  const cover = attachmentFields.find(field => field.id === props.view.config.cover_field_id)
  return (
    <div className="space-y-4">
      {attachmentFields.length > 0 && (
        <Choice
          label={t('pod.content.gallery_cover')}
          disabled={props.configuring}
          value={String(props.view.config.cover_field_id ?? '')}
          onChange={value => {
            const next: ViewConfig = { ...props.view.config }
            if (value) next.cover_field_id = value
            else delete next.cover_field_id
            props.configure(next)
          }}
          options={{
            '': t('pod.content.no_cover'),
            ...Object.fromEntries(attachmentFields.map(field => [field.id, field.name]))
          }}
        />
      )}
      <div className="grid grid-cols-[repeat(auto-fill,minmax(240px,1fr))] gap-4">
        {props.records.map(record => {
          const value = cover ? fieldValue(record, cover) : null
          const image = Array.isArray(value)
            ? (value as { mime: string; path: string; name: string }[]).find(file => file.mime.startsWith('image/'))
            : undefined
          return (
            <RecordCard
              key={record.id}
              {...props}
              record={record}
              coverImage={
                image
                  ? {
                      name: image.name,
                      src: fileURL(props.pageID, image.path.replace(`pages/${props.pageID}/`, ''))
                    }
                  : undefined
              }
            />
          )
        })}
      </div>
    </div>
  )
}

export function RecordForm(
  props: Pick<ViewProps, 'fields' | 'pageID' | 'editable'> & {
    write(changes: RecordWrite): Promise<unknown>
    close(): void
  }
) {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(RecordFormModel)
  // Read before the map so React Compiler tracks the signal values in its cache.
  const values = model.values.value,
    pending = model.pending.value,
    generation = model.generation.value

  return (
    <form
      className="contents"
      aria-busy={model.pending.value}
      onKeyDownCapture={event => {
        if (event.key === 'Enter' && (event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229)) {
          event.preventDefault()
        }
      }}
      onSubmit={event => {
        event.preventDefault()
        if (!props.editable || model.pending.value || model.uploading.value.size) return
        void model.submit(props.write)
      }}>
      <div className="pod-dialog-body grid gap-5">
        {props.fields
          .filter(field => writableField(field))
          .map(field => (
            <div key={`${field.id}:${generation}`} className="grid gap-2 text-sm">
              <span>{field.name}</span>
              <FieldInput
                pageID={props.pageID}
                field={field}
                value={values[field.id] ?? null}
                commitOnChange
                disabled={pending || !props.editable}
                onPendingChange={active => model.upload(field.id, active)}
                onChange={value => model.change(field.id, value)}
              />
            </div>
          ))}
        <ContentError error={model.error.value} />
        {!props.editable && <p role="status">{t('pod.errors.forbidden')}</p>}
        {!!model.uploading.value.size && (
          <p role="status">{t('pod.content.attachments_are_uploading_wait_before_submitting')}</p>
        )}
      </div>
      <DialogFooter>
        <Button type="button" variant="ghost" disabled={model.pending.value} onClick={props.close}>
          {t('pod.content.cancel')}
        </Button>
        <Button
          variant="default"
          type="submit"
          disabled={!props.editable || model.pending.value || !!model.uploading.value.size}>
          {model.pending.value ? t('pod.content.submitting') : t('pod.content.submit_record')}
        </Button>
      </DialogFooter>
    </form>
  )
}
