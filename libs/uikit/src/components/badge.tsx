import { mergeProps, renderElement, type RenderProp } from '@ui-sdk/react/primitive'
import { cva, type VariantProps } from 'class-variance-authority'
import type * as React from 'react'

import { cn } from '../lib/utils'

const badgeVariants = cva(
  'group/badge inline-flex max-w-52 shrink-0 items-center justify-center gap-1 overflow-hidden rounded-full border border-transparent leading-none font-normal tracking-normal whitespace-nowrap normal-case transition-colors aria-invalid:border-destructive [&>svg]:pointer-events-none [&>svg]:size-3.5!',
  {
    variants: {
      // `sm` fits inside a 28px navigation row or tab, so a count or a short state sits beside a label.
      size: {
        default: 'h-6 min-w-8 px-2 text-xs',
        sm: 'h-4 min-w-4 px-1.5 text-50 tabular-nums'
      },
      variant: {
        // A status badge lays its status background at `--status-fill-alpha` and writes its label in the dark step of
        // the same hue (`--badge-*-fg`); the dark theme keeps the full background and ink text.
        info: 'bg-badge-blue/(--status-fill-alpha) text-(--badge-blue-fg) hover:bg-badge-blue-hover [a]:hover:text-(--badge-blue-fg)',
        success:
          'bg-badge-green/(--status-fill-alpha) text-(--badge-green-fg) hover:bg-badge-green-hover [a]:hover:text-(--badge-green-fg)',
        warning:
          'bg-badge-yellow/(--status-fill-alpha) text-(--badge-yellow-fg) hover:bg-badge-yellow-hover [a]:hover:text-(--badge-yellow-fg)',
        // A count that asks for attention, such as unread items on a navigation tab: brand-60 with a white figure.
        primary: 'bg-primary px-1 text-primary-fg',
        secondary:
          'bg-layer-03 text-fg-primary hover:bg-(--badge-secondary-hover) [a]:hover:text-fg-primary [&>svg]:text-fg-secondary',
        destructive:
          'bg-badge-red/(--status-fill-alpha) text-(--badge-red-fg) hover:bg-badge-red-hover [a]:hover:text-(--badge-red-fg)',
        // An outline badge, such as a version, draws the strong overlay border around secondary text.
        outline:
          'border-border-overlay-strong bg-transparent text-fg-secondary hover:bg-layer-03 [a]:hover:text-fg-primary',
        ghost: 'bg-transparent text-fg-secondary hover:bg-layer-03 hover:text-fg-primary',
        link: 'link h-auto min-w-0 max-w-none rounded-none bg-transparent px-0'
      }
    },
    defaultVariants: {
      variant: 'secondary',
      size: 'default'
    }
  }
)

function Badge({
  className,
  variant = 'secondary',
  size = 'default',
  render,
  ...props
}: React.ComponentProps<'span'> & { render?: RenderProp } & VariantProps<typeof badgeVariants>) {
  return renderElement(
    'span',
    mergeProps(
      {
        'data-slot': 'badge',
        'data-variant': variant,
        'data-size': size,
        className: cn(badgeVariants({ variant, size }), className)
      },
      props
    ),
    render
  )
}

export { Badge, badgeVariants }
