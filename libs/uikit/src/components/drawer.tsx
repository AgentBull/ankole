import * as React from 'react'
import type { DialogFinalFocus, DialogInitialFocus } from '@ui-sdk/react/dialog'
import {
  DrawerBackdrop,
  DrawerClose as DrawerClosePrimitive,
  DrawerContent as DrawerContentPrimitive,
  DrawerDescription as DrawerDescriptionPrimitive,
  Drawer as DrawerPrimitive,
  DrawerTitle as DrawerTitlePrimitive,
  DrawerTrigger as DrawerTriggerPrimitive
} from '@ui-sdk/react/drawer'

import { type FocusTarget, focusTarget } from '@ankole/uikit/lib/focus-target'
import { cn } from '@ankole/uikit/lib/utils'
import { usePopupContainer } from '../lib/popup-container'

type DrawerProps = React.ComponentProps<typeof DrawerPrimitive>

type DrawerContextProps = {
  hasSnapPoints: boolean
  modal: DrawerProps['modal']
  showSwipeHandle: boolean
  side: NonNullable<DrawerProps['side']>
}

const DrawerContext = React.createContext<DrawerContextProps | null>(null)

function useDrawer() {
  const context = React.useContext(DrawerContext)

  if (!context) {
    throw new Error('useDrawer must be used within a Drawer.')
  }

  return context
}

function Drawer({
  modal = true,
  showSwipeHandle = false,
  snapPoints,
  side = 'bottom',
  container,
  ...props
}: DrawerProps & {
  showSwipeHandle?: boolean
}) {
  const popupContainer = usePopupContainer(container)
  const hasSnapPoints = snapPoints != null && snapPoints.length > 0
  const contextValue = React.useMemo(
    () => ({ hasSnapPoints, modal, showSwipeHandle, side }),
    [hasSnapPoints, modal, showSwipeHandle, side]
  )

  return (
    <DrawerContext.Provider value={contextValue}>
      <DrawerPrimitive modal={modal} snapPoints={snapPoints} side={side} {...props} container={popupContainer} />
    </DrawerContext.Provider>
  )
}

function DrawerTrigger(props: React.ComponentProps<typeof DrawerTriggerPrimitive>) {
  return <DrawerTriggerPrimitive {...props} />
}

function DrawerClose(props: React.ComponentProps<typeof DrawerClosePrimitive>) {
  return <DrawerClosePrimitive {...props} />
}

// ui-sdk sets the overlay's opacity as the drawer moves, so the overlay supplies only its colour and place.
function DrawerOverlay({ className, ...props }: React.ComponentProps<typeof DrawerBackdrop>) {
  return (
    <DrawerBackdrop
      render={<div data-slot="drawer-overlay" />}
      className={cn(
        'fixed inset-0 z-50 min-h-dvh bg-scrim select-none data-ending-style:pointer-events-none supports-[-webkit-touch-callout:none]:absolute',
        className
      )}
      {...props}
    />
  )
}

function DrawerSwipeHandle({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="drawer-swipe-handle"
      aria-hidden="true"
      className={cn(
        'relative z-10 flex shrink-0 cursor-grab transition-opacity duration-200 group-data-nested-open/drawer-popup:opacity-0 group-data-[swipe-axis=x]/drawer-popup:h-full group-data-[swipe-axis=x]/drawer-popup:w-3 group-data-[swipe-axis=x]/drawer-popup:items-center group-data-[swipe-axis=y]/drawer-popup:h-3 group-data-[swipe-axis=y]/drawer-popup:w-full group-data-[swipe-axis=y]/drawer-popup:justify-center group-data-[side=bottom]/drawer-popup:items-end group-data-[side=left]/drawer-popup:order-last group-data-[side=left]/drawer-popup:justify-start group-data-[side=right]/drawer-popup:justify-end group-data-[side=top]/drawer-popup:order-last group-data-[side=top]/drawer-popup:items-start after:block after:shrink-0 after:rounded-full after:bg-layer-03 group-data-[swipe-axis=x]/drawer-popup:after:h-[100px] group-data-[swipe-axis=x]/drawer-popup:after:w-1.5 group-data-[swipe-axis=y]/drawer-popup:after:h-1.5 group-data-[swipe-axis=y]/drawer-popup:after:w-[100px] active:cursor-grabbing',
        className
      )}
      {...props}
    />
  )
}

/**
 * The ceramic sheet of a drawer. ui-sdk places it against its side inside a full-screen viewport and moves it with
 * `translate`, so the kit gives it only a surface, an inset and a size.
 */
function DrawerContent({
  className,
  children,
  initialFocus,
  finalFocus,
  ...props
}: Omit<React.ComponentProps<typeof DrawerContentPrimitive>, 'children' | 'initialFocus' | 'finalFocus'> & {
  children?: React.ReactNode
  initialFocus?: FocusTarget<DialogInitialFocus>
  finalFocus?: FocusTarget<DialogFinalFocus>
}) {
  const { hasSnapPoints, modal, showSwipeHandle, side } = useDrawer()
  const swipeAxis = side === 'bottom' || side === 'top' ? 'y' : 'x'

  return (
    <>
      {modal === true && <DrawerOverlay />}
      <DrawerContentPrimitive
        render={<div data-slot="drawer-popup" />}
        data-swipe-axis={swipeAxis}
        data-snap-points={hasSnapPoints ? '' : undefined}
        initialFocus={focusTarget(initialFocus)}
        finalFocus={focusTarget(finalFocus)}
        className={cn(
          'ceramic group/drawer-popup m-(--drawer-inset) flex h-(--drawer-content-height) max-h-(--drawer-content-max-height,none) min-h-0 w-(--drawer-content-width,auto) max-w-[calc(100%-2*var(--drawer-inset))] flex-col text-sm text-fg-primary outline-none select-none',
          'data-nested-open:overflow-hidden data-nested-open:brightness-95',
          '[--drawer-inset:--spacing(2)] [--drawer-content-height:auto] data-[swipe-axis=x]:[--drawer-content-width:75%] data-[swipe-axis=y]:[--drawer-content-max-height:calc(100dvh-6rem)] data-[swipe-axis=y]:data-snap-points:[--drawer-content-height:100dvh] data-[swipe-axis=x]:sm:[--drawer-content-width:24rem]',
          'data-[swipe-axis=x]:flex-row',
          className
        )}
        {...props}>
        {showSwipeHandle && <DrawerSwipeHandle />}
        <div
          data-slot="drawer-content"
          className="flex min-h-0 flex-1 flex-col overflow-hidden overscroll-contain rounded-[inherit] transition-opacity duration-(--duration-feedback) ease-out select-text group-data-nested-open/drawer-popup:opacity-0 group-data-dragging/drawer-popup:select-none">
          {children}
        </div>
      </DrawerContentPrimitive>
    </>
  )
}

function DrawerHeader({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="drawer-header"
      className={cn(
        'flex shrink-0 flex-col gap-1 p-4 pb-0 group-data-[swipe-axis=y]/drawer-popup:text-center md:gap-2 md:text-left',
        className
      )}
      {...props}
    />
  )
}

function DrawerFooter({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="drawer-footer"
      className={cn('mt-auto flex shrink-0 flex-col gap-2 p-4 pt-0', className)}
      {...props}
    />
  )
}

function DrawerTitle({ className, ...props }: React.ComponentProps<typeof DrawerTitlePrimitive>) {
  return <DrawerTitlePrimitive className={cn('title-overlay text-fg-primary', className)} {...props} />
}

function DrawerDescription({ className, ...props }: React.ComponentProps<typeof DrawerDescriptionPrimitive>) {
  return (
    <DrawerDescriptionPrimitive
      className={cn('mt-0.5 text-sm leading-5 text-balance text-fg-secondary', className)}
      {...props}
    />
  )
}

export {
  Drawer,
  DrawerOverlay,
  DrawerSwipeHandle,
  DrawerTrigger,
  DrawerClose,
  DrawerContent,
  DrawerHeader,
  DrawerFooter,
  DrawerTitle,
  DrawerDescription
}
