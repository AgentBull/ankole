import { useQuery, useInfiniteQuery, useConsoleTenant } from '../../tenant-context'
import { Button, Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@ankole/uikit'
import { useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { dataTenantID } from '../../../common/browser-session'
import { listDriveNodesInfiniteOptions, showBrainObjectOptions } from '../../api/v2/generated/@tanstack/react-query.gen'
import { ErrorBlock } from '../../../common/error-block'

/** Resolves a canonical page ID or readable identity path to its Pod source. */
export function BrainPageLink({ pageID, children }: { pageID?: string | null; children?: ReactNode }) {
  const page = useQuery({
    ...showBrainObjectOptions({ query: { slug: pageID ?? '' } }),
    enabled: Boolean(pageID),
    retry: false
  })
  const label = children ?? page.data?.object?.title ?? pageID ?? '—'
  return page.data?.object ? (
    <a className="link text-xs" href={page.data.object.pod_url}>
      {label}
    </a>
  ) : (
    <span className="text-xs">{label}</span>
  )
}

export function BrainHolderLabel({ holder }: { holder?: string | null }) {
  return <BrainPageLink pageID={holder} />
}

export function BrainSourceLabel({ nodeID }: { nodeID?: string | null }) {
  return <span className="font-mono text-xs">{nodeID ?? '—'}</span>
}

/** Chooses an existing Drive node whose current readers receive source facts. */
export function BrainSourceSelector({
  ariaLabel,
  unsetLabel,
  value,
  onChange
}: {
  ariaLabel?: string
  unsetLabel: string
  value: string
  onChange: (value: string) => void
}) {
  const { t } = useTranslation()
  const tenant = useConsoleTenant()
  const tenantID = tenant?.id ?? dataTenantID() ?? ''
  const [parentID, setParentID] = useState<string>()
  const nodes = useInfiniteQuery({
    ...listDriveNodesInfiniteOptions({
      path: { tenant_id: tenantID },
      query: { ...(parentID ? { parent_id: parentID } : {}), limit: 100 }
    }),
    initialPageParam: { path: { tenant_id: tenantID } },
    getNextPageParam: page =>
      page.next_after ? { path: { tenant_id: tenantID }, query: { after: page.next_after } } : undefined,
    enabled: Boolean(tenantID)
  })
  const rows = nodes.data?.pages.flatMap(page => page.nodes) ?? []
  const ancestors = nodes.data?.pages[0]?.ancestors ?? []
  return (
    <div className="grid gap-2">
      <Select
        value={value || '__default__'}
        onValueChange={id => typeof id === 'string' && onChange(id === '__default__' ? '' : id)}>
        <SelectTrigger aria-label={ariaLabel}>
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="__default__">{unsetLabel}</SelectItem>
          {value && !rows.some(node => node.id === value) ? <SelectItem value={value}>{value}</SelectItem> : null}
          {rows.map(node => (
            <SelectItem key={node.id} value={node.id}>
              {node.name}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      <nav aria-label={ariaLabel} className="flex flex-wrap gap-1">
        <Button type="button" size="xs" variant="ghost" onClick={() => setParentID(undefined)}>
          {t('console.drive.title')}
        </Button>
        {ancestors.map(node => (
          <Button key={node.id} size="xs" variant="ghost" onClick={() => setParentID(node.id)}>
            {node.name}
          </Button>
        ))}
      </nav>
      <ul className="grid gap-1">
        {rows
          .filter(node => node.kind !== 'file')
          .map(node => (
            <li key={node.id}>
              <Button type="button" size="xs" variant="ghost" onClick={() => setParentID(node.id)}>
                {node.name} /
              </Button>
            </li>
          ))}
      </ul>
      {nodes.hasNextPage ? (
        <Button
          type="button"
          size="xs"
          variant="outline"
          disabled={nodes.isFetchingNextPage}
          onClick={() => nodes.fetchNextPage()}>
          {t('common.load_more')}
        </Button>
      ) : null}
      <ErrorBlock error={nodes.error} />
    </div>
  )
}
