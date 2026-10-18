import { LIST_REFRESH_MS } from '../refresh-intervals'
import {
  Button,
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Input,
  TableCell,
  TableRow,
  toast
} from '@ankole/uikit'
import { RiCloseCircleLine, RiWebhookLine } from '@remixicon/react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useDeferredValue, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebWebhookEndpointControllerCancelMutation,
  ankoleWebWebhookEndpointControllerCreateMutation,
  ankoleWebWebhookEndpointControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { WebhookEndpointItem } from '../api/generated/types.gen'
import { AgentFilter, useAgentScope } from '../console-agent-scope'
import { ConfirmDeleteButton, StatusIndicator, type StatusTone } from '../console-form'
import { formatConsoleDate } from '../console-primitives'
import { AgentCell, FilterSwitch, ResourceListPage, ResourceSearch } from '../console-list-page'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'

/** A live endpoint can still receive a callback; the rest are history. */
function live(endpoint: WebhookEndpointItem): boolean {
  return endpoint.status === 'armed' || endpoint.status === 'active'
}

export function WebhooksPage() {
  const { t } = useTranslation()
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const [includeFinished, setIncludeFinished] = useState(false)
  const scope = useAgentScope()

  // Keep the one-time result mounted when the list moves its create button.
  const [open, setOpen] = useState(false)
  const [label, setLabel] = useState('')
  const [expiresAt, setExpiresAt] = useState('')
  const create = useMutation({
    ...ankoleWebWebhookEndpointControllerCreateMutation(),
    onSuccess: () => scope.selectAgent(''),
    onError: error => toast.error(requestErrorMessage(error))
  })
  const created = create.data
  const url = created ? `${window.location.origin}/signals/v1/cloudevents/${created.token}` : ''

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
        endpoint.conversation_id
      )
    )

  const cancel = useMutation({
    ...ankoleWebWebhookEndpointControllerCancelMutation(),
    onSuccess: () => {
      toast.success(t('console.webhooks.cancelled'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <>
      <ResourceListPage
        title={t('console.webhooks.title')}
        description={t('console.webhooks.description')}
        createAction={
          <Button
            type="button"
            onClick={() => {
              create.reset()
              setOpen(true)
            }}>
            {t('console.webhooks.create')}
          </Button>
        }
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
        isFiltered={Boolean(query.trim()) || Boolean(scope.agentUID)}
        onClearFilters={() => {
          setQuery('')
          scope.selectAgent('')
        }}
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
                path: { webhook_endpoint_id: endpoint.id }
              })
            }
          />
        ))}
      </ResourceListPage>
      <Dialog
        open={open}
        onOpenChange={next => {
          setOpen(next)
          if (!next) create.reset()
        }}>
        <DialogContent closeLabel={t('common.close')}>
          <DialogHeader>
            <DialogTitle>{t('console.webhooks.create')}</DialogTitle>
            <DialogDescription>
              {t(created ? 'console.webhooks.created_url_description' : 'console.webhooks.create_description')}
            </DialogDescription>
          </DialogHeader>
          {created ? (
            <div className="grid gap-4">
              <label className="grid gap-2">
                {t('console.webhooks.endpoint_id')}
                <Input readOnly value={created.webhook_endpoint.id} />
              </label>
              <label className="grid gap-2">
                {t('console.webhooks.created_url')}
                <Input readOnly value={url} />
              </label>
              <Button
                type="button"
                variant="outline"
                onClick={() =>
                  navigator.clipboard.writeText(url).catch(error => toast.error(requestErrorMessage(error)))
                }>
                {t('common.copy')}
              </Button>
              <DialogFooter>
                <DialogClose render={<Button />}>{t('common.close')}</DialogClose>
              </DialogFooter>
            </div>
          ) : (
            <form
              className="grid gap-4"
              onSubmit={event => {
                event.preventDefault()
                create.mutate({ body: { label, expires_at: new Date(expiresAt).toISOString() } })
              }}>
              <label className="grid gap-2">
                {t('console.webhooks.label')}
                <Input required value={label} onChange={event => setLabel(event.target.value)} />
              </label>
              <label className="grid gap-2">
                {t('console.webhooks.expires_at')}
                <Input
                  required
                  type="datetime-local"
                  value={expiresAt}
                  onChange={event => setExpiresAt(event.target.value)}
                />
              </label>
              <DialogFooter>
                <DialogClose render={<Button type="button" variant="ghost" />}>{t('common.cancel')}</DialogClose>
                <Button type="submit" disabled={create.isPending}>
                  {t('console.webhooks.create')}
                </Button>
              </DialogFooter>
            </form>
          )}
        </DialogContent>
      </Dialog>
    </>
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
      {endpoint.agent_uid ? <AgentCell uid={endpoint.agent_uid} /> : <TableCell>—</TableCell>}
      <TableCell>
        <span className="block max-w-56 truncate font-mono text-xs" title={endpoint.session_id ?? undefined}>
          {endpoint.session_id}
        </span>
      </TableCell>
      <TableCell>
        <div className="grid gap-1 font-mono text-xs">
          <span>{endpoint.binding_name ?? (endpoint.event_format === 'cloudevents' ? 'CloudEvents' : '—')}</span>
          <span>{endpoint.id}</span>
          <span className="max-w-72 truncate text-muted-foreground">{endpoint.conversation_id ?? '—'}</span>
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

function webhookStatusTone(status: WebhookEndpointItem['status']): StatusTone {
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
