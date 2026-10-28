import { TableRow, useQuery, Link } from '../tenant-context'
import { SETTLED_WORKERS_REFRESH_MS, WAITING_REFRESH_MS } from '../refresh-intervals'
import { TableCell } from '@ankole/uikit'
import { RiServerLine } from '@remixicon/react'

import { useDeferredValue, useState } from 'react'
import { useTranslation } from 'react-i18next'

import { type AgentWorkerItem, agentWorkerListOptions } from '../api/agent-workers'
import { agentListOptions } from '../api/agents'
import { StatusIndicator, type StatusTone } from '../console-form'
import { AgentCell, ResourceListPage, ResourceSearch } from '../console-list-page'
import { formatConsoleDate } from '../console-primitives'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'

/**
 * The Worker of each Agent. The control plane creates, stops, and replaces
 * Workers by itself, so this page only shows their state and the latest reason
 * from the backend.
 */
export function WorkersListPage() {
  const { t } = useTranslation()
  const workers = useQuery({
    ...agentWorkerListOptions(),
    refetchInterval: query =>
      (query.state.data?.data ?? []).some(
        ({ attributes }) => attributes?.state === 'starting' || attributes?.state === 'draining'
      )
        ? WAITING_REFRESH_MS
        : SETTLED_WORKERS_REFRESH_MS
  })
  const agents = useQuery(agentListOptions())
  const agentByUID = new Map((agents.data ?? []).map(agent => [agent.uid, agent]))
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const rows = (workers.data ?? []).filter(worker => {
    const agent = agentByUID.get(worker.agent_uid)
    return matchesResourceSearch(
      searchQuery,
      worker.agent_uid,
      agent?.display_name ?? '',
      agent?.handle ?? '',
      worker.provider_id ?? '',
      worker.state,
      reason(worker)
    )
  })

  return (
    <ResourceListPage
      title={t('console.workers.title')}
      description={t('console.workers.description')}
      columns={[
        t('console.workers.agent'),
        t('console.worker_providers.provider'),
        t('console.workers.state'),
        t('console.workers.load'),
        t('console.workers.last_heartbeat'),
        t('console.workers.reason')
      ]}
      isLoading={workers.isLoading}
      isEmpty={rows.length === 0}
      count={rows.length}
      emptyTitle={t('console.workers.empty_title')}
      emptyIcon={<RiServerLine aria-hidden />}
      emptyDescription={t('console.workers.empty_description')}
      error={workers.error}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      toolbar={
        <ResourceSearch
          label={t('console.workers.search')}
          placeholder={t('console.workers.search_placeholder')}
          value={query}
          onChange={setQuery}
        />
      }>
      {rows.map(worker => (
        <TableRow key={worker.agent_uid}>
          <AgentCell uid={worker.agent_uid} />
          <TableCell className="font-mono text-xs">
            {worker.provider_id ? (
              <Link className="link" to={`/worker-providers/${encodeURIComponent(worker.provider_id)}`}>
                {worker.provider_id}
              </Link>
            ) : (
              '–'
            )}
          </TableCell>
          <TableCell>
            <StatusIndicator tone={stateTone(worker)}>{t(`console.status.${worker.state}`)}</StatusIndicator>
          </TableCell>
          <TableCell>{formatLoad(worker)}</TableCell>
          <TableCell className="text-xs text-muted-foreground">
            {formatConsoleDate(worker.last_worker_heartbeat_at)}
          </TableCell>
          <TableCell className="max-w-md truncate font-mono text-xs text-muted-foreground" title={reason(worker)}>
            {reason(worker) || '–'}
          </TableCell>
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

/** A Worker that is not ready and has a backend reason needs the operator. */
export function workerNeedsAttention(worker: AgentWorkerItem): boolean {
  return (worker.state === 'starting' || worker.state === 'stale') && Boolean(worker.last_error)
}

function stateTone(worker: AgentWorkerItem): StatusTone {
  if (workerNeedsAttention(worker)) return 'danger'
  if (worker.state === 'ready') return 'positive'
  if (worker.state === 'stale') return 'warning'
  return 'info'
}

function reason(worker: AgentWorkerItem): string {
  return worker.last_error ?? worker.drain_reason ?? ''
}

/**
 * Active turns over total turn slots, in the used-over-total order capacity
 * columns are read in. A worker that reports only capacity derives its active
 * count from the free slots.
 */
function formatLoad(worker: AgentWorkerItem): string {
  const max = integerField(worker.capacity, 'max_slots')
  const available = integerField(worker.capacity, 'available_slots')
  const active =
    integerField(worker.load, 'active_slots') ??
    (max !== undefined && available !== undefined ? Math.max(max - available, 0) : undefined)
  if (active === undefined) return '–'
  return max === undefined ? String(active) : `${active} / ${max}`
}

function integerField(map: { [key: string]: unknown } | undefined, key: string): number | undefined {
  if (!map) return undefined
  const value = map[key]
  return typeof value === 'number' ? value : undefined
}
