'use client'

import { cva, type VariantProps } from 'class-variance-authority'
import type * as React from 'react'
import { Button } from './button'
import { Input } from './input'
import { Textarea } from './textarea'
import { cn } from '../lib/utils'

/**
 * `default` is a slot in a form. `overlay` is a field inside ceramic. `paper` is a writing surface on the page: a
 * sheet of paper lifted a little off the page, whose edge darkens while it has focus. `composer` is the chat
 * composer that floats over the bottom of the page on the `composer-surface`, and the editor of a sent message takes
 * the same surface: its text area sits on top, and a 36px toolbar along its bottom edge holds the tools and
 * `InputGroupSend`.
 */
function InputGroup({
  className,
  variant = 'default',
  ...props
}: React.ComponentProps<'div'> & { variant?: 'default' | 'overlay' | 'paper' | 'composer' }) {
  return (
    <div
      data-slot="input-group"
      data-variant={variant}
      role="group"
      className={cn(
        'group/input-group relative flex h-8 w-full min-w-0 items-center px-3 outline-none transition-[background-color] duration-(--duration-feedback) has-[:is(input,textarea):disabled]:text-fg-disabled has-[>[data-align=block-end]]:h-auto has-[>[data-align=block-end]]:flex-col has-[>[data-align=block-start]]:h-auto has-[>[data-align=block-start]]:flex-col has-[>textarea]:h-auto has-[>[data-align=block-end]]:[&>input]:pt-3 has-[>[data-align=block-start]]:[&>input]:pb-3',
        variant === 'composer'
          ? 'composer-surface h-auto flex-col items-stretch px-0'
          : variant === 'paper'
            ? 'rounded-panel bg-background shadow-(--paper-shadow) has-[:is(input,textarea):focus-visible]:shadow-[0_0_0_1px_var(--border-strong),0_2px_8px_rgb(35_37_38/0.06)]'
            : variant === 'overlay'
              ? 'h-9 rounded-[6px] border border-(--menu-field-edge) bg-(--menu-field) shadow-none has-[:is(input,textarea):focus-visible]:border-[color-mix(in_srgb,var(--menu-icon-blue)_55%,transparent)] has-[:is(input,textarea):focus-visible]:shadow-[0_0_0_2px_color-mix(in_srgb,var(--menu-icon-blue)_12%,transparent)] has-[[aria-invalid=true]]:border-destructive-foreground has-[[aria-invalid=true]]:shadow-[0_0_0_2px_color-mix(in_srgb,var(--destructive-foreground)_12%,transparent)] has-[:user-invalid]:border-destructive-foreground has-[:user-invalid]:shadow-[0_0_0_2px_color-mix(in_srgb,var(--destructive-foreground)_12%,transparent)]'
              : 'rounded-control border border-field-edge border-b-input bg-field hover:bg-field-hover has-[:is(input,textarea):focus-visible]:border-control-edge has-[:is(input,textarea):focus-visible]:border-b-ring has-[:is(input,textarea):focus-visible]:bg-background has-[:is(input,textarea):focus-visible]:shadow-[inset_0_-1px_0_var(--color-ring)] has-[[data-slot][aria-invalid=true]]:border-b-destructive has-[[data-slot][aria-invalid=true]]:shadow-[inset_0_-1px_0_var(--color-destructive)] has-[:user-invalid]:border-b-destructive has-[:user-invalid]:shadow-[inset_0_-1px_0_var(--color-destructive)] has-[:is(input,textarea):disabled]:border-b-transparent',
        className
      )}
      {...props}
    />
  )
}

// In the composer, the bottom addon is the toolbar: a 36px row 10px from the composer's edges, whose controls sit
// side by side with no gap.
const inputGroupAddonVariants = cva(
  "flex h-auto cursor-text items-center justify-center gap-2 py-2 text-sm leading-5 font-medium text-muted-foreground select-none group-data-[disabled=true]/input-group:text-fg-disabled group-has-[:is(input,textarea):disabled]/input-group:text-fg-disabled [&>svg:not([class*='size-'])]:size-3.5",
  {
    variants: {
      align: {
        'inline-start': 'order-first',
        'inline-end': 'order-last',
        'block-start': 'order-first w-full justify-start pt-3 group-has-[>input]/input-group:pt-3.5 [.border-b]:pb-3.5',
        'block-end':
          'order-last w-full justify-start pb-3 group-has-[>input]/input-group:pb-3.5 [.border-t]:pt-3.5 group-data-[variant=composer]/input-group:h-9 group-data-[variant=composer]/input-group:gap-0 group-data-[variant=composer]/input-group:px-2.5 group-data-[variant=composer]/input-group:py-0'
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
        e.currentTarget.parentElement?.querySelector<HTMLElement>('input, textarea')?.focus()
      }}
      {...props}
    />
  )
}

// `icon-lg` and `toolbar` are the composer toolbar's 36px controls, which take Button's sizes of the same names.
const inputGroupButtonVariants = cva('flex min-w-0! items-center justify-center shadow-none', {
  variants: {
    size: {
      xs: "h-6 gap-1 rounded-mini px-1.5 text-xs [&>svg:not([class*='size-'])]:size-3.5",
      sm: 'gap-2 rounded-mini text-sm',
      'icon-xs': 'size-6 gap-2 rounded-mini p-0 text-xs has-[>svg]:p-0',
      'icon-sm': 'size-7 gap-2 rounded-mini p-0 text-sm has-[>svg]:p-0',
      'icon-lg': '',
      toolbar: ''
    }
  },
  defaultVariants: {
    size: 'xs'
  }
})

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
      size={size === 'icon-lg' || size === 'toolbar' ? size : undefined}
      className={cn(inputGroupButtonVariants({ size }), className)}
      {...props}
    />
  )
}

/**
 * The end of the composer's toolbar: it takes the room that the tools leave and holds the stop and send pills and
 * a control that follows them, such as a send-mode menu, 8px apart. A pill's hit area spans the toolbar's height
 * but not the gap beside it, so a click between two pills or just beside one never lands on its neighbour.
 */
function InputGroupActions({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="input-group-actions"
      className={cn('ms-auto flex shrink-0 items-center gap-2', className)}
      {...props}
    />
  )
}

/**
 * The composer's send button at the end of its toolbar: a 52 × 20 pill with a 20px icon and 16px of padding on each
 * side, whose hit area reaches 8px above and below the pill and no further beside it. While the draft is empty it
 * stays in the hovered slot fill with a disabled icon; once `ready` says that the draft can be sent, it takes the
 * primary fill with an on-colour icon. Inside `InputGroupActions` the group places the pill; placed straight in the
 * toolbar, the pill takes the toolbar's free room before it, unless the stop pill already stands there.
 */
function InputGroupSend({
  className,
  ready = false,
  type = 'submit',
  ...props
}: Omit<React.ComponentProps<typeof Button>, 'size' | 'type' | 'variant'> & {
  ready?: boolean
  type?: 'button' | 'submit' | 'reset'
}) {
  return (
    <Button
      type={type}
      variant="ghost"
      data-slot="input-group-send"
      data-ready={ready || undefined}
      className={cn(
        "relative h-5 min-w-13 rounded-surface border-0 bg-field-hover px-4 text-fg-disabled after:absolute after:inset-x-0 after:-inset-y-2 hover:bg-field-hover hover:text-fg-disabled active:bg-field-hover data-ready:bg-primary data-ready:text-primary-foreground data-ready:hover:bg-primary-hover data-ready:hover:text-primary-foreground data-ready:active:bg-primary-active [[data-slot=input-group-addon]>&]:ms-auto [[data-slot=input-group-addon]>[data-slot=input-group-stop]+&]:ms-0 [&_svg:not([class*='size-'])]:size-5",
        className
      )}
      {...props}
    />
  )
}

/**
 * The composer's stop button, which sits before `InputGroupSend` while a reply runs. It is the same pill in the slot
 * fill, with its icon in the secondary text colour, and it takes the hover fill under the pointer.
 */
function InputGroupStop({ className, ...props }: Omit<React.ComponentProps<typeof InputGroupSend>, 'ready' | 'type'>) {
  return (
    <InputGroupSend
      type="button"
      data-slot="input-group-stop"
      className={cn('text-fg-secondary hover:bg-layer-hover hover:text-foreground active:bg-layer-pressed', className)}
      {...props}
    />
  )
}

// In the composer, a text addon is a label of the toolbar, such as the one recipient that a conversation cannot
// change: 12px regular secondary text on a 20px line, inset 8px like the label of a toolbar button.
function InputGroupText({ className, ...props }: React.ComponentProps<'span'>) {
  return (
    <span
      className={cn(
        "flex items-center gap-2 text-sm leading-5 text-muted-foreground [&_svg]:pointer-events-none [&_svg:not([class*='size-'])]:size-3.5 group-data-[variant=composer]/input-group:min-w-0 group-data-[variant=composer]/input-group:px-2 group-data-[variant=composer]/input-group:text-50 group-data-[variant=composer]/input-group:font-normal group-data-[variant=composer]/input-group:text-fg-secondary",
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
        'flex-1 border-0 bg-transparent px-0 ring-0 group-has-[>[data-align=inline-end]]/input-group:pr-2 group-has-[>[data-align=inline-start]]/input-group:pl-2 hover:bg-transparent focus-visible:bg-transparent focus-visible:shadow-none focus-visible:ring-0 user-invalid:border-b-0 user-invalid:shadow-none aria-invalid:shadow-none aria-invalid:ring-0 dark:bg-transparent',
        className
      )}
      {...props}
    />
  )
}

// In the composer, text is 16px on a 24px line, starting 16px from the top and 22px from the side, with the caret
// in the primary colour and the placeholder in the disabled text colour. The text area grows with its draft up to
// 240px and then scrolls, and while it is disabled it stays on the composer's own fill.
function InputGroupTextarea({ className, ...props }: React.ComponentProps<'textarea'>) {
  return (
    <Textarea
      data-slot="input-group-control"
      className={cn(
        'flex-1 resize-none border-0 bg-transparent py-2 ring-0 hover:bg-transparent focus-visible:bg-transparent focus-visible:shadow-none focus-visible:ring-0 user-invalid:border-b-0 user-invalid:shadow-none aria-invalid:shadow-none aria-invalid:ring-0 dark:bg-transparent group-data-[variant=composer]/input-group:min-h-16 group-data-[variant=composer]/input-group:max-h-60 group-data-[variant=composer]/input-group:px-5.5 group-data-[variant=composer]/input-group:pt-4 group-data-[variant=composer]/input-group:pb-2 group-data-[variant=composer]/input-group:text-100 group-data-[variant=composer]/input-group:leading-6 group-data-[variant=composer]/input-group:caret-primary group-data-[variant=composer]/input-group:placeholder:text-fg-disabled group-data-[variant=composer]/input-group:disabled:bg-transparent',
        className
      )}
      {...props}
    />
  )
}

export {
  InputGroup,
  InputGroupActions,
  InputGroupAddon,
  InputGroupButton,
  InputGroupInput,
  InputGroupSend,
  InputGroupStop,
  InputGroupText,
  InputGroupTextarea
}
