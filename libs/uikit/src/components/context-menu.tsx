import { ContextMenu as ContextMenuPrimitive } from '@base-ui/react/context-menu'
import { cn } from '../lib/utils'
import { menuContentClassName } from './dropdown-menu'

/**
 * Opens on right-click and long press. Give the same actions a keyboard path,
 * for example a `DropdownMenu` button. Use the `DropdownMenu*` items inside.
 */
function ContextMenu({ ...props }: ContextMenuPrimitive.Root.Props) {
  return <ContextMenuPrimitive.Root data-slot="context-menu" {...props} />
}

function ContextMenuTrigger({ ...props }: ContextMenuPrimitive.Trigger.Props) {
  return <ContextMenuPrimitive.Trigger data-slot="context-menu-trigger" {...props} />
}

function ContextMenuContent({ className, ...props }: ContextMenuPrimitive.Popup.Props) {
  return (
    <ContextMenuPrimitive.Portal>
      <ContextMenuPrimitive.Positioner className="isolate z-50 outline-none">
        <ContextMenuPrimitive.Popup
          data-slot="context-menu-content"
          className={cn(menuContentClassName, 'w-56', className)}
          {...props}
        />
      </ContextMenuPrimitive.Positioner>
    </ContextMenuPrimitive.Portal>
  )
}

export { ContextMenu, ContextMenuContent, ContextMenuTrigger }
