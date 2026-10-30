import { cva, type VariantProps } from 'class-variance-authority'
import type * as React from 'react'

import { cn } from '../lib/utils'

const alertVariants = cva(
  // Columns are icon, text, and action. The icon and the action sit on the first text line, so a one-line notice with
  // buttons stays one row; below the sm breakpoint the action wraps under the text instead.
  "group/alert relative grid min-h-12 w-full content-center gap-x-3 gap-y-1 border border-l-0 px-4 py-3 text-left text-sm leading-5 after:absolute after:-inset-y-px after:left-0 after:w-[3px] has-[>svg]:grid-cols-[auto_1fr] sm:has-data-[slot=alert-action]:grid-cols-[1fr_auto] sm:has-data-[slot=alert-action]:pr-2 sm:has-[>svg]:has-data-[slot=alert-action]:grid-cols-[auto_1fr_auto] *:[svg]:row-start-1 *:[svg]:text-current *:[svg:not([class*='size-'])]:size-5",
  {
    variants: {
      variant: {
        default: 'border-info/40 bg-info-subtle text-foreground after:bg-info *:[svg]:text-info',
        destructive:
          'border-destructive/40 bg-destructive-subtle text-foreground after:bg-destructive *:data-[slot=alert-description]:text-foreground *:[svg]:text-destructive',
        warning: 'border-warning/40 bg-warning-subtle text-foreground after:bg-warning *:[svg]:text-warning'
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
        'title-inline group-has-[>svg]/alert:col-start-2 [&_a]:underline [&_a]:underline-offset-3 [&_a]:hover:text-foreground',
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
        'text-sm leading-5 text-pretty text-foreground group-has-[>svg]/alert:col-start-2 [&_a]:underline [&_a]:underline-offset-3 [&_a]:hover:text-foreground [&_p:not(:last-child)]:mb-4',
        className
      )}
      {...props}
    />
  )
}

function AlertAction({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="alert-action"
      className={cn(
        'flex flex-wrap items-center gap-1 max-sm:mt-2 max-sm:group-has-[>svg]/alert:col-start-2 sm:col-[-2/-1] sm:row-start-1 sm:-my-1',
        className
      )}
      {...props}
    />
  )
}

export { Alert, AlertAction, AlertDescription, AlertTitle }
