'use client'

import { useId, type ReactNode } from 'react'
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
      nativeButton
      render={<button type="button" />}
      data-slot="switch"
      data-size={size}
      className={cn(
        'peer relative inline-flex shrink-0 cursor-pointer items-center rounded-full border border-transparent motion-safe:[transition:background-color_200ms_ease] after:absolute after:-inset-x-3 after:-inset-y-2 focus-visible:outline-offset-1 aria-invalid:border-destructive data-[size=default]:h-5 data-[size=default]:w-[38px] data-[size=default]:[--switch-thumb:14px] data-[size=default]:[--switch-travel:18px] data-[size=sm]:h-4 data-[size=sm]:w-[30px] data-[size=sm]:[--switch-thumb:10px] data-[size=sm]:[--switch-travel:14px] data-checked:bg-foreground data-unchecked:bg-gray-70 data-disabled:cursor-not-allowed data-disabled:bg-gray-50! dark:data-unchecked:bg-gray-80 dark:data-disabled:bg-gray-90!',
        'motion-safe:[&:active:not([data-disabled],[data-readonly])]:[--switch-stretch:5px]',
        className
      )}
      {...props}>
      <SwitchPrimitive.Thumb
        data-slot="switch-thumb"
        className="pointer-events-none block h-(--switch-thumb) w-[calc(var(--switch-thumb)+var(--switch-stretch,0px))] translate-x-[2px] rounded-full bg-white ring-0 motion-safe:[transition:translate_260ms_cubic-bezier(.22,1,.36,1),width_160ms_cubic-bezier(.22,1,.36,1)] data-checked:translate-x-[calc(2px+var(--switch-travel)-var(--switch-stretch,0px))] dark:data-checked:bg-background"
      />
    </SwitchPrimitive.Root>
  )
}

function SwitchRow({
  label,
  labelFirst,
  rowClassName,
  id,
  ...props
}: Parameters<typeof Switch>[0] & { label: ReactNode; labelFirst?: boolean; rowClassName: string }) {
  const generatedID = useId()
  const switchID = id ?? generatedID
  return (
    <div className={cn('relative isolate', rowClassName)}>
      <label
        htmlFor={switchID}
        className={cn('cursor-pointer after:absolute after:inset-0 after:-z-1', !labelFirst && 'order-last')}>
        {label}
      </label>
      <Switch id={switchID} {...props} />
    </div>
  )
}

export { Switch, SwitchRow }
