import { recordValue } from '@agentbull/active-support'
import { Badge, Button, cn } from '@ankole/uikit'
import { RiCheckLine, RiCloseLine, RiErrorWarningLine, RiFileTextLine, RiShieldKeyholeLine } from '@remixicon/react'
import { useMutationState } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { BdiLabel } from '../../common/bidi-file-name'
import { podLocation } from '../../common/browser-context'
import type { ActionCardDecision } from './room-api'
import type { ActionCardState } from './types'

const DESTRUCTIVE_ACTION_KINDS = new Set(['pod.page.delete', 'pod.base.delete_table'])

export function ActionCardView({
  card,
  onResolve
}: {
  card: ActionCardState
  onResolve?: (cardID: string, decision: ActionCardDecision) => Promise<unknown>
}) {
  const { t } = useTranslation()
  const submitting = useRef(false)
  const status = card.status ?? 'prepared'
  const mutationState = useMutationState({
    filters: {
      predicate: mutation => (mutation.state.variables as { cardID?: string } | undefined)?.cardID === card.card_id
    },
    select: mutation => mutation.state
  }).at(-1)
  const pending = mutationState?.status === 'pending'
  const enabled = status === 'prepared' && !!onResolve && !pending

  const decide = (decision: ActionCardDecision) => {
    if (!enabled || submitting.current) return
    submitting.current = true
    void onResolve!(card.card_id, decision)
      .catch(() => {})
      .finally(() => {
        submitting.current = false
      })
  }

  const destructive = DESTRUCTIVE_ACTION_KINDS.has(card.action_kind)
  const details = formatPayloadDetails(card, t)

  return (
    <div
      className={cn(
        'pod-chat-choice-card',
        (status === 'cancelled' || status === 'stale') && 'pod-chat-choice-superseded'
      )}
      data-testid="chat-action-card"
      data-action-kind={card.action_kind}
      data-state={status === 'prepared' ? 'pending' : status}>
      <div className="pod-chat-choice-header justify-between">
        <span className="inline-flex items-center gap-1.5">
          <RiShieldKeyholeLine aria-hidden />
          <span>{actionKindLabel(card.action_kind, t)}</span>
        </span>
        <Badge variant={status === 'executed' ? 'secondary' : status === 'stale' ? 'destructive' : 'outline'}>
          {actionStatusLabel(status, t)}
        </Badge>
      </div>
      <p className="pod-chat-choice-question">
        <BdiLabel value={card.summary} showBidiWarning={false} />
      </p>
      {(details.length > 0 || card.target_node_id) && (
        <div className="mx-3.5 mb-3 space-y-1.5 rounded-control border border-border bg-muted/35 px-3 py-2 text-xs text-fg-secondary">
          {card.target_node_id && (
            <div className="flex items-center gap-1.5">
              <RiFileTextLine className="size-3.5 shrink-0 text-fg-tertiary" aria-hidden />
              <Link
                className="truncate font-medium text-foreground hover:underline"
                to={podLocation(`/pages/${card.target_node_id}`).pathname}>
                {t('pod.chat_action_card.open_target', { defaultValue: 'View target page' })}
              </Link>
            </div>
          )}
          {details.map((line, index) => (
            <div key={index} className="break-words">
              {line}
            </div>
          ))}
        </div>
      )}
      {status === 'prepared' && (
        <div className="flex flex-wrap items-center gap-2 px-3.5 pb-3">
          <Button
            size="sm"
            variant={destructive ? 'destructive' : 'default'}
            disabled={!enabled}
            onClick={() => decide('confirm')}>
            <RiCheckLine aria-hidden />
            {t('pod.chat_action_card.confirm', { defaultValue: 'Confirm & Execute' })}
          </Button>
          <Button size="sm" variant="outline" disabled={!enabled} onClick={() => decide('cancel')}>
            <RiCloseLine aria-hidden />
            {t('pod.chat_action_card.cancel', { defaultValue: 'Cancel' })}
          </Button>
        </div>
      )}
      {status === 'executed' && (
        <p className="pod-chat-choice-outcome">
          <RiCheckLine aria-hidden />
          <span>
            {t('pod.chat_action_card.executed_by', {
              defaultValue: 'Confirmed and executed by {$name}',
              name: card.resolved_by_name || t('pod.chat_timeline.teammate')
            })}
            {card.resolution_note && <> · {card.resolution_note}</>}
          </span>
        </p>
      )}
      {status === 'cancelled' && (
        <p className="pod-chat-choice-outcome">
          <RiCloseLine aria-hidden />
          <span>
            {t('pod.chat_action_card.cancelled_by', {
              defaultValue: 'Cancelled by {$name}',
              name: card.resolved_by_name || t('pod.chat_timeline.teammate')
            })}
          </span>
        </p>
      )}
      {status === 'stale' && (
        <p className="pod-chat-choice-outcome text-warning-foreground">
          <RiErrorWarningLine aria-hidden />
          <span>
            {card.resolution_note ||
              t('pod.chat_action_card.stale_notice', {
                defaultValue: 'Target changed since this card was drafted. Ask the Agent to inspect and draft again.'
              })}
          </span>
        </p>
      )}
      {pending && (
        <p role="status" className="pod-chat-choice-outcome">
          {t('pod.chat_action_card.submitting', { defaultValue: 'Applying decision…' })}
        </p>
      )}
    </div>
  )
}

function actionKindLabel(kind: string, t: ReturnType<typeof useTranslation>['t']): string {
  switch (kind) {
    case 'pod.page.set_sharing':
      return t('pod.chat_action_card.kind_set_sharing', { defaultValue: 'Permission change approval' })
    case 'pod.page.delete':
      return t('pod.chat_action_card.kind_page_delete', { defaultValue: 'Move to trash approval' })
    case 'pod.page.restore':
      return t('pod.chat_action_card.kind_page_restore', { defaultValue: 'Restore from trash approval' })
    case 'pod.base.delete_table':
      return t('pod.chat_action_card.kind_base_delete_table', { defaultValue: 'Delete Base table approval' })
    case 'conversation.add_participants':
      return t('pod.chat_action_card.kind_add_participants', { defaultValue: 'Add room participants approval' })
    default:
      return t('pod.chat_action_card.kind_default', { defaultValue: 'Approval required' })
  }
}

function actionStatusLabel(
  status: NonNullable<ActionCardState['status']>,
  t: ReturnType<typeof useTranslation>['t']
): string {
  switch (status) {
    case 'prepared':
      return t('pod.chat_action_card.status_prepared', { defaultValue: 'Awaiting approval' })
    case 'executed':
      return t('pod.chat_action_card.status_executed', { defaultValue: 'Executed' })
    case 'stale':
      return t('pod.chat_action_card.status_stale', { defaultValue: 'Outdated' })
    case 'cancelled':
      return t('pod.chat_action_card.status_cancelled', { defaultValue: 'Cancelled' })
  }
}

function formatPayloadDetails(card: ActionCardState, t: ReturnType<typeof useTranslation>['t']): string[] {
  const payload = card.payload ?? {}
  const lines: string[] = []
  if (card.action_kind === 'pod.page.set_sharing') {
    if (typeof payload.inherit_permissions === 'boolean') {
      lines.push(
        payload.inherit_permissions
          ? t('pod.chat_action_card.inherit_enabled', { defaultValue: 'Inherit parent permissions: enabled' })
          : t('pod.chat_action_card.inherit_disabled', { defaultValue: 'Inherit parent permissions: disabled' })
      )
    }
    if (Array.isArray(payload.grants)) {
      lines.push(
        t('pod.chat_action_card.grants_count', {
          defaultValue: 'Explicit access grants: {$count}',
          count: payload.grants.length
        })
      )
      for (const raw of payload.grants) {
        const grant = recordValue(raw)
        if (!grant) continue
        const target = grant.principal_uid ?? grant.group_id ?? grant.source_node_id
        if (typeof target !== 'string') continue
        const role = Array.isArray(grant.actions) ? grant.actions.join(', ') : String(grant.role ?? '')
        const subject = grant.source_node_id ? `${target} (${grant.source_action})` : target
        const scope = t(
          grant.target_scope === 'self' ? 'pod.content.sharing_scope_self' : 'pod.content.sharing_scope_container'
        )
        lines.push(`${subject} · ${role} · ${scope}`)
        if (typeof grant.condition === 'string' && grant.condition !== 'true') lines.push(grant.condition)
      }
    }
  } else if (card.action_kind === 'pod.base.delete_table') {
    const tableName = typeof payload.table_name === 'string' ? payload.table_name : undefined
    const tableId = typeof payload.table_id === 'string' ? payload.table_id : undefined
    if (tableName || tableId) {
      lines.push(
        t('pod.chat_action_card.table_target', {
          defaultValue: 'Table: {$target}',
          target: tableName ? `${tableName} (${tableId ?? ''})`.trim() : tableId
        })
      )
    }
  } else if (card.action_kind === 'conversation.add_participants' && Array.isArray(payload.participant_uids)) {
    lines.push(
      t('pod.chat_action_card.participants_target', {
        defaultValue: 'Participants to add: {$count}',
        count: payload.participant_uids.length
      })
    )
    const participants = Array.isArray(payload.participants) ? payload.participants : []
    for (const uid of payload.participant_uids) {
      if (typeof uid !== 'string') continue
      const participant = participants.map(recordValue).find(item => item?.uid === uid)
      lines.push(typeof participant?.name === 'string' ? `${participant.name} (@${uid})` : `@${uid}`)
    }
  }
  return lines
}
