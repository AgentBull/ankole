import { mergeProps, renderElement, type RenderProp } from '@ui-sdk/react/primitive'
import type { ComponentProps, CSSProperties, ReactNode } from 'react'

import { cn } from '../lib/utils'
import { Progress } from './progress'

/** The hue of a column's status icon: the middle step of that palette hue. */
export type BoardTone = 'gray' | 'blue' | 'amber' | 'purple' | 'green' | 'red'

/** Surface emphasis for cards that require operator attention. */
export type BoardCardTone = 'default' | 'warning' | 'danger'

/** Semantic fill for a card's inline progress track. */
export type BoardProgressTone = 'info' | 'success' | 'warning' | 'danger'

const tones: Record<BoardTone, string> = {
  gray: 'var(--board-tone-gray)',
  blue: 'var(--board-tone-blue)',
  amber: 'var(--board-tone-amber)',
  purple: 'var(--board-tone-purple)',
  green: 'var(--board-tone-green)',
  red: 'var(--board-tone-red)'
}

const progressToneClasses: Record<BoardProgressTone, string> = {
  info: '[&_[data-slot=progress-indicator]]:bg-info',
  success: '[&_[data-slot=progress-indicator]]:bg-success',
  warning: '[&_[data-slot=progress-indicator]]:bg-(--board-progress-warning)',
  danger: '[&_[data-slot=progress-indicator]]:bg-destructive'
}

/**
 * A kanban board. Its columns share the width and wrap onto another row when they do not all fit, so a board
 * never scrolls sideways, even in the narrow column beside an open side panel.
 */
function Board({ className, ...props }: ComponentProps<'div'>) {
  return (
    <div
      data-slot="board"
      className={cn('grid grid-cols-[repeat(auto-fit,minmax(min(15.5rem,100%),1fr))] items-stretch gap-3.5', className)}
      {...props}
    />
  )
}

/**
 * One column of a board: a quiet recessed lane that holds its header and its cards. `dropTarget` marks the column
 * while a dragged card may land in it.
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
        'flex min-h-40 min-w-0 flex-col gap-2 rounded-surface border border-border-subtle/60 bg-layer-01 p-2.5 dark:border-white/8 dark:bg-white/[0.025]',
        'transition-[background-color,border-color,box-shadow] duration-(--duration-feedback)',
        'data-drop-target:border-primary/50 data-drop-target:bg-layer-hover data-drop-target:ring-2 data-drop-target:ring-primary/30',
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
      className={cn(
        'flex min-h-7 min-w-0 items-center gap-2 px-1 text-65 leading-5 font-semibold text-fg-primary',
        className
      )}
      style={{ ...style, '--board-tone': tones[tone] } as CSSProperties}
      {...props}>
      {icon && (
        <span aria-hidden className="flex shrink-0 text-(--board-tone) [&>svg]:size-4">
          {icon}
        </span>
      )}
      <span className="min-w-0 truncate">{children}</span>
      {count !== undefined && (
        <span className="rounded-full bg-overlay-secondary px-1.5 py-0.5 text-50 leading-3.5 font-medium text-fg-secondary tabular-nums">
          {count}
        </span>
      )}
      {actions && <span className="ms-auto flex shrink-0 items-center gap-0.5 font-normal">{actions}</span>}
    </h2>
  )
}

/** A quiet placeholder shown inside a column that currently holds no cards. */
function BoardColumnEmpty({ className, ...props }: ComponentProps<'div'>) {
  return (
    <div
      data-slot="board-column-empty"
      className={cn(
        'flex flex-1 flex-col items-center justify-center gap-1 rounded-surface border border-dashed border-border-subtle/60 px-3 py-8 text-center text-xs leading-4 text-fg-tertiary select-none',
        className
      )}
      {...props}
    />
  )
}

/**
 * A card on a board. `selected` marks the card whose details are open, and `tone` tints cards that need attention.
 * When `BoardCardTitle` renders as a `<button>` or `<a>`, its hit area stretches across the whole card while
 * independent controls inside the card stay operable above the stretched overlay.
 */
function BoardCard({
  selected = false,
  tone = 'default',
  className,
  ...props
}: ComponentProps<'article'> & { selected?: boolean; tone?: BoardCardTone }) {
  return (
    <article
      data-slot="board-card"
      data-selected={selected || undefined}
      data-tone={tone !== 'default' ? tone : undefined}
      className={cn(
        'group/board-card relative flex min-w-0 flex-col gap-1.5 rounded-surface border border-border-subtle/80 bg-page p-3 text-65 leading-5 shadow-[0_1px_2px_rgb(0_0_0/0.03)] dark:border-white/10 dark:bg-control dark:shadow-none',
        'transition-[border-color,box-shadow,background-color] duration-(--duration-feedback)',
        '[&_:is(a,button,input,select,textarea):not([data-slot=board-card-title])]:relative [&_:is(a,button,input,select,textarea):not([data-slot=board-card-title])]:z-1',
        'has-[[data-slot=board-card-title]:is(button,a):hover]:border-control-edge has-[[data-slot=board-card-title]:is(button,a):hover]:shadow-sm',
        'has-[[data-slot=board-card-title]:is(button,a):active]:bg-control-hover',
        'has-[[data-slot=board-card-title]:focus-visible]:outline-2 has-[[data-slot=board-card-title]:focus-visible]:outline-offset-2 has-[[data-slot=board-card-title]:focus-visible]:outline-ring',
        'data-[tone=warning]:border-(--board-warning-edge) data-[tone=warning]:bg-[linear-gradient(180deg,rgb(252_179_33/0.07),transparent_60%),var(--page)] dark:data-[tone=warning]:bg-[linear-gradient(180deg,rgb(252_179_33/0.09),transparent_65%),var(--control)]',
        'data-[tone=danger]:border-(--board-danger-edge) data-[tone=danger]:bg-[linear-gradient(180deg,rgb(245_62_41/0.06),transparent_60%),var(--page)] dark:data-[tone=danger]:bg-[linear-gradient(180deg,rgb(245_62_41/0.09),transparent_65%),var(--control)]',
        'data-selected:border-fg-primary/55 data-selected:shadow-sm data-selected:ring-2 data-selected:ring-fg-primary/10 dark:data-selected:border-white/55 dark:data-selected:ring-white/15',
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
      className={cn('flex min-h-5 min-w-0 items-center gap-1.5 text-xs leading-4 text-fg-tertiary', className)}
      {...props}
    />
  )
}

/** The title of a card, up to two lines. Render it as a button or link when clicking the card opens it. */
function BoardCardTitle({ className, render, ...props }: ComponentProps<'div'> & { render?: RenderProp }) {
  return renderElement(
    'div',
    mergeProps(
      {
        'data-slot': 'board-card-title',
        className: cn(
          'line-clamp-2 w-full rounded-mini text-start text-65 leading-4.75 font-medium break-words text-fg-primary',
          "[:is(button,a)&]:cursor-pointer [:is(button,a)&]:focus-visible:outline-none [:is(button,a)&]:after:absolute [:is(button,a)&]:after:inset-0 [:is(button,a)&]:after:rounded-surface [:is(button,a)&]:after:content-['']",
          className
        )
      },
      props
    ),
    render
  )
}

/** Supporting summary or outcome snippet beneath a card's title, clamped to two lines. */
function BoardCardDescription({ className, ...props }: ComponentProps<'p'>) {
  return (
    <p
      data-slot="board-card-description"
      className={cn('line-clamp-2 text-xs leading-4.25 break-words text-fg-secondary', className)}
      {...props}
    />
  )
}

/** Determinate progress row for multi-step work on a card. */
function BoardCardProgress({
  value,
  max,
  tone = 'info',
  label,
  'aria-label': ariaLabel,
  className,
  ...props
}: ComponentProps<'div'> & {
  value: number
  max: number
  tone?: BoardProgressTone
  label?: ReactNode
}) {
  return (
    <div data-slot="board-card-progress" className={cn('flex min-w-0 items-center gap-2 pt-0.5', className)} {...props}>
      <Progress
        value={value}
        max={max}
        aria-label={ariaLabel ?? (typeof label === 'string' ? label : undefined)}
        className={cn('min-w-0 flex-1 items-center', progressToneClasses[tone])}
      />
      {label !== undefined && (
        <span className="shrink-0 font-mono text-50 leading-4 text-fg-tertiary tabular-nums">{label}</span>
      )}
    </div>
  )
}

/** The last row of a card, for who does the work and when it last moved. */
function BoardCardFooter({ className, ...props }: ComponentProps<'div'>) {
  return (
    <div
      data-slot="board-card-footer"
      className={cn(
        'mt-auto flex min-h-5 min-w-0 items-center gap-1.5 pt-0.5 text-xs leading-4 text-fg-secondary',
        className
      )}
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
        'inline-flex h-7 max-w-full min-w-0 shrink-0 items-center gap-2 rounded-full border border-(--board-chip-edge) bg-(--board-chip) ps-1 pe-3 text-xs leading-4 font-medium text-fg-primary',
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
        'ms-auto flex shrink-0 items-center gap-1.5 text-50 leading-4 text-fg-tertiary tabular-nums',
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
  BoardCardDescription,
  BoardCardFooter,
  BoardCardHeader,
  BoardCardProgress,
  BoardCardTitle,
  BoardColumn,
  BoardColumnEmpty,
  BoardColumnHeader,
  BoardPresence
}
