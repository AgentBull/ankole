import { Input as InputPrimitive } from '@ui-sdk/react/input'
import { renderElement } from '@ui-sdk/react/primitive'
import type * as React from 'react'

import { cn } from '../lib/utils'

/**
 * `default` is a slot in a form and `overlay` is a field inside ceramic. `inline` edits text where it already
 * stands, such as a title in a header or a row in a list: it keeps the surrounding size, weight and position, and
 * only the caret and the focus ring show that it is being edited.
 */
function Input({
  className,
  type,
  variant = 'default',
  'data-slot': slot = 'input',
  render,
  ...props
}: React.ComponentProps<typeof InputPrimitive> & { 'data-slot'?: string; variant?: 'default' | 'overlay' | 'inline' }) {
  return (
    <InputPrimitive
      type={type}
      data-variant={variant}
      // ui-sdk names every input `data-slot="input"`. A caller's own slot, such as an input group's control, replaces
      // that name, so the styles keyed on the caller's slot still find the element.
      render={(part, state) => renderElement('input', { ...part, 'data-slot': slot }, render, state)}
      className={cn(
        'h-8 w-full min-w-0 px-3 text-sm leading-5 outline-none placeholder:text-fg-placeholder disabled:cursor-not-allowed disabled:text-fg-disabled disabled:placeholder:text-fg-disabled',
        variant !== 'inline' &&
          'transition-[background-color,box-shadow] duration-160 ease-[ease] motion-safe:aria-invalid:animate-field-nudge motion-safe:user-invalid:animate-field-nudge',
        variant === 'inline'
          ? 'h-auto rounded-control border-0 bg-transparent px-1 py-0.5 text-[length:inherit] leading-[inherit] font-[inherit] text-inherit focus:outline-2 focus:outline-offset-0 focus:outline-ring focus:outline-solid'
          : variant === 'overlay'
            ? 'h-9 rounded-(--menu-field-radius) border border-(--menu-field-edge) bg-(--menu-field) shadow-none focus-visible:border-[color-mix(in_srgb,var(--menu-icon-blue)_55%,transparent)] focus-visible:shadow-[0_0_0_2px_color-mix(in_srgb,var(--menu-icon-blue)_12%,transparent)] user-invalid:border-destructive-fg user-invalid:shadow-[0_0_0_2px_color-mix(in_srgb,var(--destructive-fg)_12%,transparent)] aria-invalid:border-destructive-fg aria-invalid:shadow-[0_0_0_2px_color-mix(in_srgb,var(--destructive-fg)_12%,transparent)]'
            : 'rounded-control border border-field-border bg-field hover:bg-field-hover focus-visible:border-control-edge focus-visible:border-b-ring focus-visible:bg-page focus-visible:shadow-[inset_0_-1px_0_var(--color-ring)] user-invalid:bg-(--field-invalid) disabled:border-transparent disabled:bg-field aria-invalid:bg-(--field-invalid)',
        type === 'file'
          ? 'cursor-pointer py-1 file:mr-3 file:inline-flex file:h-7 file:cursor-pointer file:items-center file:border-0 file:bg-transparent file:text-sm file:font-normal file:text-fg-primary'
          : variant !== 'inline' && 'py-2',
        type === 'search' &&
          'appearance-none [&::-webkit-search-cancel-button]:appearance-none [&::-webkit-search-decoration]:appearance-none',
        className
      )}
      {...props}
    />
  )
}

export { Input }
