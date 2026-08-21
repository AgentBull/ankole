import { LIST_REFRESH_MS } from '../refresh-intervals'
import { TableCell, TableRow, toast } from '@ankole/uikit'
import { RiCloseCircleLine, RiWebhookLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebWebhookEndpointControllerDeleteMutation,
  ankoleWebWebhookEndpointControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { WebhookEndpointItem } from '../api/generated/types.gen'
import { AgentFilter, useAgentScope } from '../console-agent-scope'
import { ConfirmDeleteButton, StatusIndicator } from '../console-form'
import { formatConsoleDate } from '../console-primitives'
import { AgentCell, FilterSwitch, ResourceListPage, ResourceSearch } from '../console-list-page'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'

/** A live endpoint can still receive a callback; the rest are history. */
function live(endpoint: WebhookEndpointItem): boolean {
  return endpoint.status === 'armed' || endpoint.status === 'active'
}

export function WebhooksPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const [includeFinished, setIncludeFinished] = useState(false)
  const scope = useAgentScope()

  const endpoints = useQuery({
    ...ankoleWebWebhookEndpointControllerIndexOptions({ query: { agent: scope.agentUID || undefined } }),
    refetchInterval: LIST_REFRESH_MS
  })

  const rows = (endpoints.data?.webhook_endpoints ?? [])
    .filter(endpoint => includeFinished || live(endpoint))
    .filter(endpoint =>
      matchesResourceSearch(
        searchQuery,
        endpoint.label,
        endpoint.mode,
        endpoint.status,
        endpoint.agent_uid,
        endpoint.binding_name,
        endpoint.session_id,
        endpoint.signal_channel_id
      )
    )

  const cancel = useMutation({
    ...ankoleWebWebhookEndpointControllerDeleteMutation(),
    onSuccess: () => {
      toast.success(t('console.webhooks.cancelled'))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <ResourceListPage
      title={t('console.webhooks.title')}
      description={t('console.webhooks.description')}
      columns={[
        t('console.webhooks.label'),
        t('console.agents.agent'),
        t('console.session'),
        t('console.webhooks.route'),
        t('console.webhooks.mode'),
        t('console.webhooks.status'),
        t('console.webhooks.expires_at')
      ]}
      count={rows.length}
      emptyTitle={t('console.webhooks.empty_title')}
      emptyIcon={<RiWebhookLine aria-hidden />}
      emptyDescription={t('console.webhooks.empty_description')}
      error={endpoints.error}
      isEmpty={rows.length === 0}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      isLoading={endpoints.isLoading}
      toolbarCanRevealRows
      toolbar={
        <ResourceSearch
          label={t('console.webhooks.search_placeholder')}
          value={query}
          onChange={setQuery}
          filters={
            <>
              <AgentFilter scope={scope} />
              <FilterSwitch
                checked={includeFinished}
                label={t('console.include_finished')}
                onChange={setIncludeFinished}
              />
            </>
          }
        />
      }>
      {rows.map(endpoint => (
        <WebhookEndpointRow
          key={`${endpoint.agent_uid}:${endpoint.id}`}
          endpoint={endpoint}
          cancelling={cancel.isPending}
          onCancel={() =>
            cancel.mutate({
              path: { agent_uid: endpoint.agent_uid, webhook_endpoint_id: endpoint.id }
            })
          }
        />
      ))}
    </ResourceListPage>
  )
}

function WebhookEndpointRow({
  endpoint,
  cancelling,
  onCancel
}: {
  endpoint: WebhookEndpointItem
  cancelling: boolean
  onCancel: () => void
}) {
  const { t } = useTranslation()

  return (
    <TableRow>
      <TableCell>
        <div className="grid gap-1">
          <span className="font-medium">{endpoint.label}</span>
          <span className="font-mono text-xs text-muted-foreground">{formatConsoleDate(endpoint.created_at)}</span>
        </div>
      </TableCell>
      <AgentCell uid={endpoint.agent_uid} />
      <TableCell>
        <span className="block max-w-56 truncate font-mono text-xs" title={endpoint.session_id}>
          {endpoint.session_id}
        </span>
      </TableCell>
      <TableCell>
        <div className="grid gap-1 font-mono text-xs">
          <span>{endpoint.binding_name}</span>
          <span className="max-w-72 truncate text-muted-foreground">{endpoint.signal_channel_id ?? '—'}</span>
        </div>
      </TableCell>
      <TableCell>{t(`console.webhooks.mode_${endpoint.mode}`)}</TableCell>
      <TableCell>
        <StatusIndicator tone={webhookStatusTone(endpoint.status)}>
          {t(`console.webhooks.status_${endpoint.status}`)}
        </StatusIndicator>
      </TableCell>
      <TableCell>{formatConsoleDate(endpoint.expires_at)}</TableCell>
      <TableCell className="text-right">
        {live(endpoint) ? (
          <ConfirmDeleteButton
            icon={<RiCloseCircleLine />}
            pending={cancelling}
            confirm={{
              title: t('console.webhooks.cancel_title'),
              description: t('console.webhooks.cancel_description', { label: endpoint.label }),
              confirmLabel: t('console.webhooks.cancel')
            }}
            onConfirm={onCancel}
          />
        ) : null}
      </TableCell>
    </TableRow>
  )
}

function webhookStatusTone(
  status: WebhookEndpointItem['status']
): 'danger' | 'info' | 'neutral' | 'positive' | 'warning' {
  switch (status) {
    case 'armed':
    case 'active':
      return 'positive'
    case 'fired':
      return 'info'
    case 'expired':
      return 'warning'
    case 'cancelled':
      return 'neutral'
  }
}
