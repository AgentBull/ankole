'use client'

import { Separator as SeparatorPrimitive } from '@base-ui/react/separator'

import { cn } from '../lib/utils'

/**
 * A 1px divider line. A horizontal separator spans its container's width; a vertical one stretches to the height of
 * the row that holds it. Base UI marks the orientation in `data-orientation`.
 */
function Separator({ className, orientation = 'horizontal', ...props }: SeparatorPrimitive.Props) {
  return (
    <SeparatorPrimitive
      data-slot="separator"
      orientation={orientation}
      className={cn(
        'shrink-0 bg-divider data-[orientation=horizontal]:h-px data-[orientation=horizontal]:w-full data-[orientation=vertical]:w-px data-[orientation=vertical]:self-stretch',
        className
      )}
      {...props}
    />
  )
}

export { Separator }
