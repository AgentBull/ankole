'use client'

import { Checkbox as CheckboxPrimitive } from '@base-ui/react/checkbox'
import { RiCheckLine } from '@remixicon/react'
import { cn } from '../lib/utils'

function Checkbox({ className, ...props }: CheckboxPrimitive.Root.Props) {
  return (
    <CheckboxPrimitive.Root
      data-slot="checkbox"
      className={cn(
        'peer relative flex size-4 shrink-0 cursor-pointer items-center justify-center rounded-mini border border-input bg-background transition-shadow after:absolute after:-inset-x-3 after:-inset-y-2 focus-visible:outline-offset-1 data-disabled:cursor-not-allowed data-disabled:data-unchecked:border-border! data-disabled:data-unchecked:bg-field! data-disabled:data-checked:border-fg-disabled! data-disabled:data-checked:bg-fg-disabled! aria-invalid:border-destructive aria-invalid:aria-checked:border-foreground data-checked:border-foreground data-checked:bg-foreground data-checked:text-background',
        className
      )}
      {...props}>
      <CheckboxPrimitive.Indicator
        data-slot="checkbox-indicator"
        className="grid place-content-center text-current transition-none [&>svg]:size-4">
        <RiCheckLine />
      </CheckboxPrimitive.Indicator>
    </CheckboxPrimitive.Root>
  )
}

export { Checkbox }
