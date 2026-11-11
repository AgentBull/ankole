import type { Spec } from '@json-render/react'
import { useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { InteractionSurface, interactionSpec } from './interaction-surface'
import { useRoomActions } from './room-api'
import type { AccessBlockedPrompt } from './types'

function pageAccessSpec(
  prompt: AccessBlockedPrompt,
  view: { submitting: boolean },
  t: ReturnType<typeof useTranslation>['t']
): Spec {
  const { add, spec } = interactionSpec()
  const state = prompt.state
  const canGrant = state === 'pending' && prompt.can_grant === true
  const hasVisibleTitle = typeof prompt.page_title === 'string' && prompt.page_title.length > 0
  const targetLabel =
    prompt.target_name ||
    (prompt.grant_target_uid ? `@${prompt.grant_target_uid}` : prompt.agent_name || `@${prompt.agent_uid}`)

  const title = hasVisibleTitle
    ? prompt.page_title!
    : t('pod.chat_page_access.restricted_page_title', { defaultValue: 'Restricted page' })

  const badgeText =
    state === 'answered'
      ? t('pod.chat_page_access.status_granted', { defaultValue: 'Access granted' })
      : state === 'superseded'
        ? t('pod.chat_page_access.status_superseded', { defaultValue: 'Superseded' })
        : t('pod.chat_page_access.status_pending', { defaultValue: 'View access required' })

  const summary = canGrant
    ? t('pod.chat_page_access.summary_can_grant', {
        defaultValue: 'Grant {$target} view access to continue this turn automatically.',
        target: targetLabel
      })
    : t('pod.chat_page_access.summary_waiting_owner', {
        defaultValue: '{$target} needs view access from a page manager to continue.',
        target: targetLabel
      })

  return spec(
    add(
      'card',
      'InteractionCard',
      {
        kind: 'approval',
        title,
        state,
        muted: state === 'superseded',
        badge: {
          text: badgeText,
          variant: state === 'answered' ? 'secondary' : 'outline'
        },
        testid: 'chat-page-access-card',
        actionKind: 'pod.page.grant_view'
      },
      [
        add('summary', 'Question', { text: summary, bidi: true }),
        hasVisibleTitle &&
          add('details', 'Group', { kind: 'details' }, [
            add('page-link', 'PageLink', {
              pageID: prompt.page_id,
              label: prompt.page_title!
            })
          ]),
        prompt.explain &&
          add('waterfall-group', 'Group', { kind: 'drafts' }, [
            add('waterfall', 'WaterfallDisclosure', {
              title: t('pod.chat_page_access.why_blocked', { defaultValue: 'Why access was blocked (4 stages)' }),
              explain: prompt.explain,
              open: false
            })
          ]),
        canGrant &&
          add('actions', 'Group', { kind: 'actions' }, [
            add(
              'grant',
              'ActionButton',
              {
                label: t('pod.chat_page_access.grant_and_continue', {
                  defaultValue: 'Grant View & Continue'
                }),
                variant: 'default',
                size: 'sm',
                icon: 'check',
                disabled: view.submitting
              },
              [],
              { press: { action: 'grant', params: {} } }
            )
          ]),
        state === 'pending' &&
          !canGrant &&
          add('waiting-owner', 'Outcome', {
            text: prompt.already_granted
              ? t('pod.chat_page_access.already_granted_notice', {
                  defaultValue: 'View access is now granted.'
                })
              : t('pod.chat_page_access.waiting_for_manager', {
                  defaultValue: 'Waiting for a page manager to grant view access.'
                })
          }),
        view.submitting &&
          add('submitting', 'Outcome', {
            text: t('pod.chat_page_access.granting', {
              defaultValue: 'Granting view access and resuming…'
            }),
            live: true
          }),
        state === 'answered' &&
          add('answered', 'Outcome', {
            icon: 'check',
            text: prompt.answered_by_name
              ? t('pod.chat_page_access.granted_by', {
                  defaultValue: 'Granted by {$name} · Resuming automatically',
                  name: prompt.answered_by_name
                })
              : t('pod.chat_page_access.granted_resuming', {
                  defaultValue: 'Access granted · Resuming automatically'
                })
          }),
        state === 'superseded' &&
          add('superseded', 'Outcome', {
            text: t('pod.chat_page_access.superseded_notice', {
              defaultValue: 'Conversation moved on before view access was granted.'
            })
          })
      ]
    )
  )
}

export function PageAccessCardView({
  conversationID,
  prompt,
  onGrantAccess
}: {
  conversationID: string
  prompt: AccessBlockedPrompt
  onGrantAccess?: (interactionID: string) => Promise<unknown>
}) {
  const { t } = useTranslation()
  const cardRef = useRef<HTMLDivElement>(null)
  const roomActions = useRoomActions(conversationID)
  const [submitting, setSubmitting] = useState(false)

  const handleGrant = () => {
    if (submitting || prompt.state !== 'pending' || !prompt.can_grant) return
    setSubmitting(true)
    const action = onGrantAccess
      ? onGrantAccess(prompt.interaction_id)
      : roomActions.grantPageAccess.mutateAsync({ interactionID: prompt.interaction_id })
    void action
      .catch(() => {})
      .finally(() => {
        setSubmitting(false)
      })
  }

  return (
    <InteractionSurface
      cardRef={cardRef}
      spec={pageAccessSpec(prompt, { submitting: submitting || roomActions.grantPageAccess.isPending }, t)}
      handlers={{
        grant: handleGrant
      }}
    />
  )
}
