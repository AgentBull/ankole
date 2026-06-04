import type * as React from 'react'

import { cn } from '@/uikit/lib/utils'

function Label({ className, ...props }: React.ComponentProps<'label'>) {
  return (
    <label
      data-slot="label"
      className={cn(
        'flex items-center gap-2 text-xs font-normal tracking-normal normal-case select-none has-data-[slot=checkbox]:cursor-pointer has-data-[slot=radio-group-item]:cursor-pointer has-data-[slot=switch]:cursor-pointer has-disabled:cursor-not-allowed group-data-[disabled=true]:pointer-events-none group-data-[disabled=true]:opacity-50 peer-disabled:cursor-not-allowed peer-disabled:opacity-50 peer-data-[slot=checkbox]:text-sm peer-data-[slot=radio-group-item]:text-sm peer-data-[slot=switch]:text-sm',
        className
      )}
      {...props}
    />
  )
}

export { Label }
