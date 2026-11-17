import {
  Badge,
  Button,
  Dialog,
  DialogContent,
  DialogTitle,
  Label,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Skeleton,
  toast
} from '@ankole/uikit'
import { CheckmarkRegular } from '@ankole/uikit/icons'
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useId, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { AppletBindings, TableBinding } from '@ankole/applet-sdk/types'
import * as api from './api/generated/sdk.gen'
import { baseHTTP } from './base-api'
import { contentKeys, type PageDetail } from './content-api'
import { ContentError, ContentLoading } from './content-primitives'
import { PagePicker } from './page-picker'

type Slot = {
  tableId?: string
  required?: boolean
  description?: string
  fields?: Record<string, { fieldId?: string; type?: string; description?: string }>
}
type Override = { table_id?: string | null; field_overrides?: Record<string, string> }
const AUTO_FIELD = '__auto__'

type SlotBaseline = { signature: string; table: string; fields: Record<string, string> }

export function reconcileSlotDraft(
  current: { table: string; fields: Record<string, string> },
  previous: SlotBaseline,
  next: SlotBaseline
): { table: string; fields: Record<string, string> } | undefined {
  if (next.signature === previous.signature) return undefined
  const matchesPrevious =
    current.table === previous.table && JSON.stringify(current.fields) === JSON.stringify(previous.fields)
  const matchesNext = current.table === next.table && JSON.stringify(current.fields) === JSON.stringify(next.fields)
  return matchesPrevious || matchesNext ? { table: next.table, fields: next.fields } : undefined
}

export function AppletBindingsTab({ detail }: { detail: PageDetail }) {
  const { t } = useTranslation()
  const query = useQuery({
    queryKey: [...contentKeys.page(detail.page.id), 'bindings', detail.bindings_digest],
    queryFn: () => api.podAppletBindings({ path: { page_id: detail.page.id } }),
    placeholderData: keepPreviousData
  })
  if (query.isPending) return <ContentLoading />
  const tables = (query.data?.manifest as { tables?: Record<string, Slot> } | undefined)?.tables ?? {}
  const bindings = (query.data?.bindings ?? {}) as AppletBindings
  const overrides = (query.data?.overrides ?? {}) as Record<string, Override>
  return (
    <div className="space-y-5">
      <h2 className="text-base font-semibold">{t('pod.applet_settings.tab_bindings')}</h2>
      <ContentError error={query.error} retry={() => void query.refetch()} />
      {Object.keys(tables).length === 0 && (
        <p className="text-sm text-fg-secondary">{t('pod.applet_settings.no_bindings')}</p>
      )}
      {Object.entries(tables).map(([slot, spec]) => (
        <SlotBinding
          key={slot}
          pageID={detail.page.id}
          slot={slot}
          spec={spec}
          binding={bindings[slot]}
          override={overrides[slot]}
          tableId={bindings[slot]?.tableId ?? undefined}
        />
      ))}
    </div>
  )
}

function SlotBinding({
  pageID,
  slot,
  spec,
  binding,
  override,
  tableId
}: {
  pageID: string
  slot: string
  spec: Slot
  binding?: TableBinding
  override?: Override
  tableId?: string | null
}) {
  const { t } = useTranslation()
  const baseId = useId()
  const client = useQueryClient()
  const serverTable = tableId ?? ''
  const serverFields = override?.field_overrides ?? {}
  const serverSignature = `${serverTable}:${JSON.stringify(serverFields)}`
  const [table, setTable] = useState(serverTable)
  const [fields, setFields] = useState<Record<string, string>>(serverFields)
  const [picking, setPicking] = useState(false)
  const [basePage, setBasePage] = useState<string>()
  const baselineRef = useRef<SlotBaseline>({ signature: serverSignature, table: serverTable, fields: serverFields })

  useEffect(() => {
    const nextBaseline: SlotBaseline = { signature: serverSignature, table: serverTable, fields: serverFields }
    const reconciled = reconcileSlotDraft({ table, fields }, baselineRef.current, nextBaseline)
    baselineRef.current = nextBaseline
    if (reconciled) {
      setTable(reconciled.table)
      setFields(reconciled.fields)
    }
  }, [serverSignature])

  const tables = useQuery({
    queryKey: [...contentKeys.page(basePage ?? ''), 'tables'],
    queryFn: () => baseHTTP.tables(basePage!),
    enabled: !!basePage
  })
  const schema = useQuery({
    queryKey: [...contentKeys.all, 'binding-schema', table],
    queryFn: () => baseHTTP.schema(table),
    enabled: !!table
  })
  const fieldNamesById = new Map((schema.data?.fields ?? []).map(item => [item.id, item.name]))
  const hasOverride = Boolean(override?.table_id || Object.keys(override?.field_overrides ?? {}).length > 0)

  const save = useMutation({
    mutationFn: (reset: boolean) =>
      reset
        ? api.podAppletBindingDelete({ path: { page_id: pageID, slot_key: slot } })
        : api.podAppletBindingPut({
            path: { page_id: pageID, slot_key: slot },
            body: { data: { table_id: table || null, field_overrides: fields } }
          }),
    onSuccess: async (result, reset) => {
      if (reset) {
        const nextTable = (result.bindings as AppletBindings)[slot]?.tableId ?? ''
        baselineRef.current = { signature: `${nextTable}:{}`, table: nextTable, fields: {} }
        setFields({})
        setTable(nextTable)
        toast.success(t('pod.applet_settings.binding_reset', { slot }))
      } else {
        toast.success(t('pod.applet_settings.binding_saved', { slot }))
      }
      await client.invalidateQueries({ queryKey: contentKeys.page(pageID) })
    }
  })

  return (
    <section className="space-y-3 rounded-lg border border-border-subtle p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex flex-wrap items-center gap-2">
          <h3 className="text-sm font-medium text-fg-primary">
            {slot}
            {spec.required ? ' *' : ''}
          </h3>
          {binding?.status === 'ready' ? (
            <Badge variant="secondary">{t('pod.applet_settings.binding_ready')}</Badge>
          ) : binding?.status === 'missing_fields' && binding.missing.length > 0 ? (
            <Badge variant="warning">
              {t('pod.applet_settings.binding_missing_fields', { fields: binding.missing.join(', ') })}
            </Badge>
          ) : (
            <Badge variant="outline">{t('pod.applet_settings.unconfigured')}</Badge>
          )}
        </div>
        <Button
          size="xs"
          variant="outline"
          onClick={() => {
            setBasePage(undefined)
            setPicking(true)
          }}>
          {t('pod.applet_settings.choose_table')}
        </Button>
      </div>
      {spec.description && <p className="text-sm text-fg-secondary">{spec.description}</p>}
      <div className="text-sm text-fg-secondary">
        {schema.isPending && table ? (
          <Skeleton className="h-4 w-36" />
        ) : (
          schema.data?.table.name || t('pod.applet_settings.unconfigured')
        )}
      </div>
      <ContentError error={schema.error} />
      {Object.entries(spec.fields ?? {}).map(([key, field]) => {
        const controlId = `${baseId}-field-${key}`
        const resolvedId = binding?.tableId === table ? binding?.fields[key] : undefined
        const autoLabel =
          !fields[key] && resolvedId && fieldNamesById.get(resolvedId)
            ? `${t('pod.applet_settings.automatic_field')} (${fieldNamesById.get(resolvedId)})`
            : t('pod.applet_settings.automatic_field')
        return (
          <div key={key} className="grid grid-cols-1 items-center gap-1.5 sm:grid-cols-[minmax(8rem,1fr)_2fr] sm:gap-3">
            <Label htmlFor={controlId}>
              {key}
              {field.type ? <span className="ml-1 font-normal text-fg-secondary">· {field.type}</span> : null}
            </Label>
            <Select
              value={fields[key] || AUTO_FIELD}
              onValueChange={value =>
                setFields(current => {
                  const next = { ...current }
                  if (value && value !== AUTO_FIELD) next[key] = value
                  else delete next[key]
                  return next
                })
              }
              loading={schema.isPending}
              disabled={!table}>
              <SelectTrigger id={controlId}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={AUTO_FIELD}>{autoLabel}</SelectItem>
                {(schema.data?.fields ?? [])
                  .filter(item => !field.type || item.type === field.type)
                  .map(item => (
                    <SelectItem key={item.id} value={item.id}>
                      {item.name}
                    </SelectItem>
                  ))}
              </SelectContent>
            </Select>
          </div>
        )
      })}
      <ContentError error={save.error} />
      <div className="flex flex-wrap gap-2 pt-1">
        <Button size="sm" disabled={save.isPending} onClick={() => save.mutate(false)}>
          {t('pod.content.save')}
        </Button>
        {hasOverride && (
          <Button size="sm" variant="ghost" disabled={save.isPending} onClick={() => save.mutate(true)}>
            {t('pod.applet_settings.reset_binding')}
          </Button>
        )}
      </div>
      <Dialog open={picking} onOpenChange={setPicking}>
        <DialogContent className="pod-dialog max-w-md" closeLabel={t('common.close')}>
          <DialogTitle>{t('pod.applet_settings.choose_table')}</DialogTitle>
          <div className="pod-dialog-body space-y-3">
            <PagePicker
              label={t('pod.applet_settings.choose_base')}
              requiredAction="node_view"
              canSelect={page => page.type === 'base'}
              onSelect={setBasePage}
            />
            {tables.isFetching && <ContentLoading />}
            <ContentError error={tables.error} />
            {tables.data && tables.data.tables.length === 0 && (
              <p className="text-sm text-fg-secondary">{t('pod.applet_settings.no_tables_in_base')}</p>
            )}
            {(tables.data?.tables.length ?? 0) > 0 && (
              <div className="grid gap-1.5">
                {tables.data!.tables.map(item => {
                  const active = item.id === table
                  return (
                    <Button
                      key={item.id}
                      variant="outline"
                      className="justify-between"
                      onClick={() => {
                        setTable(item.id)
                        setFields({})
                        setPicking(false)
                      }}>
                      <span className="truncate">{item.name}</span>
                      {active && <CheckmarkRegular aria-hidden className="size-4 shrink-0 text-primary" />}
                    </Button>
                  )
                })}
              </div>
            )}
          </div>
        </DialogContent>
      </Dialog>
    </section>
  )
}
