import { recordValue } from '@agentbull/active-support'
import type { Spec } from '@json-render/react'
import { useMutationState } from '@tanstack/react-query'
import { useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { InteractionSurface, interactionSpec } from './interaction-surface'
import type { ActionCardDecision } from './room-api'
import type { ActionCardState } from './types'

const DESTRUCTIVE_ACTION_KINDS = new Set(['pod.page.delete', 'pod.base.delete_table'])
const KNOWLEDGE_ACTION_KINDS = new Set(['pod.knowledge.save', 'brain.object.create'])

/**
 * Builds the Action Card as an interaction spec from the card that the control plane drafted. `enabled` says
 * that the viewer may decide now: the card is prepared and no decision is in flight.
 */
function actionCardSpec(
  card: ActionCardState,
  view: { enabled: boolean; submitting: boolean; decision?: ActionCardDecision; fresh: boolean },
  t: ReturnType<typeof useTranslation>['t']
): Spec {
  const { add, spec } = interactionSpec()
  const status = card.status ?? 'prepared'
  const payload = card.payload ?? {}
  const details = formatPayloadDetails(card, t)
  const resolvedBy = card.resolved_by_name || t('pod.chat_timeline.teammate')
  return spec(
    add(
      'card',
      'InteractionCard',
      {
        kind: 'approval',
        title: actionKindLabel(card.action_kind, t),
        state: status === 'prepared' ? 'pending' : status,
        muted: status === 'cancelled' || status === 'stale',
        badge: {
          text: actionStatusLabel(status, t),
          variant: status === 'executed' ? 'secondary' : status === 'stale' ? 'destructive' : 'outline'
        },
        testid: 'chat-action-card',
        actionKind: card.action_kind
      },
      [
        add('summary', 'Question', { text: card.summary, bidi: true }),
        (details.length > 0 || !!card.target_node_id) &&
          add('details', 'Group', { kind: 'details' }, [
            card.target_node_id &&
              add('target', 'PageLink', {
                pageID: card.target_node_id,
                label: t('pod.chat_action_card.open_target', { defaultValue: 'View target page' })
              }),
            ...details.map((text, index) => add(`detail:${index}`, 'Line', { text }))
          ]),
        KNOWLEDGE_ACTION_KINDS.has(card.action_kind) &&
          add('drafts', 'Group', { kind: 'drafts' }, [
            typeof payload.diff === 'string' &&
              add('diff', 'Disclosure', {
                title: t('pod.chat_action_card.proposed_changes'),
                text: payload.diff,
                open: true
              }),
            typeof payload.markdown === 'string' &&
              add('markdown', 'Disclosure', {
                title: t('pod.chat_action_card.complete_draft'),
                text: payload.markdown || t('pod.chat_action_card.empty_draft'),
                tall: true
              })
          ]),
        status === 'prepared' &&
          add('actions', 'Group', { kind: 'actions' }, [
            add(
              'confirm',
              'ActionButton',
              {
                label: t('pod.chat_action_card.confirm', { defaultValue: 'Confirm & Execute' }),
                variant: DESTRUCTIVE_ACTION_KINDS.has(card.action_kind) ? 'destructive' : 'default',
                size: 'sm',
                icon: 'check',
                disabled: !view.enabled,
                busy: view.submitting && view.decision === 'confirm'
              },
              [],
              { press: { action: 'resolve', params: { decision: 'confirm' } } }
            ),
            add(
              'cancel',
              'ActionButton',
              {
                label: t('pod.chat_action_card.cancel', { defaultValue: 'Cancel' }),
                variant: 'outline',
                size: 'sm',
                icon: 'close',
                disabled: !view.enabled,
                busy: view.submitting && view.decision === 'cancel'
              },
              [],
              { press: { action: 'resolve', params: { decision: 'cancel' } } }
            )
          ]),
        status === 'executed' &&
          add('executed', 'Outcome', {
            icon: 'check',
            fresh: view.fresh,
            text: [
              t('pod.chat_action_card.executed_by', {
                defaultValue: 'Confirmed and executed by {$name}',
                name: resolvedBy
              }),
              card.resolution_note
            ]
              .filter(Boolean)
              .join(' · ')
          }),
        status === 'cancelled' &&
          add('cancelled', 'Outcome', {
            icon: 'close',
            fresh: view.fresh,
            text: t('pod.chat_action_card.cancelled_by', { defaultValue: 'Cancelled by {$name}', name: resolvedBy })
          }),
        status === 'stale' &&
          add('stale', 'Outcome', {
            icon: 'warning',
            warning: true,
            text:
              card.resolution_note ||
              t('pod.chat_action_card.stale_notice', {
                defaultValue: 'Target changed since this card was drafted. Ask the Agent to inspect and draft again.'
              })
          }),
        view.submitting &&
          add('submitting', 'Outcome', {
            text: t('pod.chat_action_card.submitting', { defaultValue: 'Applying decision…' }),
            live: true
          })
      ]
    )
  )
}

export function ActionCardView({
  card,
  onResolve
}: {
  card: ActionCardState
  onResolve?: (cardID: string, decision: ActionCardDecision) => Promise<unknown>
}) {
  const { t } = useTranslation()
  const submitting = useRef(false)
  const mutationState = useMutationState({
    filters: {
      predicate: mutation => (mutation.state.variables as { cardID?: string } | undefined)?.cardID === card.card_id
    },
    select: mutation => mutation.state
  }).at(-1)
  const pending = mutationState?.status === 'pending'
  const decision = (mutationState?.variables as { decision?: ActionCardDecision } | undefined)?.decision
  const enabled = (card.status ?? 'prepared') === 'prepared' && !!onResolve && !pending
  // A card that was already decided when it was first shown renders its outcome still.
  const [firstStatus] = useState(card.status ?? 'prepared')

  const decide = (decision: ActionCardDecision) => {
    if (!enabled || submitting.current) return
    submitting.current = true
    void onResolve!(card.card_id, decision)
      .catch(() => {})
      .finally(() => {
        submitting.current = false
      })
  }

  return (
    <InteractionSurface
      spec={actionCardSpec(
        card,
        { enabled, submitting: pending, decision, fresh: (card.status ?? 'prepared') !== firstStatus },
        t
      )}
      handlers={{ resolve: params => decide(params.decision === 'confirm' ? 'confirm' : 'cancel') }}
    />
  )
}

function actionKindLabel(kind: string, t: ReturnType<typeof useTranslation>['t']): string {
  switch (kind) {
    case 'brain.object.create':
    case 'pod.knowledge.save':
      return t('pod.chat_action_card.kind_knowledge_save')
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
  if (KNOWLEDGE_ACTION_KINDS.has(card.action_kind)) {
    if (typeof payload.node_title === 'string') {
      lines.push(t('pod.chat_action_card.page_target', { title: payload.node_title }))
    }
    if (typeof payload.base_revision === 'number') {
      lines.push(t('pod.chat_action_card.base_revision', { revision: payload.base_revision }))
    }
  } else if (card.action_kind === 'pod.page.set_sharing') {
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
