import { useTranslation } from 'react-i18next'
import { Button } from '@ankole/uikit'
import { useEffect, useRef, useState, type DragEvent, type RefObject } from 'react'
import { expectedVersions } from '@ankole/applet-sdk'
import type { BaseRecord, RecordData, Value, WriteResult } from '@ankole/applet-sdk/types'
import { FieldValue, RecordTitle } from './base-fields'
import { fieldValue } from './state/table-query'
import { requestErrorMessage } from '../common/request-errors'
import { contentError } from './content-errors'
import type { RecordDetailsDialogComponent, ViewProps } from './base-views'

export type CardViewProps = ViewProps & { RecordDetailsDialog: RecordDetailsDialogComponent }
export type RecordDrag = { record?: BaseRecord; from?: Value }

const recordDragType = 'application/ankole-record'

export const readRecordDrag = (event: DragEvent): RecordDrag => JSON.parse(event.dataTransfer.getData(recordDragType))
export const commitRecordDrag = (update: ViewProps['update'], record: BaseRecord, data: RecordData) =>
  update(record.id, data, expectedVersions(record, data))
export const writeRecordDrag = (event: DragEvent, record: BaseRecord, from?: Value) =>
  event.dataTransfer.setData(recordDragType, JSON.stringify({ record, ...(from === undefined ? {} : { from }) }))

export function InfiniteScrollSentinel({
  hasNextPage,
  isFetchingNextPage,
  error,
  onLoadMore,
  rootRef
}: {
  hasNextPage?: boolean
  isFetchingNextPage?: boolean
  error?: unknown
  onLoadMore?(): void
  rootRef?: RefObject<HTMLElement | null>
}) {
  const { t } = useTranslation()
  const sentinelRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const node = sentinelRef.current
    if (!node || !hasNextPage || isFetchingNextPage || Boolean(error) || !onLoadMore) return
    if (typeof IntersectionObserver === 'undefined') return
    const observer = new IntersectionObserver(
      entries => {
        if (entries.some(entry => entry.isIntersecting)) onLoadMore()
      },
      { root: rootRef?.current ?? null, rootMargin: '300px' }
    )
    observer.observe(node)
    return () => observer.disconnect()
  }, [hasNextPage, isFetchingNextPage, error, onLoadMore, rootRef])

  if (!hasNextPage && !isFetchingNextPage && !error) return null
  return (
    <div ref={sentinelRef} className="flex items-center justify-center py-2 text-xs text-fg-tertiary">
      {error ? (
        <div className="flex items-center gap-2">
          <span className="text-destructive">{requestErrorMessage(contentError(error))}</span>
          {onLoadMore && (
            <Button size="xs" variant="outline" onClick={onLoadMore}>
              {t('common.retry')}
            </Button>
          )}
        </div>
      ) : isFetchingNextPage ? (
        <span>{t('pod.content.loading_records')}</span>
      ) : null}
    </div>
  )
}

export function mergeRetainedDetailRecord(
  current: BaseRecord | undefined,
  records: readonly BaseRecord[]
): BaseRecord | undefined {
  if (!current) return undefined
  return records.find(record => record.id === current.id) ?? current
}

function extractUpdatedRecord(result: unknown, id: string): BaseRecord | undefined {
  if (!result || typeof result !== 'object' || !('records' in result)) return undefined
  const records = (result as Partial<WriteResult>).records
  return Array.isArray(records) ? records.find(record => record.id === id) : undefined
}

/**
 * Keeps an open record-details dialog mounted even if pagination trims cached pages back to page 1.
 */
export function useRetainedDetailRecord(
  records: readonly BaseRecord[],
  update: ViewProps['update'],
  remove: ViewProps['remove']
) {
  const [snapshot, setSnapshot] = useState<BaseRecord>()
  const live = snapshot ? records.find(record => record.id === snapshot.id) : undefined

  useEffect(() => {
    if (live && live !== snapshot) {
      setSnapshot(live)
    }
  }, [live, snapshot])

  const detailRecord = mergeRetainedDetailRecord(snapshot, records)
  const wrappedUpdate: ViewProps['update'] = async (id, data, expected) => {
    const result = await update(id, data, expected)
    const updated = extractUpdatedRecord(result, id)
    if (updated) {
      setSnapshot(current => (current?.id === id ? updated : current))
    }
    return result
  }
  const wrappedRemove: ViewProps['remove'] = async (id, expected) => {
    const result = await remove(id, expected)
    setSnapshot(current => (current?.id === id ? undefined : current))
    return result
  }

  return {
    record: detailRecord,
    open: (record: BaseRecord) => setSnapshot(record),
    close: () => setSnapshot(undefined),
    update: wrappedUpdate,
    remove: wrappedRemove
  }
}

export function RecordCard(
  props: CardViewProps & {
    record: BaseRecord
    draggable?: boolean
    dragFrom?: Value
    coverImage?: { name: string; src: string }
    onOpenDetail?: (record: BaseRecord) => void
  }
) {
  const { RecordDetailsDialog } = props
  const [open, setOpen] = useState(false)
  const triggerOpen = () => {
    if (props.onOpenDetail) props.onOpenDetail(props.record)
    else setOpen(true)
  }
  const primary = props.fields.find(field => field.is_primary) ?? props.fields[0]
  return (
    <>
      <article
        draggable={props.draggable}
        onDragStart={event => writeRecordDrag(event, props.record, props.dragFrom)}
        onClick={event => {
          const target = event.target as HTMLElement | null
          if (target?.closest('a, button, input, select, textarea')) return
          triggerOpen()
        }}
        className="cursor-pointer space-y-2 overflow-hidden rounded-control border border-border-subtle bg-page p-3 transition-colors hover:border-control-edge">
        {props.coverImage && (
          <img
            className="-mx-3 -mt-3 mb-2 h-36 w-[calc(100%+1.5rem)] max-w-none object-cover"
            alt={props.coverImage.name}
            src={props.coverImage.src}
          />
        )}
        <Button size="sm" variant="ghost" className="max-w-full justify-start px-0 font-semibold" onClick={triggerOpen}>
          <span className="min-w-0 truncate">
            <RecordTitle record={props.record} primary={primary} />
          </span>
        </Button>
        {props.fields
          .filter(
            field =>
              field !== primary &&
              // A board column already names the group, so its cards leave the grouping field out.
              field.id !== props.view.config.group_field_id &&
              (!props.view.config.visible_fields || props.view.config.visible_fields.includes(field.id))
          )
          .map(field => (
            <p key={field.id} className="text-xs text-fg-tertiary">
              <span>{field.name}: </span>
              <FieldValue field={field} value={fieldValue(props.record, field)} pageID={props.pageID} />
            </p>
          ))}
      </article>
      {!props.onOpenDetail && open ? (
        <RecordDetailsDialog
          open
          onOpenChange={setOpen}
          record={props.record}
          fields={props.fields}
          pageID={props.pageID}
          editable={props.editable}
          pending={props.pending}
          update={props.update}
          remove={props.remove}
        />
      ) : null}
    </>
  )
}
