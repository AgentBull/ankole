import { Avatar, AvatarImage, AvatarFallback, cn } from '@ankole/uikit'
import { avatarInitials } from '../avatar-initials'
import { currentProfileAvatarContext, profileAvatarURL } from '../native-transfers'

export { avatarInitials }

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
      <AvatarFallback>{avatarInitials(name)}</AvatarFallback>
    </Avatar>
  )
}
