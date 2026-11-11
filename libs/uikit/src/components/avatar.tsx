import { Avatar as AvatarPrimitive } from '@base-ui/react/avatar'
import type * as React from 'react'

import { cn } from '../lib/utils'

/**
 * A picture of a person or a place, or its initials while there is no picture. It is 32px by default, 40px at `lg`,
 * 24px at `sm`, and 20px at `xs`, the size of a mark beside 12px text, whose initials take the 10px step. The avatar
 * is round unless the caller gives it another radius, such as the rounded square of an Agent; its picture, the fill
 * behind its initials, and its hairline edge all take the avatar's radius, so the avatar keeps one shape.
 */
function Avatar({
  className,
  size = 'default',
  ...props
}: AvatarPrimitive.Root.Props & {
  size?: 'default' | 'sm' | 'xs' | 'lg'
}) {
  return (
    <AvatarPrimitive.Root
      data-slot="avatar"
      data-size={size}
      className={cn(
        'group/avatar relative flex size-8 shrink-0 rounded-full select-none after:absolute after:inset-0 after:rounded-[inherit] after:border after:border-border after:mix-blend-darken data-[size=lg]:size-10 data-[size=sm]:size-6 data-[size=xs]:size-5 dark:after:mix-blend-lighten',
        className
      )}
      {...props}
    />
  )
}

function AvatarImage({ className, ...props }: AvatarPrimitive.Image.Props) {
  return (
    <AvatarPrimitive.Image
      data-slot="avatar-image"
      className={cn('aspect-square size-full rounded-[inherit] object-cover', className)}
      {...props}
    />
  )
}

function AvatarFallback({ className, ...props }: AvatarPrimitive.Fallback.Props) {
  return (
    <AvatarPrimitive.Fallback
      data-slot="avatar-fallback"
      className={cn(
        'flex size-full items-center justify-center rounded-[inherit] bg-muted text-sm text-muted-foreground group-data-[size=sm]/avatar:text-xs group-data-[size=xs]/avatar:text-25',
        className
      )}
      {...props}
    />
  )
}

function AvatarBadge({ className, ...props }: React.ComponentProps<'span'>) {
  return (
    <span
      data-slot="avatar-badge"
      className={cn(
        'absolute right-0 bottom-0 z-10 inline-flex items-center justify-center rounded-full bg-foreground text-background bg-blend-color ring-2 ring-background select-none',
        'group-data-[size=sm]/avatar:size-2 group-data-[size=sm]/avatar:[&>svg]:hidden',
        'group-data-[size=default]/avatar:size-2.5 group-data-[size=default]/avatar:[&>svg]:size-2',
        'group-data-[size=lg]/avatar:size-3 group-data-[size=lg]/avatar:[&>svg]:size-2',
        className
      )}
      {...props}
    />
  )
}

/**
 * A presence mark: a 4px dot centred 4px below its avatar. It paints in the current text colour, so the caller gives
 * each person their colour with a text utility or `style`.
 */
function AvatarDot({ className, ...props }: React.ComponentProps<'span'>) {
  return (
    <span
      data-slot="avatar-dot"
      aria-hidden
      className={cn('absolute -bottom-2 left-1/2 size-1 -translate-x-1/2 rounded-full bg-current', className)}
      {...props}
    />
  )
}

function AvatarGroup({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="avatar-group"
      className={cn(
        'group/avatar-group flex -space-x-2 *:data-[slot=avatar]:ring-2 *:data-[slot=avatar]:ring-background',
        className
      )}
      {...props}
    />
  )
}

function AvatarGroupCount({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="avatar-group-count"
      className={cn(
        'relative flex size-8 shrink-0 items-center justify-center rounded-full bg-muted text-sm text-muted-foreground ring-2 ring-background group-has-data-[size=lg]/avatar-group:size-10 group-has-data-[size=sm]/avatar-group:size-6 [&>svg]:size-4 group-has-data-[size=lg]/avatar-group:[&>svg]:size-5 group-has-data-[size=sm]/avatar-group:[&>svg]:size-3',
        className
      )}
      {...props}
    />
  )
}

export { Avatar, AvatarBadge, AvatarDot, AvatarFallback, AvatarGroup, AvatarGroupCount, AvatarImage }
