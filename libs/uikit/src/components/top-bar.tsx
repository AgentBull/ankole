import * as React from 'react'
import { SidebarContext } from './sidebar-context'
import { cn } from '../lib/utils'

/**
 * The window's top bar: 44px high on the ground, across the sidebar column and the content card, with no fill and
 * no edge. It lays out four zones from start to end: `TopBarLeading` above the sidebar column, `TopBarHistory`,
 * `TopBarTitle`, and `TopBarActions`, which ends 20px before the window's edge, in line with the content card.
 * Inside a `SidebarProvider`, the bar moves the docked sidebar below itself.
 */
function TopBar({ className, ...props }: React.ComponentProps<'header'>) {
  return (
    <header
      data-slot="top-bar"
      className={cn('flex h-top-bar w-full shrink-0 items-center pe-5', className)}
      {...props}
    />
  )
}

/**
 * The zone above the sidebar column: the product mark and the sidebar toggle. While the sidebar is docked open, the
 * zone spans the column less 8px, so the first 36px button of the next zone draws its icon on the content card's edge,
 * and its `SidebarTrigger` hides. Otherwise the zone is as wide as what it holds. The zone's width follows the
 * column's clock (see `Sidebar`); the toggle fades and grows in over 160ms from 100ms into a hide, and it fades out
 * within 80ms of a dock. A screen that asks for reduced motion swaps both at once.
 */
function TopBarLeading({ className, ...props }: React.ComponentProps<'div'>) {
  const sidebar = React.useContext(SidebarContext)
  const docked = sidebar?.state === 'expanded' && !sidebar.isMobile
  return (
    <div
      data-slot="top-bar-leading"
      data-docked={docked ? '' : undefined}
      className={cn(
        'flex min-w-0 shrink-0 items-center gap-1 ps-2 transition-[min-width] duration-(--duration-dialog) ease-drawer motion-reduce:transition-none data-docked:min-w-[calc(var(--sidebar-width)-var(--spacing)*2)] data-docked:duration-(--duration-drawer)',
        '[&>[data-slot=sidebar-trigger]]:[transition:opacity_160ms_var(--ease-out)_100ms,scale_160ms_var(--ease-out)_100ms,visibility_0s_100ms,background-color_var(--duration-feedback)_var(--ease-productive),color_var(--duration-feedback)_var(--ease-productive)] data-docked:[&>[data-slot=sidebar-trigger]]:invisible data-docked:[&>[data-slot=sidebar-trigger]]:scale-90 data-docked:[&>[data-slot=sidebar-trigger]]:opacity-0 data-docked:[&>[data-slot=sidebar-trigger]]:[transition:opacity_80ms_var(--ease-out),scale_80ms_var(--ease-out),visibility_0s_80ms] motion-reduce:[&>[data-slot=sidebar-trigger]]:transition-none!',
        className
      )}
      {...props}
    />
  )
}

/**
 * Back and forward through the window's history: 36px icon buttons, 4px apart, so their icons sit 20px apart. An
 * available direction draws its icon in the tertiary colour, and the title zone starts 2px after the group.
 */
function TopBarHistory({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="top-bar-history"
      role="group"
      className={cn('me-0.5 flex shrink-0 items-center gap-1 *:text-fg-tertiary', className)}
      {...props}
    />
  )
}

/**
 * The zone for the breadcrumb or the title of the open place. It takes the width that the other zones leave, and its
 * content starts 4px inside it.
 */
function TopBarTitle({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="top-bar-title"
      className={cn('flex min-w-0 flex-1 items-center gap-1 overflow-hidden ps-1', className)}
      {...props}
    />
  )
}

/** The actions at the end of the bar: 36px controls, 12px apart. */
function TopBarActions({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div data-slot="top-bar-actions" className={cn('ms-auto flex shrink-0 items-center gap-3', className)} {...props} />
  )
}

export { TopBar, TopBarActions, TopBarHistory, TopBarLeading, TopBarTitle }
