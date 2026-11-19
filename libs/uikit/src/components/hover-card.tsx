'use client'

import {
  HoverCardContent as HoverCardContentPrimitive,
  HoverCard as HoverCardPrimitive,
  HoverCardTrigger as HoverCardTriggerPrimitive
} from '@ui-sdk/react/hover-card'
import type * as React from 'react'

import { usePopupContainer } from '../lib/popup-container'
import { cn } from '../lib/utils'

function HoverCard({ container, ...props }: React.ComponentProps<typeof HoverCardPrimitive>) {
  return <HoverCardPrimitive container={usePopupContainer(container)} {...props} />
}

function HoverCardTrigger(props: React.ComponentProps<typeof HoverCardTriggerPrimitive>) {
  return <HoverCardTriggerPrimitive {...props} />
}

function HoverCardContent({
  className,
  side = 'bottom',
  sideOffset = 4,
  align = 'center',
  alignOffset = 4,
  ...props
}: React.ComponentProps<typeof HoverCardContentPrimitive>) {
  return (
    <HoverCardContentPrimitive
      align={align}
      alignOffset={alignOffset}
      side={side}
      sideOffset={sideOffset}
      className={cn(
        'ceramic z-50 w-72 origin-(--transform-origin) p-4 text-sm text-fg-primary outline-hidden transition-[opacity,scale] duration-(--duration-overlay) ease-out data-starting-style:opacity-0 data-starting-style:scale-[0.96] data-ending-style:opacity-0 data-ending-style:scale-[0.96]',
        className
      )}
      {...props}
    />
  )
}

export { HoverCard, HoverCardTrigger, HoverCardContent }
