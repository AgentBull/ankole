'use client'

import {
  type PopoverFinalFocus,
  type PopoverInitialFocus,
  PopoverContent as PopoverContentPrimitive,
  PopoverDescription as PopoverDescriptionPrimitive,
  Popover as PopoverPrimitive,
  PopoverTitle as PopoverTitlePrimitive,
  PopoverTrigger as PopoverTriggerPrimitive
} from '@ui-sdk/react/popover'
import type * as React from 'react'

import { type FocusTarget, focusTarget } from '../lib/focus-target'
import { usePopupContainer } from '../lib/popup-container'
import { cn } from '../lib/utils'

function Popover({ container, ...props }: React.ComponentProps<typeof PopoverPrimitive>) {
  return <PopoverPrimitive container={usePopupContainer(container)} {...props} />
}

function PopoverTrigger({ className, ...props }: React.ComponentProps<typeof PopoverTriggerPrimitive>) {
  return <PopoverTriggerPrimitive className={cn('cursor-pointer disabled:cursor-not-allowed', className)} {...props} />
}

/**
 * The ceramic surface of a popover, placed beside its trigger, or beside `anchor` when the popover opens without
 * one, such as a prompt that belongs to a field.
 */
function PopoverContent({
  className,
  align = 'center',
  alignOffset = 0,
  side = 'bottom',
  sideOffset = 4,
  initialFocus,
  finalFocus,
  ...props
}: Omit<React.ComponentProps<typeof PopoverContentPrimitive>, 'initialFocus' | 'finalFocus'> & {
  initialFocus?: FocusTarget<PopoverInitialFocus>
  finalFocus?: FocusTarget<PopoverFinalFocus>
}) {
  return (
    <PopoverContentPrimitive
      align={align}
      alignOffset={alignOffset}
      side={side}
      sideOffset={sideOffset}
      initialFocus={focusTarget(initialFocus)}
      finalFocus={focusTarget(finalFocus)}
      className={cn(
        'ceramic z-50 flex w-72 origin-(--transform-origin) flex-col gap-4 p-4 text-sm text-fg-primary outline-hidden transition-[opacity,scale] duration-(--duration-overlay) ease-out data-starting-style:opacity-0 data-starting-style:scale-[0.96] data-ending-style:opacity-0 data-ending-style:scale-[0.96]',
        className
      )}
      {...props}
    />
  )
}

function PopoverHeader({ className, ...props }: React.ComponentProps<'div'>) {
  return <div data-slot="popover-header" className={cn('flex flex-col gap-1 text-sm', className)} {...props} />
}

function PopoverTitle({ className, ...props }: React.ComponentProps<typeof PopoverTitlePrimitive>) {
  return <PopoverTitlePrimitive className={cn('title-inline', className)} {...props} />
}

function PopoverDescription({ className, ...props }: React.ComponentProps<typeof PopoverDescriptionPrimitive>) {
  return (
    <PopoverDescriptionPrimitive className={cn('mt-0.5 text-sm leading-5 text-fg-secondary', className)} {...props} />
  )
}

export { Popover, PopoverContent, PopoverDescription, PopoverHeader, PopoverTitle, PopoverTrigger }
