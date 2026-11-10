import { useQuery } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import type { ReactNode } from 'react'
import { authenticationRef, podID } from '../../common/browser-context'
import { browserSession } from '../../common/api/generated/sdk.gen'
import { podKeys, type PodAgent } from '../api'
import { podConversations } from '../api/generated/sdk.gen'
import { ChatAvatar } from './chat-avatar'
import { ConversationGlyph, ConversationTitle, conversationPath } from './conversation-row'
import { formatRelativeTime } from '../../common/date-time'
import { ContentError } from '../content-primitives'
import { NextStepsMenu } from './next-steps-menu'

export function ChatHomeView({
  composer,
  onSuggestion,
  showSuggestions,
  pageID,
  colleague,
  children
}: {
  composer: ReactNode
  onSuggestion(text: string): void
  showSuggestions: boolean
  pageID?: string
  colleague?: PodAgent
  children?: ReactNode
}) {
  const { t, i18n } = useTranslation()
  const session = useQuery({
    queryKey: ['pod-session', authenticationRef() ?? '', podID() ?? ''],
    queryFn: () => browserSession()
  })
  const recent = useQuery({
    queryKey: [...podKeys.conversations, 'recent'],
    queryFn: ({ signal }) => podConversations({ query: { order: 'recent', limit: 3 }, signal }),
    enabled: !pageID && !colleague
  })
  return (
    <div className="pod-chat-home">
      <div className="pod-chat-home-main">
        {colleague ? (
          // A colleague the user has not written to yet introduces itself by name, handle, and responsibility.
          <div className="pod-chat-colleague-intro">
            <ChatAvatar name={colleague.displayName} src={colleague.avatarURL} agent />
            <h1>{colleague.displayName}</h1>
            <p className="pod-chat-colleague-uid">@{colleague.uid}</p>
          </div>
        ) : (
          !pageID && (
            <>
              <p className="pod-chat-home-eyebrow">{t('pod.chat_room.workspace')}</p>
              <h1>{t('pod.chat_room.greeting', { name: session.data?.displayName || t('pod.chat_room.team') })}</h1>
            </>
          )
        )}
        <p className="pod-chat-home-subtitle">
          {colleague
            ? colleague.role || t('pod.superagent.dm_no_role')
            : t(pageID ? 'pod.page_chat.start_hint' : 'pod.chat_room.home_hint')}
        </p>
        {children}
        {composer}
      </div>
      {!pageID && !colleague && (
        <div className="pod-chat-home-guides">
          {showSuggestions && !pageID && (
            <NextStepsMenu
              onChoose={onSuggestion}
              fallback={
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
              }
            />
          )}
          {!pageID && !colleague && (!!recent.data?.conversations.length || recent.isError) && (
            <section>
              <h2>{t('pod.chat_room.recent')}</h2>
              <ContentError error={recent.error} retry={() => void recent.refetch()} />
              {recent.data?.conversations.map(room => (
                <Link key={room.id} className="pod-chat-recent-row" to={conversationPath(room)}>
                  <ConversationGlyph room={room} size="md" />
                  <span className="pod-chat-recent-copy">
                    <span className="pod-chat-recent-title">
                      <ConversationTitle room={room} />
                    </span>
                    <span className="pod-chat-subtle">{formatRelativeTime(room.lastActivityAt, i18n.language)}</span>
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
