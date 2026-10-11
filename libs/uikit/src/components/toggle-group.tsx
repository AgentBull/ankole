'use client'

import * as React from 'react'
import { Toggle as TogglePrimitive } from '@base-ui/react/toggle'
import { ToggleGroup as ToggleGroupPrimitive } from '@base-ui/react/toggle-group'
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
}: ToggleGroupPrimitive.Props &
  VariantProps<typeof toggleVariants> & {
    spacing?: number
    orientation?: 'horizontal' | 'vertical'
  }) {
  return (
    <ToggleGroupPrimitive
      data-slot="toggle-group"
      data-variant={variant}
      data-size={size}
      data-spacing={spacing}
      data-orientation={orientation}
      style={{ '--gap': spacing } as React.CSSProperties}
      className={cn(
        // With no spacing, the group is a segmented choice: a slot that holds the chosen object.
        'group/toggle-group flex w-fit flex-row items-center gap-[--spacing(var(--gap))] data-[spacing=0]:gap-0.5 data-[spacing=0]:rounded-control data-[spacing=0]:border data-[spacing=0]:border-field-edge data-[spacing=0]:border-b-input data-[spacing=0]:bg-field data-[spacing=0]:p-0.5 data-vertical:flex-col data-vertical:items-stretch',
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
}: TogglePrimitive.Props & VariantProps<typeof toggleVariants>) {
  const context = React.useContext(ToggleGroupContext)

  return (
    <TogglePrimitive
      data-slot="toggle-group-item"
      data-variant={context.variant || variant}
      data-size={context.size || size}
      data-spacing={context.spacing}
      className={cn(
        'shrink-0 focus:z-10 focus-visible:z-10 group-data-[spacing=0]/toggle-group:h-6.5 group-data-[spacing=0]/toggle-group:rounded-mini group-data-[spacing=0]/toggle-group:px-2.5 group-data-[spacing=0]/toggle-group:hover:bg-field-hover group-data-[spacing=0]/toggle-group:focus-visible:-outline-offset-2 group-data-[spacing=0]/toggle-group:data-[size=sm]:h-5.5 group-data-[spacing=0]/toggle-group:data-[size=sm]:px-2 group-data-[spacing=0]/toggle-group:aria-pressed:border-control-edge group-data-[spacing=0]/toggle-group:aria-pressed:border-b-control-base group-data-[spacing=0]/toggle-group:aria-pressed:bg-control',
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
