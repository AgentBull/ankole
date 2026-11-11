import { recordValue } from '@agentbull/active-support'
import type { Spec } from '@json-render/react'
import { useMutationState } from '@tanstack/react-query'
import { useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { InteractionSurface, interactionSpec } from './interaction-surface'
import type { ActionCardDecision } from './room-api'
import type { ActionCardState } from './types'

const DESTRUCTIVE_ACTION_KINDS = new Set(['pod.page.delete', 'pod.base.delete_table'])
const DRAFT_DISCLOSURE_ACTION_KINDS = new Set(['pod.knowledge.save', 'brain.object.create', 'library.skill.save'])
const KNOWLEDGE_ACTION_KINDS = new Set(['pod.knowledge.save', 'brain.object.create'])

/**
 * Builds the Action Card as an interaction spec from the card that the control plane drafted. `enabled` says
 * that the viewer may decide now: the card is prepared and no decision is in flight.
 */
function actionCardSpec(
  card: ActionCardState,
  view: { enabled: boolean; submitting: boolean },
  t: ReturnType<typeof useTranslation>['t']
): Spec {
  const { add, spec } = interactionSpec()
  const status = card.status ?? 'prepared'
  const payload = card.payload ?? {}
  const details = formatPayloadDetails(card, t)
  const sharingExplainText =
    card.action_kind === 'pod.page.set_sharing' ? formatSharingExplainText(payload.explain_summaries, t) : undefined
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
                disabled: !view.enabled
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
                disabled: !view.enabled
              },
              [],
              { press: { action: 'resolve', params: { decision: 'cancel' } } }
            )
          ]),
        status === 'executed' &&
          add('executed', 'Outcome', {
            icon: 'check',
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
  const redacted = card.payload?.redacted === true
  const enabled = (card.status ?? 'prepared') === 'prepared' && !!onResolve && !pending && !redacted

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
      spec={actionCardSpec(card, { enabled, submitting: pending }, t)}
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
