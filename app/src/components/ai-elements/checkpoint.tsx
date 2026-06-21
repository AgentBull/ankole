'use client'

import { Button } from '@/uikit/components/button'
import { Separator } from '@/uikit/components/separator'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/uikit/components/tooltip'
import { cn } from '@/uikit/lib/utils'
import type { LucideProps } from 'lucide-react'
import { BookmarkIcon } from 'lucide-react'
import type { ComponentProps, HTMLAttributes } from 'react'

export type CheckpointProps = HTMLAttributes<HTMLDivElement>

/** Inline divider row marking a saved checkpoint in the conversation (a point a run can be restored to);
 * the trailing separator draws the line out to fill the remaining width. */
export const Checkpoint = ({ className, children, ...props }: CheckpointProps) => (
  <div className={cn('flex items-center gap-0.5 overflow-hidden text-muted-foreground', className)} {...props}>
    {children}
    <Separator />
  </div>
)

export type CheckpointIconProps = LucideProps

/** Checkpoint marker icon, defaulting to a bookmark; a passed child overrides it. */
export const CheckpointIcon = ({ className, children, ...props }: CheckpointIconProps) =>
  children ?? <BookmarkIcon className={cn('size-4 shrink-0', className)} {...props} />

export type CheckpointTriggerProps = ComponentProps<typeof Button> & {
  tooltip?: string
}

/** Clickable label for the checkpoint (e.g. "restore here"); wrapped in a tooltip only when `tooltip` is set. */
export const CheckpointTrigger = ({
  children,
  variant = 'ghost',
  size = 'sm',
  tooltip,
  ...props
}: CheckpointTriggerProps) =>
  tooltip ? (
    <Tooltip>
      <TooltipTrigger render={<Button size={size} type="button" variant={variant} {...props} />}>
        {children}
      </TooltipTrigger>
      <TooltipContent align="start" side="bottom">
        {tooltip}
      </TooltipContent>
    </Tooltip>
  ) : (
    <Button size={size} type="button" variant={variant} {...props}>
      {children}
    </Button>
  )
