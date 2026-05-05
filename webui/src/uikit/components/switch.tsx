"use client"

import { Switch as SwitchPrimitive } from "@base-ui/react/switch"

import { cn } from "@/uikit/lib/utils"

function Switch({
  className,
  size = "default",
  ...props
}: SwitchPrimitive.Root.Props & {
  size?: "sm" | "default"
}) {
  return (
    <SwitchPrimitive.Root
      data-slot="switch"
      data-size={size}
      className={cn(
        "peer group/switch relative inline-flex shrink-0 cursor-pointer items-center rounded-full border border-transparent transition-colors outline-none after:absolute after:-inset-x-3 after:-inset-y-2 focus-visible:ring-2 focus-visible:ring-ring/30 aria-invalid:border-destructive aria-invalid:ring-2 aria-invalid:ring-destructive/20 data-[size=default]:h-6 data-[size=default]:w-12 data-[size=default]:[--switch-thumb:1.125rem] data-[size=default]:[--switch-x:1.6875rem] data-[size=sm]:h-4 data-[size=sm]:w-8 data-[size=sm]:[--switch-thumb:0.625rem] data-[size=sm]:[--switch-x:1.1875rem] dark:aria-invalid:border-destructive/50 dark:aria-invalid:ring-destructive/40 data-checked:bg-success data-unchecked:bg-gray-50 data-disabled:cursor-not-allowed data-disabled:opacity-50 dark:data-unchecked:bg-gray-60",
        className,
      )}
      {...props}>
      <SwitchPrimitive.Thumb
        data-slot="switch-thumb"
        className="pointer-events-none block size-[var(--switch-thumb)] rounded-full bg-white ring-0 transition-transform data-checked:translate-x-[var(--switch-x)] data-unchecked:translate-x-[0.1875rem]"
      />
    </SwitchPrimitive.Root>
  )
}

export { Switch }
