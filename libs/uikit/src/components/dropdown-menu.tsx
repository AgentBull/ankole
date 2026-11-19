import {
  Menu,
  MenuCheckboxItem,
  MenuContent,
  MenuGroup,
  MenuItem,
  MenuItemIndicator,
  MenuRadioGroup,
  MenuRadioItem,
  MenuSeparator,
  MenuSub,
  MenuSubContent,
  MenuSubTrigger,
  MenuTrigger,
  type MenuContentState,
  type MenuTriggerState
} from '@ui-sdk/react/menu'
import type { RenderProp } from '@ui-sdk/react/primitive'
import { CheckmarkRegular, ChevronRightRegular } from '../icons'
import * as React from 'react'
import { focusTarget } from '../lib/focus-target'
import { usePopupContainer } from '../lib/popup-container'
import { cn } from '../lib/utils'

/**
 * A ui-sdk part writes its own `data-slot`, such as `menu-content`, unless the element it renders already carries
 * one. Page styles and popup checks select the uikit names, so the popup and trigger parts render through this. A
 * caller's element that names its own slot keeps it.
 */
function slotted<State>(
  slot: string,
  render: RenderProp<State> | React.ReactElement | undefined,
  tag: 'button' | 'div'
): RenderProp<State> {
  if (typeof render === 'function') return (props, state) => render({ ...props, 'data-slot': slot }, state)
  const element = (render ?? React.createElement(tag)) as React.ReactElement<Record<string, unknown>>
  return element.props['data-slot'] ? element : React.cloneElement(element, { 'data-slot': slot })
}

/**
 * Where focus goes when a menu closes. Besides ui-sdk's targets, a ref names an element, and a function may return
 * `true` to send focus back to the trigger or `false` to leave it where the chosen action put it.
 */
type MenuFinalFocus =
  | React.ComponentProps<typeof MenuContent>['finalFocus']
  | React.RefObject<HTMLElement | null>
  | (() => HTMLElement | boolean | null | undefined | void)

function menuFinalFocus(finalFocus: MenuFinalFocus): React.ComponentProps<typeof MenuContent>['finalFocus'] {
  if (typeof finalFocus !== 'function') return focusTarget(finalFocus)
  return () => {
    const target = finalFocus()
    if (target !== false) return target === true ? null : (target ?? null)
    // The element that already holds focus outside the closing menu keeps it.
    const active = document.activeElement
    return active instanceof HTMLElement ? active : null
  }
}

function DropdownMenu({ container, ...props }: React.ComponentProps<typeof Menu>) {
  return <Menu container={usePopupContainer(container)} {...props} />
}

/** The kit already mounts every menu in the document body, so this part only keeps the callers that wrap it. */
function DropdownMenuPortal({ children }: { children?: React.ReactNode }) {
  return <>{children}</>
}

function DropdownMenuTrigger({
  className,
  render,
  ...props
}: Omit<React.ComponentProps<typeof MenuTrigger>, 'render'> & {
  render?: RenderProp<MenuTriggerState> | React.ReactElement
}) {
  return (
    <MenuTrigger
      render={slotted('dropdown-menu-trigger', render, 'button')}
      className={cn('cursor-pointer disabled:cursor-not-allowed', className)}
      {...props}
    />
  )
}

const menuPopupClassName =
  'ceramic-menu z-50 max-h-(--available-height) w-auto min-w-[max(var(--anchor-width),10rem)] origin-(--transform-origin) overflow-x-hidden overflow-y-auto text-fg-primary outline-none transition-none data-closed:overflow-hidden data-starting-style:opacity-0 data-ending-style:opacity-0'

const menuContentClassName = cn('ceramic ceramic-primary p-1', menuPopupClassName)

type DropdownMenuContentProps = Omit<
  React.ComponentProps<typeof MenuContent>,
  'finalFocus' | 'className' | 'render'
> & {
  className?: string | ((state: MenuContentState) => string | undefined)
  render?: RenderProp<MenuContentState> | React.ReactElement
  finalFocus?: MenuFinalFocus
  surface?: 'ceramic' | 'composer'
}

function menuPopupProps({
  finalFocus,
  surface = 'ceramic',
  className,
  render,
  slot,
  ...props
}: DropdownMenuContentProps & { slot: string }) {
  return {
    ...props,
    'aria-labelledby': props['aria-labelledby'] ?? (props['aria-label'] ? '' : undefined),
    finalFocus: menuFinalFocus(finalFocus),
    render: slotted(slot, render, 'div'),
    className: (state: MenuContentState) =>
      cn(
        surface === 'composer' ? cn('composer-menu', menuPopupClassName) : menuContentClassName,
        typeof className === 'function' ? className(state) : className
      )
  }
}

/**
 * The popup of a menu. It is ceramic, like every menu. A menu that opens from the composer's toolbar takes the
 * `composer` surface: the same ceramic with rows that run from edge to edge.
 */
function DropdownMenuContent({
  align = 'start',
  alignOffset = 0,
  side = 'bottom',
  sideOffset = 4,
  ...props
}: DropdownMenuContentProps) {
  return (
    <MenuContent
      align={align}
      alignOffset={alignOffset}
      side={side}
      sideOffset={sideOffset}
      {...menuPopupProps({ ...props, slot: 'dropdown-menu-content' })}
    />
  )
}

function DropdownMenuGroup({ ...props }: React.ComponentProps<typeof MenuGroup>) {
  return <MenuGroup {...props} />
}

function DropdownMenuLabel({
  className,
  inset,
  ...props
}: React.ComponentProps<'div'> & {
  inset?: boolean
}) {
  return (
    <div
      data-slot="dropdown-menu-label"
      data-inset={inset}
      className={cn('menu-group-label data-inset:pl-9', className)}
      {...props}
    />
  )
}

const menuItemClassName =
  "group/dropdown-menu-item relative flex min-h-10 cursor-pointer items-center gap-2.5 rounded-control px-2.5 py-2 text-sm leading-5 font-normal text-fg-primary outline-hidden select-none focus:bg-(--layer-hover) data-inset:pl-9 data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-disabled:text-fg-disabled [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4"

/**
 * One action. `onClick` runs whenever the item is chosen, by pointer or keyboard; ui-sdk chooses a keyboard item
 * without a click, so the item hands `onClick` to ui-sdk's `onSelect`. Calling `preventDefault()` on its event keeps
 * the menu open.
 */
function DropdownMenuItem({
  className,
  inset,
  variant = 'default',
  onClick,
  ...props
}: Omit<React.ComponentProps<typeof MenuItem>, 'className' | 'onClick'> & {
  className?: string
  inset?: boolean
  variant?: 'default' | 'destructive'
  onClick?: (event: Event) => unknown
}) {
  return (
    <MenuItem
      data-inset={inset}
      data-variant={variant}
      className={cn(
        menuItemClassName,
        'data-[variant=destructive]:text-destructive-fg data-[variant=destructive]:focus:bg-destructive/10 dark:data-[variant=destructive]:focus:bg-destructive/20 data-[variant=destructive]:*:[svg]:text-destructive',
        className
      )}
      onSelect={onClick}
      {...props}
    />
  )
}

function DropdownMenuSub({ ...props }: React.ComponentProps<typeof MenuSub>) {
  return <MenuSub {...props} />
}

function DropdownMenuSubTrigger({
  className,
  inset,
  children,
  ...props
}: Omit<React.ComponentProps<typeof MenuSubTrigger>, 'className' | 'children'> & {
  className?: string
  children?: React.ReactNode
  inset?: boolean
}) {
  return (
    <MenuSubTrigger
      data-inset={inset}
      className={cn(menuItemClassName, 'data-open:bg-(--layer-hover)', className)}
      {...props}>
      {children}
      <ChevronRightRegular aria-hidden className="ml-auto -mr-1 size-4" />
    </MenuSubTrigger>
  )
}

/** ui-sdk opens a submenu beside its trigger and lines its first item up with the trigger. */
function DropdownMenuSubContent({ className, ...props }: DropdownMenuContentProps) {
  return (
    <MenuSubContent
      {...menuPopupProps({
        ...props,
        className: state => cn('w-auto min-w-36', typeof className === 'function' ? className(state) : className),
        slot: 'dropdown-menu-sub-content'
      })}
    />
  )
}

const menuItemIndicatorClassName =
  'pointer-events-none ml-auto flex size-4 shrink-0 items-center justify-center group-has-data-[slot=dropdown-menu-shortcut]/dropdown-menu-item:order-1'

/**
 * A setting that turns on and off. ui-sdk names each checkbox item by `value`; the item makes one up when the
 * caller has no use for it. `onClick` runs on every toggle, by pointer or keyboard.
 */
function DropdownMenuCheckboxItem({
  className,
  children,
  inset,
  value,
  onClick,
  onCheckedChange,
  ...props
}: Omit<React.ComponentProps<typeof MenuCheckboxItem>, 'className' | 'children' | 'value' | 'onClick'> & {
  className?: string
  children?: React.ReactNode
  inset?: boolean
  value?: string
  onClick?: (event: Event | undefined) => unknown
}) {
  const id = React.useId()
  return (
    <MenuCheckboxItem
      data-inset={inset}
      value={value ?? id}
      className={cn(menuItemClassName, className)}
      onCheckedChange={(checked, details) => {
        onClick?.(details.event)
        onCheckedChange?.(checked, details)
      }}
      {...props}>
      {children}
      <span className={menuItemIndicatorClassName} data-slot="dropdown-menu-checkbox-item-indicator">
        <MenuItemIndicator>
          <CheckmarkRegular aria-hidden />
        </MenuItemIndicator>
      </span>
    </MenuCheckboxItem>
  )
}

function DropdownMenuRadioGroup<T extends string = string>({
  ...props
}: React.ComponentProps<typeof MenuRadioGroup<T>>) {
  return <MenuRadioGroup<T> {...props} />
}

function DropdownMenuRadioItem({
  className,
  children,
  inset,
  ...props
}: Omit<React.ComponentProps<typeof MenuRadioItem>, 'className' | 'children'> & {
  className?: string
  children?: React.ReactNode
  inset?: boolean
}) {
  return (
    <MenuRadioItem data-inset={inset} className={cn(menuItemClassName, className)} {...props}>
      {children}
      <span className={menuItemIndicatorClassName} data-slot="dropdown-menu-radio-item-indicator">
        <MenuItemIndicator>
          <CheckmarkRegular aria-hidden />
        </MenuItemIndicator>
      </span>
    </MenuRadioItem>
  )
}

function DropdownMenuSeparator({
  className,
  ...props
}: Omit<React.ComponentProps<typeof MenuSeparator>, 'className'> & { className?: string }) {
  return <MenuSeparator className={cn('mx-2.5 my-1.5 h-px bg-divider-overlay', className)} {...props} />
}

function DropdownMenuShortcut({ className, ...props }: React.ComponentProps<'span'>) {
  return (
    <span
      data-slot="dropdown-menu-shortcut"
      className={cn(
        'ml-auto shrink-0 whitespace-nowrap text-right text-xs tracking-normal text-fg-secondary group-focus/dropdown-menu-item:text-fg-primary group-data-disabled/dropdown-menu-item:text-fg-disabled group-has-data-[slot=dropdown-menu-checkbox-item-indicator]/dropdown-menu-item:order-2 group-has-data-[slot=dropdown-menu-checkbox-item-indicator]/dropdown-menu-item:ml-0 group-has-data-[slot=dropdown-menu-radio-item-indicator]/dropdown-menu-item:order-2 group-has-data-[slot=dropdown-menu-radio-item-indicator]/dropdown-menu-item:ml-0',
        className
      )}
      {...props}
    />
  )
}

export {
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuPortal,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuShortcut,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger,
  menuContentClassName
}
