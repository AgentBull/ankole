import { mergeProps } from '@base-ui/react/merge-props'
import { useRender } from '@base-ui/react/use-render'
import { cva, type VariantProps } from 'class-variance-authority'

import { cn } from '../lib/utils'

const badgeVariants = cva(
  'group/badge inline-flex max-w-52 shrink-0 items-center justify-center gap-1 overflow-hidden rounded-full border border-transparent leading-none font-normal tracking-normal whitespace-nowrap normal-case transition-colors aria-invalid:border-destructive [&>svg]:pointer-events-none [&>svg]:size-3.5!',
  {
    variants: {
      // `sm` fits inside a 28px navigation row or tab, so a count or a short state sits beside a label.
      size: {
        default: 'h-6 min-w-8 px-2 text-xs',
        sm: 'h-4 min-w-4 px-1.5 text-[11px] tabular-nums'
      },
      variant: {
        // A status badge is the status background with ink text, in both themes.
        info: 'bg-badge-blue text-foreground hover:bg-badge-blue-hover [a]:hover:text-foreground',
        success: 'bg-badge-green text-foreground hover:bg-badge-green-hover [a]:hover:text-foreground',
        warning: 'bg-badge-yellow text-foreground hover:bg-badge-yellow-hover [a]:hover:text-foreground',
        secondary: 'bg-muted text-foreground hover:bg-gray-50 [a]:hover:text-foreground dark:hover:bg-gray-80',
        destructive: 'bg-badge-red text-foreground hover:bg-badge-red-hover [a]:hover:text-foreground',
        outline: 'border-control-edge bg-transparent text-foreground hover:bg-muted [a]:hover:text-foreground',
        ghost: 'bg-transparent text-muted-foreground hover:bg-muted hover:text-foreground',
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
}: useRender.ComponentProps<'span'> & VariantProps<typeof badgeVariants>) {
  return useRender({
    defaultTagName: 'span',
    props: mergeProps<'span'>(
      {
        className: cn(badgeVariants({ variant, size }), className)
      },
      props
    ),
    render,
    state: {
      slot: 'badge',
      variant,
      size
    }
  })
}

export { Badge, badgeVariants }
