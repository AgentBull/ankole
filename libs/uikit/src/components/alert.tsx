import { cva, type VariantProps } from 'class-variance-authority'
import type * as React from 'react'

import { cn } from '../lib/utils'

const alertVariants = cva(
  "group/alert relative grid min-h-12 w-full gap-1 border border-l-0 px-4 py-3 text-left text-sm leading-5 after:absolute after:-inset-y-px after:left-0 after:w-[3px] has-data-[slot=alert-action]:relative has-data-[slot=alert-action]:pr-18 has-[>svg]:grid-cols-[auto_1fr] has-[>svg]:gap-x-3 *:[svg]:row-span-2 *:[svg]:mt-0.5 *:[svg]:text-current *:[svg:not([class*='size-'])]:size-5",
  {
    variants: {
      variant: {
        default:
          'border-blue-60/40 bg-blue-10 text-foreground after:bg-info *:[svg]:text-info dark:border-blue-40/60 dark:bg-blue-100 dark:after:bg-blue-40 dark:*:[svg]:text-blue-40',
        destructive:
          'border-red-60/40 bg-red-10 text-foreground after:bg-destructive *:data-[slot=alert-description]:text-foreground *:[svg]:text-destructive dark:border-red-50/60 dark:bg-red-100 dark:after:bg-red-50 dark:*:[svg]:text-red-50'
      }
    },
    defaultVariants: {
      variant: 'default'
    }
  }
)

function Alert({ className, variant, ...props }: React.ComponentProps<'div'> & VariantProps<typeof alertVariants>) {
  return <div data-slot="alert" role="alert" className={cn(alertVariants({ variant }), className)} {...props} />
}

function AlertTitle({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="alert-title"
      className={cn(
        'text-sm leading-5 font-semibold tracking-normal group-has-[>svg]/alert:col-start-2 [&_a]:underline [&_a]:underline-offset-3 [&_a]:hover:text-foreground',
        className
      )}
      {...props}
    />
  )
}

function AlertDescription({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="alert-description"
      className={cn(
        'text-sm leading-5 text-balance text-foreground md:text-pretty [&_a]:underline [&_a]:underline-offset-3 [&_a]:hover:text-foreground [&_p:not(:last-child)]:mb-4',
        className
      )}
      {...props}
    />
  )
}

function AlertAction({ className, ...props }: React.ComponentProps<'div'>) {
  return <div data-slot="alert-action" className={cn('absolute top-2.5 right-3', className)} {...props} />
}

export { Alert, AlertAction, AlertDescription, AlertTitle }
