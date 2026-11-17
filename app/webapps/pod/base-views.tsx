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
  cn,
  toast
} from '@ankole/uikit'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { defaultRangeExtractor, useVirtualizer } from '@tanstack/react-virtual'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import type {
  BaseField,
  BaseRecord,
  BaseTable,
  RecordData,
  RecordWrite,
  Versions,
  WriteResult
} from '@ankole/applet-sdk/types'
import { baseGridRowEstimate } from './base-row-size'
import { ContentError } from './content-primitives'
import {
  BaseCell,
  FieldEditorButton,
  FieldInput,
  RecordTitle,
  resolveVisibleFields,
  writableField
} from './base-fields'
import { useRetainedDetailRecord } from './base-card-views'
import { ReferenceLabelsProvider } from './base-field-value'
import { RecordFormModel } from './state/record-form'
import type { ConfiguredView, ViewConfig } from './state/view-config'
import { requestErrorMessage } from '../common/request-errors'
import { contentError } from './content-errors'
import { AddRegular, ArrowMaximizeRegular, DeleteRegular } from '@ankole/uikit/icons'
import { fieldIcons, fieldTypes } from './base-field-types'
import { ChartView } from './base-chart-view'
import { GalleryView } from './base-gallery-view'
import { KanbanView } from './base-kanban-view'

export { GalleryView, KanbanView }

export type ViewProps = {
  pageID: string
  tableID: string
  tables: BaseTable[]
  fields: BaseField[]
  records: BaseRecord[]
  totalCount?: number
  hasNextPage?: boolean
  isFetchingNextPage?: boolean
  fetchNextError?: unknown
  fetchNextPage?(): void
  isFetchingRecords?: boolean
  view: ConfiguredView
  editable: boolean
  schemaEditable: boolean
  canConfigureChart?: boolean
  chartControlsOpen?: boolean
  chartControlsId?: string
  pending?: boolean
  create(data: RecordData): Promise<WriteResult>
  update(id: string, data: RecordData, expected: Versions): Promise<unknown>
  remove(id: string, expected: Versions): Promise<unknown>
  configure(config: ViewConfig): void
  configuring?: boolean
  onFieldCreated?(fieldID: string): void
}

export function BaseViewContent(props: ViewProps) {
  return <BaseView {...props} />
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
          RecordDetailsDialog={RecordDetailsDialog}
        />
      )
    case 'gallery':
      return <GalleryView {...props} RecordDetailsDialog={RecordDetailsDialog} />
    case 'chart':
      return (
        <ReferenceLabelsProvider fields={props.fields} records={props.records}>
          <ChartView {...props} RecordDetailsDialog={RecordDetailsDialog} />
        </ReferenceLabelsProvider>
      )
  }
}

function GridView(props: ViewProps) {
  const { t } = useTranslation()
  const visible = resolveVisibleFields(props.fields, props.view.config.visible_fields, 'grid')
  const scroll = useRef<HTMLDivElement>(null)
  const [retained, setRetained] = useState<string[]>([])
  const detail = useRetainedDetailRecord(props.records, props.update, props.remove)
  const [addingRow, setAddingRow] = useState(false)
  const [pendingFocusID, setPendingFocusID] = useState<string>()
  const [pendingNewRecord, setPendingNewRecord] = useState<BaseRecord>()
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
  const recordIndex = useMemo(() => {
    const index = new Map<string, number>()
    props.records.forEach((record, position) => index.set(record.id, position))
    return index
  }, [props.records])
  const estimatedRow = baseGridRowEstimate()
  const virtual = useVirtualizer({
    count: props.records.length,
    getScrollElement: () => scroll.current,
    getItemKey: index => props.records[index]!.id,
    estimateSize: () => estimatedRow,
    overscan: 8,
    rangeExtractor: useCallback(
      range => {
        const pinned = pendingFocusID ? [...retained, pendingFocusID] : retained
        const extra: number[] = []
        for (const id of pinned) {
          const position = recordIndex.get(id)
          if (position !== undefined) extra.push(position)
        }
        return [...new Set([...defaultRangeExtractor(range), ...extra])].sort((left, right) => left - right)
      },
      [pendingFocusID, retained, recordIndex]
    )
  })
  useEffect(() => {
    if (!pendingNewRecord || props.pending || props.isFetchingRecords) return
    const exists = props.records.some(record => record.id === pendingNewRecord.id)
    if (exists) {
      setPendingFocusID(pendingNewRecord.id)
    } else {
      detail.open(pendingNewRecord)
    }
    setPendingNewRecord(undefined)
  }, [pendingNewRecord, props.pending, props.isFetchingRecords, props.records])
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
  const lastRowIndex = rows.at(-1)?.index
  useEffect(() => {
    if (
      lastRowIndex !== undefined &&
      lastRowIndex >= props.records.length - 12 &&
      props.hasNextPage &&
      !props.isFetchingNextPage &&
      !props.fetchNextError &&
      props.fetchNextPage
    ) {
      props.fetchNextPage()
    }
  }, [
    lastRowIndex,
    props.records.length,
    props.hasNextPage,
    props.isFetchingNextPage,
    props.fetchNextError,
    props.fetchNextPage
  ])
  const detailRecord = detail.record
  const visibleRecords = useMemo(() => {
    const list = rows.map(row => props.records[row.index]!).filter(Boolean)
    if (detailRecord && !list.some(record => record.id === detailRecord.id)) list.push(detailRecord)
    return list
  }, [rows, props.records, detailRecord])
  const triggerCreateRow = () => {
    if (addingRow) return
    setAddingRow(true)
    void props
      .create({})
      .then(result => {
        const created = result.records[0]
        if (created) setPendingNewRecord(created)
      })
      .catch(error => toast.error(requestErrorMessage(contentError(error))))
      .finally(() => setAddingRow(false))
  }
  const reportedTotal = Math.max(props.totalCount ?? props.records.length, props.records.length)
  return (
    <ReferenceLabelsProvider fields={props.fields} records={visibleRecords}>
      <div
        ref={scroll}
        className="pod-base-grid max-h-[70vh] overflow-auto"
        role="region"
        aria-label={t('pod.content.table_records')}
        tabIndex={0}>
        <Table containerClassName="overflow-visible" aria-rowcount={reportedTotal + 1}>
          <TableHeader className="sticky top-0 z-10 bg-page">
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
                  iconOnly
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
                    {visible.map((field, colIndex) => (
                      <TableCell
                        key={field.id}
                        className={cn(
                          field.is_primary && 'font-medium',
                          (field.is_primary || colIndex === 0) && field.type !== 'checkbox' && 'pod-base-primary'
                        )}>
                        {colIndex === 0 ? (
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
                              onClick={() => detail.open(record)}>
                              <ArrowMaximizeRegular aria-hidden="true" />
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
            {(props.isFetchingNextPage || Boolean(props.fetchNextError)) && (
              <TableRow>
                <TableCell colSpan={visible.length + 1} className="border-r-0 py-2 text-xs text-fg-tertiary">
                  {props.fetchNextError ? (
                    <div className="flex items-center gap-2">
                      <span className="text-destructive">
                        {requestErrorMessage(contentError(props.fetchNextError))}
                      </span>
                      {props.fetchNextPage && (
                        <Button size="xs" variant="outline" onClick={props.fetchNextPage}>
                          {t('common.retry')}
                        </Button>
                      )}
                    </div>
                  ) : (
                    <span>{t('pod.content.loading_records')}</span>
                  )}
                </TableCell>
              </TableRow>
            )}
            {props.editable && !props.hasNextPage && (
              <TableRow className="pod-base-add-row">
                <TableCell colSpan={visible.length + 1} className="border-r-0 p-1">
                  <Button
                    size="sm"
                    variant="ghost"
                    className="w-full justify-start text-fg-tertiary hover:text-fg-primary"
                    disabled={addingRow || props.pending}
                    onClick={triggerCreateRow}>
                    <AddRegular aria-hidden="true" />
                    {t('pod.content.add_row', { defaultValue: 'New row' })}
                  </Button>
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </div>
      {props.editable && props.hasNextPage && (
        <div className="pod-base-add-row border-t border-border-subtle/60 bg-page/95 px-1 py-1">
          <Button
            size="sm"
            variant="ghost"
            className="w-full justify-start text-fg-tertiary hover:text-fg-primary"
            disabled={addingRow || props.pending}
            onClick={triggerCreateRow}>
            <AddRegular aria-hidden="true" />
            {t('pod.content.add_row', { defaultValue: 'New row' })}
          </Button>
        </div>
      )}
      {detailRecord && (
        <RecordDetailsDialog
          open
          onOpenChange={next => {
            if (!next) detail.close()
          }}
          record={detailRecord}
          fields={props.fields}
          pageID={props.pageID}
          editable={props.editable}
          pending={props.pending}
          update={detail.update}
          remove={detail.remove}
        />
      )}
    </ReferenceLabelsProvider>
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

export type RecordDetailsDialogComponent = typeof RecordDetailsDialog

export function RecordDetailsDialog({
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
        <DeleteRegular aria-hidden="true" />
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
          <RecordTitle record={deleting ?? record} fields={fields} />{' '}
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

  const writableFields = props.fields.filter(field => writableField(field))

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
        {writableFields.length > 0 ? (
          writableFields.map(field => (
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
          ))
        ) : (
          <div className="grid gap-2 text-sm text-fg-secondary">
            {props.fields.map(field => {
              const Icon = fieldIcons[field.type]
              return (
                <div
                  key={field.id}
                  className="flex items-center justify-between gap-3 rounded-control border border-border-subtle px-3 py-2">
                  <span className="flex min-w-0 items-center gap-2 truncate text-fg-primary">
                    <Icon aria-hidden="true" className="size-4 shrink-0 text-fg-tertiary" />
                    <span className="truncate">{field.name}</span>
                  </span>
                  <span className="shrink-0 text-xs text-fg-tertiary">{fieldTypes[field.type]}</span>
                </div>
              )
            })}
          </div>
        )}
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
