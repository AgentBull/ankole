import { Avatar, AvatarImage, AvatarFallback, cn } from '@ankole/uikit'
import { BotRegular } from '@ankole/uikit/icons'
import { avatarInitials } from '../avatar-initials'
import { currentProfileAvatarContext, profileAvatarURL } from '../native-transfers'

export { avatarInitials }

/**
 * A chat member's avatar: the uploaded picture, or else the initials of a person's name or an Agent's bot mark. An
 * Agent's name often starts with its owner's name, as a personal assistant's does, so its initials would read as the
 * owner's avatar.
 */
export function ChatAvatar({
  name,
  src,
  agent = false,
  size = 'sm',
  className
}: {
  name: string
  src?: string | null
  agent?: boolean
  /** The kit avatar size: 24px by default, 32px beside a message, 20px beside a line of 12px text. */
  size?: 'default' | 'sm' | 'xs'
  className?: string
}) {
  return (
    <Avatar
      aria-hidden
      title={name}
      size={size}
      className={cn('pod-chat-avatar', agent && 'pod-chat-avatar-agent', className)}>
      {src && <AvatarImage src={profileAvatarURL(src, currentProfileAvatarContext())} alt="" />}
      <AvatarFallback>{agent ? <BotRegular className="size-[62%]" /> : avatarInitials(name)}</AvatarFallback>
    </Avatar>
  )
}
