import { recordValue } from '@agentbull/active-support'
import type { Spec } from '@json-render/react'
import { useMutationState, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { podKeys } from '../api'
import { InteractionSurface, interactionSpec } from './interaction-surface'
import type { ActionCardDecision } from './room-api'
import type { ActionCardState } from './types'

const DESTRUCTIVE_ACTION_KINDS = new Set(['pod.page.delete', 'pod.base.delete_table'])
const DRAFT_DISCLOSURE_ACTION_KINDS = new Set(['pod.knowledge.save', 'brain.object.create', 'library.skill.save'])
const KNOWLEDGE_ACTION_KINDS = new Set(['pod.knowledge.save', 'brain.object.create'])
const EXECUTING_LEASE_REFRESH_MS = 15_000

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
  const canRecover = status === 'executing' && card.can_recover === true
  const payload = card.payload ?? {}
  const details = formatPayloadDetails(card, t)
  const sharingExplainText =
    card.action_kind === 'pod.page.set_sharing' ? formatSharingExplainText(payload.explain_summaries, t) : undefined
  const resolvedBy = card.resolved_by_name || t('pod.chat_timeline.teammate')
  const confirmedBy = t('pod.chat_action_card.confirmed_by', {
    defaultValue: 'Confirmed by {$name}',
    name: resolvedBy
  })
  const settledOutcome = (
    id: string,
    icon: 'check' | 'warning',
    warning: boolean,
    actorText: string,
    fallbackNote?: string
  ) =>
    add(id, 'Outcome', {
      icon,
      warning,
      fresh: view.fresh,
      text: [actorText, card.resolution_note || fallbackNote].filter(Boolean).join(' · ')
    })
  return spec(
    add(
      'card',
      'InteractionCard',
      {
        kind: 'approval',
        title: actionKindLabel(card.action_kind, t),
        state: status === 'prepared' || canRecover ? 'pending' : status,
        muted: status === 'cancelled' || status === 'stale',
        badge: {
          text: actionStatusLabel(status, t),
          variant: actionBadgeVariant(status)
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
        DRAFT_DISCLOSURE_ACTION_KINDS.has(card.action_kind) &&
          (typeof payload.diff === 'string' || typeof payload.markdown === 'string') &&
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
        sharingExplainText &&
          add('sharing-explain', 'Group', { kind: 'drafts' }, [
            add('explain-summaries', 'Disclosure', {
              title: t('pod.chat_action_card.current_access_preview', {
                defaultValue: 'Current access before this change'
              }),
              text: sharingExplainText,
              open: false
            })
          ]),
        card.action_kind === 'connectors.tool.call' &&
          typeof payload.arguments_preview === 'string' &&
          add('connector-args', 'Group', { kind: 'drafts' }, [
            add('arguments-preview', 'Disclosure', {
              title: t('pod.chat_action_card.tool_arguments', {
                defaultValue: 'Locked tool arguments'
              }),
              text: payload.arguments_preview,
              open: true
            })
          ]),
        status === 'prepared' &&
          add('actions', 'Group', { kind: 'actions' }, [
            add(
              'confirm',
              'ActionButton',
              {
                label: t('pod.chat_action_card.confirm', { defaultValue: 'Confirm & Execute' }),
                variant:
                  DESTRUCTIVE_ACTION_KINDS.has(card.action_kind) ||
                  (card.action_kind === 'connectors.tool.call' && payload.destructive === true)
                    ? 'destructive'
                    : 'default',
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
        canRecover &&
          !view.submitting &&
          add('interrupted', 'Outcome', {
            icon: 'warning',
            warning: true,
            text: t('pod.chat_action_card.execution_interrupted_notice', {
              defaultValue:
                'Previous execution attempt did not report completion. Settle its recorded receipt before retrying.'
            })
          }),
        canRecover &&
          add('recover-actions', 'Group', { kind: 'actions' }, [
            add(
              'recover',
              'ActionButton',
              {
                label: t('pod.chat_action_card.recover_execution', { defaultValue: 'Check & Settle Outcome' }),
                variant: 'outline',
                size: 'sm',
                icon: 'check',
                disabled: !view.enabled,
                busy: view.submitting
              },
              [],
              { press: { action: 'resolve', params: { decision: 'confirm' } } }
            )
          ]),
        status === 'executing' &&
          !canRecover &&
          !view.submitting &&
          add('executing', 'Outcome', {
            text: t('pod.chat_action_card.executing_by', {
              defaultValue: 'Confirmed by {$name} · Executing…',
              name: resolvedBy
            }),
            live: true
          }),
        status === 'executed' &&
          settledOutcome(
            'executed',
            'check',
            false,
            t('pod.chat_action_card.executed_by', {
              defaultValue: 'Confirmed and executed by {$name}',
              name: resolvedBy
            })
          ),
        status === 'execution_uncertain' &&
          settledOutcome(
            'execution-uncertain',
            'warning',
            true,
            confirmedBy,
            t('pod.chat_action_card.uncertain_notice', {
              defaultValue: 'The upstream call ended with an uncertain outcome. Inspect upstream state before retrying.'
            })
          ),
        status === 'failed' &&
          settledOutcome(
            'failed',
            'warning',
            true,
            confirmedBy,
            t('pod.chat_action_card.failed_notice', {
              defaultValue: 'Execution failed before mutating upstream state.'
            })
          ),
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
  const client = useQueryClient()
  const submitting = useRef(false)
  const mutationState = useMutationState({
    filters: {
      predicate: mutation => (mutation.state.variables as { cardID?: string } | undefined)?.cardID === card.card_id
    },
    select: mutation => mutation.state
  }).at(-1)
  const pending = mutationState?.status === 'pending'
  const decision = (mutationState?.variables as { decision?: ActionCardDecision } | undefined)?.decision
  const redacted = card.payload?.redacted === true
  const currentStatus = card.status ?? 'prepared'
  const canRecover = currentStatus === 'executing' && card.can_recover === true
  const actionable = currentStatus === 'prepared' || canRecover
  const enabled = actionable && !!onResolve && !pending && !redacted
  // A card that was already decided when it was first shown renders its outcome still.
  const [firstStatus] = useState(currentStatus)

  useEffect(() => {
    if (currentStatus !== 'executing' || canRecover) return
    // Re-check periodically while executing so an expired 120s server lease surfaces recovery without reload.
    const timer = setInterval(() => {
      void client.invalidateQueries({ queryKey: podKeys.actionCard(card.card_id), refetchType: 'active' })
      void client.invalidateQueries({
        predicate: query =>
          Array.isArray(query.queryKey) &&
          query.queryKey.at(-2) === 'conversation' &&
          typeof query.queryKey.at(-1) === 'string',
        refetchType: 'active'
      })
    }, EXECUTING_LEASE_REFRESH_MS)
    return () => clearInterval(timer)
  }, [client, card.card_id, currentStatus, canRecover])

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
    case 'library.skill.save':
      return t('pod.chat_action_card.kind_skill_save', { defaultValue: 'Save Skill approval' })
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
    case 'connectors.tool.call':
      return t('pod.chat_action_card.kind_connector_call', { defaultValue: 'External tool approval' })
    default:
      return t('pod.chat_action_card.kind_default', { defaultValue: 'Approval required' })
  }
}

function actionBadgeVariant(status: NonNullable<ActionCardState['status']>): 'secondary' | 'destructive' | 'outline' {
  if (status === 'executed') return 'secondary'
  if (status === 'stale' || status === 'failed' || status === 'execution_uncertain') return 'destructive'
  return 'outline'
}

function actionStatusLabel(
  status: NonNullable<ActionCardState['status']>,
  t: ReturnType<typeof useTranslation>['t']
): string {
  switch (status) {
    case 'prepared':
      return t('pod.chat_action_card.status_prepared', { defaultValue: 'Awaiting approval' })
    case 'executing':
      return t('pod.chat_action_card.status_executing', { defaultValue: 'Executing' })
    case 'executed':
      return t('pod.chat_action_card.status_executed', { defaultValue: 'Executed' })
    case 'execution_uncertain':
      return t('pod.chat_action_card.status_execution_uncertain', { defaultValue: 'Outcome uncertain' })
    case 'failed':
      return t('pod.chat_action_card.status_failed', { defaultValue: 'Execution failed' })
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
  } else if (card.action_kind === 'library.skill.save') {
    const skillName = typeof payload.skill_name === 'string' ? payload.skill_name : undefined
    const slug = typeof payload.slug === 'string' ? payload.slug : undefined
    if (skillName || slug) {
      lines.push(
        t('pod.chat_action_card.skill_target', {
          defaultValue: 'Skill: {$target}',
          target: skillName && slug ? `${skillName} (/${slug})` : (skillName ?? `/${slug}`)
        })
      )
    }
    if (typeof payload.target === 'string') {
      lines.push(
        payload.target === 'workspace'
          ? typeof payload.bind_agent_uid === 'string'
            ? t('pod.chat_action_card.skill_scope_workspace_bound', {
                defaultValue: 'Scope: Workspace Skill (enabled for @{$agent})',
                agent: payload.bind_agent_uid
              })
            : t('pod.chat_action_card.skill_scope_workspace', { defaultValue: 'Scope: Workspace Skill' })
          : t('pod.chat_action_card.skill_scope_personal', {
              defaultValue: 'Scope: Personal Skill (only on your Personal Assistant)'
            })
      )
    }
    if (typeof payload.base_revision === 'number') {
      lines.push(t('pod.chat_action_card.base_revision', { revision: payload.base_revision }))
    }
    if (typeof payload.scope_note === 'string' && payload.scope_note.trim()) {
      lines.push(payload.scope_note)
    }
    if (payload.redacted === true) {
      lines.push(
        t('pod.chat_action_card.skill_private_redacted', {
          defaultValue: 'Draft content is only visible to the Personal Assistant owner.'
        })
      )
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
  } else if (card.action_kind === 'connectors.tool.call') {
    const connection =
      (typeof payload.connection_name === 'string' && payload.connection_name) ||
      (typeof payload.connection === 'string' && payload.connection) ||
      (typeof payload.server === 'string' && payload.server) ||
      undefined
    const toolName = typeof payload.tool_name === 'string' ? payload.tool_name : undefined
    if (connection || toolName) {
      lines.push(
        t('pod.chat_action_card.connector_target', {
          defaultValue: 'Tool: {$target}',
          target: [connection, toolName].filter(Boolean).join(' · ')
        })
      )
    }
  }
  return lines
}

function formatSharingExplainText(
  rawSummaries: unknown,
  t: ReturnType<typeof useTranslation>['t']
): string | undefined {
  if (!Array.isArray(rawSummaries) || rawSummaries.length === 0) return undefined
  const lines: string[] = []
  for (const raw of rawSummaries) {
    const item = recordValue(raw)
    if (!item || typeof item.subject_uid !== 'string') continue
    const subjectLabel =
      typeof item.subject_name === 'string' && item.subject_name
        ? `${item.subject_name} (@${item.subject_uid})`
        : `@${item.subject_uid}`
    const verdict =
      item.current_allowed === true
        ? typeof item.current_role === 'string' && item.current_role
          ? `${t('pod.sharing.verdict_allowed', { defaultValue: 'Allowed' })} (${item.current_role})`
          : t('pod.sharing.verdict_allowed', { defaultValue: 'Allowed' })
        : t('pod.sharing.verdict_denied', { defaultValue: 'Denied' })
    const reason = typeof item.decision_reason === 'string' ? item.decision_reason : ''
    lines.push(reason ? `${subjectLabel}: ${verdict} — ${reason}` : `${subjectLabel}: ${verdict}`)
  }
  return lines.length > 0 ? lines.join('\n') : undefined
}
