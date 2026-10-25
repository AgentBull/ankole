import { Avatar, AvatarImage, AvatarFallback, cn } from '@ankole/uikit'

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
  const words = name.trim().split(/\s+/)
  const initials =
    (words.length > 1
      ? words
          .slice(0, 2)
          .map(word => Array.from(word)[0])
          .join('')
      : Array.from(name.trim()).slice(0, 2).join('')
    ).toLocaleUpperCase() || '?'
  return (
    <Avatar
      aria-hidden
      title={name}
      size="sm"
      className={cn('pod-chat-avatar', agent && 'pod-chat-avatar-agent', className)}>
      {src && <AvatarImage src={src} alt="" />}
      <AvatarFallback>{initials}</AvatarFallback>
    </Avatar>
  )
}
