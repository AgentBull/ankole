'use client'

import { Radio, RadioGroup as RadioGroupPrimitive, RadioIndicator } from '@ui-sdk/react/radio'
import type { ComponentProps } from 'react'

import { cn } from '../lib/utils'

function RadioGroup({ className, ...props }: ComponentProps<typeof RadioGroupPrimitive>) {
  return <RadioGroupPrimitive className={cn('grid w-full gap-3', className)} {...props} />
}

function RadioGroupItem({ className, ...props }: ComponentProps<typeof Radio>) {
  return (
    <Radio
      className={cn(
        'group/radio-group-item peer relative flex aspect-square size-4 shrink-0 cursor-pointer rounded-full border border-(--choice-edge) bg-page motion-safe:[transition:border-color_160ms_ease,scale_160ms_var(--ease-segment)] motion-safe:active:not-data-disabled:scale-90 after:absolute after:-inset-x-3 after:-inset-y-2 focus-visible:outline-offset-1 data-disabled:cursor-not-allowed data-disabled:border-border-subtle! data-disabled:bg-field! aria-invalid:border-destructive aria-invalid:aria-checked:border-(--choice) data-checked:border-(--choice)',
        className
      )}
      {...props}>
      <RadioIndicator className="flex size-4 items-center justify-center">
        <span className="absolute top-1/2 left-1/2 size-2 -translate-x-1/2 -translate-y-1/2 rounded-full bg-(--choice) group-data-disabled/radio-group-item:bg-fg-disabled motion-safe:animate-radio-dot" />
      </RadioIndicator>
    </Radio>
  )
}

export { RadioGroup, RadioGroupItem }
