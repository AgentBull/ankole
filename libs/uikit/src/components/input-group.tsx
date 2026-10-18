'use client'

import { cva, type VariantProps } from 'class-variance-authority'
import type * as React from 'react'
import { Button } from './button'
import { Input } from './input'
import { Textarea } from './textarea'
import { cn } from '../lib/utils'

function InputGroup({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="input-group"
      role="group"
      className={cn(
        'group/input-group relative flex h-8 w-full min-w-0 items-center rounded-control border border-field-edge border-b-input bg-field px-3 outline-none transition-[background-color] duration-(--duration-feedback) hover:bg-field-hover has-[[data-slot=input-group-control]:focus-visible]:border-control-edge has-[[data-slot=input-group-control]:focus-visible]:border-b-ring has-[[data-slot=input-group-control]:focus-visible]:bg-background has-[[data-slot=input-group-control]:focus-visible]:shadow-[inset_0_-1px_0_var(--color-ring)] has-[[data-slot][aria-invalid=true]]:border-b-destructive has-[[data-slot][aria-invalid=true]]:shadow-[inset_0_-1px_0_var(--color-destructive)] has-[:user-invalid]:border-b-destructive has-[:user-invalid]:shadow-[inset_0_-1px_0_var(--color-destructive)] has-[input:disabled]:border-b-transparent has-[input:disabled]:text-fg-disabled has-[>[data-align=block-end]]:h-auto has-[>[data-align=block-end]]:flex-col has-[>[data-align=block-start]]:h-auto has-[>[data-align=block-start]]:flex-col has-[>textarea]:h-auto has-[>[data-align=block-end]]:[&>input]:pt-3 has-[>[data-align=block-start]]:[&>input]:pb-3',
        className
      )}
      {...props}
    />
  )
}

const inputGroupAddonVariants = cva(
  "flex h-auto cursor-text items-center justify-center gap-2 py-2 text-sm leading-5 font-medium text-muted-foreground select-none group-data-[disabled=true]/input-group:opacity-50 [&>svg:not([class*='size-'])]:size-3.5",
  {
    variants: {
      align: {
        'inline-start': 'order-first',
        'inline-end': 'order-last',
        'block-start': 'order-first w-full justify-start pt-3 group-has-[>input]/input-group:pt-3.5 [.border-b]:pb-3.5',
        'block-end': 'order-last w-full justify-start pb-3 group-has-[>input]/input-group:pb-3.5 [.border-t]:pt-3.5'
      }
    },
    defaultVariants: {
      align: 'inline-start'
    }
  }
)

function InputGroupAddon({
  className,
  align = 'inline-start',
  ...props
}: React.ComponentProps<'div'> & VariantProps<typeof inputGroupAddonVariants>) {
  return (
    <div
      role="group"
      data-slot="input-group-addon"
      data-align={align}
      className={cn(inputGroupAddonVariants({ align }), className)}
      onMouseDown={e => {
        if (!e.currentTarget.contains(e.target as Node) || (e.target as HTMLElement).closest('button')) {
          return
        }
        e.currentTarget.parentElement?.querySelector('input')?.focus()
      }}
      {...props}
    />
  )
}

const inputGroupButtonVariants = cva(
  'flex min-w-0! items-center justify-center gap-2 rounded-mini text-sm shadow-none',
  {
    variants: {
      size: {
        xs: "h-6 gap-1 rounded-mini px-1.5 text-xs [&>svg:not([class*='size-'])]:size-3.5",
        sm: '',
        'icon-xs': 'size-6 p-0 text-xs has-[>svg]:p-0',
        'icon-sm': 'size-7 p-0 has-[>svg]:p-0'
      }
    },
    defaultVariants: {
      size: 'xs'
    }
  }
)

function InputGroupButton({
  className,
  type = 'button',
  variant = 'ghost',
  size = 'xs',
  ...props
}: Omit<React.ComponentProps<typeof Button>, 'size' | 'type'> &
  VariantProps<typeof inputGroupButtonVariants> & {
    type?: 'button' | 'submit' | 'reset'
  }) {
  return (
    <Button
      type={type}
      data-size={size}
      variant={variant}
      className={cn(inputGroupButtonVariants({ size }), className)}
      {...props}
    />
  )
}

function InputGroupText({ className, ...props }: React.ComponentProps<'span'>) {
  return (
    <span
      className={cn(
        "flex items-center gap-2 text-sm leading-5 text-muted-foreground [&_svg]:pointer-events-none [&_svg:not([class*='size-'])]:size-3.5",
        className
      )}
      {...props}
    />
  )
}

function InputGroupInput({ className, ...props }: React.ComponentProps<'input'>) {
  return (
    <Input
      data-slot="input-group-control"
      className={cn(
        'flex-1 border-0 bg-transparent px-0 ring-0 group-has-[>[data-align=inline-end]]/input-group:pr-2 group-has-[>[data-align=inline-start]]/input-group:pl-2 hover:bg-transparent focus-visible:bg-transparent focus-visible:shadow-none focus-visible:ring-0 aria-invalid:shadow-none aria-invalid:ring-0 dark:bg-transparent',
        className
      )}
      {...props}
    />
  )
}

function InputGroupTextarea({ className, ...props }: React.ComponentProps<'textarea'>) {
  return (
    <Textarea
      data-slot="input-group-control"
      className={cn(
        'flex-1 resize-none border-0 bg-transparent py-2 ring-0 hover:bg-transparent focus-visible:bg-transparent focus-visible:shadow-none focus-visible:ring-0 aria-invalid:shadow-none aria-invalid:ring-0 dark:bg-transparent',
        className
      )}
      {...props}
    />
  )
}

export { InputGroup, InputGroupAddon, InputGroupButton, InputGroupInput, InputGroupText, InputGroupTextarea }
