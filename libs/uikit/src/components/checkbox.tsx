'use client'

import { Checkbox as CheckboxPrimitive } from '@base-ui/react/checkbox'
import { cn } from '../lib/utils'

function Checkbox({ className, ...props }: CheckboxPrimitive.Root.Props) {
  return (
    <CheckboxPrimitive.Root
      data-slot="checkbox"
      className={cn(
        'peer group/checkbox relative flex size-4 shrink-0 cursor-pointer items-center justify-center rounded-mini border border-input bg-background after:absolute after:-inset-x-3 after:-inset-y-2 focus-visible:outline-offset-1 data-disabled:cursor-not-allowed data-disabled:data-unchecked:border-border! data-disabled:data-unchecked:bg-field! aria-invalid:border-destructive',
        '[&:is([data-checked],[data-indeterminate])]:border-foreground [&:is([data-checked],[data-indeterminate])]:bg-foreground [&:is([data-checked],[data-indeterminate])]:text-background [&[data-disabled]:is([data-checked],[data-indeterminate])]:border-fg-disabled! [&[data-disabled]:is([data-checked],[data-indeterminate])]:bg-fg-disabled!',
        'motion-safe:[transition:background-color_160ms_ease,border-color_160ms_ease,box-shadow_160ms_ease,scale_160ms_cubic-bezier(.22,1,.36,1)] motion-safe:[&:active:not([data-disabled],[data-readonly])]:scale-90',
        className
      )}
      {...props}>
      <CheckboxPrimitive.Indicator
        data-slot="checkbox-indicator"
        keepMounted
        aria-hidden
        className="grid place-content-center">
        <svg
          viewBox="0 0 16 16"
          className="size-4"
          fill="none"
          stroke="currentColor"
          strokeWidth={1.8}
          strokeLinecap="round"
          strokeLinejoin="round">
          <path
            d="M4 8.5 6.75 11.25 12 5"
            pathLength={1}
            className="opacity-0 [stroke-dasharray:1] [stroke-dashoffset:1] group-data-checked/checkbox:opacity-100 group-data-checked/checkbox:[stroke-dashoffset:0] motion-safe:group-data-checked/checkbox:[transition:stroke-dashoffset_260ms_cubic-bezier(.22,1,.36,1)_40ms]"
          />
          <path
            d="M4.5 8h7"
            pathLength={1}
            className="opacity-0 [stroke-dasharray:1] [stroke-dashoffset:1] group-data-indeterminate/checkbox:opacity-100 group-data-indeterminate/checkbox:[stroke-dashoffset:0] motion-safe:group-data-indeterminate/checkbox:[transition:stroke-dashoffset_200ms_cubic-bezier(.22,1,.36,1)]"
          />
        </svg>
      </CheckboxPrimitive.Indicator>
    </CheckboxPrimitive.Root>
  )
}

export { Checkbox }
