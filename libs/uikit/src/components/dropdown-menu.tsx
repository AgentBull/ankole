import { Menu as MenuPrimitive } from '@base-ui/react/menu'
import { CheckmarkRegular, ChevronRightRegular } from '../icons'
import type * as React from 'react'
import { cn } from '../lib/utils'

function DropdownMenu({ ...props }: MenuPrimitive.Root.Props) {
  return <MenuPrimitive.Root data-slot="dropdown-menu" {...props} />
}

function DropdownMenuPortal({ ...props }: MenuPrimitive.Portal.Props) {
  return <MenuPrimitive.Portal data-slot="dropdown-menu-portal" {...props} />
}

function DropdownMenuTrigger({ className, ...props }: MenuPrimitive.Trigger.Props) {
  return (
    <MenuPrimitive.Trigger
      data-slot="dropdown-menu-trigger"
      className={cn('cursor-pointer disabled:cursor-not-allowed', className)}
      {...props}
    />
  )
}

const menuPopupClassName =
  'ceramic-menu z-50 max-h-(--available-height) w-auto min-w-[max(var(--anchor-width),10rem)] origin-(--transform-origin) overflow-x-hidden overflow-y-auto text-popover-foreground outline-none transition-none data-closed:overflow-hidden data-starting-style:opacity-0 data-ending-style:opacity-0'

const menuContentClassName = cn('ceramic ceramic-primary p-1', menuPopupClassName)

/**
 * The popup of a menu. It is ceramic, like every menu. A menu that opens from the composer's toolbar takes the
 * `composer` surface instead, so the menu and the composer read as one object.
 */
function DropdownMenuContent({
  align = 'start',
  alignOffset = 0,
  side = 'bottom',
  sideOffset = 4,
  surface = 'ceramic',
  className,
  ...props
}: MenuPrimitive.Popup.Props &
  Pick<MenuPrimitive.Positioner.Props, 'align' | 'alignOffset' | 'side' | 'sideOffset'> & {
    surface?: 'ceramic' | 'composer'
  }) {
  return (
    <MenuPrimitive.Portal>
      <MenuPrimitive.Positioner
        className="isolate z-50 outline-none"
        align={align}
        alignOffset={alignOffset}
        side={side}
        sideOffset={sideOffset}>
        <MenuPrimitive.Popup
          data-slot="dropdown-menu-content"
          className={cn(
            surface === 'composer' ? cn('composer-menu', menuPopupClassName) : menuContentClassName,
            className
          )}
          {...props}
        />
      </MenuPrimitive.Positioner>
    </MenuPrimitive.Portal>
  )
}

function DropdownMenuGroup({ ...props }: MenuPrimitive.Group.Props) {
  return <MenuPrimitive.Group data-slot="dropdown-menu-group" {...props} />
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

function DropdownMenuItem({
  className,
  inset,
  variant = 'default',
  ...props
}: MenuPrimitive.Item.Props & {
  inset?: boolean
  variant?: 'default' | 'destructive'
}) {
  return (
    <MenuPrimitive.Item
      data-slot="dropdown-menu-item"
      data-inset={inset}
      data-variant={variant}
      className={cn(
        "group/dropdown-menu-item relative flex min-h-10 cursor-pointer items-center gap-2.5 rounded-control px-2.5 py-2 text-sm leading-5 font-normal text-foreground outline-hidden select-none focus:bg-(--layer-hover) data-inset:pl-9 data-[variant=destructive]:text-destructive-foreground data-[variant=destructive]:focus:bg-destructive/10 dark:data-[variant=destructive]:focus:bg-destructive/20 data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-disabled:text-fg-disabled [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4 data-[variant=destructive]:*:[svg]:text-destructive",
        className
      )}
      {...props}
    />
  )
}

function DropdownMenuSub({ ...props }: MenuPrimitive.SubmenuRoot.Props) {
  return <MenuPrimitive.SubmenuRoot data-slot="dropdown-menu-sub" {...props} />
}

function DropdownMenuSubTrigger({
  className,
  inset,
  children,
  ...props
}: MenuPrimitive.SubmenuTrigger.Props & {
  inset?: boolean
}) {
  return (
    <MenuPrimitive.SubmenuTrigger
      data-slot="dropdown-menu-sub-trigger"
      data-inset={inset}
      className={cn(
        "group/dropdown-menu-item relative flex min-h-10 cursor-pointer items-center gap-2.5 rounded-control px-2.5 py-2 text-sm leading-5 font-normal text-foreground outline-hidden select-none focus:bg-(--layer-hover) data-inset:pl-9 data-open:bg-(--layer-hover) data-popup-open:bg-(--layer-hover) data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-disabled:text-fg-disabled [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      {...props}>
      {children}
      <ChevronRightRegular aria-hidden className="ml-auto -mr-1 size-4" />
    </MenuPrimitive.SubmenuTrigger>
  )
}

function DropdownMenuSubContent({
  align = 'start',
  alignOffset = -3,
  side = 'right',
  sideOffset = 0,
  className,
  ...props
}: React.ComponentProps<typeof DropdownMenuContent>) {
  return (
    <DropdownMenuContent
      data-slot="dropdown-menu-sub-content"
      className={cn('w-auto min-w-36', className)}
      align={align}
      alignOffset={alignOffset}
      side={side}
      sideOffset={sideOffset}
      {...props}
    />
  )
}

function DropdownMenuCheckboxItem({
  className,
  children,
  checked,
  inset,
  ...props
}: MenuPrimitive.CheckboxItem.Props & {
  inset?: boolean
}) {
  return (
    <MenuPrimitive.CheckboxItem
      data-slot="dropdown-menu-checkbox-item"
      data-inset={inset}
      className={cn(
        "group/dropdown-menu-item relative flex min-h-10 cursor-pointer items-center gap-2.5 rounded-control px-2.5 py-2 text-sm leading-5 font-normal text-foreground outline-hidden select-none focus:bg-(--layer-hover) data-inset:pl-9 data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-disabled:text-fg-disabled [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      checked={checked}
      {...props}>
      {children}
      <span
        className="pointer-events-none ml-auto flex size-4 shrink-0 items-center justify-center group-has-data-[slot=dropdown-menu-shortcut]/dropdown-menu-item:order-1"
        data-slot="dropdown-menu-checkbox-item-indicator">
        <MenuPrimitive.CheckboxItemIndicator>
          <CheckmarkRegular aria-hidden />
        </MenuPrimitive.CheckboxItemIndicator>
      </span>
    </MenuPrimitive.CheckboxItem>
  )
}

function DropdownMenuRadioGroup({ ...props }: MenuPrimitive.RadioGroup.Props) {
  return <MenuPrimitive.RadioGroup data-slot="dropdown-menu-radio-group" {...props} />
}

function DropdownMenuRadioItem({
  className,
  children,
  inset,
  ...props
}: MenuPrimitive.RadioItem.Props & {
  inset?: boolean
}) {
  return (
    <MenuPrimitive.RadioItem
      data-slot="dropdown-menu-radio-item"
      data-inset={inset}
      className={cn(
        "group/dropdown-menu-item relative flex min-h-10 cursor-pointer items-center gap-2.5 rounded-control px-2.5 py-2 text-sm leading-5 font-normal text-foreground outline-hidden select-none focus:bg-(--layer-hover) data-inset:pl-9 data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-disabled:text-fg-disabled [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      {...props}>
      {children}
      <span
        className="pointer-events-none ml-auto flex size-4 shrink-0 items-center justify-center group-has-data-[slot=dropdown-menu-shortcut]/dropdown-menu-item:order-1"
        data-slot="dropdown-menu-radio-item-indicator">
        <MenuPrimitive.RadioItemIndicator>
          <CheckmarkRegular aria-hidden />
        </MenuPrimitive.RadioItemIndicator>
      </span>
    </MenuPrimitive.RadioItem>
  )
}

function DropdownMenuSeparator({ className, ...props }: MenuPrimitive.Separator.Props) {
  return (
    <MenuPrimitive.Separator
      data-slot="dropdown-menu-separator"
      className={cn('mx-2.5 my-1.5 h-px bg-divider-overlay', className)}
      {...props}
    />
  )
}

function DropdownMenuShortcut({ className, ...props }: React.ComponentProps<'span'>) {
  return (
    <span
      data-slot="dropdown-menu-shortcut"
      className={cn(
        'ml-auto shrink-0 whitespace-nowrap text-right text-xs tracking-normal text-muted-foreground group-focus/dropdown-menu-item:text-accent-foreground group-data-disabled/dropdown-menu-item:text-fg-disabled group-has-data-[slot=dropdown-menu-checkbox-item-indicator]/dropdown-menu-item:order-2 group-has-data-[slot=dropdown-menu-checkbox-item-indicator]/dropdown-menu-item:ml-0 group-has-data-[slot=dropdown-menu-radio-item-indicator]/dropdown-menu-item:order-2 group-has-data-[slot=dropdown-menu-radio-item-indicator]/dropdown-menu-item:ml-0',
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
