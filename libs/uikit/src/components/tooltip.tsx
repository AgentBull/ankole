import {
  TooltipContent as TooltipContentPrimitive,
  Tooltip as TooltipPrimitive,
  TooltipTrigger as TooltipTriggerPrimitive
} from '@ui-sdk/react/tooltip'
import type * as React from 'react'

import { usePopupContainer } from '../lib/popup-container'
import { cn } from '../lib/utils'

/**
 * ui-sdk groups tooltips without a provider: once one tooltip is open, or was open a moment ago, a neighbouring
 * tooltip opens at once. The kit keeps `TooltipProvider` so that existing layouts can wrap a region in it, and the
 * provider renders only its children.
 */
function TooltipProvider({ children }: { children?: React.ReactNode }) {
  return children
}

// A hovered tooltip opens after this delay, and keyboard focus opens a tooltip immediately.
function Tooltip({ container, delay = 400, ...props }: React.ComponentProps<typeof TooltipPrimitive>) {
  return <TooltipPrimitive container={usePopupContainer(container)} delay={delay} {...props} />
}

function TooltipTrigger(props: React.ComponentProps<typeof TooltipTriggerPrimitive>) {
  return <TooltipTriggerPrimitive {...props} />
}

function TooltipContent({
  className,
  side = 'top',
  sideOffset = 4,
  align = 'center',
  alignOffset = 0,
  ...props
}: React.ComponentProps<typeof TooltipContentPrimitive>) {
  return (
    <TooltipContentPrimitive
      align={align}
      alignOffset={alignOffset}
      side={side}
      sideOffset={sideOffset}
      className={cn(
        'ceramic z-50 inline-flex w-fit [--ceramic-radius:var(--ceramic-radius-tip)] max-w-xs origin-(--transform-origin) items-center gap-1.5 px-3 py-1.5 text-xs text-fg-primary has-data-[slot=kbd]:pr-1.5 transition-opacity duration-(--duration-tooltip) ease-out data-instant:transition-none **:data-[slot=kbd]:relative **:data-[slot=kbd]:isolate **:data-[slot=kbd]:z-50 data-starting-style:opacity-0 data-ending-style:opacity-0',
        className
      )}
      {...props}
    />
  )
}

export { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger }
