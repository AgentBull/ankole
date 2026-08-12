import {
  Badge,
  Button,
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  Checkbox,
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Skeleton
} from '@ankole/uikit'
import { RiArrowDownSLine, RiCloseLine, RiFilter3Line, RiHistoryLine, RiRefreshLine } from '@remixicon/react'
import { useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router'
import type { BrainAuditLog, PrincipalItem } from '../api/generated/types.gen'
import { ErrorBlock } from '../../common/error-block'
import { formatConsoleDate, formatJSON } from '../console-primitives'
import { LabeledField } from '../console-form'
import { SubNav } from '../console-list-page'

export function BrainTaskNavigation({ ownerUID, store }: { ownerUID: string; store?: string }) {
  const { t } = useTranslation()
  const search = brainSearch(ownerUID, store)
  return (
    <SubNav
      ariaLabel={t('console.brain.task_surfaces')}
      items={[
        { to: `/brain?${search}`, label: t('console.brain.entries_tab'), end: true },
        { to: `/brain/sources?${search}`, label: t('console.brain.sources_tab') },
        { to: `/brain/skill-experience?${brainSearch(ownerUID)}`, label: t('console.brain.experience_tab') },
        { to: `/brain/status?${brainSearch(ownerUID)}`, label: t('console.brain.status_tab') },
        { to: `/brain/audit?${search}`, label: t('console.brain.audit_tab') },
        { to: `/brain/dreaming?${brainSearch(ownerUID)}`, label: t('console.brain.dreaming_tab') }
      ]}
    />
  )
}

export function BrainOwnerField({
  ownerUID,
  principals,
  onChange
}: {
  ownerUID: string
  principals: PrincipalOption[]
  onChange: (value: string) => void
}) {
  const { t } = useTranslation()
  const options: PrincipalOption[] =
    ownerUID && !principals.some(principal => principal.uid === ownerUID)
      ? [{ uid: ownerUID }, ...principals]
      : principals

  return (
    <LabeledField label={t('console.brain.owner')}>
      <Select value={ownerUID} onValueChange={value => onChange(String(value))}>
        <SelectTrigger className="w-full">
          <SelectValue placeholder={t('console.brain.owner_placeholder')} />
        </SelectTrigger>
        <SelectContent emptyLabel={t('common.select_empty')}>
          {options.map(principal => (
            <SelectItem key={principal.uid} value={principal.uid}>
              {principal.display_name ? `${principal.display_name} · ${principal.uid}` : principal.uid}
              {principal.type ? <Badge variant="secondary">{principal.type}</Badge> : null}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </LabeledField>
  )
}

export function BrainStoreField({
  ownerUID,
  store,
  principals,
  allowAll = false,
  onChange
}: {
  ownerUID: string
  store: string
  principals: PrincipalOption[]
  allowAll?: boolean
  onChange: (value: string) => void
}) {
  const { t } = useTranslation()
  const peerOptions = principals.filter(principal => principal.uid !== ownerUID)
  const knownStores = new Set(['', 'shared', 'self', ...peerOptions.map(principal => `dm:${principal.uid}`)])
  const unknownStore = store && !knownStores.has(store) ? store : undefined

  return (
    <LabeledField label={t('console.brain.store')} description={t('console.brain.store_hint')}>
      <Select value={store || '__all__'} onValueChange={value => onChange(value === '__all__' ? '' : String(value))}>
        <SelectTrigger className="w-full">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {allowAll ? <SelectItem value="__all__">{t('console.brain.store_all')}</SelectItem> : null}
          <SelectItem value="shared">{t('console.brain.store_shared')}</SelectItem>
          <SelectItem value="self">{t('console.brain.store_self')}</SelectItem>
          {unknownStore ? <SelectItem value={unknownStore}>{unknownStore}</SelectItem> : null}
          {peerOptions.map(principal => (
            <SelectItem key={principal.uid} value={`dm:${principal.uid}`}>
              {t('console.brain.store_dm', {
                peer: principal.display_name ? `${principal.display_name} · ${principal.uid}` : principal.uid
              })}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </LabeledField>
  )
}

export function BrainStoreName({ store, principals }: { store: string; principals: PrincipalOption[] }) {
  const { t } = useTranslation()
  if (store === 'shared') return t('console.brain.store_shared')
  if (store === 'self') return t('console.brain.store_self')

  if (store.startsWith('dm:')) {
    const uid = store.slice(3)
    const principal = principals.find(option => option.uid === uid)
    const peer = principal?.display_name ? `${principal.display_name} · ${uid}` : uid
    return t('console.brain.store_dm', { peer })
  }

  return store
}

export function brainSearch(ownerUID: string, store?: string): string {
  const params = new URLSearchParams()
  if (ownerUID) params.set('owner', ownerUID)
  if (store) params.set('store', store)
  return params.toString()
}

type PrincipalOption = Pick<PrincipalItem, 'uid'> & Partial<Pick<PrincipalItem, 'type' | 'display_name'>>

/**
 * Pieces the Brain entry pages and the Brain audit pages both render.
 *
 * They used to sit in `brain.tsx` beside the entry pages, so the audit pages
 * imported a module twice their size to reach three helpers.
 */
export const RESTORABLE_AUDIT_ACTIONS = new Set([
  'create_entry',
  'delete_entry',
  'append_block',
  'edit_block',
  'delete_block',
  'set_property',
  'set_summary',
  'set_aliases',
  'set_name',
  'set_type',
  'add_relation',
  'remove_relation'
])

export type ActiveFilter = {
  id: string
  label: string
  value: string
  onRemove: () => void
}

export function FilterDisclosure({
  filters,
  onClear,
  children
}: {
  filters: ActiveFilter[]
  onClear?: () => void
  children: ReactNode
}) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)

  return (
    <Collapsible open={open} onOpenChange={setOpen} className="grid gap-3 border-t border-border pt-3">
      <div className="flex min-w-0 flex-wrap items-center justify-between gap-2">
        <div className="flex min-w-0 flex-wrap items-center gap-2">
          <CollapsibleTrigger className="group inline-flex h-10 items-center gap-2 px-2 text-sm font-medium outline-none hover:bg-muted focus-visible:ring-2 focus-visible:ring-ring/40">
            <RiFilter3Line aria-hidden />
            {t('console.brain.more_filters')}
            {filters.length > 0 ? <Badge variant="info">{filters.length}</Badge> : null}
            <RiArrowDownSLine
              aria-hidden
              className="transition-transform duration-200 group-aria-expanded:rotate-180 motion-reduce:transition-none"
            />
          </CollapsibleTrigger>
          {filters.map(filter => (
            <Badge
              key={filter.id}
              variant="secondary"
              render={
                <button
                  type="button"
                  aria-label={t('console.brain.remove_filter', { label: filter.label, value: filter.value })}
                  onClick={filter.onRemove}
                />
              }>
              <span className="truncate">
                {filter.label}: {filter.value}
              </span>
              <RiCloseLine aria-hidden />
            </Badge>
          ))}
        </div>
        {filters.length > 0 && onClear ? (
          <Button type="button" size="xs" variant="ghost" onClick={onClear}>
            {t('console.brain.clear_filters')}
          </Button>
        ) : null}
      </div>
      <CollapsibleContent>{children}</CollapsibleContent>
    </Collapsible>
  )
}

export function AuditTrail({
  rows,
  loading,
  error,
  restoring,
  onRestore,
  selectedIDs,
  onSelectedChange,
  entryHref
}: {
  rows: BrainAuditLog[]
  loading: boolean
  error: unknown
  restoring: boolean
  onRestore?: (auditID: string) => void
  selectedIDs?: Set<string>
  onSelectedChange?: (auditID: string, selected: boolean) => void
  entryHref?: (row: BrainAuditLog) => string | undefined
}) {
  const { t } = useTranslation()
  if (loading) return <Skeleton className="h-72 w-full" />
  if (error) return <ErrorBlock error={error} />
  if (rows.length === 0) return <p className="text-sm text-muted-foreground">{t('console.brain.no_audit')}</p>
  return (
    <div className="grid gap-3">
      {rows.map(row => {
        const restorable = RESTORABLE_AUDIT_ACTIONS.has(row.action)
        const href = entryHref?.(row)
        const runID = typeof row.metadata.run_id === 'string' ? row.metadata.run_id : undefined

        return (
          <Card key={row.id}>
            <CardHeader>
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div className="flex min-w-0 items-start gap-3">
                  {onSelectedChange && restorable ? (
                    <Checkbox
                      className="mt-1"
                      checked={selectedIDs?.has(row.id) ?? false}
                      aria-label={t('console.brain.select_audit', { action: row.action })}
                      onCheckedChange={checked => onSelectedChange(row.id, checked === true)}
                    />
                  ) : null}
                  <div className="min-w-0">
                    <CardTitle className="flex flex-wrap items-center gap-2">
                      <RiHistoryLine />
                      {row.action}
                    </CardTitle>
                    <CardDescription>
                      {row.store_key} · {row.actor_kind} · {row.actor_uid || '—'} · {formatConsoleDate(row.inserted_at)}
                    </CardDescription>
                    <div className="mt-1 flex flex-wrap gap-x-3 gap-y-1 font-mono text-xs text-muted-foreground">
                      <span>{row.id}</span>
                      {href && row.entry_id ? (
                        <Link to={href} className="text-link hover:underline">
                          {t('console.brain.audit_entry')}: {row.entry_id}
                        </Link>
                      ) : null}
                      {runID ? (
                        <span>
                          {t('console.brain.audit_run')}: {runID}
                        </span>
                      ) : null}
                    </div>
                  </div>
                </div>
                {restorable && onRestore ? (
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    disabled={restoring}
                    onClick={() => onRestore(row.id)}>
                    <RiRefreshLine />
                    {t('console.brain.restore')}
                  </Button>
                ) : null}
              </div>
            </CardHeader>
            <CardContent className="grid grid-cols-1 gap-3 md:grid-cols-2">
              <AuditSnapshot title={t('console.brain.before')} value={row.before} />
              <AuditSnapshot title={t('console.brain.after')} value={row.after} />
            </CardContent>
          </Card>
        )
      })}
    </div>
  )
}

function AuditSnapshot({ title, value }: { title: string; value?: Record<string, unknown> | null }) {
  const { t } = useTranslation()
  const fields = value ? Object.entries(value) : []
  return (
    <section className="grid min-w-0 gap-1">
      {/* Level follows the page's h2, not the visual size. It was an h4 under an
          h2, so a screen reader's outline reported a level that does not exist. */}
      <h3 className="text-xs font-medium text-muted-foreground">{title}</h3>
      {value ? (
        <div className="border border-border bg-card">
          <dl className="divide-y divide-border">
            {fields.map(([key, fieldValue]) => (
              <div key={key} className="grid grid-cols-1 gap-1 px-3 py-2 sm:grid-cols-[minmax(8rem,1fr)_2fr] sm:gap-3">
                <dt className="break-all font-mono text-xs text-muted-foreground">{key}</dt>
                <dd className="break-all text-xs">{auditValuePreview(fieldValue)}</dd>
              </div>
            ))}
          </dl>
          <details className="border-t border-border">
            <summary className="cursor-pointer px-3 py-2 text-xs font-medium text-muted-foreground hover:bg-muted">
              {t('console.brain.raw_json')}
            </summary>
            <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-all border-t border-border bg-muted p-3 text-xs">
              {formatJSON(value)}
            </pre>
          </details>
        </div>
      ) : (
        <div className="border border-border bg-muted p-3 text-xs text-muted-foreground">—</div>
      )}
    </section>
  )
}

function auditValuePreview(value: unknown): string {
  if (value === null) return 'null'
  if (typeof value === 'string') return value || '""'
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  if (Array.isArray(value)) return `[${value.length}] ${truncateText(JSON.stringify(value), 180)}`
  if (typeof value === 'object') return truncateText(JSON.stringify(value), 180)
  return String(value)
}

function truncateText(value: string, limit: number): string {
  return value.length <= limit ? value : `${value.slice(0, limit)}…`
}

export function localDateStartISO(value: string): string | undefined {
  if (!value) return undefined
  const date = new Date(`${value}T00:00:00`)
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString()
}

export function restorationAction(restoration: unknown): string | undefined {
  if (!restoration || typeof restoration !== 'object' || Array.isArray(restoration)) return undefined
  const action = (restoration as Record<string, unknown>).restored
  return typeof action === 'string' ? action : undefined
}
