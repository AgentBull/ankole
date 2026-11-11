import { mergeProps } from '@base-ui/react/merge-props'
import { useRender } from '@base-ui/react/use-render'
import type { ComponentProps, CSSProperties, ReactNode } from 'react'

import { cn } from '../lib/utils'

/** The hue of a column's status icon: the middle step of that palette hue. */
export type BoardTone = 'gray' | 'blue' | 'amber' | 'purple' | 'green' | 'red'

const tones: Record<BoardTone, string> = {
  gray: 'var(--color-gray-50)',
  blue: 'var(--color-blue-50)',
  amber: 'var(--color-amber-50)',
  purple: 'var(--color-purple-50)',
  green: 'var(--color-green-50)',
  red: 'var(--color-red-50)'
}

/**
 * A kanban board. Its columns share the width and wrap onto another row when they do not all fit, so a board
 * never scrolls sideways, even in the narrow column beside an open side panel.
 */
function Board({ className, ...props }: ComponentProps<'div'>) {
  return (
    <div
      data-slot="board"
      className={cn('grid grid-cols-[repeat(auto-fit,minmax(min(10.5rem,100%),1fr))] items-start gap-3', className)}
      {...props}
    />
  )
}

/**
 * One column of a board: a quiet surface that holds its header and its cards. `dropTarget` marks the column while
 * a dragged card may land in it.
 */
function BoardColumn({
  dropTarget = false,
  className,
  ...props
}: ComponentProps<'section'> & { dropTarget?: boolean }) {
  return (
    <section
      data-slot="board-column"
      data-drop-target={dropTarget || undefined}
      className={cn(
        'flex min-h-24 min-w-0 flex-col gap-2 rounded-surface bg-background-secondary p-2',
        'transition-[background-color,box-shadow] duration-(--duration-feedback)',
        'data-drop-target:bg-accent data-drop-target:ring-2 data-drop-target:ring-primary/40',
        className
      )}
      {...props}
    />
  )
}

/**
 * The header of a column: the status icon in its tone, the column's title, the number of cards, and the column's
 * actions at the end.
 */
function BoardColumnHeader({
  icon,
  tone = 'gray',
  count,
  actions,
  className,
  style,
  children,
  ...props
}: ComponentProps<'h2'> & { icon?: ReactNode; tone?: BoardTone; count?: number; actions?: ReactNode }) {
  return (
    <h2
      data-slot="board-column-header"
      className={cn('flex min-h-7 min-w-0 items-center gap-2 px-1.5 text-sm leading-5 font-semibold', className)}
      style={{ ...style, '--board-tone': tones[tone] } as CSSProperties}
      {...props}>
      {icon && (
        <span aria-hidden className="flex shrink-0 text-(--board-tone) [&>svg]:size-4">
          {icon}
        </span>
      )}
      <span className="min-w-0 truncate">{children}</span>
      {count !== undefined && <span className="font-normal text-fg-tertiary tabular-nums">{count}</span>}
      {actions && <span className="ms-auto flex shrink-0 items-center gap-1 font-normal">{actions}</span>}
    </h2>
  )
}

/** A card on a board. `selected` marks the card whose details are open. */
function BoardCard({ selected = false, className, ...props }: ComponentProps<'article'> & { selected?: boolean }) {
  return (
    <article
      data-slot="board-card"
      data-selected={selected || undefined}
      className={cn(
        'group/board-card flex min-w-0 flex-col gap-1.5 rounded-surface border border-border bg-card p-3 text-[13px] leading-5',
        'transition-[border-color,box-shadow] duration-(--duration-feedback) hover:shadow-sm',
        'data-selected:border-primary data-selected:ring-1 data-selected:ring-primary',
        className
      )}
      {...props}
    />
  )
}

/** The first row of a card, for what the card is and how its work runs right now. */
function BoardCardHeader({ className, ...props }: ComponentProps<'div'>) {
  return (
    <div
      data-slot="board-card-header"
      className={cn('flex min-h-5 min-w-0 items-center gap-2 text-xs leading-4 text-fg-tertiary', className)}
      {...props}
    />
  )
}

/** The title of a card, up to two lines. Render it as a button when the title opens the card. */
function BoardCardTitle({ className, render, ...props }: useRender.ComponentProps<'div'>) {
  return useRender({
    defaultTagName: 'div',
    props: mergeProps<'div'>(
      {
        className: cn(
          'line-clamp-2 w-full rounded-mini text-start text-[15px] leading-[22px] font-medium break-words text-foreground',
          'focus-visible:outline-2 focus-visible:outline-ring enabled:cursor-pointer enabled:hover:underline',
          className
        )
      },
      props
    ),
    render,
    state: { slot: 'board-card-title' }
  })
}

/** The last row of a card, for who does the work. */
function BoardCardFooter({ className, ...props }: ComponentProps<'div'>) {
  return (
    <div
      data-slot="board-card-footer"
      className={cn('flex min-h-6 min-w-0 items-center gap-2 text-[13px] leading-5 text-fg-secondary', className)}
      {...props}
    />
  )
}

/**
 * A card's own controls, such as Stop. They take their place while the card is hovered or holds focus, and always
 * on a touch screen, so a quiet card keeps its actions within reach without giving up its room. Keyboard focus on
 * the card's title reveals them before Tab reaches them.
 */
function BoardCardActions({ className, ...props }: ComponentProps<'span'>) {
  return (
    <span
      data-slot="board-card-actions"
      className={cn(
        'hidden shrink-0 items-center gap-0.5',
        'group-hover/board-card:flex group-focus-within/board-card:flex [@media(hover:none)]:flex',
        className
      )}
      {...props}
    />
  )
}

/** A pill that names who is working on a board right now, led by their avatars. */
function BoardPresence({ avatars, className, children, ...props }: ComponentProps<'span'> & { avatars?: ReactNode }) {
  return (
    <span
      data-slot="board-presence"
      className={cn(
        'inline-flex h-7 max-w-full min-w-0 shrink-0 items-center gap-2 rounded-full bg-badge-blue ps-1 pe-3 text-xs leading-4 text-foreground',
        className
      )}
      {...props}>
      {avatars && <span className="flex shrink-0 items-center gap-0.5">{avatars}</span>}
      <span className="min-w-0 truncate">{children}</span>
    </span>
  )
}

/** The trailing fact of a card's row, such as when the work last moved. */
function BoardCardAside({ className, ...props }: ComponentProps<'span'>) {
  return (
    <span
      data-slot="board-card-aside"
      className={cn(
        'ms-auto flex shrink-0 items-center gap-1.5 text-xs leading-4 text-fg-tertiary tabular-nums',
        className
      )}
      {...props}
    />
  )
}

export {
  Board,
  BoardCard,
  BoardCardActions,
  BoardCardAside,
  BoardCardFooter,
  BoardCardHeader,
  BoardCardTitle,
  BoardColumn,
  BoardColumnHeader,
  BoardPresence
}
