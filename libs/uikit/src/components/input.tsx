import { Input as InputPrimitive } from '@base-ui/react/input'
import type * as React from 'react'

import { cn } from '../lib/utils'

function Input({ className, type, ...props }: React.ComponentProps<'input'>) {
  return (
    <InputPrimitive
      type={type}
      data-slot="input"
      className={cn(
        'h-8 w-full min-w-0 rounded-control border border-field-edge border-b-input bg-field px-3 text-sm leading-5 outline-none transition-[background-color] duration-(--duration-feedback) placeholder:text-fg-placeholder hover:bg-field-hover focus-visible:border-control-edge focus-visible:border-b-ring focus-visible:bg-background focus-visible:shadow-[inset_0_-1px_0_var(--color-ring)] user-invalid:border-b-destructive user-invalid:shadow-[inset_0_-1px_0_var(--color-destructive)] disabled:cursor-not-allowed disabled:border-b-transparent disabled:bg-field disabled:text-fg-disabled disabled:placeholder:text-fg-disabled aria-invalid:border-b-destructive aria-invalid:shadow-[inset_0_-1px_0_var(--color-destructive)]',
        type === 'file'
          ? 'cursor-pointer py-1 file:mr-3 file:inline-flex file:h-7 file:cursor-pointer file:items-center file:border-0 file:bg-transparent file:text-sm file:font-normal file:text-foreground'
          : 'py-2',
        type === 'search' &&
          'appearance-none [&::-webkit-search-cancel-button]:appearance-none [&::-webkit-search-decoration]:appearance-none',
        className
      )}
      {...props}
    />
  )
}

export { Input }
