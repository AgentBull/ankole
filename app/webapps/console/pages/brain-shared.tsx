import { Badge, Select, SelectContent, SelectItem, SelectTrigger, SelectValue, cn } from '@ankole/uikit'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router'
import type { PrincipalItem } from '../api/generated/types.gen'
import { formatConsoleDate } from '../console-primitives'
import { LabeledField } from '../console-shell'

export type BrainTask = 'entries' | 'sources' | 'experience' | 'status' | 'audit' | 'dreaming'

export function BrainTaskNavigation({
  active,
  ownerUID,
  store
}: {
  active: BrainTask
  ownerUID: string
  store?: string
}) {
  const { t } = useTranslation()
  const search = brainSearch(ownerUID, store)
  const items: Array<{ id: BrainTask; label: string; to: string }> = [
    { id: 'entries', label: t('console.brain.entries_tab'), to: `/brain?${search}` },
    { id: 'sources', label: t('console.brain.sources_tab'), to: `/brain/sources?${search}` },
    {
      id: 'experience',
      label: t('console.brain.experience_tab'),
      to: `/brain/skill-experience?${brainSearch(ownerUID)}`
    },
    { id: 'status', label: t('console.brain.status_tab'), to: `/brain/status?${brainSearch(ownerUID)}` },
    { id: 'audit', label: t('console.brain.audit_tab'), to: `/brain/audit?${search}` },
    { id: 'dreaming', label: t('console.brain.dreaming_tab'), to: `/brain/dreaming?${brainSearch(ownerUID)}` }
  ]

  return (
    <nav aria-label={t('console.brain.task_surfaces')} className="overflow-x-auto border-b border-border">
      <div className="flex min-w-max">
        {items.map(item => (
          <Link
            key={item.id}
            to={item.to}
            aria-current={item.id === active ? 'page' : undefined}
            className={cn(
              'border-b-2 px-4 py-3 text-sm font-medium transition-colors hover:bg-muted hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/40',
              item.id === active
                ? 'border-primary bg-muted/50 text-foreground'
                : 'border-transparent text-muted-foreground'
            )}>
            {item.label}
          </Link>
        ))}
      </div>
    </nav>
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
        <SelectTrigger className="w-full" disabled={options.length === 0}>
          <SelectValue placeholder={t('console.brain.owner_placeholder')} />
        </SelectTrigger>
        <SelectContent>
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

// Thin alias over the shared console date formatter; kept so existing brain
// call sites read as brain-local without changing their imports.
export function formatBrainDate(value?: string | null): string {
  return formatConsoleDate(value)
}

type PrincipalOption = Pick<PrincipalItem, 'uid'> & Partial<Pick<PrincipalItem, 'type' | 'display_name'>>
