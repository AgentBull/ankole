import type { Spec } from '@json-render/react'
import { useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { principalUID } from '../../common/browser-context'
import { InteractionSurface, interactionSpec } from './interaction-surface'
import type { ConnectorAuthPrompt } from './types'

function popupAuthorizationUrl(rawUrl: string): string {
  try {
    const parsed = new URL(rawUrl, window.location.origin)
    parsed.searchParams.set('popup', '1')
    return parsed.toString()
  } catch {
    return rawUrl
  }
}

function openCenteredPopup(rawUrl: string) {
  const url = popupAuthorizationUrl(rawUrl)
  const width = 620
  const height = 720
  const left = Math.max(0, Math.round(window.screenX + (window.outerWidth - width) / 2))
  const top = Math.max(0, Math.round(window.screenY + (window.outerHeight - height) / 2))
  const popup = window.open(
    url,
    'ankole-connector-auth',
    `popup=yes,width=${width},height=${height},left=${left},top=${top}`
  )
  if (!popup) {
    window.open(url, '_blank', 'noopener,noreferrer')
  }
}

function connectorAuthSpec(
  prompt: ConnectorAuthPrompt,
  view: { canAuthorize: boolean; opening: boolean },
  t: ReturnType<typeof useTranslation>['t']
): Spec {
  const { add, spec } = interactionSpec()
  const state = prompt.state
  const scopes = (prompt.required_scopes ?? []).filter(Boolean)
  const isTeam = prompt.subject_kind === 'app'
  const details: string[] = [
    isTeam
      ? t('pod.chat_connector_auth.subject_team', {
          defaultValue: 'Account scope: Workspace shared connection'
        })
      : !view.canAuthorize && prompt.human_uid
        ? t('pod.chat_connector_auth.subject_owner', {
            defaultValue: 'Account scope: @{$uid} personal account',
            uid: prompt.human_uid
          })
        : t('pod.chat_connector_auth.subject_personal', {
            defaultValue: 'Account scope: Your personal account'
          })
  ]
  if (scopes.length > 0) {
    details.push(
      t('pod.chat_connector_auth.required_scopes', {
        defaultValue: 'Required permissions: {$scopes}',
        scopes: scopes.join(', ')
      })
    )
  }

  const badgeText =
    state === 'answered'
      ? t('pod.chat_connector_auth.status_connected', { defaultValue: 'Connected' })
      : state === 'superseded'
        ? t('pod.chat_connector_auth.status_superseded', { defaultValue: 'Superseded' })
        : t('pod.chat_connector_auth.status_pending', { defaultValue: 'Authorization needed' })

  const summary = t('pod.chat_connector_auth.summary', {
    defaultValue: 'Connect {$name} so I can continue this step automatically.',
    name: prompt.display_name
  })

  return spec(
    add(
      'card',
      'InteractionCard',
      {
        kind: 'approval',
        title: prompt.display_name,
        state,
        muted: state === 'superseded',
        badge: {
          text: badgeText,
          variant: state === 'answered' ? 'secondary' : 'outline'
        },
        testid: 'chat-connector-auth-card',
        actionKind: 'connector.auth'
      },
      [
        add('summary', 'Question', { text: summary, bidi: true }),
        add(
          'details',
          'Group',
          { kind: 'details' },
          details.map((text, index) => add(`detail:${index}`, 'Line', { text }))
        ),
        state === 'pending' &&
          view.canAuthorize &&
          add('actions', 'Group', { kind: 'actions' }, [
            add(
              'connect',
              'ActionButton',
              {
                label: t('pod.chat_connector_auth.connect_button', {
                  defaultValue: 'Connect & Authorize'
                }),
                variant: 'default',
                size: 'sm',
                icon: 'check',
                disabled: false
              },
              [],
              { press: { action: 'connect', params: {} } }
            )
          ]),
        state === 'pending' &&
          view.canAuthorize &&
          view.opening &&
          add('waiting', 'Outcome', {
            text: t('pod.chat_connector_auth.waiting_window', {
              defaultValue: 'Complete authorization in the opened window—this conversation will resume automatically.'
            }),
            live: true
          }),
        state === 'pending' &&
          !view.canAuthorize &&
          prompt.human_uid &&
          add('waiting-owner', 'Outcome', {
            text: t('pod.chat_connector_auth.waiting_for_owner', {
              defaultValue: 'Waiting for @{$uid} to connect {$name}.',
              uid: prompt.human_uid,
              name: prompt.display_name
            })
          }),
        state === 'answered' &&
          add('connected', 'Outcome', {
            icon: 'check',
            text: prompt.answered_by_name
              ? t('pod.chat_connector_auth.connected_by', {
                  defaultValue: 'Connected by {$name} · Resuming automatically',
                  name: prompt.answered_by_name
                })
              : t('pod.chat_connector_auth.connected_resuming', {
                  defaultValue: 'Connected · Resuming automatically'
                })
          }),
        state === 'superseded' &&
          add('superseded', 'Outcome', {
            text: t('pod.chat_connector_auth.superseded_notice', {
              defaultValue: 'Conversation moved on before this connector was authorized.'
            })
          })
      ]
    )
  )
}

export function ConnectorAuthCardView({ prompt }: { prompt: ConnectorAuthPrompt }) {
  const { t } = useTranslation()
  const cardRef = useRef<HTMLDivElement>(null)
  const [opening, setOpening] = useState(false)
  const viewerUID = principalUID()
  const canAuthorize =
    prompt.subject_kind === 'app' || !prompt.human_uid || !viewerUID || prompt.human_uid === viewerUID

  return (
    <InteractionSurface
      cardRef={cardRef}
      spec={connectorAuthSpec(prompt, { canAuthorize, opening }, t)}
      handlers={{
        connect: () => {
          if (!canAuthorize) return
          setOpening(true)
          openCenteredPopup(prompt.authorization_url)
        }
      }}
    />
  )
}
