import { cn } from '../lib/utils'

/**
 * A placeholder for content that is loading. One band of light crosses every skeleton on the page together, so a
 * loading list reads as one surface instead of a set of blinking blocks.
 */
function Skeleton({ className, ...props }: React.ComponentProps<'div'>) {
  return <div data-slot="skeleton" className={cn('rounded-mini bg-skeleton', className)} {...props} />
}

export { Skeleton }
