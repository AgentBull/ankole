'use client'

import { Switch as SwitchPrimitive } from '@base-ui/react/switch'

import { cn } from '../lib/utils'

/**
 * On/off control.
 *
 * The checked track is ink. A switch reports a setting the operator chose, which
 * is a state, not an intent: green would claim that the system is healthy, and
 * berry would ask the operator to act.
 */
function Switch({
  className,
  size = 'default',
  ...props
}: SwitchPrimitive.Root.Props & {
  size?: 'sm' | 'default'
}) {
  return (
    <SwitchPrimitive.Root
      data-slot="switch"
      data-size={size}
      className={cn(
        'peer group/switch relative inline-flex shrink-0 cursor-pointer items-center rounded-full border border-transparent transition-colors after:absolute after:-inset-x-3 after:-inset-y-2 focus-visible:outline-offset-1 aria-invalid:border-destructive data-[size=default]:h-5 data-[size=default]:w-[38px] data-[size=default]:[--switch-thumb:14px] data-[size=default]:[--switch-x:20px] data-[size=default]:[--switch-x0:2px] data-[size=sm]:h-4 data-[size=sm]:w-[30px] data-[size=sm]:[--switch-thumb:10px] data-[size=sm]:[--switch-x:16px] data-[size=sm]:[--switch-x0:2px] data-checked:bg-foreground data-unchecked:bg-gray-50 data-disabled:cursor-not-allowed data-disabled:bg-gray-30! dark:data-unchecked:bg-gray-60 dark:data-disabled:bg-gray-70!',
        className
      )}
      {...props}>
      <SwitchPrimitive.Thumb
        data-slot="switch-thumb"
        className="pointer-events-none block size-[var(--switch-thumb)] rounded-full bg-white ring-0 transition-transform dark:data-checked:bg-background data-checked:translate-x-[var(--switch-x)] data-unchecked:translate-x-[var(--switch-x0)]"
      />
    </SwitchPrimitive.Root>
  )
}

export { Switch }
