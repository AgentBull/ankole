import {
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  TableCell,
  TableRow,
  toast
} from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router'
import { requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebAgentControllerIndexOptions,
  ankoleWebAgentSessionControllerIndexOptions,
  ankoleWebWebhookEndpointControllerDeleteMutation,
  ankoleWebWebhookEndpointControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { WebhookEndpointItem } from '../api/generated/types.gen'
import { ConfirmDeleteButton, LabeledField, StatusIndicator } from '../console-form'
import { formatConsoleDate } from '../console-primitives'
import { ResourceListPage } from '../console-list-page'
import { matchesResourceSearch } from '../state/resource-search'

export function WebhooksPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const [query, setQuery] = useState('')

  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const agentList = agents.data?.agents ?? []
  const agentUID = searchParams.get('agent') ?? agentList[0]?.uid ?? ''

  const sessions = useQuery({
    ...ankoleWebAgentSessionControllerIndexOptions({ path: { agent_uid: agentUID } }),
    enabled: Boolean(agentUID)
  })
  const sessionList = sessions.data?.sessions ?? []
  const sessionID = searchParams.get('session') ?? sessionList[0]?.session_id ?? ''
  const scopeReady = Boolean(agentUID && sessionID)

  const endpoints = useQuery({
    ...ankoleWebWebhookEndpointControllerIndexOptions({
      path: { agent_uid: agentUID, session_id: sessionID }
    }),
    enabled: scopeReady
  })

  const rows = (endpoints.data?.webhook_endpoints ?? []).filter(endpoint =>
    matchesResourceSearch(
      query,
      endpoint.label,
      endpoint.mode,
      endpoint.status,
      endpoint.binding_name,
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

  const selectAgent = (uid: string) => {
    setSearchParams(uid ? new URLSearchParams({ agent: uid }) : new URLSearchParams())
  }

  const selectSession = (session: string) => {
    const next = new URLSearchParams(searchParams)
    if (session) next.set('session', session)
    else next.delete('session')
    setSearchParams(next)
  }

  return (
    <ResourceListPage
      title={t('console.webhooks.title')}
      description={t('console.webhooks.description')}
      columns={[
        t('console.webhooks.label'),
        t('console.webhooks.route'),
        t('console.webhooks.mode'),
        t('console.webhooks.status'),
        t('console.webhooks.expires_at')
      ]}
      count={rows.length}
      emptyTitle={scopeReady ? t('console.webhooks.empty_title') : t('console.webhooks.select_scope_title')}
      emptyDescription={
        scopeReady ? t('console.webhooks.empty_description') : t('console.webhooks.select_scope_description')
      }
      error={endpoints.error}
      isEmpty={rows.length === 0}
      isFiltered={Boolean(query.trim())}
      isLoading={scopeReady && endpoints.isLoading}
      subNav={
        <WebhookScope
          agentUID={agentUID}
          agents={agentList}
          sessionID={sessionID}
          sessions={sessionList}
          onSelectAgent={selectAgent}
          onSelectSession={selectSession}
        />
      }
      toolbar={
        <Input
          aria-label={t('console.webhooks.search_placeholder')}
          className="max-w-sm"
          value={query}
          onChange={event => setQuery(event.target.value)}
          placeholder={t('console.webhooks.search_placeholder')}
        />
      }>
      {rows.map(endpoint => (
        <WebhookEndpointRow
          key={endpoint.id}
          endpoint={endpoint}
          cancelling={cancel.isPending}
          onCancel={() =>
            cancel.mutate({
              path: {
                agent_uid: agentUID,
                session_id: sessionID,
                webhook_endpoint_id: endpoint.id
              }
            })
          }
        />
      ))}
    </ResourceListPage>
  )
}

function WebhookScope({
  agentUID,
  agents,
  sessionID,
  sessions,
  onSelectAgent,
  onSelectSession
}: {
  agentUID: string
  agents: { uid: string }[]
  sessionID: string
  sessions: { session_id: string; title?: string | null }[]
  onSelectAgent: (uid: string) => void
  onSelectSession: (sessionID: string) => void
}) {
  const { t } = useTranslation()

  return (
    <div className="grid grid-cols-1 gap-3 border-b-0 md:grid-cols-2">
      <div className="border border-border bg-card p-3">
        <LabeledField label={t('console.webhooks.agent')}>
          <Select value={agentUID} onValueChange={value => onSelectAgent(String(value))}>
            <SelectTrigger className="w-full">
              <SelectValue placeholder={t('console.webhooks.select_agent')} />
            </SelectTrigger>
            <SelectContent>
              {agents.map(agent => (
                <SelectItem key={agent.uid} value={agent.uid}>
                  {agent.uid}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </LabeledField>
      </div>
      <div className="border border-border bg-card p-3">
        <LabeledField label={t('console.webhooks.session')}>
          <Select
            value={sessionID}
            onValueChange={value => onSelectSession(String(value))}
            disabled={!agentUID || sessions.length === 0}>
            <SelectTrigger className="w-full">
              <SelectValue placeholder={t('console.webhooks.select_session')} />
            </SelectTrigger>
            <SelectContent>
              {sessions.map(session => (
                <SelectItem key={session.session_id} value={session.session_id}>
                  <span className="font-mono text-xs">{session.session_id}</span>
                  {session.title ? (
                    <span className="ml-2 truncate text-muted-foreground">— {session.title}</span>
                  ) : null}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </LabeledField>
      </div>
    </div>
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
  const active = endpoint.status === 'armed' || endpoint.status === 'active'

  return (
    <TableRow>
      <TableCell>
        <div className="grid gap-1">
          <span className="font-medium">{endpoint.label}</span>
          <span className="font-mono text-xs text-muted-foreground">{formatConsoleDate(endpoint.created_at)}</span>
        </div>
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
        {active ? (
          <ConfirmDeleteButton
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
