import type * as React from 'react'

import { cn } from '../lib/utils'

type TableProps = React.ComponentProps<'table'> & {
  containerClassName?: string
  containerLabel?: string
}

function Table({ className, containerClassName, containerLabel, ...props }: TableProps) {
  return (
    <div
      data-slot="table-container"
      aria-label={containerLabel}
      role={containerLabel ? 'region' : undefined}
      tabIndex={containerLabel ? 0 : undefined}
      className={cn(
        'relative w-full overflow-x-auto focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring',
        containerClassName
      )}>
      <table
        data-slot="table"
        className={cn('w-full border-collapse caption-bottom text-sm leading-5', className)}
        {...props}
      />
    </div>
  )
}

function TableHeader({ className, ...props }: React.ComponentProps<'thead'>) {
  return <thead data-slot="table-header" className={cn('bg-muted', className)} {...props} />
}

function TableBody({ className, ...props }: React.ComponentProps<'tbody'>) {
  return <tbody data-slot="table-body" className={cn('[&_tr:last-child]:border-0', className)} {...props} />
}

function TableFooter({ className, ...props }: React.ComponentProps<'tfoot'>) {
  return (
    <tfoot
      data-slot="table-footer"
      className={cn('border-t bg-muted font-medium [&>tr]:last:border-b-0', className)}
      {...props}
    />
  )
}

function TableRow({ className, ...props }: React.ComponentProps<'tr'>) {
  return (
    <tr
      data-slot="table-row"
      className={cn(
        'h-12 transition-colors hover:bg-accent has-aria-expanded:bg-accent data-[state=selected]:bg-muted',
        className
      )}
      {...props}
    />
  )
}

// `scope` defaults to the column, which is what every header in a data table is.
// Without it a screen reader has to guess the header a cell belongs to, and it
// guesses from layout rather than from markup.
function TableHead({ className, scope = 'col', ...props }: React.ComponentProps<'th'>) {
  return (
    <th
      data-slot="table-head"
      scope={scope}
      className={cn(
        'h-12 px-4 text-left align-middle text-sm leading-5 font-semibold tracking-normal whitespace-nowrap text-foreground [&:has([role=checkbox])]:pr-0',
        className
      )}
      {...props}
    />
  )
}

function TableCell({ className, ...props }: React.ComponentProps<'td'>) {
  return (
    <td
      data-slot="table-cell"
      className={cn(
        'border-b border-border px-4 py-3 align-middle whitespace-nowrap text-muted-foreground [&:has([role=checkbox])]:pr-0',
        className
      )}
      {...props}
    />
  )
}

function TableCaption({ className, ...props }: React.ComponentProps<'caption'>) {
  return (
    <caption data-slot="table-caption" className={cn('mt-4 text-sm text-muted-foreground', className)} {...props} />
  )
}

export { Table, TableBody, TableCaption, TableCell, TableFooter, TableHead, TableHeader, TableRow }
