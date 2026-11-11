import { Badge } from '@ankole/uikit'
import { ChatRegular, PeopleRegular } from '@ankole/uikit/icons'
import { useTranslation } from 'react-i18next'
import { podLocation } from '../../common/browser-context'
import type { podConversations } from '../api/generated/sdk.gen'
import { ChatAvatar } from './chat-avatar'

// Every list that shows a conversation (the Chat sidebar, Home recents, the Recent page, search) names, marks, and
// links it through this module, so a colleague or a task looks the same wherever the user meets it.

export type RoomRow = NonNullable<Awaited<ReturnType<typeof podConversations>>>['conversations'][number]
type AgentIdentity = { uid: string; displayName: string; agentType?: string | null }

/** A colleague DM lives at its stable `/dm/$uid` route; every other conversation lives at its ID. */
export function conversationPath(room: Pick<RoomRow, 'id' | 'conversationKind' | 'agents'>) {
  const colleague = room.conversationKind === 'colleague_dm' ? room.agents[0] : undefined
  return podLocation(colleague ? `/dm/${encodeURIComponent(colleague.uid)}` : `/conversations/${room.id}`).pathname
}

/**
 * Shows an Agent by its display name, followed by its `@uid` in the quieter tertiary ink. The personal
 * assistant has no uid of its own that a user would type, so it shows only its name.
 */
export function AgentName({ agent }: { agent: AgentIdentity }) {
  return (
    <>
      {agent.displayName}
      {agent.agentType !== 'personal_assistant' && <span className="text-fg-tertiary"> @{agent.uid}</span>}
    </>
  )
}

/** The plain-text form of `AgentName`, for titles, labels, and announcements. */
export function agentLabel(agent: AgentIdentity) {
  return agent.agentType === 'personal_assistant' ? agent.displayName : `${agent.displayName} @${agent.uid}`
}

/** A DM is named by its colleague; a task or a group is named by its title. */
export function ConversationTitle({ room }: { room: RoomRow }) {
  const { t } = useTranslation()
  const colleague = room.conversationKind === 'colleague_dm' ? room.agents[0] : undefined
  return colleague ? <AgentName agent={colleague} /> : <>{room.title || t('pod.content.untitled')}</>
}

export function conversationLabel(room: RoomRow, untitled: string) {
  const colleague = room.conversationKind === 'colleague_dm' ? room.agents[0] : undefined
  return colleague ? agentLabel(colleague) : room.title || untitled
}

/**
 * The leading mark tells the three kinds apart at a glance: a colleague DM shows the colleague's face, a group
 * shows a group mark, and an assistant task shows a plain conversation mark, because every task belongs to the
 * same assistant and repeating its avatar on each row would add noise rather than information.
 */
export function ConversationGlyph({ room, size = 'sm' }: { room: RoomRow; size?: 'sm' | 'md' }) {
  const colleague = room.conversationKind === 'colleague_dm' ? room.agents[0] : undefined
  if (colleague) {
    return (
      <span className="pod-conversation-glyph" data-size={size}>
        <ChatAvatar name={colleague.displayName} src={colleague.avatarURL} agent />
      </span>
    )
  }
  const Icon = room.conversationKind === 'group' ? PeopleRegular : ChatRegular
  return (
    <span className="pod-conversation-glyph" data-size={size}>
      <Icon />
    </span>
  )
}

/**
 * A conversation that waits for the viewer carries a labeled badge, because it is the one state that needs the
 * viewer to act. Running work spins and unread messages show a dot; an idle conversation shows nothing.
 */
export function ChatRowStatus({ status }: { status: RoomRow['rowStatus'] }) {
  const { t } = useTranslation()
  if (status === 'idle') return null
  if (status === 'waiting_choice') {
    return (
      <Badge variant="warning" size="sm" title={t('pod.chat_room.status_waiting_choice')}>
        {t('pod.superagent.waiting_you')}
      </Badge>
    )
  }
  return (
    <span role="img" aria-label={t(`pod.chat_room.status_${status}`)} title={t(`pod.chat_room.status_${status}`)}>
      <span className={`pod-chat-status-dot pod-chat-status-${status}`} />
    </span>
  )
}
