import { Button, Popover, PopoverContent, PopoverTitle, PopoverTrigger } from '@ankole/uikit'
import { useTranslation } from 'react-i18next'
import type { ConversationDetail } from '../api'
import { ChatAvatar } from './chat-avatar'

/** The room header's participant avatars. Clicking them lists who is in the room. */
export function ParticipantsPopover({ room }: { room: ConversationDetail['conversation'] }) {
  const { t } = useTranslation()
  const names = room.participants.map(member => member.displayName).join(', ')
  return (
    <Popover>
      <PopoverTrigger
        render={
          <Button
            size="sm"
            variant="ghost"
            className="pod-chat-avatar-cluster gap-0 px-1"
            aria-label={t('pod.chat_room.participants_list', { names })}
            title={names}
          />
        }>
        {room.participants.slice(0, 4).map(member => (
          <ChatAvatar
            key={member.uid}
            name={member.displayName}
            src={member.avatarURL}
            agent={member.type === 'agent'}
          />
        ))}
        {room.participants.length > 4 && (
          <span className="pod-chat-avatar pod-chat-avatar-overflow">+{room.participants.length - 4}</span>
        )}
      </PopoverTrigger>
      <PopoverContent align="end" className="w-64 gap-3">
        <PopoverTitle>{t('pod.chat_room.in_room')}</PopoverTitle>
        <div className="max-h-72 overflow-y-auto">
          {room.participants.map(member => (
            <div key={member.uid} className="pod-chat-member">
              <ChatAvatar name={member.displayName} src={member.avatarURL} agent={member.type === 'agent'} />
              <span>{member.displayName}</span>
              {member.type === 'human' && (
                <span className="pod-chat-subtle">{t(`pod.chat_room.role_${member.role || 'member'}`)}</span>
              )}
            </div>
          ))}
        </div>
      </PopoverContent>
    </Popover>
  )
}
