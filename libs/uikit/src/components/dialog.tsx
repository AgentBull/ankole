import {
  type DialogFinalFocus,
  type DialogInitialFocus,
  DialogBackdrop,
  DialogClose as DialogClosePrimitive,
  DialogContent as DialogContentPrimitive,
  DialogDescription as DialogDescriptionPrimitive,
  Dialog as DialogPrimitive,
  DialogTitle as DialogTitlePrimitive,
  DialogTrigger as DialogTriggerPrimitive
} from '@ui-sdk/react/dialog'
import { DismissRegular } from '../icons'
import type * as React from 'react'
import { Button } from './button'
import { type FocusTarget, focusTarget } from '../lib/focus-target'
import { usePopupContainer } from '../lib/popup-container'
import { cn } from '../lib/utils'

function Dialog({ container, ...props }: React.ComponentProps<typeof DialogPrimitive>) {
  return <DialogPrimitive container={usePopupContainer(container)} {...props} />
}

function DialogTrigger({ className, ...props }: React.ComponentProps<typeof DialogTriggerPrimitive>) {
  return <DialogTriggerPrimitive className={cn('cursor-pointer disabled:cursor-not-allowed', className)} {...props} />
}

function DialogClose({ className, ...props }: React.ComponentProps<typeof DialogClosePrimitive>) {
  return <DialogClosePrimitive className={cn('cursor-pointer disabled:cursor-not-allowed', className)} {...props} />
}

// The kit names the overlay `dialog-overlay` instead of ui-sdk's `dialog-backdrop`, because app stylesheets select it.
function DialogOverlay({ className, ...props }: React.ComponentProps<typeof DialogBackdrop>) {
  return (
    <DialogBackdrop
      render={<div data-slot="dialog-overlay" />}
      className={cn(
        'fixed inset-0 isolate z-50 bg-scrim transition-opacity duration-(--duration-dialog) ease-out data-starting-style:opacity-0 data-ending-style:opacity-0',
        className
      )}
      {...props}
    />
  )
}

function DialogContent({
  className,
  children,
  closeLabel = 'Close',
  showCloseButton = true,
  initialFocus,
  finalFocus,
  ...props
}: Omit<React.ComponentProps<typeof DialogContentPrimitive>, 'children' | 'initialFocus' | 'finalFocus'> & {
  children?: React.ReactNode
  closeLabel?: string
  initialFocus?: FocusTarget<DialogInitialFocus>
  finalFocus?: FocusTarget<DialogFinalFocus>
  showCloseButton?: boolean
}) {
  return (
    <>
      <DialogOverlay />
      <DialogContentPrimitive
        initialFocus={focusTarget(initialFocus)}
        finalFocus={focusTarget(finalFocus)}
        className={cn(
          'ceramic fixed top-1/2 left-1/2 z-50 grid max-h-[calc(100dvh-2rem)] w-full max-w-[calc(100%-2rem)] -translate-x-1/2 -translate-y-1/2 gap-6 overflow-y-auto p-6 text-sm text-fg-primary outline-none transition-[opacity,scale] duration-(--duration-dialog) ease-out sm:max-w-3xl data-starting-style:opacity-0 data-starting-style:scale-[0.96] data-ending-style:opacity-0 data-ending-style:scale-[0.96]',
          className
        )}
        {...props}>
        {children}
        {showCloseButton && (
          <DialogClosePrimitive
            render={
              <Button
                variant="ghost"
                className="absolute top-2 right-2 pointer-coarse:after:absolute pointer-coarse:after:-inset-1.5"
                size="icon"
              />
            }>
            <DismissRegular />
            <span className="sr-only">{closeLabel}</span>
          </DialogClosePrimitive>
        )}
      </DialogContentPrimitive>
    </>
  )
}

function DialogHeader({ className, ...props }: React.ComponentProps<'div'>) {
  return <div data-slot="dialog-header" className={cn('flex flex-col gap-2', className)} {...props} />
}

function DialogFooter({
  className,
  closeLabel = 'Close',
  showCloseButton = false,
  children,
  ...props
}: React.ComponentProps<'div'> & {
  closeLabel?: string
  showCloseButton?: boolean
}) {
  return (
    <div
      data-slot="dialog-footer"
      className={cn(
        '-mx-6 -mb-6 mt-2 flex flex-row items-center justify-end gap-2 border-t border-border-subtle px-6 py-4',
        className
      )}
      {...props}>
      {showCloseButton && (
        <DialogClosePrimitive render={<Button variant="outline" />}>{closeLabel}</DialogClosePrimitive>
      )}
      {children}
    </div>
  )
}

function DialogTitle({ className, ...props }: React.ComponentProps<typeof DialogTitlePrimitive>) {
  return <DialogTitlePrimitive className={cn('title-overlay', className)} {...props} />
}

function DialogDescription({ className, ...props }: React.ComponentProps<typeof DialogDescriptionPrimitive>) {
  return (
    <DialogDescriptionPrimitive
      className={cn(
        'mt-0.5 text-sm leading-5 text-fg-secondary *:[a]:underline *:[a]:underline-offset-3 *:[a]:hover:text-fg-primary',
        className
      )}
      {...props}
    />
  )
}

export {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogOverlay,
  DialogTitle,
  DialogTrigger
}
