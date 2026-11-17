'use client'

import { Toggle as TogglePrimitive } from '@ui-sdk/react/toggle'
import { cva, type VariantProps } from 'class-variance-authority'
import type { ComponentProps } from 'react'

import { cn } from '@ankole/uikit/lib/utils'

const toggleVariants = cva(
  "group/toggle inline-flex items-center justify-center gap-1.5 rounded-control border border-transparent text-65 font-medium whitespace-nowrap text-fg-secondary transition-colors hover:bg-layer-hover hover:text-fg-primary focus-visible:outline-offset-1 disabled:pointer-events-none disabled:text-fg-disabled aria-invalid:border-destructive aria-pressed:bg-field aria-pressed:text-fg-primary [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
  {
    variants: {
      variant: {
        default: 'bg-transparent',
        outline:
          'border-control-edge bg-control hover:bg-control-hover aria-pressed:bg-field disabled:border-border-subtle disabled:bg-field'
      },
      size: {
        default: 'h-8 min-w-8 px-3 has-data-[icon=inline-end]:pr-2.5 has-data-[icon=inline-start]:pl-2.5',
        sm: 'h-7 min-w-7 px-2.5 has-data-[icon=inline-end]:pr-2 has-data-[icon=inline-start]:pl-2',
        // A shell toolbar's 32px toggle, like the `icon-lg` button: its fills tint only the box that holds the 20px
        // icon, 6px inside the toggle's edge, and keep the micro radius there.
        'icon-lg':
          "size-8 min-w-8 rounded-[calc(var(--radius-micro)+var(--spacing)*1.5)] bg-clip-content p-1.25 [&_svg:not([class*='size-'])]:size-5"
      }
    },
    defaultVariants: {
      variant: 'default',
      size: 'default'
    }
  }
)

function Toggle({
  className,
  variant = 'default',
  size = 'default',
  ...props
}: ComponentProps<typeof TogglePrimitive> & VariantProps<typeof toggleVariants>) {
  return <TogglePrimitive data-slot="toggle" className={cn(toggleVariants({ variant, size, className }))} {...props} />
}

export { Toggle, toggleVariants }
