'use client'

import { Button } from '@/uikit/components/button'
import { HoverCard, HoverCardContent, HoverCardTrigger } from '@/uikit/components/hover-card'
import { cn } from '@/uikit/lib/utils'
import type { FileUIPart, SourceDocumentUIPart } from '@/llm'
import { FileTextIcon, GlobeIcon, ImageIcon, Music2Icon, PaperclipIcon, VideoIcon, XIcon } from 'lucide-react'
import type { ComponentProps, HTMLAttributes, ReactNode } from 'react'
import { createContext, useCallback, useContext, useMemo } from 'react'

// ============================================================================
// Types
// ============================================================================

/** One attachment to render: either an uploaded file part or a cited source document, tagged with a stable id. */
export type AttachmentData = (FileUIPart & { id: string }) | (SourceDocumentUIPart & { id: string })

/** Coarse media bucket derived from an attachment's MIME type, used to pick an icon and a preview style. */
export type AttachmentMediaCategory = 'image' | 'video' | 'audio' | 'document' | 'source' | 'unknown'

/** Layout mode shared down the tree: `grid` = thumbnail tiles, `inline` = chips in a row, `list` = full-width rows. */
export type AttachmentVariant = 'grid' | 'inline' | 'list'

const mediaCategoryIcons: Record<AttachmentMediaCategory, typeof ImageIcon> = {
  audio: Music2Icon,
  document: FileTextIcon,
  image: ImageIcon,
  source: GlobeIcon,
  unknown: PaperclipIcon,
  video: VideoIcon
}

// ============================================================================
// Utility Functions
// ============================================================================

/** Maps an attachment to its coarse media bucket. Source documents are their own bucket; everything else
 * is classified by the MIME prefix, falling back to `unknown` when the type is missing or unrecognized. */
export const getMediaCategory = (data: AttachmentData): AttachmentMediaCategory => {
  if (data.type === 'source-document') {
    return 'source'
  }

  const mediaType = data.mediaType ?? ''

  if (mediaType.startsWith('image/')) {
    return 'image'
  }
  if (mediaType.startsWith('video/')) {
    return 'video'
  }
  if (mediaType.startsWith('audio/')) {
    return 'audio'
  }
  if (mediaType.startsWith('application/') || mediaType.startsWith('text/')) {
    return 'document'
  }

  return 'unknown'
}

/** Picks the best human label for an attachment, walking from the most specific field to a generic fallback. */
export const getAttachmentLabel = (data: AttachmentData): string => {
  if (data.type === 'source-document') {
    return data.title || data.filename || 'Source'
  }

  const category = getMediaCategory(data)
  return data.filename || (category === 'image' ? 'Image' : 'Attachment')
}

/** Renders an image preview at the right size for the layout: a large cover tile for `grid`, a tiny inline thumb otherwise. */
const renderAttachmentImage = (url: string, filename: string | undefined, isGrid: boolean) =>
  isGrid ? (
    <img alt={filename || 'Image'} className="size-full object-cover" height={96} src={url} width={96} />
  ) : (
    <img alt={filename || 'Image'} className="size-full rounded object-cover" height={20} src={url} width={20} />
  )

// ============================================================================
// Contexts
// ============================================================================

// The layout `variant` is chosen once on the container and read by every descendant, so it travels
// through context instead of being threaded as a prop through each subcomponent.
interface AttachmentsContextValue {
  variant: AttachmentVariant
}

const AttachmentsContext = createContext<AttachmentsContextValue | null>(null)

// Per-item context: the item's own data plus the derived category and remove handler, so the preview,
// info, and remove-button subcomponents can render without re-deriving any of it.
interface AttachmentContextValue {
  data: AttachmentData
  mediaCategory: AttachmentMediaCategory
  onRemove?: () => void
  variant: AttachmentVariant
}

const AttachmentContext = createContext<AttachmentContextValue | null>(null)

// ============================================================================
// Hooks
// ============================================================================

// Defaults to `grid` rather than throwing, so an <Attachment> can be rendered standalone (outside an
// <Attachments> container) and still has a sensible layout.
export const useAttachmentsContext = () => useContext(AttachmentsContext) ?? { variant: 'grid' as const }

// The per-item subcomponents genuinely cannot work without item context, so this one throws to surface
// misuse early instead of rendering empty.
export const useAttachmentContext = () => {
  const ctx = useContext(AttachmentContext)
  if (!ctx) {
    throw new Error('Attachment components must be used within <Attachment>')
  }
  return ctx
}

// ============================================================================
// Attachments - Container
// ============================================================================

export type AttachmentsProps = HTMLAttributes<HTMLDivElement> & {
  variant?: AttachmentVariant
}

/** Container for a set of attachments; publishes the chosen `variant` to its children and lays them out to match. */
export const Attachments = ({ variant = 'grid', className, children, ...props }: AttachmentsProps) => {
  const contextValue = useMemo(() => ({ variant }), [variant])

  return (
    <AttachmentsContext.Provider value={contextValue}>
      <div
        className={cn(
          'flex items-start',
          variant === 'list' ? 'flex-col gap-2' : 'flex-wrap gap-2',
          variant === 'grid' && 'ml-auto w-fit',
          className
        )}
        {...props}>
        {children}
      </div>
    </AttachmentsContext.Provider>
  )
}

// ============================================================================
// Attachment - Item
// ============================================================================

export type AttachmentProps = HTMLAttributes<HTMLDivElement> & {
  data: AttachmentData
  onRemove?: () => void
}

/** A single attachment item. Derives its media category once and exposes it (plus the remove handler) to
 * the preview/info/remove subcomponents via context. The styling switches on the inherited layout variant. */
export const Attachment = ({ data, onRemove, className, children, ...props }: AttachmentProps) => {
  const { variant } = useAttachmentsContext()
  const mediaCategory = getMediaCategory(data)

  const contextValue = useMemo<AttachmentContextValue>(
    () => ({ data, mediaCategory, onRemove, variant }),
    [data, mediaCategory, onRemove, variant]
  )

  return (
    <AttachmentContext.Provider value={contextValue}>
      <div
        className={cn(
          'group relative',
          variant === 'grid' && 'size-24 overflow-hidden rounded-lg',
          variant === 'inline' && [
            'flex h-8 cursor-pointer select-none items-center gap-1.5',
            'rounded-md border border-border px-1.5',
            'font-medium text-sm transition-all',
            'hover:bg-accent hover:text-accent-foreground dark:hover:bg-accent/50'
          ],
          variant === 'list' && ['flex w-full items-center gap-3 rounded-lg border p-3', 'hover:bg-accent/50'],
          className
        )}
        {...props}>
        {children}
      </div>
    </AttachmentContext.Provider>
  )
}

// ============================================================================
// AttachmentPreview - Media preview
// ============================================================================

export type AttachmentPreviewProps = HTMLAttributes<HTMLDivElement> & {
  fallbackIcon?: ReactNode
}

/** Visual thumbnail for an item: shows the real image/video when a URL is available, and otherwise falls
 * back to a category icon (or a caller-supplied one). The frame size tracks the layout variant. */
export const AttachmentPreview = ({ fallbackIcon, className, ...props }: AttachmentPreviewProps) => {
  const { data, mediaCategory, variant } = useAttachmentContext()

  const iconSize = variant === 'inline' ? 'size-3' : 'size-4'

  const renderIcon = (Icon: typeof ImageIcon) => <Icon className={cn(iconSize, 'text-muted-foreground')} />

  // Only render real media when the part is a file that actually carries a URL; source documents and
  // url-less files drop through to the icon fallback.
  const renderContent = () => {
    if (mediaCategory === 'image' && data.type === 'file' && data.url) {
      return renderAttachmentImage(data.url, data.filename, variant === 'grid')
    }

    if (mediaCategory === 'video' && data.type === 'file' && data.url) {
      return <video className="size-full object-cover" muted src={data.url} />
    }

    const Icon = mediaCategoryIcons[mediaCategory]
    return fallbackIcon ?? renderIcon(Icon)
  }

  return (
    <div
      className={cn(
        'flex shrink-0 items-center justify-center overflow-hidden',
        variant === 'grid' && 'size-full bg-muted',
        variant === 'inline' && 'size-5 rounded bg-background',
        variant === 'list' && 'size-12 rounded bg-muted',
        className
      )}
      {...props}>
      {renderContent()}
    </div>
  )
}

// ============================================================================
// AttachmentInfo - Name and type display
// ============================================================================

export type AttachmentInfoProps = HTMLAttributes<HTMLDivElement> & {
  showMediaType?: boolean
}

/** Text column for an item: the attachment label and, optionally, its MIME type. */
export const AttachmentInfo = ({ showMediaType = false, className, ...props }: AttachmentInfoProps) => {
  const { data, variant } = useAttachmentContext()
  const label = getAttachmentLabel(data)

  // Grid tiles are image-only thumbnails with no room for text, so the info row is suppressed there.
  if (variant === 'grid') {
    return null
  }

  return (
    <div className={cn('min-w-0 flex-1', className)} {...props}>
      <span className="block truncate">{label}</span>
      {showMediaType && data.mediaType && (
        <span className="block truncate text-muted-foreground text-xs">{data.mediaType}</span>
      )}
    </div>
  )
}

// ============================================================================
// AttachmentRemove - Remove button
// ============================================================================

export type AttachmentRemoveProps = ComponentProps<typeof Button> & {
  label?: string
}

/** Remove button shown on an item. Renders nothing when no `onRemove` was provided, so read-only
 * attachment lists stay free of dead controls. */
export const AttachmentRemove = ({ label = 'Remove', className, children, ...props }: AttachmentRemoveProps) => {
  const { onRemove, variant } = useAttachmentContext()

  const handleClick = useCallback(
    (e: React.MouseEvent) => {
      // The whole item is clickable in inline/list mode; stop the click here so removing does not also
      // trigger the item's own open/select handler.
      e.stopPropagation()
      onRemove?.()
    },
    [onRemove]
  )

  if (!onRemove) {
    return null
  }

  return (
    <Button
      aria-label={label}
      className={cn(
        variant === 'grid' && [
          'absolute top-2 right-2 size-6 rounded-full p-0',
          'bg-background/80 backdrop-blur-sm',
          'opacity-0 transition-opacity group-hover:opacity-100',
          'hover:bg-background',
          '[&>svg]:size-3'
        ],
        variant === 'inline' && [
          'size-5 rounded p-0',
          'opacity-0 transition-opacity group-hover:opacity-100',
          '[&>svg]:size-2.5'
        ],
        variant === 'list' && ['size-8 shrink-0 rounded p-0', '[&>svg]:size-4'],
        className
      )}
      onClick={handleClick}
      type="button"
      variant="ghost"
      {...props}>
      {children ?? <XIcon />}
      <span className="sr-only">{label}</span>
    </Button>
  )
}

// ============================================================================
// AttachmentHoverCard - Hover preview
// ============================================================================

export type AttachmentHoverCardProps = ComponentProps<typeof HoverCard>

/** Hover card used to show a larger preview of an attachment on hover. Open/close delays default to 0 so
 * the preview appears and disappears immediately rather than after the usual hover-intent delay. */
export const AttachmentHoverCard = ({ openDelay = 0, closeDelay = 0, ...props }: AttachmentHoverCardProps) => (
  <HoverCard closeDelay={closeDelay} openDelay={openDelay} {...props} />
)

export type AttachmentHoverCardTriggerProps = ComponentProps<typeof HoverCardTrigger>

/** Element that opens the attachment hover preview when pointed at. */
export const AttachmentHoverCardTrigger = (props: AttachmentHoverCardTriggerProps) => <HoverCardTrigger {...props} />

export type AttachmentHoverCardContentProps = ComponentProps<typeof HoverCardContent>

/** Floating panel content for the attachment hover preview. */
export const AttachmentHoverCardContent = ({
  align = 'start',
  className,
  ...props
}: AttachmentHoverCardContentProps) => (
  <HoverCardContent align={align} className={cn('w-auto p-2', className)} {...props} />
)

// ============================================================================
// AttachmentEmpty - Empty state
// ============================================================================

export type AttachmentEmptyProps = HTMLAttributes<HTMLDivElement>

/** Placeholder shown in place of the list when there are no attachments. */
export const AttachmentEmpty = ({ className, children, ...props }: AttachmentEmptyProps) => (
  <div className={cn('flex items-center justify-center p-4 text-muted-foreground text-sm', className)} {...props}>
    {children ?? 'No attachments'}
  </div>
)
