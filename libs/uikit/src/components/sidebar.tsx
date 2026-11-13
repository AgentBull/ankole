import { Collapsible as CollapsiblePrimitive } from '@base-ui/react/collapsible'
import { mergeProps } from '@base-ui/react/merge-props'
import { useRender } from '@base-ui/react/use-render'
import { cva, type VariantProps } from 'class-variance-authority'
import * as React from 'react'
import { Button } from './button'
import { Input } from './input'
import { Separator } from './separator'
import { Sheet, SheetContent, SheetHeader, SheetTitle } from './sheet'
import { Skeleton } from './skeleton'
import { Tooltip, TooltipContent, TooltipTrigger } from './tooltip'
import { SidebarContext, type SidebarContextProps, useSidebar } from './sidebar-context'
import { useIsMobile } from '../hooks/use-mobile'
import { CaretRightFilled, PanelLeftRegular } from '../icons'
import { cn } from '../lib/utils'

const SIDEBAR_COOKIE_NAME = 'sidebar_state'
const SIDEBAR_COOKIE_MAX_AGE = 60 * 60 * 24 * 7
const SIDEBAR_WIDTH = 'var(--spacing-sidebar)'
const SIDEBAR_WIDTH_MOBILE = '18rem'
const SIDEBAR_WIDTH_ICON = '3rem'
const SIDEBAR_KEYBOARD_SHORTCUT = 'b'

/** How deep the menu rows inside a `SidebarMenuSub` sit; the top-level menu is level 0. */
const SidebarMenuLevelContext = React.createContext(0)
/** Whether a `SidebarMenuAction` sits in a `SidebarMenuActions` group, which positions and reveals it. */
const SidebarMenuActionsContext = React.createContext(false)
/** Whether a `SidebarMenuToggle` sits in a section title, where it follows the title's text. */
const SidebarGroupLabelContext = React.createContext(false)

/**
 * The window of an app with a sidebar. It paints the ground, which shows through the sidebar and around the content
 * card. A `TopBar` inside the provider moves the docked sidebar below the bar.
 */
function SidebarProvider({
  defaultOpen = true,
  mobileBreakpoint,
  open: openProp,
  onOpenChange: setOpenProp,
  className,
  style,
  children,
  ...props
}: React.ComponentProps<'div'> & {
  defaultOpen?: boolean
  mobileBreakpoint?: number
  open?: boolean
  onOpenChange?: (open: boolean) => void
}) {
  const isMobile = useIsMobile(mobileBreakpoint)
  const [openMobile, setOpenMobile] = React.useState(false)

  const [_open, _setOpen] = React.useState(defaultOpen)
  const open = openProp ?? _open
  const setOpen = React.useCallback(
    (value: boolean | ((value: boolean) => boolean)) => {
      const openState = typeof value === 'function' ? value(open) : value
      if (setOpenProp) {
        setOpenProp(openState)
      } else {
        _setOpen(openState)
      }

      document.cookie = `${SIDEBAR_COOKIE_NAME}=${openState}; path=/; max-age=${SIDEBAR_COOKIE_MAX_AGE}`
    },
    [setOpenProp, open]
  )

  const toggleSidebar = React.useCallback(() => {
    return isMobile ? setOpenMobile(open => !open) : setOpen(open => !open)
  }, [isMobile, setOpen])

  React.useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (
        event.defaultPrevented ||
        event.isComposing ||
        event.keyCode === 229 ||
        event.repeat ||
        event.altKey ||
        event.shiftKey
      ) {
        return
      }
      if (
        event.target instanceof Element &&
        event.target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"])')
      ) {
        return
      }
      if (event.key.toLowerCase() === SIDEBAR_KEYBOARD_SHORTCUT && (event.metaKey || event.ctrlKey)) {
        event.preventDefault()
        toggleSidebar()
      }
    }

    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [toggleSidebar])

  const state = open ? 'expanded' : 'collapsed'

  const contextValue = React.useMemo<SidebarContextProps>(
    () => ({
      state,
      open,
      setOpen,
      isMobile,
      openMobile,
      setOpenMobile,
      toggleSidebar
    }),
    [state, open, setOpen, isMobile, openMobile, toggleSidebar]
  )

  return (
    <SidebarContext.Provider value={contextValue}>
      <div
        data-slot="sidebar-wrapper"
        style={
          {
            '--sidebar-width': SIDEBAR_WIDTH,
            '--sidebar-width-icon': SIDEBAR_WIDTH_ICON,
            ...style
          } as React.CSSProperties
        }
        className={cn(
          'group/sidebar-wrapper flex min-h-svh w-full bg-ground has-data-[slot=top-bar]:[--sidebar-top:var(--spacing-top-bar)]',
          className
        )}
        {...props}>
        {children}
      </div>
    </SidebarContext.Provider>
  )
}

/**
 * The navigation column. The `inset` and `sidebar` variants draw no fill of their own, so the window's ground shows
 * through them; the `floating` variant is a card of its own. While the column is collapsed off the canvas it is
 * inert, so its controls leave the tab order; a caller that shows the collapsed column, such as a hover preview,
 * passes `inert={false}` while it shows.
 *
 * Docking and hiding run on one clock: the column slides its own width with the drawer curve, 240ms to dock and
 * 200ms to hide, and the gap beside it, the content card's start margin, and the top bar's leading zone follow with
 * the same duration and curve, so the card's edge stays on the column's edge. The column fades out over the first
 * 120ms of a hide and fades in over 160ms from 60ms into a dock. A screen that asks for reduced motion swaps the
 * states at once.
 *
 * On a narrow screen the column opens as a sheet sized for touch: its rows and section titles are 40px high, every
 * button in it is at least 32px square, each row shows its actions without a hover, each parent row shows its arrow
 * in its icon slot, and each nesting level indents 24px.
 */
function Sidebar({
  side = 'left',
  variant = 'sidebar',
  collapsible = 'offcanvas',
  className,
  children,
  dir,
  mobileTitle,
  inert,
  ...props
}: React.ComponentProps<'div'> & {
  side?: 'left' | 'right'
  variant?: 'sidebar' | 'floating' | 'inset'
  collapsible?: 'offcanvas' | 'icon' | 'none'
  mobileTitle: string
}) {
  const { isMobile, state, openMobile, setOpenMobile } = useSidebar()

  if (collapsible === 'none') {
    return (
      <div
        data-slot="sidebar"
        inert={inert}
        className={cn('flex h-full w-(--sidebar-width) flex-col text-sidebar-foreground', className)}
        {...props}>
        {children}
      </div>
    )
  }

  if (isMobile) {
    return (
      <Sheet open={openMobile} onOpenChange={setOpenMobile} {...props}>
        <SheetContent
          dir={dir}
          data-sidebar="sidebar"
          data-slot="sidebar"
          data-mobile="true"
          className="data-[side=left]:w-(--sidebar-width) data-[side=right]:w-(--sidebar-width) p-0 text-sidebar-foreground [--sidebar-menu-indent:calc(var(--spacing)*6)] [&_button]:min-h-8 [&_button]:min-w-8 [&>button]:hidden"
          style={
            {
              '--sidebar-width': SIDEBAR_WIDTH_MOBILE
            } as React.CSSProperties
          }
          side={side}>
          <SheetHeader className="sr-only">
            <SheetTitle>{mobileTitle}</SheetTitle>
          </SheetHeader>
          <div className={cn('flex h-full w-full flex-col', variant === 'floating' && 'p-2')}>{children}</div>
        </SheetContent>
      </Sheet>
    )
  }

  return (
    <div
      className="group peer hidden text-sidebar-foreground md:block"
      data-state={state}
      data-collapsible={state === 'collapsed' ? collapsible : ''}
      data-variant={variant}
      data-side={side}
      data-slot="sidebar">
      <div
        data-slot="sidebar-gap"
        className={cn(
          'relative w-(--sidebar-width) bg-transparent transition-[width] duration-(--duration-drawer) ease-drawer group-data-[state=collapsed]:duration-(--duration-dialog) motion-reduce:transition-none',
          'group-data-[collapsible=offcanvas]:w-0',
          'group-data-[side=right]:rotate-180',
          variant === 'floating' || variant === 'inset'
            ? 'group-data-[collapsible=icon]:w-[calc(var(--sidebar-width-icon)+(--spacing(4)))]'
            : 'group-data-[collapsible=icon]:w-(--sidebar-width-icon)'
        )}
      />
      <div
        data-slot="sidebar-container"
        data-side={side}
        inert={inert ?? (state === 'collapsed' && collapsible === 'offcanvas')}
        className={cn(
          'fixed top-[var(--sidebar-top,0px)] bottom-0 hidden w-(--sidebar-width) [transition:translate_var(--duration-drawer)_var(--ease-drawer),width_var(--duration-drawer)_var(--ease-drawer),opacity_160ms_var(--ease-out)_60ms] group-data-[state=collapsed]:[transition:translate_var(--duration-dialog)_var(--ease-drawer),width_var(--duration-dialog)_var(--ease-drawer),opacity_120ms_var(--ease-out)] motion-reduce:transition-none! group-data-[collapsible=offcanvas]:opacity-0 data-[side=left]:left-0 data-[side=left]:group-data-[collapsible=offcanvas]:-translate-x-full data-[side=right]:right-0 data-[side=right]:group-data-[collapsible=offcanvas]:translate-x-full md:flex',
          variant === 'inset' ? 'z-0' : 'z-10',
          variant === 'floating'
            ? 'p-2 group-data-[collapsible=icon]:w-[calc(var(--sidebar-width-icon)+(--spacing(4))+2px)]'
            : variant === 'inset'
              ? 'group-data-[collapsible=icon]:w-[calc(var(--sidebar-width-icon)+(--spacing(4))+2px)]'
              : 'group-data-[collapsible=icon]:w-(--sidebar-width-icon) group-data-[side=left]:border-r group-data-[side=right]:border-l',
          className
        )}
        {...props}>
        <div
          data-sidebar="sidebar"
          data-slot="sidebar-inner"
          className="flex size-full flex-col group-data-[variant=floating]:rounded-panel group-data-[variant=floating]:bg-sidebar group-data-[variant=floating]:shadow-sm group-data-[variant=floating]:ring-1 group-data-[variant=floating]:ring-sidebar-border">
          {children}
        </div>
      </div>
    </div>
  )
}

/**
 * The sidebar toggle: a 24px ghost button whose 24px icon fills it. At another button size, such as the top bar's
 * 36px `icon-lg`, it draws a 20px icon like the buttons beside it. The default icon is the panel mark turned a quarter,
 * so its bar sits at the start like the column it toggles; `children` replaces it.
 */
function SidebarTrigger({
  className,
  onClick,
  label,
  children,
  size = 'icon-xs',
  ...props
}: React.ComponentProps<typeof Button> & { label: string }) {
  const { toggleSidebar } = useSidebar()

  return (
    <Tooltip>
      <TooltipTrigger
        render={
          <Button
            type="button"
            variant="ghost"
            size={size}
            className={cn(
              size === 'icon-xs' ? "[&_svg:not([class*='size-'])]:size-6" : "[&_svg:not([class*='size-'])]:size-5",
              className
            )}
            {...props}
          />
        }
        data-sidebar="trigger"
        data-slot="sidebar-trigger"
        aria-label={label}
        onClick={event => {
          onClick?.(event)
          toggleSidebar()
        }}>
        {children ?? <PanelLeftRegular />}
      </TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  )
}

function SidebarRail({ className, ...props }: React.ComponentProps<'button'>) {
  const { toggleSidebar } = useSidebar()

  return (
    <button
      data-sidebar="rail"
      data-slot="sidebar-rail"
      aria-label="Toggle Sidebar"
      tabIndex={-1}
      onClick={toggleSidebar}
      title="Toggle Sidebar"
      className={cn(
        'absolute inset-y-0 z-20 hidden w-4 transition-[background-color] ease-linear motion-safe:transition-[background-color,transform] group-data-[side=left]:-right-4 group-data-[side=right]:left-0 after:absolute after:inset-y-0 after:start-1/2 after:w-[2px] hover:after:bg-sidebar-border sm:flex ltr:-translate-x-1/2 rtl:-translate-x-1/2',
        'in-data-[side=left]:cursor-w-resize in-data-[side=right]:cursor-e-resize',
        '[[data-side=left][data-state=collapsed]_&]:cursor-e-resize [[data-side=right][data-state=collapsed]_&]:cursor-w-resize',
        'group-data-[collapsible=offcanvas]:translate-x-0 group-data-[collapsible=offcanvas]:after:left-full hover:group-data-[collapsible=offcanvas]:bg-sidebar',
        '[[data-side=left][data-collapsible=offcanvas]_&]:-right-2',
        '[[data-side=right][data-collapsible=offcanvas]_&]:-left-2',
        className
      )}
      {...props}
    />
  )
}

/**
 * The content card beside the sidebar: the page's fill with the surface radius at its top corners, no edge, and
 * 20px of ground between it and the window's end. It runs to the bottom of the window. While the sidebar is
 * collapsed, the card keeps 20px of ground at its start as well. Columns that the content lays out side by side,
 * such as a page and the drawers at its end, share the card's fill and its top corners, and the card clips a
 * drawer that slides in or out at its edge.
 */
function SidebarInset({ className, ...props }: React.ComponentProps<'main'>) {
  return (
    <main
      data-slot="sidebar-inset"
      className={cn(
        'relative flex w-full min-w-0 flex-1 flex-col overflow-clip bg-background transition-[margin] duration-(--duration-drawer) ease-drawer peer-data-[state=collapsed]:duration-(--duration-dialog) motion-reduce:transition-none md:peer-data-[variant=inset]:z-10 md:peer-data-[variant=inset]:me-5 md:peer-data-[variant=inset]:rounded-t-surface md:peer-data-[variant=inset]:peer-data-[state=collapsed]:ms-5',
        className
      )}
      {...props}
    />
  )
}

/** A field in the sidebar, such as a filter: 32px high, and 40px in the phone sheet. */
function SidebarInput({ className, ...props }: React.ComponentProps<typeof Input>) {
  return (
    <Input
      data-slot="sidebar-input"
      data-sidebar="input"
      className={cn('h-8 w-full border-input bg-transparent shadow-none in-data-[mobile=true]:h-10', className)}
      {...props}
    />
  )
}

/** The top of the sidebar: rows that stay put while the content scrolls, inset 8px from the column's edges. */
function SidebarHeader({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="sidebar-header"
      data-sidebar="header"
      className={cn('flex shrink-0 flex-col px-2', className)}
      {...props}
    />
  )
}

/**
 * The sidebar's first row, 44px high: the tabs or the title at its start and the sidebar toggle at its end, 12px
 * apart. The toggle ends 2px inside the rows' fills.
 */
function SidebarHeaderRow({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="sidebar-header-row"
      data-sidebar="header-row"
      className={cn(
        'flex h-11 shrink-0 items-center gap-3 [&>[data-slot=sidebar-trigger]]:ms-auto [&>[data-slot=sidebar-trigger]]:me-0.5',
        className
      )}
      {...props}
    />
  )
}

/** The sidebar's last row, 42px high, such as the account switcher. */
function SidebarFooter({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="sidebar-footer"
      data-sidebar="footer"
      className={cn('flex min-h-10.5 shrink-0 items-center gap-1 px-2', className)}
      {...props}
    />
  )
}

/**
 * The footer's one row, such as the account switcher: a 42px navigation row that spans the footer. It starts with a
 * 26px `Avatar` at the fill's edge, whose initials take the 12px step, then a `SidebarFooterLabel`, and it ends with
 * an 18px icon in the secondary colour 4px inside the fill. While the menu that it opens is open, it keeps the hover
 * fill. `render` names another element, such as a menu trigger.
 */
function SidebarFooterButton({
  className,
  render,
  ...props
}: useRender.ComponentProps<'button'> & React.ComponentProps<'button'>) {
  return useRender({
    defaultTagName: 'button',
    props: mergeProps<'button'>(
      {
        className: cn(
          'nav-row flex h-10.5 w-full min-w-0 cursor-pointer items-center gap-1 rounded-control pe-1 text-start focus-visible:-outline-offset-2 data-popup-open:bg-layer-hover *:data-[slot=avatar]:size-6.5 [&>[data-slot=avatar]_[data-slot=avatar-fallback]]:text-50 [&>svg:last-child]:size-4.5 [&>svg:last-child]:shrink-0 [&>svg:last-child]:text-fg-secondary',
          className
        )
      },
      props
    ),
    render,
    state: {
      slot: 'sidebar-footer-button',
      sidebar: 'footer-button'
    }
  })
}

/** The label of a `SidebarFooterButton`: a name in 14px primary text, then a `small` detail in 12px secondary text. */
function SidebarFooterLabel({ className, ...props }: React.ComponentProps<'span'>) {
  return (
    <span
      data-slot="sidebar-footer-label"
      className={cn(
        'flex min-w-0 flex-1 items-baseline gap-1 text-75 *:truncate [&>small]:text-50 [&>small]:text-fg-secondary',
        className
      )}
      {...props}
    />
  )
}

/**
 * The hairline between parts of the sidebar, in the overlay divider. It ends where the rows' fills end and starts
 * 8px later than they do; inside the header, which carries the rows' inset already, it keeps the same line.
 */
function SidebarSeparator({ className, ...props }: React.ComponentProps<typeof Separator>) {
  return (
    <Separator
      data-slot="sidebar-separator"
      data-sidebar="separator"
      className={cn(
        'ms-4 me-2 bg-sidebar-border data-[orientation=horizontal]:w-auto in-data-[slot=sidebar-header]:ms-2 in-data-[slot=sidebar-header]:me-0',
        className
      )}
      {...props}
    />
  )
}

/** The rows between the header and the footer. They scroll on their own, with the thin thumb of a scrolling menu. */
function SidebarContent({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="sidebar-content"
      data-sidebar="content"
      className={cn(
        'flex min-h-0 flex-1 flex-col overflow-auto menu-scrollbar group-data-[collapsible=icon]:overflow-hidden',
        className
      )}
      {...props}
    />
  )
}

/**
 * A section of the sidebar's rows, inset 8px from the column's edges. The first section sits 8px below what comes
 * before it and every later section 16px, so a section title has room above it. `render` names another element,
 * such as a `section` that names the group as a region.
 */
function SidebarGroup({ className, render, ...props }: useRender.ComponentProps<'div'> & React.ComponentProps<'div'>) {
  return useRender({
    defaultTagName: 'div',
    props: mergeProps<'div'>(
      {
        className: cn(
          'relative flex w-full min-w-0 flex-col px-2 pt-(--sidebar-group-gap) [--sidebar-group-gap:calc(var(--spacing)*4)] first:[--sidebar-group-gap:calc(var(--spacing)*2)] last:pb-2',
          className
        )
      },
      props
    ),
    render,
    state: {
      slot: 'sidebar-group',
      sidebar: 'group'
    }
  })
}

/**
 * A section title: a 32px row of 12px secondary text that starts where the rows' icons start, and 40px high in the
 * phone sheet, where a link in the title fills the row's height. A `SidebarMenuToggle` in the title follows the
 * text (see there).
 */
function SidebarGroupLabel({
  className,
  render,
  ...props
}: useRender.ComponentProps<'div'> & React.ComponentProps<'div'>) {
  const label = useRender({
    defaultTagName: 'div',
    props: mergeProps<'div'>(
      {
        className: cn(
          'group/sidebar-group-label flex h-8 shrink-0 items-center gap-1.5 rounded-control ps-3 pe-2 text-50 text-fg-secondary group-data-[collapsible=icon]:-mt-8 group-data-[collapsible=icon]:opacity-0 focus-visible:-outline-offset-2 in-data-[mobile=true]:min-h-10 in-data-[mobile=true]:[&>a]:flex in-data-[mobile=true]:[&>a]:items-center in-data-[mobile=true]:[&>a]:self-stretch [&>svg]:size-4 [&>svg]:shrink-0',
          className
        )
      },
      props
    ),
    render,
    state: {
      slot: 'sidebar-group-label',
      sidebar: 'group-label'
    }
  })
  return <SidebarGroupLabelContext value={true}>{label}</SidebarGroupLabelContext>
}

/** A 24px action at the end of a section title, in line with the rows' actions below it. */
function SidebarGroupAction({
  className,
  render,
  ...props
}: useRender.ComponentProps<'button'> & React.ComponentProps<'button'>) {
  return useRender({
    defaultTagName: 'button',
    props: mergeProps<'button'>(
      {
        className: cn(
          'absolute end-3 top-[calc(var(--sidebar-group-gap,0px)+var(--spacing))] flex size-6 cursor-pointer items-center justify-center rounded-mini p-0 text-fg-secondary transition-colors duration-(--duration-feedback) group-data-[collapsible=icon]:hidden after:absolute after:-inset-1 hover:bg-layer-hover hover:text-foreground active:bg-layer-pressed focus-visible:-outline-offset-2 md:after:hidden [&>svg]:size-4 [&>svg]:shrink-0',
          className
        )
      },
      props
    ),
    render,
    state: {
      slot: 'sidebar-group-action',
      sidebar: 'group-action'
    }
  })
}

/**
 * The motion of a group of rows that opens and closes. Opening runs its height up from zero over 200ms while the rows
 * fade in; closing runs it down over 180ms while the rows fade out in the first 100ms, both on the out curve, so the
 * rows below move with it. The group clips its rows only while it moves, and a closed group leaves the DOM once it
 * has closed. A group that is open when it first renders shows open at once, and a screen that asks for reduced
 * motion opens and closes at once.
 */
const sidebarCollapseClassName =
  'h-(--collapsible-panel-height) transition-[height,opacity] duration-(--duration-dialog) ease-out data-starting-style:h-0 data-starting-style:opacity-0 data-starting-style:overflow-hidden data-ending-style:h-0 data-ending-style:opacity-0 data-ending-style:overflow-hidden data-ending-style:[transition-duration:var(--duration-overlay),100ms] data-moving:overflow-hidden motion-reduce:transition-none'

/** Marks a group with `data-moving` while its own height runs, so it clips its rows only then. */
function trackHeightMotion(panel: HTMLElement | null) {
  if (!panel) return
  const mark = (event: TransitionEvent) => {
    if (event.target !== panel || event.propertyName !== 'height') return
    if (event.type === 'transitionrun') panel.dataset.moving = ''
    else delete panel.dataset.moving
  }
  const types = ['transitionrun', 'transitionend', 'transitioncancel'] as const
  for (const type of types) panel.addEventListener(type, mark)
  return () => {
    for (const type of types) panel.removeEventListener(type, mark)
  }
}

/**
 * Renders `element` as a group that opens and closes with `open` (see `sidebarCollapseClassName`). An `instant` group
 * opens and closes at once, for a change that the person did not ask for, such as a restored or revealed row.
 */
function SidebarCollapse({
  open,
  instant = false,
  element,
  children
}: {
  open: boolean
  instant?: boolean
  element: React.ReactElement<Record<string, unknown>>
  children?: React.ReactNode
}) {
  // The root holds only the open state, so the group stays a direct child of its row's item or section.
  return (
    <CollapsiblePrimitive.Root open={open} render={({ children: panel }) => <>{panel}</>}>
      <CollapsiblePrimitive.Panel
        render={element}
        className={cn(sidebarCollapseClassName, instant && 'transition-none')}
        ref={trackHeightMotion}>
        {children}
      </CollapsiblePrimitive.Panel>
    </CollapsiblePrimitive.Root>
  )
}

/**
 * The body of a section, below its title. With `open`, the body opens and closes with the sidebar's disclosure motion
 * and leaves the DOM while it is closed (see `sidebarCollapseClassName`); without it, the body always shows.
 */
function SidebarGroupContent({
  className,
  open,
  children,
  ...props
}: React.ComponentProps<'div'> & { open?: boolean }) {
  const body = {
    'data-slot': 'sidebar-group-content',
    'data-sidebar': 'group-content',
    className: cn('w-full text-sm', className),
    ...props
  }
  if (open === undefined) return <div {...body}>{children}</div>
  return (
    <SidebarCollapse open={open} element={<div {...body} />}>
      {children}
    </SidebarCollapse>
  )
}

function SidebarMenu({ className, ...props }: React.ComponentProps<'ul'>) {
  return (
    <ul
      data-slot="sidebar-menu"
      data-sidebar="menu"
      className={cn('flex w-full min-w-0 flex-col', className)}
      {...props}
    />
  )
}

/**
 * One entry of a sidebar menu. An entry holds its row, a `SidebarMenuButton` with an optional `SidebarMenuToggle`
 * before it and a `SidebarMenuAction` or `SidebarMenuActions` after it, and then its nested `SidebarMenuSub`. The
 * arrow, the actions, and a badge centre on the nearest positioned box, so an entry whose child rows can open puts
 * its row in a `SidebarMenuRow`; an entry without children may hold the row's parts directly. `level` sets the
 * nesting depth of an entry that a flat list renders; inside a `SidebarMenuSub` the depth follows the nesting.
 */
function SidebarMenuItem({ className, level, style, ...props }: React.ComponentProps<'li'> & { level?: number }) {
  return (
    <li
      data-slot="sidebar-menu-item"
      data-sidebar="menu-item"
      className={cn('group/menu-item relative', className)}
      style={level === undefined ? style : ({ '--sidebar-menu-level': level, ...style } as React.CSSProperties)}
      {...props}
    />
  )
}

/**
 * The row of a `SidebarMenuItem` whose child rows follow it: a positioned box that holds the row's arrow, its
 * `SidebarMenuButton`, and its actions, so they centre on the row and not on the open `SidebarMenuSub` below it. The
 * row decides when its arrow takes the place of its icon (see `SidebarMenuToggle`). `render` names another element,
 * such as the trigger of the row's context menu.
 */
function SidebarMenuRow({
  className,
  render,
  ...props
}: useRender.ComponentProps<'div'> & React.ComponentProps<'div'>) {
  return useRender({
    defaultTagName: 'div',
    props: mergeProps<'div'>({ className: cn('relative', className) }, props),
    render,
    state: {
      slot: 'sidebar-menu-row',
      sidebar: 'menu-row'
    }
  })
}

/**
 * A sidebar row is 32px high with the control radius, and 40px high in the phone sheet. Its content starts 12px in,
 * and one indent further for each nesting level. The indent is 20px, and 24px in the phone sheet. A 20px icon in a
 * `SidebarMenuIcon` sits 6px before a label of 14px primary text on a 26px line; a parent row's arrow takes the same
 * slot, so a parent's icon and label line up with its siblings'. A row of someone to talk to is `size="lg"`: 48px
 * high, with a 32px avatar in a `SidebarMenuIcon size="lg"` 8px before the two lines of a `SidebarMenuText`. The
 * states come from `nav-row`, and the row gives up room at its end while its actions show (see `styles.css`).
 */
const sidebarMenuButtonVariants = cva(
  "nav-row peer/menu-button group/menu-button flex w-full min-w-0 cursor-pointer items-center gap-1.5 overflow-hidden rounded-control py-0 ps-[calc(var(--spacing)*3+var(--sidebar-menu-level,0)*var(--sidebar-menu-indent,calc(var(--spacing)*5)))] pe-[calc(var(--spacing)*2+var(--sidebar-menu-trail,0px))] text-left text-75 group-data-[collapsible=icon]:size-8! group-data-[collapsible=icon]:p-1.5! focus-visible:-outline-offset-2 in-data-[mobile=true]:min-h-10 disabled:pointer-events-none disabled:cursor-not-allowed disabled:text-fg-disabled aria-disabled:pointer-events-none aria-disabled:cursor-not-allowed aria-disabled:text-fg-disabled [&_svg]:shrink-0 [&_svg]:text-(--nav-icon) [&_svg:not([class*='size-'])]:size-5 [&>span:last-child]:truncate",
  {
    variants: {
      size: {
        default: 'h-8',
        sm: 'h-7 text-[13px] leading-5',
        lg: 'h-12 gap-2 group-data-[collapsible=icon]:p-0!'
      }
    },
    defaultVariants: {
      size: 'default'
    }
  }
)

/** The row itself: a button, or the element that `render` names, such as a router link. */
function SidebarMenuButton({
  render,
  isActive = false,
  size = 'default',
  tooltip,
  className,
  ...props
}: useRender.ComponentProps<'button'> &
  React.ComponentProps<'button'> & {
    isActive?: boolean
    tooltip?: string | React.ComponentProps<typeof TooltipContent>
  } & VariantProps<typeof sidebarMenuButtonVariants>) {
  const { isMobile, state } = useSidebar()
  const comp = useRender({
    defaultTagName: 'button',
    props: mergeProps<'button'>(
      {
        className: cn(sidebarMenuButtonVariants({ size }), className)
      },
      props
    ),
    render: !tooltip ? render : <TooltipTrigger render={render} />,
    state: {
      slot: 'sidebar-menu-button',
      sidebar: 'menu-button',
      size,
      active: isActive
    }
  })

  if (!tooltip) {
    return comp
  }

  if (typeof tooltip === 'string') {
    tooltip = {
      children: tooltip
    }
  }

  return (
    <Tooltip>
      {comp}
      <TooltipContent side="right" align="center" hidden={state !== 'collapsed' || isMobile} {...tooltip} />
    </Tooltip>
  )
}

/**
 * A row's icon in the 20px slot at the start of a `SidebarMenuButton`: a glyph, an emoji, a picture, or an avatar.
 * `size="lg"` is the 32px slot of a `size="lg"` row, which holds a default-size `Avatar`. The icon takes the primary
 * colour in every state of the row; `tone="secondary"` draws the icon of a row that starts an action, such as a new
 * conversation, in the secondary colour. A parent row's arrow takes this slot while it shows (see
 * `SidebarMenuToggle`).
 */
function SidebarMenuIcon({
  className,
  tone = 'primary',
  size = 'default',
  ...props
}: React.ComponentProps<'span'> & { tone?: 'primary' | 'secondary'; size?: 'default' | 'lg' }) {
  return (
    <span
      aria-hidden
      data-slot="sidebar-menu-icon"
      data-sidebar="menu-icon"
      data-size={size}
      className={cn(
        'grid shrink-0 place-items-center text-(--nav-icon)',
        size === 'lg' ? 'size-8' : 'size-5',
        tone === 'secondary' ? '[--nav-icon:var(--fg-secondary)]' : '[--nav-icon:var(--foreground)]',
        className
      )}
      {...props}
    />
  )
}

/**
 * The two lines of a `size="lg"` row: the title in the row's 14px primary text and, under it, a description in 12px
 * tertiary text, each cut to one line. `meta`, such as a time, ends the title line, and `status`, such as an unread
 * mark, ends the description line; both take the 12px tertiary step with tabular digits, so they read as one
 * trailing column. Without a description or a status the title stands alone, centred in the row.
 */
function SidebarMenuText({
  className,
  title,
  description,
  meta,
  status,
  ...props
}: Omit<React.ComponentProps<'span'>, 'title' | 'children'> & {
  title: React.ReactNode
  description?: React.ReactNode
  meta?: React.ReactNode
  status?: React.ReactNode
}) {
  const trailing = 'flex shrink-0 items-center gap-1 text-50 leading-4 text-fg-tertiary tabular-nums'
  return (
    <span data-slot="sidebar-menu-text" className={cn('grid min-w-0 flex-1 gap-0.5', className)} {...props}>
      <span className="flex min-w-0 items-center gap-2">
        <span className="min-w-0 flex-1 truncate leading-5">{title}</span>
        {meta && <span className={trailing}>{meta}</span>}
      </span>
      {(description || status) && (
        <span className="flex min-w-0 items-center gap-2">
          <span className="min-w-0 flex-1 truncate text-50 leading-4 text-fg-tertiary">{description}</span>
          {status && <span className={trailing}>{status}</span>}
        </span>
      )}
    </span>
  )
}

/**
 * The arrow of a row that has child rows: a 20px button over the row's icon slot, before the row's
 * `SidebarMenuButton` in a `SidebarMenuRow`, so the row's icon and label keep their siblings' places. On a screen with
 * a fine pointer the row rests on its `SidebarMenuIcon`, and the arrow takes the slot while the row is hovered, while
 * the arrow, the row, or one of the row's actions holds keyboard focus, and while the arrow is busy; a screen without
 * hover and the phone sheet keep the arrow in the slot (see `styles.css`). The arrow draws in the secondary colour,
 * and the pointer over it lays the hover wash on the arrow's own box. In the phone sheet the box grows to 32px around
 * the same 20px arrow. The arrow turns a quarter while `aria-expanded` is true, with the duration and curve of the
 * child list's height (see `SidebarMenuSub`), and at once when `instant` is set, as for a list that opens at once; a
 * 16px spinner that `children` puts in its place while the child rows load keeps its own turn. `children` replaces
 * the default filled arrow.
 *
 * In a `SidebarGroupLabel` the toggle is a 16px caret in the tertiary colour that follows the title's text instead.
 * On a screen with a fine pointer it then rests hidden, whether its section is open or closed, and it shows while
 * the title is hovered or holds focus.
 */
function SidebarMenuToggle({
  className,
  render,
  children,
  instant = false,
  ...props
}: useRender.ComponentProps<'button'> & React.ComponentProps<'button'> & { instant?: boolean }) {
  const inTitle = React.useContext(SidebarGroupLabelContext)
  return useRender({
    defaultTagName: 'button',
    props: mergeProps<'button'>(
      {
        type: 'button',
        className: cn(
          'flex shrink-0 cursor-pointer items-center justify-center p-0 group-data-[collapsible=icon]:hidden after:absolute after:-inset-1 focus-visible:outline-offset-0 [&>svg]:shrink-0 [&>svg]:transition-[rotate] [&>svg]:duration-(--duration-overlay) [&>svg]:ease-out aria-expanded:[&>svg]:duration-(--duration-dialog) aria-expanded:[&>svg:not([data-slot=spinner])]:rotate-90 rtl:[&>svg:not([data-slot=spinner])]:-scale-x-100 rtl:aria-expanded:[&>svg:not([data-slot=spinner])]:-rotate-90 motion-reduce:[&>svg]:transition-none',
          inTitle
            ? 'relative size-4 rounded-mini text-fg-tertiary transition-opacity duration-(--duration-feedback) hover:text-foreground in-data-[mobile=true]:-ms-2 fine-hover:opacity-0 fine-hover:group-hover/sidebar-group-label:opacity-100 fine-hover:group-focus-within/sidebar-group-label:opacity-100 [&>svg]:size-4'
            : 'absolute start-[calc(var(--spacing)*3+var(--sidebar-menu-level,0)*var(--sidebar-menu-indent,calc(var(--spacing)*5)))] top-1/2 z-10 size-5 -translate-y-1/2 rounded-control text-fg-secondary transition-colors duration-(--duration-feedback) hover:bg-layer-hover active:bg-layer-pressed in-data-[mobile=true]:-ms-1.5 [&>svg:not([data-slot=spinner])]:size-5 [&>svg[data-slot=spinner]]:size-4',
          instant && '[&>svg]:transition-none',
          className
        ),
        children: children ?? <CaretRightFilled aria-hidden />
      },
      props
    ),
    render,
    state: {
      slot: 'sidebar-menu-toggle',
      sidebar: 'menu-toggle'
    }
  })
}

/**
 * A 24px action with a 16px primary icon at the end of a row, such as "more" or "add", and 32px in the phone sheet. By
 * default an action waits for its row: it shows while the row is hovered or focused, while it holds an open menu,
 * on the current row, and on every row of the phone sheet (see `styles.css`); `showOnHover={false}` keeps it
 * visible. Inside `SidebarMenuActions`, the group places and reveals its actions instead.
 */
function SidebarMenuAction({
  className,
  render,
  showOnHover = true,
  ...props
}: useRender.ComponentProps<'button'> &
  React.ComponentProps<'button'> & {
    showOnHover?: boolean
  }) {
  const grouped = React.useContext(SidebarMenuActionsContext)
  return useRender({
    defaultTagName: 'button',
    props: mergeProps<'button'>(
      {
        className: cn(
          'flex size-6 shrink-0 cursor-pointer items-center justify-center rounded-mini p-0 text-foreground transition-[background-color,opacity] duration-(--duration-feedback) ease-productive group-data-[collapsible=icon]:hidden hover:bg-layer-hover active:bg-layer-pressed aria-expanded:bg-layer-hover data-popup-open:bg-layer-hover focus-visible:-outline-offset-2 [&>svg]:shrink-0 [&>svg:not([class*=size-])]:size-4',
          !grouped && 'absolute end-1 top-1/2 -translate-y-1/2 after:absolute after:-inset-1 md:after:hidden',
          className
        )
      },
      props
    ),
    render,
    state: {
      slot: 'sidebar-menu-action',
      sidebar: 'menu-action',
      reveal: !grouped && showOnHover ? 'hover' : undefined
    }
  })
}

/**
 * Several actions at the end of a row, side by side. The group waits for its row like a single action does, and the
 * row's label gives up room for two actions while the group shows. Every button in the group, such as a menu
 * trigger that another component renders, counts as one of the row's actions: it takes their primary ink, and 32px in
 * the phone sheet.
 */
function SidebarMenuActions({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <SidebarMenuActionsContext value={true}>
      <div
        data-slot="sidebar-menu-actions"
        data-sidebar="menu-actions"
        className={cn(
          'absolute end-1 top-1/2 flex -translate-y-1/2 items-center transition-opacity duration-(--duration-feedback) ease-productive group-data-[collapsible=icon]:hidden *:text-foreground',
          className
        )}
        {...props}
      />
    </SidebarMenuActionsContext>
  )
}

function SidebarMenuBadge({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="sidebar-menu-badge"
      data-sidebar="menu-badge"
      className={cn(
        'pointer-events-none absolute end-1 top-1/2 flex h-5 min-w-5 -translate-y-1/2 items-center justify-center rounded-mini px-1 text-xs font-medium text-fg-secondary tabular-nums select-none group-data-[collapsible=icon]:hidden peer-hover/menu-button:text-foreground peer-data-active/menu-button:text-foreground',
        className
      )}
      {...props}
    />
  )
}

function SidebarMenuSkeleton({
  className,
  showIcon = false,
  ...props
}: React.ComponentProps<'div'> & {
  showIcon?: boolean
}) {
  const [width] = React.useState(() => {
    return `${Math.floor(Math.random() * 40) + 50}%`
  })

  return (
    <div
      data-slot="sidebar-menu-skeleton"
      data-sidebar="menu-skeleton"
      className={cn('flex h-8 items-center gap-1.5 rounded-control ps-3 pe-2', className)}
      {...props}>
      {showIcon && <Skeleton className="size-5" data-sidebar="menu-skeleton-icon" />}
      <Skeleton
        className="h-4 max-w-(--skeleton-width) flex-1"
        data-sidebar="menu-skeleton-text"
        style={
          {
            '--skeleton-width': width
          } as React.CSSProperties
        }
      />
    </div>
  )
}

/**
 * The child rows of a row. The list draws no line of its own; each row inside it indents 20px further than its
 * parent while its fill still spans the full width of the column. With `open`, the list opens and closes with the
 * sidebar's disclosure motion and leaves the DOM while it is closed (see `sidebarCollapseClassName`), so a parent row
 * renders its list in both states; `instant` opens and closes it at once instead. Without `open`, the list always
 * shows.
 */
function SidebarMenuSub({
  className,
  style,
  open,
  instant,
  children,
  ...props
}: React.ComponentProps<'ul'> & { open?: boolean; instant?: boolean }) {
  const level = React.useContext(SidebarMenuLevelContext) + 1
  const list = {
    'data-slot': 'sidebar-menu-sub',
    'data-sidebar': 'menu-sub',
    className: cn('flex min-w-0 flex-col group-data-[collapsible=icon]:hidden', className),
    style: { '--sidebar-menu-level': level, ...style } as React.CSSProperties,
    ...props
  }
  return (
    <SidebarMenuLevelContext value={level}>
      {open === undefined ? (
        <ul {...list}>{children}</ul>
      ) : (
        <SidebarCollapse open={open} instant={instant} element={<ul {...list} />}>
          {children}
        </SidebarCollapse>
      )}
    </SidebarMenuLevelContext>
  )
}

function SidebarMenuSubItem({ className, ...props }: React.ComponentProps<'li'>) {
  return (
    <li
      data-slot="sidebar-menu-sub-item"
      data-sidebar="menu-sub-item"
      className={cn('group/menu-sub-item relative', className)}
      {...props}
    />
  )
}

/** A child row; it takes the same geometry and states as `SidebarMenuButton` at its nesting level. */
function SidebarMenuSubButton({
  render,
  size = 'md',
  isActive = false,
  className,
  ...props
}: useRender.ComponentProps<'a'> &
  React.ComponentProps<'a'> & {
    size?: 'sm' | 'md'
    isActive?: boolean
  }) {
  return useRender({
    defaultTagName: 'a',
    props: mergeProps<'a'>(
      {
        className: cn(
          sidebarMenuButtonVariants({ size: size === 'sm' ? 'sm' : 'default' }),
          'group-data-[collapsible=icon]:hidden',
          className
        )
      },
      props
    ),
    render,
    state: {
      slot: 'sidebar-menu-sub-button',
      sidebar: 'menu-sub-button',
      size,
      active: isActive
    }
  })
}

export {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarFooterButton,
  SidebarFooterLabel,
  SidebarGroup,
  SidebarGroupAction,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarHeaderRow,
  SidebarInput,
  SidebarInset,
  SidebarMenu,
  SidebarMenuAction,
  SidebarMenuActions,
  SidebarMenuBadge,
  SidebarMenuButton,
  SidebarMenuIcon,
  SidebarMenuItem,
  SidebarMenuRow,
  SidebarMenuSkeleton,
  SidebarMenuSub,
  SidebarMenuSubButton,
  SidebarMenuSubItem,
  SidebarMenuText,
  SidebarMenuToggle,
  SidebarProvider,
  SidebarRail,
  SidebarSeparator,
  SidebarTrigger,
  useSidebar
}
