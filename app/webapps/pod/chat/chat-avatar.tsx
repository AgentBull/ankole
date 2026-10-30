import { Avatar, AvatarImage, AvatarFallback, cn } from '@ankole/uikit'
import { avatarInitials } from '../avatar-initials'

export { avatarInitials }

export function ChatAvatar({
  name,
  src,
  agent = false,
  className
}: {
  name: string
  src?: string | null
  agent?: boolean
  className?: string
}) {
  return (
    <Avatar
      aria-hidden
      title={name}
      size="sm"
      className={cn('pod-chat-avatar', agent && 'pod-chat-avatar-agent', className)}>
      {src && <AvatarImage src={src} alt="" />}
      <AvatarFallback>{avatarInitials(name)}</AvatarFallback>
    </Avatar>
  )
}
