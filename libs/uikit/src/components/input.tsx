import { Input as InputPrimitive } from '@base-ui/react/input'
import type * as React from 'react'

import { cn } from '../lib/utils'

function Input({ className, type, ...props }: React.ComponentProps<'input'>) {
  return (
    <InputPrimitive
      type={type}
      data-slot="input"
      className={cn(
        'h-10 w-full min-w-0 rounded-none border border-transparent border-b-input bg-field px-4 text-sm leading-5 outline-none placeholder:text-muted-foreground focus-visible:border-b-ring user-invalid:border-b-destructive disabled:cursor-not-allowed disabled:border-b-transparent disabled:bg-field disabled:text-fg-disabled disabled:placeholder:text-fg-disabled aria-invalid:border-b-destructive dark:aria-invalid:border-b-destructive/50',
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
