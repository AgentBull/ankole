'use client'

import { renderElement } from '@ui-sdk/react/primitive'
import { Separator as SeparatorPrimitive } from '@ui-sdk/react/separator'
import type { ComponentProps } from 'react'

import { cn } from '../lib/utils'

/**
 * A 1px divider line. A horizontal separator spans its container's width; a vertical one stretches to the height of
 * the row that holds it. ui-sdk marks the orientation in `data-orientation`.
 */
function Separator({
  className,
  orientation = 'horizontal',
  'data-slot': slot = 'separator',
  render,
  ...props
}: ComponentProps<typeof SeparatorPrimitive> & { 'data-slot'?: string }) {
  return (
    <SeparatorPrimitive
      orientation={orientation}
      // A caller's own slot, such as a sidebar's or a button group's separator, replaces the name ui-sdk writes.
      render={(part, state) => renderElement('div', { ...part, 'data-slot': slot }, render, state)}
      className={cn(
        'shrink-0 bg-divider data-[orientation=horizontal]:h-px data-[orientation=horizontal]:w-full data-[orientation=vertical]:w-px data-[orientation=vertical]:self-stretch',
        className
      )}
      {...props}
    />
  )
}

export { Separator }
