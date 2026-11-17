import {
  ScrollArea as ScrollAreaPrimitive,
  ScrollAreaCorner,
  ScrollAreaScrollbar,
  ScrollAreaThumb,
  ScrollAreaViewport
} from '@ui-sdk/react/scroll-area'
import type * as React from 'react'

import { cn } from '../lib/utils'

/** A scroll area whose scrollbar shows whenever its content overflows. */
function ScrollArea({
  className,
  children,
  type = 'auto',
  ...props
}: React.ComponentProps<typeof ScrollAreaPrimitive>) {
  return (
    <ScrollAreaPrimitive type={type} data-slot="scroll-area" className={cn('relative', className)} {...props}>
      <ScrollAreaViewport
        data-slot="scroll-area-viewport"
        className="size-full rounded-[inherit] transition-[color,box-shadow] focus-visible:-outline-offset-2">
        {children}
      </ScrollAreaViewport>
      <ScrollBar />
      <ScrollAreaCorner />
    </ScrollAreaPrimitive>
  )
}

function ScrollBar({
  className,
  orientation = 'vertical',
  ...props
}: React.ComponentProps<typeof ScrollAreaScrollbar>) {
  return (
    <ScrollAreaScrollbar
      data-slot="scroll-area-scrollbar"
      orientation={orientation}
      className={cn(
        'flex touch-none p-px transition-colors select-none data-[orientation=horizontal]:h-2.5 data-[orientation=horizontal]:flex-col data-[orientation=horizontal]:border-t data-[orientation=horizontal]:border-t-transparent data-[orientation=vertical]:h-full data-[orientation=vertical]:w-2.5 data-[orientation=vertical]:border-l data-[orientation=vertical]:border-l-transparent',
        className
      )}
      {...props}>
      <ScrollAreaThumb data-slot="scroll-area-thumb" className="relative flex-1 rounded-full bg-border-subtle" />
    </ScrollAreaScrollbar>
  )
}

export { ScrollArea, ScrollBar }
