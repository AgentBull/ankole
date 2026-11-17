'use client'

import { Toggle as TogglePrimitive, ToggleGroup as ToggleGroupPrimitive } from '@ui-sdk/react/toggle'
import * as React from 'react'
import { type VariantProps } from 'class-variance-authority'

import { cn } from '@ankole/uikit/lib/utils'
import { toggleVariants } from '@ankole/uikit/components/toggle'

const ToggleGroupContext = React.createContext<
  VariantProps<typeof toggleVariants> & {
    spacing?: number
    orientation?: 'horizontal' | 'vertical'
  }
>({
  size: 'default',
  variant: 'default',
  spacing: 2,
  orientation: 'horizontal'
})

function ToggleGroup({
  className,
  variant,
  size,
  spacing = 2,
  orientation = 'horizontal',
  children,
  ...props
}: Omit<React.ComponentProps<typeof ToggleGroupPrimitive>, 'children'> &
  VariantProps<typeof toggleVariants> & {
    children?: React.ReactNode
    spacing?: number
    orientation?: 'horizontal' | 'vertical'
  }) {
  return (
    <ToggleGroupPrimitive
      orientation={orientation}
      data-variant={variant}
      data-size={size}
      data-spacing={spacing}
      style={{ '--gap': spacing } as React.CSSProperties}
      className={cn(
        // With no spacing, the group is a segmented choice: a slot that holds the chosen object.
        'group/toggle-group flex w-fit flex-row items-center gap-[--spacing(var(--gap))] data-[spacing=0]:gap-0.5 data-[spacing=0]:rounded-control data-[spacing=0]:border data-[spacing=0]:border-field-border data-[spacing=0]:bg-field data-[spacing=0]:p-0.5 data-[orientation=vertical]:flex-col data-[orientation=vertical]:items-stretch',
        className
      )}
      {...props}>
      <ToggleGroupContext.Provider value={{ variant, size, spacing, orientation }}>
        {children}
      </ToggleGroupContext.Provider>
    </ToggleGroupPrimitive>
  )
}

function ToggleGroupItem({
  className,
  children,
  variant = 'default',
  size = 'default',
  ...props
}: React.ComponentProps<typeof TogglePrimitive> & VariantProps<typeof toggleVariants>) {
  const context = React.useContext(ToggleGroupContext)

  return (
    <TogglePrimitive
      data-variant={context.variant || variant}
      data-size={context.size || size}
      data-spacing={context.spacing}
      className={cn(
        'shrink-0 focus:z-10 focus-visible:z-10 group-data-[spacing=0]/toggle-group:h-6.5 group-data-[spacing=0]/toggle-group:rounded-micro group-data-[spacing=0]/toggle-group:px-2.5 group-data-[spacing=0]/toggle-group:hover:bg-field-hover group-data-[spacing=0]/toggle-group:focus-visible:-outline-offset-2 group-data-[spacing=0]/toggle-group:data-[size=sm]:h-5.5 group-data-[spacing=0]/toggle-group:data-[size=sm]:px-2 group-data-[spacing=0]/toggle-group:aria-pressed:border-(--choice) group-data-[spacing=0]/toggle-group:aria-pressed:bg-control group-data-[spacing=0]/toggle-group:aria-pressed:shadow-control',
        toggleVariants({
          variant: context.variant || variant,
          size: context.size || size
        }),
        className
      )}
      {...props}>
      {children}
    </TogglePrimitive>
  )
}

export { ToggleGroup, ToggleGroupItem }
