import { mergeProps } from '@base-ui/react/merge-props'
import { useRender } from '@base-ui/react/use-render'
import type * as React from 'react'
import { cn } from '../lib/utils'

/**
 * A rich menu row, such as a block type in the slash menu: a 44px icon tile 8px from the start, then a label of 14px
 * primary text on a 26px line and an optional hint at the end, on a 60px row that runs from edge to edge. It renders
 * a `div` by default; `render` makes it the item of the menu around it, such as a `CommandItem`, a
 * `DropdownMenuItem`, or a listbox option, and that item keeps its own `data-slot`. A `button` render keeps the
 * label at the start of the row. The row takes the hover fill under a fine pointer and whenever that item reports
 * itself highlighted or selected.
 */
function MenuRichItem({
  className,
  render,
  icon,
  hint,
  children,
  ...props
}: useRender.ComponentProps<'div'> &
  Omit<React.ComponentProps<'div'>, 'children'> & {
    icon?: React.ReactNode
    hint?: React.ReactNode
    children?: React.ReactNode
  }) {
  return useRender({
    defaultTagName: 'div',
    props: mergeProps<'div'>(
      {
        className: cn(
          'relative flex h-15 min-h-15 w-full cursor-pointer items-center gap-2 rounded-none py-0 ps-2 pe-4 text-start text-75 text-foreground outline-hidden select-none fine-hover:hover:bg-layer-hover data-highlighted:bg-layer-hover data-[selected=true]:bg-layer-hover aria-selected:bg-layer-hover data-disabled:pointer-events-none data-disabled:text-fg-disabled data-[disabled=true]:pointer-events-none data-[disabled=true]:text-fg-disabled aria-disabled:pointer-events-none aria-disabled:text-fg-disabled',
          className
        ),
        children: (
          <>
            {icon != null ? (
              <span data-slot="menu-rich-item-icon" className="flex size-11 shrink-0 items-center justify-center">
                {icon}
              </span>
            ) : null}
            <span data-slot="menu-rich-item-label" className="min-w-0 flex-1 truncate">
              {children}
            </span>
            {hint != null ? (
              <span data-slot="menu-rich-item-hint" className="shrink-0 text-50 text-fg-tertiary">
                {hint}
              </span>
            ) : null}
          </>
        )
      },
      props
    ),
    render,
    state: render === undefined ? { slot: 'menu-rich-item' } : {}
  })
}

/**
 * The footer row of a menu, such as the slash menu's "Explore": a 32px row of 12px medium tertiary text that starts
 * 16px in, with an optional 16px icon at its end. `render` turns it into a button or a link.
 */
function MenuFooter({ className, render, ...props }: useRender.ComponentProps<'div'> & React.ComponentProps<'div'>) {
  return useRender({
    defaultTagName: 'div',
    props: mergeProps<'div'>(
      {
        className: cn(
          "flex h-8 shrink-0 items-center justify-between gap-2 px-4 text-50 font-medium text-fg-tertiary [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
          className
        )
      },
      props
    ),
    render,
    state: {
      slot: 'menu-footer'
    }
  })
}

export { MenuFooter, MenuRichItem }
