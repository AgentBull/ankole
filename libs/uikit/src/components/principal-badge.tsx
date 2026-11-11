import { BotRegular } from '../icons'
import type * as React from 'react'

import { cn } from '../lib/utils'
import { Avatar, AvatarFallback, AvatarImage } from './avatar'
import { Badge } from './badge'

export type PrincipalKind = 'human' | 'agent'

export type PrincipalBadgeProps = React.ComponentProps<'span'> & {
  uid: string
  name?: string | null
  kind?: PrincipalKind
  avatarUrl?: string | null
  size?: 'sm' | 'default'
  showUid?: boolean
  agentLabel?: string
}

export function principalInitials(nameOrUid: string): string {
  const clean = nameOrUid.trim().replace(/^@/, '')
  if (!clean) return '?'
  const parts = clean.split(/[\s._-]+/).filter(Boolean)
  if (parts.length >= 2) {
    return `${Array.from(parts[0]!)[0] ?? ''}${Array.from(parts[1]!)[0] ?? ''}`.toUpperCase()
  }
  return Array.from(clean).slice(0, 2).join('').toUpperCase()
}

export function PrincipalBadge({
  uid,
  name,
  kind = 'human',
  avatarUrl,
  size = 'sm',
  showUid = false,
  agentLabel = 'AI',
  className,
  ...props
}: PrincipalBadgeProps) {
  const displayName = name?.trim() || uid
  return (
    <span
      data-slot="principal-badge"
      data-kind={kind}
      className={cn('inline-flex max-w-full min-w-0 items-center gap-1.5 align-middle', className)}
      {...props}>
      <Avatar size={size === 'sm' ? 'sm' : 'default'}>
        {avatarUrl ? <AvatarImage src={avatarUrl} alt="" /> : null}
        <AvatarFallback>
          {kind === 'agent' ? (
            <BotRegular aria-hidden="true" className="size-3.5 text-muted-foreground" />
          ) : (
            principalInitials(displayName)
          )}
        </AvatarFallback>
      </Avatar>
      <span className="truncate text-sm font-medium text-foreground">{displayName}</span>
      {showUid && displayName !== uid && <span className="truncate text-xs text-muted-foreground">@{uid}</span>}
      {kind === 'agent' && agentLabel && (
        <Badge variant="secondary" className="shrink-0 px-1.5 py-0 text-[10px]">
          {agentLabel}
        </Badge>
      )}
    </span>
  )
}
