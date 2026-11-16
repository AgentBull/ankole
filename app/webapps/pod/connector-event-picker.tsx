import { Input, Label, Select, SelectContent, SelectItem, SelectTrigger, SelectValue, Skeleton } from '@ankole/uikit'
import { useQuery } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useId, useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import * as api from './api/generated/sdk.gen'
import { ContentError } from './content-primitives'
import {
  connectorFailureMessage,
  connectorKeys,
  connectorReturnTo,
  type ConnectorAutomationContext
} from './state/connectors'

export type ConnectorEventOrigin = {
  reference: string
  label: string
  connectionStatus: string
  status: string
  subscription: boolean
  eventTypes: string[]
  lastError: Record<string, unknown> | null | undefined
  manageURL: string
}

export type CoalescePayload = {
  enabled: true
  window_ms: number
  max_batch_size: number
}

export function eventTypeFilterExpression(eventType: string): string | undefined {
  return eventType ? `signal.type == ${JSON.stringify(eventType)}` : undefined
}

export function describeBindingFilter(
  filters: Record<string, unknown>,
  eventTypes: string[],
  anyEventLabel: string
): string {
  if (Object.keys(filters).length === 0) return anyEventLabel
  const matched = eventTypes.find(type => filters.cel === `signal.type == ${JSON.stringify(type)}`)
  return matched ?? JSON.stringify(filters)
}

export function parseCoalesceSettings(coalesce?: Record<string, unknown> | null): {
  windowSec: number
  maxBatch: number
} {
  const rawWindowMs = typeof coalesce?.window_ms === 'number' ? coalesce.window_ms : 5_000
  const rawMaxBatch = typeof coalesce?.max_batch_size === 'number' ? coalesce.max_batch_size : 20
  return {
    windowSec: Math.max(0, Math.min(300, Math.round(rawWindowMs / 1000))),
    maxBatch: Math.max(1, Math.min(100, Math.round(rawMaxBatch)))
  }
}

export function isValidCoalesceInput(windowSecText: string, maxBatchText: string): boolean {
  if (windowSecText.trim() === '' || maxBatchText.trim() === '') return false
  const parsedWindowSec = Number(windowSecText)
  const parsedMaxBatch = Number(maxBatchText)
  return (
    Number.isFinite(parsedWindowSec) &&
    parsedWindowSec >= 0 &&
    parsedWindowSec <= 300 &&
    Number.isInteger(parsedMaxBatch) &&
    parsedMaxBatch >= 1 &&
    parsedMaxBatch <= 100
  )
}

export function buildCoalescePayload(windowSecText: string, maxBatchText: string): CoalescePayload {
  return {
    enabled: true,
    window_ms: Math.round(Number(windowSecText) * 1000),
    max_batch_size: Number(maxBatchText)
  }
}

export function coalesceMatchesBinding(
  stored: Record<string, unknown> | null | undefined,
  draft: CoalescePayload
): boolean {
  if (!stored || stored.enabled === false) return false
  const parsed = parseCoalesceSettings(stored)
  return parsed.windowSec * 1000 === draft.window_ms && parsed.maxBatch === draft.max_batch_size
}

export function useConnectorEventSources({
  enabled = true,
  pollIntervalMs = false,
  automation
}: {
  enabled?: boolean
  pollIntervalMs?: number | false
  automation?: ConnectorAutomationContext
} = {}) {
  const catalog = useQuery({
    queryKey: connectorKeys.catalog,
    queryFn: ({ signal }) => api.podConnectorsCatalog({ signal }),
    enabled
  })
  const triggers = useQuery({
    queryKey: connectorKeys.triggers,
    queryFn: ({ signal }) => api.podConnectorTriggersList({ signal }),
    enabled,
    refetchInterval: pollIntervalMs
  })
  const connections = useQuery({
    queryKey: connectorKeys.connections,
    queryFn: ({ signal }) => api.podConnectorAuthConfigsList({ signal }),
    enabled,
    refetchInterval: pollIntervalMs
  })

  const origins = useMemo<ConnectorEventOrigin[]>(() => {
    const visibleConnections = connections.data?.connections ?? []
    const items: ConnectorEventOrigin[] = (triggers.data?.triggers ?? []).flatMap(item => {
      const connection = visibleConnections.find(value => value.id === item.auth_config_id)
      const definition = catalog.data?.connectors
        ?.find(value => value.plugin_id === connection?.plugin_id)
        ?.trigger_types?.find(value => value.id === item.trigger_type)
      return connection && item.status !== 'deleting'
        ? [
            {
              reference: item.config_ref,
              label: `${connection.display_name} · ${definition?.label ?? item.trigger_type} · ${item.scope_key}`,
              connectionStatus: connection.status,
              status: item.status,
              subscription: true,
              eventTypes: [],
              lastError: item.last_error,
              manageURL: connectorReturnTo({
                connection: connection.slug,
                trigger: { type: item.trigger_type, scope: item.scope_key, id: item.id },
                ...(automation ? { automation } : {})
              })
            }
          ]
        : []
    })

    if (catalog.data?.can_manage) {
      for (const connection of visibleConnections) {
        const declaration = catalog.data.connectors?.find(item => item.plugin_id === connection.plugin_id)
        for (const stream of declaration?.event_streams ?? []) {
          items.push({
            reference: `connector://${connection.id}/${stream.id}`,
            label: `${connection.display_name} · ${stream.label}`,
            connectionStatus: connection.status,
            status: connection.status,
            subscription: false,
            eventTypes: stream.event_types,
            lastError: null,
            manageURL: connectorReturnTo({
              connection: connection.slug,
              ...(automation ? { automation } : {})
            })
          })
        }
      }
    }

    return items
  }, [automation, catalog.data, connections.data?.connections, triggers.data?.triggers])

  const choices = useMemo(() => origins.filter(item => item.connectionStatus === 'active'), [origins])

  return {
    catalog,
    triggers,
    connections,
    origins,
    choices,
    isPending: catalog.isPending || triggers.isPending || connections.isPending,
    error: catalog.error ?? triggers.error ?? connections.error
  }
}

export function ConnectorEventSourceFields({
  sources,
  selectedRef,
  onSelectRef,
  eventType,
  onSelectEventType,
  coalesceWindowSec,
  onCoalesceWindowSecChange,
  coalesceMaxBatch,
  onCoalesceMaxBatchChange,
  disabled = false,
  openConnectorsURL = '/connectors'
}: {
  sources: ReturnType<typeof useConnectorEventSources>
  selectedRef: string
  onSelectRef: (ref: string) => void
  eventType: string
  onSelectEventType: (eventType: string) => void
  coalesceWindowSec: string
  onCoalesceWindowSecChange: (next: string) => void
  coalesceMaxBatch: string
  onCoalesceMaxBatchChange: (next: string) => void
  disabled?: boolean
  openConnectorsURL?: string
}) {
  const { t } = useTranslation()
  const sourceLabelId = useId()
  const eventTypeLabelId = useId()
  const windowInputId = useId()
  const maxBatchInputId = useId()

  const activeSource = selectedRef ? sources.choices.find(item => item.reference === selectedRef) : sources.choices[0]
  const resolvedEventType = activeSource?.eventTypes.includes(eventType) ? eventType : ''

  if (sources.error) {
    return <ContentError error={sources.error} />
  }

  if (sources.isPending) {
    return (
      <div className="grid gap-2">
        <Skeleton className="h-4 w-32" />
        <Skeleton className="h-9 w-full" />
      </div>
    )
  }

  if (sources.choices.length === 0) {
    return (
      <div className="grid gap-1.5 text-xs text-fg-secondary">
        <p>{t('pod.automation.no_events')}</p>
        <Link
          className="justify-self-start font-medium text-fg-primary underline underline-offset-4"
          to={openConnectorsURL}>
          {t('pod.automation.open_connectors')}
        </Link>
      </div>
    )
  }

  return (
    <div className="grid gap-3">
      <div className="grid gap-1.5">
        <div className="flex items-center justify-between gap-2">
          <Label id={sourceLabelId}>{t('pod.automation.event_source')}</Label>
          <Link className="text-xs text-fg-secondary underline underline-offset-4" to={openConnectorsURL}>
            {t('pod.automation.open_connectors')}
          </Link>
        </div>
        <Select
          loading={sources.isPending}
          value={activeSource?.reference ?? ''}
          disabled={disabled}
          onValueChange={value => {
            if (!value) return
            onSelectRef(value)
            onSelectEventType('')
          }}>
          <SelectTrigger aria-labelledby={sourceLabelId} className="w-full">
            <SelectValue placeholder={t('pod.automation.event_source')} />
          </SelectTrigger>
          <SelectContent>
            {sources.choices.map(choice => (
              <SelectItem key={choice.reference} value={choice.reference}>
                {choice.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      {activeSource && activeSource.eventTypes.length > 0 && (
        <div className="grid gap-1.5">
          <Label id={eventTypeLabelId}>{t('pod.automation.event_type')}</Label>
          <Select
            value={resolvedEventType || 'all'}
            disabled={disabled}
            onValueChange={value => {
              if (value !== null) onSelectEventType(value === 'all' ? '' : value)
            }}>
            <SelectTrigger aria-labelledby={eventTypeLabelId} className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">{t('pod.automation.any_event')}</SelectItem>
              {activeSource.eventTypes.map(type => (
                <SelectItem key={type} value={type}>
                  {type}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      )}

      {activeSource?.lastError && (
        <p className="text-xs text-destructive-fg [overflow-wrap:anywhere]">
          {connectorFailureMessage(activeSource.lastError)}{' '}
          <Link className="underline underline-offset-4" to={activeSource.manageURL}>
            {t('pod.automation.manage_event_source')}
          </Link>
        </p>
      )}

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div className="grid gap-1.5">
          <Label htmlFor={windowInputId}>{t('pod.jobs.coalesce_window')}</Label>
          <Input
            id={windowInputId}
            name="coalesceWindowSec"
            type="number"
            inputMode="numeric"
            min={0}
            max={300}
            required
            disabled={disabled}
            value={coalesceWindowSec}
            onChange={event => onCoalesceWindowSecChange(event.target.value)}
          />
        </div>
        <div className="grid gap-1.5">
          <Label htmlFor={maxBatchInputId}>{t('pod.jobs.coalesce_max_batch')}</Label>
          <Input
            id={maxBatchInputId}
            name="coalesceMaxBatch"
            type="number"
            inputMode="numeric"
            min={1}
            max={100}
            required
            disabled={disabled}
            value={coalesceMaxBatch}
            onChange={event => onCoalesceMaxBatchChange(event.target.value)}
          />
        </div>
      </div>
    </div>
  )
}
