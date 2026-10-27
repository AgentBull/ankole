import { t } from 'i18next'
import { useQueries, useQuery, useQueryClient } from '@tanstack/react-query'
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import type { BaseField, BaseRecord, Value } from '@ankole/applet-sdk/types'
import { contentKeys, fileURL } from './content-api'
import { podSubjects } from './api/generated/sdk.gen'
import { baseHTTP } from './base-api'
import { displayValue } from './base-field-types'
import { useContent } from './content-context'
import { isRealtimeAccessDenied } from './realtime'
import { fieldValue, principalUID } from './state/table-query'

type TableReferenceLabels = { labels: Map<string, string>; pending: boolean }
const ReferenceLabels = createContext<Map<string, TableReferenceLabels> | null>(null)

/** Batch record labels at the view boundary instead of one schema/query pair per cell. */
export function ReferenceLabelsProvider({
  fields,
  records,
  children
}: {
  fields: BaseField[]
  records: BaseRecord[]
  children: ReactNode
}) {
  const { base } = useContent()
  const client = useQueryClient()
  const [revoked, setRevoked] = useState(new Set<string>())
  const tables = new Map<string, Set<string>>()
  for (const field of fields.filter(field => field.type === 'link')) {
    const tableID = String(field.config.table_id)
    const ids = tables.get(tableID) ?? new Set<string>()
    for (const record of records) {
      for (const id of (Array.isArray(record.data[field.id]) ? record.data[field.id] : []) as string[]) ids.add(id)
    }
    if (ids.size) tables.set(tableID, ids)
  }
  const entries = [...tables.entries()].map(([tableID, ids]) => ({ tableID, ids: [...ids].sort() }))
  const tableIDs = entries
    .map(entry => entry.tableID)
    .sort()
    .join(',')
  useEffect(() => {
    const subscriptions = tableIDs
      .split(',')
      .filter(Boolean)
      .map(tableID =>
        base.subscribe(tableID, event => {
          if (event.access_revoked) setRevoked(previous => new Set([...previous, tableID]))
          void client.invalidateQueries({ queryKey: [...contentKeys.all, 'reference-labels', tableID] })
        })
      )
    return () => {
      for (const unsubscribe of subscriptions) unsubscribe()
    }
  }, [base, client, tableIDs])
  const labels = useQueries({
    queries: entries.map(({ tableID, ids }) => ({
      queryKey: [...contentKeys.all, 'reference-labels', tableID, ids],
      queryFn: () => loadReferenceLabels(tableID, ids),
      retry: false,
      enabled: !revoked.has(tableID)
    }))
  })
  return (
    <ReferenceLabels
      value={
        new Map(
          entries.map((entry, index) => {
            const denied = revoked.has(entry.tableID) || isRealtimeAccessDenied(labels[index]?.error)
            return [
              entry.tableID,
              {
                labels: denied ? new Map<string, string>() : (labels[index]?.data ?? new Map<string, string>()),
                pending: !denied && Boolean(labels[index]?.isPending)
              }
            ]
          })
        )
      }>
      {children}
    </ReferenceLabels>
  )
}

export async function loadReferenceLabels(tableID: string, ids: string[]) {
  const schema = await baseHTTP.schema(tableID)
  const primary = schema.fields.find(field => field.is_primary)
  const records: BaseRecord[] = []
  for (let offset = 0; offset < ids.length; offset += 1000) {
    let page_token: string | undefined
    do {
      const result = await baseHTTP.query(tableID, { ids: ids.slice(offset, offset + 1000), page_token })
      records.push(...result.records)
      page_token = result.page_token ?? undefined
    } while (page_token)
  }
  return new Map(
    records.map(record => [
      record.id,
      primary ? displayValue(primary, fieldValue(record, primary)) : t('pod.content.untitled')
    ])
  )
}

export function FieldValue({ field, value, pageID }: { field: BaseField; value: Value; pageID?: string }) {
  const sharedLabels = useContext(ReferenceLabels)
  const people = ['user', 'created_by', 'updated_by'].includes(field.type)
  const link = field.type === 'link'
  const values = (Array.isArray(value) ? value : value === null ? [] : [value]).map(item => {
    if (people) return principalUID(item as Value) ?? String(item)
    if (item && typeof item === 'object' && 'uid' in item) return String(item.uid)
    return String(item).split(':principal/').at(-1)!
  })
  const subjects = useQuery({
    queryKey: [...contentKeys.all, 'subjects'],
    queryFn: () => podSubjects(),
    enabled: people && values.length > 0,
    staleTime: 60000
  })
  const records = useQuery({
    queryKey: [...contentKeys.all, 'reference-labels', field.config.table_id, values],
    queryFn: () => loadReferenceLabels(String(field.config.table_id), values),
    enabled: link && !sharedLabels && values.length > 0,
    retry: false
  })
  if (field.type === 'attachment') {
    const files = Array.isArray(value)
      ? (value as { path?: string; name?: string }[]).filter(file => file && typeof file === 'object' && file.name)
      : []
    if (!files.length) return <>—</>
    return (
      <span className="inline-flex max-w-full flex-wrap items-center gap-x-2 gap-y-1">
        {files.map((file, index) => {
          const match = typeof file.path === 'string' ? /^pages\/([^/]+)\/(.+)$/.exec(file.path) : null
          const ownerPageID = pageID ?? match?.[1]
          const relativePath =
            ownerPageID && typeof file.path === 'string' ? file.path.replace(`pages/${ownerPageID}/`, '') : undefined
          return ownerPageID && relativePath ? (
            <a
              key={`${file.path}:${index}`}
              className="link truncate"
              href={fileURL(ownerPageID, relativePath)}
              download={file.name}
              onClick={event => event.stopPropagation()}>
              {file.name}
            </a>
          ) : (
            <span key={index} className="truncate">
              {file.name}
            </span>
          )
        })}
      </span>
    )
  }
  if (!people && !link) return <>{displayValue(field, value)}</>
  if (!values.length) return <>—</>
  const shared = link ? sharedLabels?.get(String(field.config.table_id)) : undefined
  if ((people && subjects.isPending) || (link && (shared ? shared.pending : !sharedLabels && records.isPending))) {
    return <span className="text-fg-tertiary">…</span>
  }
  return (
    <>
      {values
        .map(id =>
          people
            ? (subjects.data?.subjects.find(subject => subject.principal_uid === id)?.name ??
              t('pod.content.unknown_member'))
            : (shared?.labels.get(id) ??
              (isRealtimeAccessDenied(records.error) ? undefined : records.data?.get(id)) ??
              t('pod.content.cannot_display'))
        )
        .join(', ')}
    </>
  )
}
