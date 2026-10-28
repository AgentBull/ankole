import { TableRow, useMutation, useQuery } from '../tenant-context'
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
  toast
} from '@ankole/uikit'
import { RiCheckLine, RiCloseCircleLine, RiFileCopyLine, RiWebhookLine } from '@remixicon/react'

import { useDeferredValue, useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { requestErrorMessage } from '../../common/request-errors'
import { fromDocument } from '../api/json-api'
import {
  cancelWebhookEndpointMutation,
  createWebhookEndpointMutation,
  listWebhookEndpointsOptions
} from '../api/v2/generated/@tanstack/react-query.gen'
import { AgentFilter, useAgentScope } from '../console-agent-scope'
import {
  ConfirmDeleteButton,
  DiscardConfirmDialog,
  LabeledField,
  StatusIndicator,
  useDialogDiscardGuard,
  type StatusTone
} from '../console-form'
import { formatConsoleDate } from '../console-primitives'
import { AgentCell, FilterSwitch, ResourceListPage, ResourceSearch } from '../console-list-page'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'
import { instantFromDateTimeLocal } from '../state/token-quota-editor-model'

type WebhookEndpointItem = {
  id: string
  agent_uid: string | null
  binding_name: string | null
  session_id: string | null
  conversation_id: string | null
  event_format: string
  label: string
  mode: string
  status: 'armed' | 'fired' | 'active' | 'cancelled' | 'expired'
  expires_at: string
  source_provenance: Record<string, unknown>
  inserted_at: string
  updated_at: string
}

/** The list of webhook endpoints, also read by the route loader. */
export function webhookEndpointListOptions(agentUID: string | undefined) {
  return listWebhookEndpointsOptions({ query: { agent: agentUID || undefined, page: { limit: 100 } } })
}

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
  const [labelError, setLabelError] = useState<string>()
  const [expiresAtError, setExpiresAtError] = useState<string>()
  const [copied, setCopied] = useState(false)
  const copyTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(
    () => () => {
      if (copyTimerRef.current !== null) clearTimeout(copyTimerRef.current)
    },
    []
  )

  const create = useMutation({
    ...createWebhookEndpointMutation(),
    onSuccess: () => scope.selectAgent(''),
    onError: error => toast.error(requestErrorMessage(error))
  })
  const created = create.data
  const url = created ? `${window.location.origin}/signals/v1/cloudevents/${created.token}` : ''

  const resetDialog = () => {
    setLabel('')
    setExpiresAt('')
    setLabelError(undefined)
    setExpiresAtError(undefined)
    setCopied(false)
    if (copyTimerRef.current !== null) {
      clearTimeout(copyTimerRef.current)
      copyTimerRef.current = null
    }
    create.reset()
  }

  const handleOpenChange = (next: boolean) => {
    setOpen(next)
    if (!next) resetDialog()
  }

  const discardGuard = useDialogDiscardGuard({
    dirty: open && !created && Boolean(label.trim() || expiresAt.trim()),
    onOpenChange: handleOpenChange,
    pending: create.isPending
  })

  const endpoints = useQuery({
    ...webhookEndpointListOptions(scope.agentUID),
    select: document => fromDocument(document) as WebhookEndpointItem[],
    refetchInterval: LIST_REFRESH_MS
  })

  const rows = (endpoints.data ?? [])
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
    ...cancelWebhookEndpointMutation(),
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
              resetDialog()
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
            label={t('console.webhooks.search', { defaultValue: 'Search webhooks' })}
            placeholder={t('console.webhooks.search_placeholder')}
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
                path: { id: endpoint.id }
              })
            }
          />
        ))}
      </ResourceListPage>
      <Dialog open={open} onOpenChange={discardGuard.requestOpenChange}>
        <DialogContent closeLabel={t('common.close')}>
          <DialogHeader>
            <DialogTitle>{t('console.webhooks.create')}</DialogTitle>
            <DialogDescription>
              {t(created ? 'console.webhooks.created_url_description' : 'console.webhooks.create_description')}
            </DialogDescription>
          </DialogHeader>
          {created ? (
            <div className="grid gap-4">
              <LabeledField label={t('console.webhooks.endpoint_id')}>
                <Input readOnly value={String(created.webhook_endpoint.id)} />
              </LabeledField>
              <LabeledField label={t('console.webhooks.created_url')}>
                <Input readOnly value={url} />
              </LabeledField>
              <Button
                type="button"
                variant="outline"
                onClick={() =>
                  navigator.clipboard
                    .writeText(url)
                    .then(() => {
                      setCopied(true)
                      if (copyTimerRef.current !== null) clearTimeout(copyTimerRef.current)
                      copyTimerRef.current = setTimeout(() => {
                        setCopied(false)
                        copyTimerRef.current = null
                      }, 2000)
                      toast.success(t('console.webhooks.url_copied', { defaultValue: 'Capability URL copied.' }))
                    })
                    .catch(error => toast.error(requestErrorMessage(error)))
                }>
                {copied ? <RiCheckLine data-icon="inline-start" /> : <RiFileCopyLine data-icon="inline-start" />}
                {copied ? t('common.copied', { defaultValue: 'Copied' }) : t('common.copy', { defaultValue: 'Copy' })}
              </Button>
              <DialogFooter>
                <DialogClose render={<Button />}>{t('common.close')}</DialogClose>
              </DialogFooter>
            </div>
          ) : (
            <form
              className="grid gap-4"
              noValidate
              onInvalidCapture={event => event.preventDefault()}
              onSubmit={event => {
                event.preventDefault()
                const trimmedLabel = label.trim()
                const nextLabelError = trimmedLabel
                  ? undefined
                  : t('common.field_required', { field: t('console.webhooks.label') })
                const trimmedExpires = expiresAt.trim()
                const parsedInstant = trimmedExpires ? instantFromDateTimeLocal(trimmedExpires) : undefined
                const nextExpiresError = !trimmedExpires
                  ? t('common.field_required', { field: t('console.webhooks.expires_at') })
                  : parsedInstant
                    ? undefined
                    : t('common.field_invalid', { field: t('console.webhooks.expires_at') })
                setLabelError(nextLabelError)
                setExpiresAtError(nextExpiresError)
                if (nextLabelError || nextExpiresError || !parsedInstant) return
                create.mutate({ body: { data: { label: trimmedLabel, expires_at: parsedInstant } } })
              }}>
              <LabeledField label={t('console.webhooks.label')} required error={labelError}>
                <Input
                  value={label}
                  onChange={event => {
                    setLabel(event.target.value)
                    if (labelError) setLabelError(undefined)
                  }}
                />
              </LabeledField>
              <LabeledField label={t('console.webhooks.expires_at')} required error={expiresAtError}>
                <Input
                  type="datetime-local"
                  value={expiresAt}
                  onChange={event => {
                    setExpiresAt(event.target.value)
                    if (expiresAtError) setExpiresAtError(undefined)
                  }}
                />
              </LabeledField>
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
      <DiscardConfirmDialog
        open={discardGuard.confirming}
        onDiscard={discardGuard.confirmDiscard}
        onKeep={discardGuard.keepEditing}
      />
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
          <span className="font-mono text-xs text-muted-foreground">{formatConsoleDate(endpoint.inserted_at)}</span>
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
