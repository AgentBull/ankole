import { Avatar, AvatarImage, AvatarFallback, cn } from '@ankole/uikit'
import { BotRegular, PeopleRegular } from '@ankole/uikit/icons'
import { avatarInitials } from '../avatar-initials'
import { currentProfileAvatarContext, profileAvatarURL } from '../native-transfers'

export { avatarInitials }

/**
 * A chat member's avatar: the uploaded picture, or else the initials of a person's name or an Agent's bot mark. An
 * Agent's name often starts with its owner's name, as a personal assistant's does, so its initials would read as the
 * owner's avatar. A group has no picture of its own and shows the group mark. Agents and groups take the kit's rounded
 * square and people the circle; the timeline draws every author round (`round`), so a reply and a person's message
 * share one avatar.
 */
export function ChatAvatar({
  name,
  src,
  agent = false,
  group = false,
  round = false,
  size = 'sm',
  className
}: {
  name: string
  src?: string | null
  agent?: boolean
  group?: boolean
  round?: boolean
  /** The kit avatar size: 24px by default, 32px beside a message or in a sidebar conversation row, 20px beside a line
   * of 12px text. */
  size?: 'default' | 'sm' | 'xs'
  className?: string
}) {
  const Mark = group ? PeopleRegular : agent ? BotRegular : undefined
  return (
    <Avatar
      aria-hidden
      title={name}
      size={size}
      shape={(agent || group) && !round ? 'square' : 'circle'}
      className={cn('pod-chat-avatar', className)}>
      {src && !group && <AvatarImage src={profileAvatarURL(src, currentProfileAvatarContext())} alt="" />}
      <AvatarFallback>{Mark ? <Mark className="size-[62%]" /> : avatarInitials(name)}</AvatarFallback>
    </Avatar>
  )
}
