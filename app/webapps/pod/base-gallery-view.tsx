import { useTranslation } from 'react-i18next'
import { useEffect, useMemo, useRef, useState } from 'react'
import { useVirtualizer } from '@tanstack/react-virtual'
import type { BaseRecord } from '@ankole/applet-sdk/types'
import { InfiniteScrollSentinel, RecordCard, useRetainedDetailRecord, type CardViewProps } from './base-card-views'
import { ReferenceLabelsProvider } from './base-field-value'
import { fileURL } from './content-api'
import { Choice } from './content-primitives'
import { fieldValue } from './state/table-query'
import type { ViewConfig } from './state/view-config'

export function GalleryView(props: CardViewProps) {
  const { t } = useTranslation()
  const { RecordDetailsDialog } = props
  const detail = useRetainedDetailRecord(props.records, props.update, props.remove, props.recordLocation)
  const scrollRef = useRef<HTMLDivElement>(null)
  const [columns, setColumns] = useState(3)
  const attachmentFields = props.fields.filter(field => field.type === 'attachment')
  const cover = attachmentFields.find(field => field.id === props.view.config.cover_field_id)

  useEffect(() => {
    const node = scrollRef.current
    if (!node || typeof ResizeObserver === 'undefined') return
    const update = () => {
      const width = node.clientWidth
      if (width > 0) setColumns(Math.max(1, Math.floor((width + 16) / 256)))
    }
    update()
    const observer = new ResizeObserver(update)
    observer.observe(node)
    return () => observer.disconnect()
  }, [])

  const rowCount = Math.ceil(props.records.length / columns)
  const virtual = useVirtualizer({
    count: rowCount,
    getScrollElement: () => scrollRef.current,
    getItemKey: index => props.records[index * columns]?.id ?? String(index),
    estimateSize: () => (cover ? 280 : 180),
    overscan: 3
  })
  const virtualRows = virtual.getVirtualItems()
  const renderedRows = virtualRows.length > 0 ? virtualRows : null
  const visibleRecords = useMemo(() => {
    if (!renderedRows) return props.records.slice(0, columns * 6)
    const slice: BaseRecord[] = []
    for (const row of renderedRows) {
      const start = row.index * columns
      for (let idx = start; idx < Math.min(props.records.length, start + columns); idx++) {
        slice.push(props.records[idx]!)
      }
    }
    return slice
  }, [renderedRows, props.records, columns])

  const renderCard = (record: BaseRecord) => {
    const value = cover ? fieldValue(record, cover) : null
    const image = Array.isArray(value)
      ? (value as { mime: string; path: string; name: string }[]).find(file => file.mime.startsWith('image/'))
      : undefined
    return (
      <RecordCard
        key={record.id}
        {...props}
        record={record}
        onOpenDetail={detail.open}
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
  }

  return (
    <ReferenceLabelsProvider fields={props.fields} records={visibleRecords}>
      <div className="space-y-4 pt-2">
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
        <div ref={scrollRef} className="max-h-[75vh] overflow-y-auto pr-0.5">
          {renderedRows ? (
            <div style={{ height: virtual.getTotalSize(), position: 'relative', width: '100%' }}>
              {renderedRows.map(row => {
                const start = row.index * columns
                const rowRecords = props.records.slice(start, start + columns)
                return (
                  <div
                    key={row.key}
                    data-index={row.index}
                    ref={virtual.measureElement}
                    className="pb-4"
                    style={{
                      position: 'absolute',
                      top: 0,
                      left: 0,
                      width: '100%',
                      transform: `translateY(${row.start}px)`
                    }}>
                    <div className="grid gap-4" style={{ gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))` }}>
                      {rowRecords.map(renderCard)}
                    </div>
                  </div>
                )
              })}
            </div>
          ) : (
            <div className="grid grid-cols-[repeat(auto-fill,minmax(240px,1fr))] gap-4">
              {visibleRecords.map(renderCard)}
            </div>
          )}
          <InfiniteScrollSentinel
            hasNextPage={props.hasNextPage}
            isFetchingNextPage={props.isFetchingNextPage}
            error={props.fetchNextError}
            onLoadMore={props.fetchNextPage}
            rootRef={scrollRef}
          />
        </div>
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
          pending={props.pending}
          update={detail.update}
          remove={detail.remove}
        />
      )}
    </ReferenceLabelsProvider>
  )
}
