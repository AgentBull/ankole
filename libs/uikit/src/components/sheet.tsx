import {
  type DialogFinalFocus,
  type DialogInitialFocus,
  DialogBackdrop,
  DialogClose,
  DialogContent,
  DialogDescription,
  Dialog as SheetPrimitive,
  DialogTitle,
  DialogTrigger
} from '@ui-sdk/react/dialog'
import { DismissRegular } from '../icons'
import type * as React from 'react'
import { Button } from './button'
import { type FocusTarget, focusTarget } from '../lib/focus-target'
import { usePopupContainer } from '../lib/popup-container'
import { cn } from '../lib/utils'

// A sheet is a ui-sdk dialog. The kit names its surface, overlay, title and description `sheet-*`, so that dialog
// styles in app stylesheets leave sheets alone.

function Sheet({ container, ...props }: React.ComponentProps<typeof SheetPrimitive>) {
  return <SheetPrimitive container={usePopupContainer(container)} {...props} />
}

function SheetTrigger({ className, ...props }: React.ComponentProps<typeof DialogTrigger>) {
  return <DialogTrigger className={cn('cursor-pointer disabled:cursor-not-allowed', className)} {...props} />
}

function SheetClose({ className, ...props }: React.ComponentProps<typeof DialogClose>) {
  return <DialogClose className={cn('cursor-pointer disabled:cursor-not-allowed', className)} {...props} />
}

function SheetOverlay({ className, ...props }: React.ComponentProps<typeof DialogBackdrop>) {
  return (
    <DialogBackdrop
      render={<div data-slot="sheet-overlay" />}
      className={cn(
        'fixed inset-0 z-50 bg-scrim transition-opacity duration-(--duration-drawer) ease-drawer data-ending-style:opacity-0 data-starting-style:opacity-0',
        className
      )}
      {...props}
    />
  )
}

function SheetContent({
  className,
  children,
  closeLabel = 'Close',
  side = 'right',
  showCloseButton = true,
  initialFocus,
  finalFocus,
  ...props
}: Omit<React.ComponentProps<typeof DialogContent>, 'children' | 'initialFocus' | 'finalFocus'> & {
  children?: React.ReactNode
  closeLabel?: string
  initialFocus?: FocusTarget<DialogInitialFocus>
  finalFocus?: FocusTarget<DialogFinalFocus>
  side?: 'top' | 'right' | 'bottom' | 'left'
  showCloseButton?: boolean
}) {
  return (
    <>
      <SheetOverlay />
      <DialogContent
        // ui-sdk's own `data-slot` wins over a prop, so the kit sets the caller's slot, such as a sidebar's, here.
        render={<div data-slot={(props as { 'data-slot'?: string })['data-slot'] ?? 'sheet-content'} />}
        data-side={side}
        initialFocus={focusTarget(initialFocus)}
        finalFocus={focusTarget(finalFocus)}
        className={cn(
          'ceramic fixed z-50 flex max-w-[calc(100%-1rem)] flex-col overflow-hidden text-sm outline-none text-fg-primary transition-[translate,opacity] duration-(--duration-drawer) ease-drawer data-starting-style:opacity-0 data-ending-style:opacity-0 data-[side=bottom]:inset-x-2 data-[side=bottom]:bottom-2 data-[side=bottom]:h-auto data-[side=bottom]:data-ending-style:translate-y-[calc(100%+--spacing(2))] data-[side=bottom]:data-starting-style:translate-y-[calc(100%+--spacing(2))] data-[side=left]:inset-y-2 data-[side=left]:left-2 data-[side=left]:w-3/4 data-[side=left]:data-ending-style:-translate-x-[calc(100%+--spacing(2))] data-[side=left]:data-starting-style:-translate-x-[calc(100%+--spacing(2))] data-[side=right]:inset-y-2 data-[side=right]:right-2 data-[side=right]:w-3/4 data-[side=right]:data-ending-style:translate-x-[calc(100%+--spacing(2))] data-[side=right]:data-starting-style:translate-x-[calc(100%+--spacing(2))] data-[side=top]:inset-x-2 data-[side=top]:top-2 data-[side=top]:h-auto data-[side=top]:data-ending-style:-translate-y-[calc(100%+--spacing(2))] data-[side=top]:data-starting-style:-translate-y-[calc(100%+--spacing(2))] data-[side=left]:sm:max-w-sm data-[side=right]:sm:max-w-sm',
          className
        )}
        {...props}>
        {children}
        {showCloseButton && (
          <DialogClose
            render={
              <Button
                variant="ghost"
                className="absolute top-2 right-2 pointer-coarse:after:absolute pointer-coarse:after:-inset-1.5"
                size="icon"
              />
            }>
            <DismissRegular />
            <span className="sr-only">{closeLabel}</span>
          </DialogClose>
        )}
      </DialogContent>
    </>
  )
}

function SheetHeader({ className, ...props }: React.ComponentProps<'div'>) {
  return <div data-slot="sheet-header" className={cn('flex flex-col gap-1.5 p-6', className)} {...props} />
}

function SheetFooter({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="sheet-footer"
      className={cn(
        'mt-auto flex flex-row items-center justify-end gap-2 border-t border-border-subtle px-6 py-4',
        className
      )}
      {...props}
    />
  )
}

function SheetTitle({ className, ...props }: React.ComponentProps<typeof DialogTitle>) {
  return (
    <DialogTitle
      render={<h2 data-slot="sheet-title" />}
      className={cn('title-overlay text-fg-primary', className)}
      {...props}
    />
  )
}

function SheetDescription({ className, ...props }: React.ComponentProps<typeof DialogDescription>) {
  return (
    <DialogDescription
      render={<p data-slot="sheet-description" />}
      className={cn('mt-0.5 text-sm leading-5 text-fg-secondary', className)}
      {...props}
    />
  )
}

export { Sheet, SheetClose, SheetContent, SheetDescription, SheetFooter, SheetHeader, SheetTitle, SheetTrigger }
