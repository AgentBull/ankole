import { useQuery } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import type { ReactNode } from 'react'
import { SidebarTrigger, useSidebar } from '@ankole/uikit'
import { authenticationRef, podID, podLocation } from '../../common/browser-context'
import { browserSession } from '../../common/api/generated/sdk.gen'
import { podKeys } from '../api'
import { podConversations } from '../api/generated/sdk.gen'
import { ChatAvatar } from './chat-avatar'
import { ContentError } from '../content-primitives'

export function ChatHomeView({
  composer,
  onSuggestion,
  showSuggestions,
  pageID,
  children
}: {
  composer: ReactNode
  onSuggestion(text: string): void
  showSuggestions: boolean
  pageID?: string
  children?: ReactNode
}) {
  const { t } = useTranslation()
  const session = useQuery({
    queryKey: ['pod-session', authenticationRef() ?? '', podID() ?? ''],
    queryFn: () => browserSession()
  })
  const recent = useQuery({
    queryKey: [...podKeys.conversations, 'recent'],
    queryFn: ({ signal }) => podConversations({ query: { order: 'recent', limit: 3 }, signal }),
    enabled: !pageID
  })
  return (
    <div className="pod-chat-home">
      <div className="pod-chat-home-main">
        {!pageID && (
          <>
            <p className="pod-chat-home-eyebrow">{t('pod.chat_room.workspace')}</p>
            <h1>{t('pod.chat_room.greeting', { name: session.data?.displayName || t('pod.chat_room.team') })}</h1>
          </>
        )}
        <p className="pod-chat-home-subtitle">{t(pageID ? 'pod.page_chat.start_hint' : 'pod.chat_room.home_hint')}</p>
        {children}
        {composer}
      </div>
      {!pageID && (
        <div className="pod-chat-home-guides">
          {showSuggestions && !pageID && (
            <section>
              <h2>{t('pod.chat_room.start_with')}</h2>
              <div className="pod-chat-starters">
                {['research', 'analyze', 'build', 'notes'].map(key => (
                  <button type="button" key={key} onClick={() => onSuggestion(t(`pod.chat_room.starter_${key}`))}>
                    {t(`pod.chat_room.starter_${key}`)}
                  </button>
                ))}
              </div>
            </section>
          )}
          {!pageID && (!!recent.data?.conversations.length || recent.isError) && (
            <section>
              <h2>{t('pod.chat_room.recent')}</h2>
              <ContentError error={recent.error} retry={() => void recent.refetch()} />
              {recent.data?.conversations.map(room => (
                <Link
                  key={room.id}
                  className="pod-chat-recent-row"
                  to={podLocation(`/conversations/${room.id}`).pathname}>
                  {room.agents.length > 0 && (
                    <span className="pod-chat-avatar-cluster">
                      {room.agents.slice(0, 2).map(agent => (
                        <ChatAvatar key={agent.uid} name={agent.displayName} src={agent.avatarURL} agent />
                      ))}
                    </span>
                  )}
                  <span className="pod-chat-recent-copy">
                    <span className="pod-chat-recent-title">{room.title}</span>
                    <span className="pod-chat-subtle">{room.agents.map(agent => agent.displayName).join(', ')}</span>
                  </span>
                </Link>
              ))}
            </section>
          )}
        </div>
      )}
    </div>
  )
}

export function ChatHomeToolbar() {
  const { t } = useTranslation()
  const { state } = useSidebar()
  return (
    <header className="pod-chat-home-toolbar">
      <SidebarTrigger className={state === 'expanded' ? 'md:hidden' : undefined} label={t('pod.sidebar.expand')} />
    </header>
  )
}
