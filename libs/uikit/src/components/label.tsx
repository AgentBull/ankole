import type * as React from 'react'

import { cn } from '../lib/utils'

function Label({ className, ...props }: React.ComponentProps<'label'>) {
  return (
    <label
      data-slot="label"
      className={cn(
        'flex items-center gap-2 text-[13px] leading-5 font-medium select-none has-data-[slot=checkbox]:font-normal has-data-[slot=radio-group-item]:font-normal has-data-[slot=switch]:font-normal peer-data-[slot=checkbox]:font-normal peer-data-[slot=radio-group-item]:font-normal peer-data-[slot=switch]:font-normal has-data-[slot=checkbox]:cursor-pointer has-data-[slot=radio-group-item]:cursor-pointer has-data-[slot=switch]:cursor-pointer has-disabled:cursor-not-allowed has-data-disabled:cursor-not-allowed has-data-disabled:text-fg-disabled group-data-[disabled=true]:pointer-events-none group-data-[disabled=true]:text-fg-disabled peer-disabled:cursor-not-allowed peer-disabled:text-fg-disabled peer-data-disabled:cursor-not-allowed peer-data-disabled:text-fg-disabled',
        className
      )}
      {...props}
    />
  )
}

export { Label }
