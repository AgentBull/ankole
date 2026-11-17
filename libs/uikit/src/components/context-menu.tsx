import { Menu, MenuContextTrigger } from '@ui-sdk/react/menu'
import type * as React from 'react'
import { usePopupContainer } from '../lib/popup-container'
import { cn } from '../lib/utils'
import { DropdownMenuContent } from './dropdown-menu'

/**
 * Opens on right-click and long press. Give the same actions a keyboard path,
 * for example a `DropdownMenu` button. Use the `DropdownMenu*` items inside.
 */
function ContextMenu({ container, ...props }: React.ComponentProps<typeof Menu>) {
  return <Menu container={usePopupContainer(container)} {...props} />
}

/** `disabled` leaves the browser's own menu to this area. */
function ContextMenuTrigger({ ...props }: React.ComponentProps<typeof MenuContextTrigger>) {
  return <MenuContextTrigger {...props} />
}

/** The menu opens with its corner at the pointer. */
function ContextMenuContent({ className, ...props }: React.ComponentProps<typeof DropdownMenuContent>) {
  return (
    <DropdownMenuContent
      render={<div data-slot="context-menu-content" />}
      sideOffset={0}
      className={state => cn('w-56', typeof className === 'function' ? className(state) : className)}
      {...props}
    />
  )
}

export { ContextMenu, ContextMenuContent, ContextMenuTrigger }
