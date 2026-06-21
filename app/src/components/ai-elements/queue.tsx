'use client'

import { Button } from '@/uikit/components/button'
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@/uikit/components/collapsible'
import { ScrollArea } from '@/uikit/components/scroll-area'
import { cn } from '@/uikit/lib/utils'
import { ChevronDownIcon, PaperclipIcon } from 'lucide-react'
import type { ComponentProps } from 'react'

// The Queue family renders the agent's pending-work panel: queued user messages and a to-do list,
// grouped into collapsible sections. These components are the presentation layer only — the shapes
// below describe the data the host feeds in.

/** One content part of a queued message (text, or a file/image reference). Mirrors the SDK message part. */
export interface QueueMessagePart {
  type: string
  text?: string
  url?: string
  filename?: string
  mediaType?: string
}

/** A message waiting in the send queue, identified for list keys. */
export interface QueueMessage {
  id: string
  parts: QueueMessagePart[]
}

/** A single to-do entry; `status` drives the struck-through "completed" styling. */
export interface QueueTodo {
  id: string
  title: string
  description?: string
  status?: 'pending' | 'completed'
}

export type QueueItemProps = ComponentProps<'li'>

/** A row in the queue list; hover reveals its row actions (see {@link QueueItemAction}). */
export const QueueItem = ({ className, ...props }: QueueItemProps) => (
  <li
    className={cn('group flex flex-col gap-1 rounded-md px-3 py-1 text-sm transition-colors hover:bg-muted', className)}
    {...props}
  />
)

export type QueueItemIndicatorProps = ComponentProps<'span'> & {
  completed?: boolean
}

/** Small status dot at the start of a row; dimmed/filled when `completed`. */
export const QueueItemIndicator = ({ completed = false, className, ...props }: QueueItemIndicatorProps) => (
  <span
    className={cn(
      'mt-0.5 inline-block size-2.5 rounded-full border',
      completed ? 'border-muted-foreground/20 bg-muted-foreground/10' : 'border-muted-foreground/50',
      className
    )}
    {...props}
  />
)

export type QueueItemContentProps = ComponentProps<'span'> & {
  completed?: boolean
}

/** Primary line of a row, clamped to one line; struck through when `completed`. */
export const QueueItemContent = ({ completed = false, className, ...props }: QueueItemContentProps) => (
  <span
    className={cn(
      'line-clamp-1 grow break-words',
      completed ? 'text-muted-foreground/50 line-through' : 'text-muted-foreground',
      className
    )}
    {...props}
  />
)

export type QueueItemDescriptionProps = ComponentProps<'div'> & {
  completed?: boolean
}

/** Secondary line under the content, indented to align past the indicator. */
export const QueueItemDescription = ({ completed = false, className, ...props }: QueueItemDescriptionProps) => (
  <div
    className={cn(
      'ml-6 text-xs',
      completed ? 'text-muted-foreground/40 line-through' : 'text-muted-foreground',
      className
    )}
    {...props}
  />
)

export type QueueItemActionsProps = ComponentProps<'div'>

/** Container for a row's action buttons (e.g. remove/edit). */
export const QueueItemActions = ({ className, ...props }: QueueItemActionsProps) => (
  <div className={cn('flex gap-1', className)} {...props} />
)

export type QueueItemActionProps = Omit<ComponentProps<typeof Button>, 'variant' | 'size'>

/** A single row action button. Hidden until the row is hovered (`group-hover` reveals it) to keep rows clean. */
export const QueueItemAction = ({ className, ...props }: QueueItemActionProps) => (
  <Button
    className={cn(
      'size-auto rounded p-1 text-muted-foreground opacity-0 transition-opacity hover:bg-muted-foreground/10 hover:text-foreground group-hover:opacity-100',
      className
    )}
    size="icon"
    type="button"
    variant="ghost"
    {...props}
  />
)

export type QueueItemAttachmentProps = ComponentProps<'div'>

/** Wrapping strip that holds a queued message's image thumbnails and file chips. */
export const QueueItemAttachment = ({ className, ...props }: QueueItemAttachmentProps) => (
  <div className={cn('mt-1 flex flex-wrap gap-2', className)} {...props} />
)

export type QueueItemImageProps = ComponentProps<'img'>

/** Thumbnail for an image attachment. `alt` is intentionally empty: it is decorative next to the filename. */
export const QueueItemImage = ({ className, ...props }: QueueItemImageProps) => (
  <img alt="" className={cn('h-8 w-8 rounded border object-cover', className)} height={32} width={32} {...props} />
)

export type QueueItemFileProps = ComponentProps<'span'>

/** Chip for a non-image file attachment: paperclip icon plus a truncated filename. */
export const QueueItemFile = ({ children, className, ...props }: QueueItemFileProps) => (
  <span className={cn('flex items-center gap-1 rounded border bg-muted px-2 py-1 text-xs', className)} {...props}>
    <PaperclipIcon size={12} />
    <span className="max-w-[100px] truncate">{children}</span>
  </span>
)

export type QueueListProps = ComponentProps<typeof ScrollArea>

/** Scrollable `<ul>` of queue rows, capped at a fixed height so a long queue scrolls rather than growing the panel. */
export const QueueList = ({ children, className, ...props }: QueueListProps) => (
  <ScrollArea className={cn('mt-2 -mb-1', className)} {...props}>
    <div className="max-h-40 pr-4">
      <ul>{children}</ul>
    </div>
  </ScrollArea>
)

/** Collapsible section grouping related rows (e.g. "Queued" vs "Done"); open by default. */
export type QueueSectionProps = ComponentProps<typeof Collapsible>

export const QueueSection = ({ className, defaultOpen = true, ...props }: QueueSectionProps) => (
  <Collapsible className={cn(className)} defaultOpen={defaultOpen} {...props} />
)

/** Header button that toggles a {@link QueueSection}; the chevron in its label rotates with open state. */
export type QueueSectionTriggerProps = ComponentProps<'button'>

export const QueueSectionTrigger = ({ children, className, ...props }: QueueSectionTriggerProps) => (
  <CollapsibleTrigger
    render={
      <button
        className={cn(
          'group flex w-full items-center justify-between rounded-md bg-muted/40 px-3 py-2 text-left font-medium text-muted-foreground text-sm transition-colors hover:bg-muted',
          className
        )}
        type="button"
        {...props}
      />
    }>
    {children}
  </CollapsibleTrigger>
)

/**
 * Label inside a section trigger: a disclosure chevron (rotates when the section is collapsed), an
 * optional icon, and a "{count} {label}" caption such as "3 queued".
 */
export type QueueSectionLabelProps = ComponentProps<'span'> & {
  count?: number
  label: string
  icon?: React.ReactNode
}

export const QueueSectionLabel = ({ count, label, icon, className, ...props }: QueueSectionLabelProps) => (
  <span className={cn('flex items-center gap-2', className)} {...props}>
    <ChevronDownIcon className="size-4 transition-transform group-data-[state=closed]:-rotate-90" />
    {icon}
    <span>
      {count} {label}
    </span>
  </span>
)

/** Collapsible body of a {@link QueueSection}, holding its {@link QueueList}. */
export type QueueSectionContentProps = ComponentProps<typeof CollapsibleContent>

export const QueueSectionContent = ({ className, ...props }: QueueSectionContentProps) => (
  <CollapsibleContent className={cn(className)} {...props} />
)

export type QueueProps = ComponentProps<'div'>

/** Outermost card that frames the whole pending-work queue panel. */
export const Queue = ({ className, ...props }: QueueProps) => (
  <div
    className={cn(
      'flex flex-col gap-2 rounded-xl border border-border bg-background px-3 pt-2 pb-2 shadow-xs',
      className
    )}
    {...props}
  />
)
