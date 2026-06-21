'use client'

import { Button } from '@/uikit/components/button'
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/uikit/components/tooltip'
import { cn } from '@/uikit/lib/utils'
import type { LucideIcon } from 'lucide-react'
import { XIcon } from 'lucide-react'
import type { ComponentProps, HTMLAttributes } from 'react'

export type ArtifactProps = HTMLAttributes<HTMLDivElement>

/**
 * Framed panel that shows a single agent-produced artifact (a document, a piece of code, a preview)
 * in the console. The header/title/actions/content pieces below compose inside it.
 */
export const Artifact = ({ className, ...props }: ArtifactProps) => (
  <div
    className={cn('flex flex-col overflow-hidden rounded-lg border bg-background shadow-sm', className)}
    {...props}
  />
)

export type ArtifactHeaderProps = HTMLAttributes<HTMLDivElement>

/** Top bar of the artifact panel; usually holds the title/description on the left and actions on the right. */
export const ArtifactHeader = ({ className, ...props }: ArtifactHeaderProps) => (
  <div className={cn('flex items-center justify-between border-b bg-muted/50 px-4 py-3', className)} {...props} />
)

export type ArtifactCloseProps = ComponentProps<typeof Button>

/** Icon button that closes/dismisses the artifact panel. Defaults to an X icon with a screen-reader label. */
export const ArtifactClose = ({
  className,
  children,
  size = 'sm',
  variant = 'ghost',
  ...props
}: ArtifactCloseProps) => (
  <Button
    className={cn('size-8 p-0 text-muted-foreground hover:text-foreground', className)}
    size={size}
    type="button"
    variant={variant}
    {...props}>
    {children ?? <XIcon className="size-4" />}
    <span className="sr-only">Close</span>
  </Button>
)

export type ArtifactTitleProps = HTMLAttributes<HTMLParagraphElement>

/** Artifact name shown in the header. */
export const ArtifactTitle = ({ className, ...props }: ArtifactTitleProps) => (
  <p className={cn('font-medium text-foreground text-sm', className)} {...props} />
)

export type ArtifactDescriptionProps = HTMLAttributes<HTMLParagraphElement>

/** Secondary muted line under the title, for a short artifact subtitle or status. */
export const ArtifactDescription = ({ className, ...props }: ArtifactDescriptionProps) => (
  <p className={cn('text-muted-foreground text-sm', className)} {...props} />
)

export type ArtifactActionsProps = HTMLAttributes<HTMLDivElement>

/** Right-side container in the header that groups the action buttons (copy, download, close, ...). */
export const ArtifactActions = ({ className, ...props }: ArtifactActionsProps) => (
  <div className={cn('flex items-center gap-1', className)} {...props} />
)

export type ArtifactActionProps = ComponentProps<typeof Button> & {
  tooltip?: string
  label?: string
  icon?: LucideIcon
}

/**
 * Single header action button (e.g. copy, download). The button is wrapped in a tooltip only when a
 * `tooltip` string is given; otherwise the bare button is returned to avoid an empty tooltip popup.
 */
export const ArtifactAction = ({
  tooltip,
  label,
  icon: Icon,
  children,
  className,
  size = 'sm',
  variant = 'ghost',
  ...props
}: ArtifactActionProps) => {
  const button = (
    <Button
      className={cn('size-8 p-0 text-muted-foreground hover:text-foreground', className)}
      size={size}
      type="button"
      variant={variant}
      {...props}>
      {Icon ? <Icon className="size-4" /> : children}
      <span className="sr-only">{label || tooltip}</span>
    </Button>
  )

  if (tooltip) {
    return (
      <TooltipProvider>
        <Tooltip>
          <TooltipTrigger>{button}</TooltipTrigger>
          <TooltipContent>
            <p>{tooltip}</p>
          </TooltipContent>
        </Tooltip>
      </TooltipProvider>
    )
  }

  return button
}

export type ArtifactContentProps = HTMLAttributes<HTMLDivElement>

/** Scrollable body of the panel that holds the actual artifact content. */
export const ArtifactContent = ({ className, ...props }: ArtifactContentProps) => (
  <div className={cn('flex-1 overflow-auto p-4', className)} {...props} />
)
