import type * as React from 'react'

import { cn } from '@/uikit/lib/utils'

function Textarea({ className, ...props }: React.ComponentProps<'textarea'>) {
  return (
    <textarea
      data-slot="textarea"
      className={cn(
        'flex field-sizing-content min-h-24 w-full resize-none rounded-none border border-transparent border-b-input bg-field px-4 py-3 text-sm transition-[background-color,border-color] outline-none placeholder:text-muted-foreground focus-visible:border-b-ring disabled:cursor-not-allowed disabled:bg-muted disabled:text-muted-foreground aria-invalid:border-b-destructive dark:aria-invalid:border-b-destructive/50',
        className
      )}
      {...props}
    />
  )
}

export { Textarea }
