import type * as React from 'react'

import { cn } from '../lib/utils'

function Textarea({ className, ...props }: React.ComponentProps<'textarea'>) {
  return (
    <textarea
      data-slot="textarea"
      className={cn(
        'flex field-sizing-content min-h-24 w-full resize-none rounded-control border border-field-edge border-b-input bg-field px-3 py-1.5 text-sm leading-[22px] outline-none transition-[background-color] duration-(--duration-feedback) placeholder:text-fg-placeholder hover:bg-field-hover focus-visible:border-control-edge focus-visible:border-b-ring focus-visible:bg-background focus-visible:shadow-[inset_0_-1px_0_var(--color-ring)] user-invalid:border-b-destructive user-invalid:shadow-[inset_0_-1px_0_var(--color-destructive)] disabled:cursor-not-allowed disabled:border-b-transparent disabled:bg-field disabled:text-fg-disabled disabled:placeholder:text-fg-disabled aria-invalid:border-b-destructive aria-invalid:shadow-[inset_0_-1px_0_var(--color-destructive)]',
        className
      )}
      {...props}
    />
  )
}

export { Textarea }
