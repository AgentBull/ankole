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
      className={cn('relative w-full overflow-x-auto focus-visible:-outline-offset-2', containerClassName)}>
      <table
        data-slot="table"
        className={cn('w-full border-collapse caption-bottom text-sm leading-5', className)}
        {...props}
      />
    </div>
  )
}

function TableHeader({ className, ...props }: React.ComponentProps<'thead'>) {
  return <thead data-slot="table-header" className={cn(className)} {...props} />
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

/**
 * A row whose object opens somewhere marks its opening control with `data-row-link`: the name link, or a
 * button that opens a view. A click on any other part of the row follows that control, so the whole row
 * opens the object, and the control stays the keyboard path.
 */
function TableRow({ className, onClick, ...props }: React.ComponentProps<'tr'>) {
  return (
    <tr
      data-slot="table-row"
      className={cn(
        'h-8 transition-colors fine-hover:hover:bg-accent has-aria-expanded:bg-accent has-data-row-link:cursor-pointer data-[state=selected]:bg-selection fine-hover:[&:hover_[data-row-link]]:underline',
        className
      )}
      onClick={event => {
        onClick?.(event)
        if (!event.defaultPrevented) followRowLink(event)
      }}
      {...props}
    />
  )
}

const ROW_CONTROLS =
  'a, button, input, select, textarea, label, summary, [role="button"], [role="checkbox"], [role="switch"], [role="menuitem"]'

function followRowLink(event: React.MouseEvent<HTMLTableRowElement>) {
  if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
  const row = event.currentTarget
  const control = (event.target as Element).closest(ROW_CONTROLS)
  // A click on a control in the row belongs to that control.
  if (control && row.contains(control)) return
  // A drag that selects text in the row is not a click on the row.
  if (document.getSelection()?.isCollapsed === false) return
  row.querySelector<HTMLElement>('[data-row-link]')?.click()
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
        'h-8 border-b border-gray-30 px-3 text-left align-middle text-xs leading-4 font-medium whitespace-nowrap text-muted-foreground dark:border-gray-70 [&:has([role=checkbox])]:pr-0',
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
        'border-b border-border px-3 py-1.5 align-middle whitespace-nowrap text-muted-foreground [&:has([role=checkbox])]:pr-0',
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
