import { RiLoaderLine } from '@remixicon/react'
import type { ComponentPropsWithoutRef } from 'react'
import { cn } from '@/uikit/lib/utils'

type SpinnerProps = Omit<ComponentPropsWithoutRef<typeof RiLoaderLine>, 'children'>

function Spinner({ className, ...props }: SpinnerProps) {
  return <RiLoaderLine role="status" aria-label="Loading" className={cn('size-4 animate-spin', className)} {...props} />
}

export { Spinner }
