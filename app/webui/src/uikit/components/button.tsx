import { Button as ButtonPrimitive } from '@base-ui/react/button'
import { cva, type VariantProps } from 'class-variance-authority'
import * as React from 'react'

import { cn } from '@/uikit/lib/utils'

const buttonVariants = cva(
  "group/button inline-flex w-max max-w-80 shrink-0 cursor-pointer items-center justify-start rounded-none border border-transparent text-sm leading-5 font-normal tracking-normal whitespace-nowrap normal-case transition-colors outline-none select-none focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/30 disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-50 aria-invalid:border-destructive aria-invalid:ring-2 aria-invalid:ring-destructive/20 dark:aria-invalid:border-destructive/50 dark:aria-invalid:ring-destructive/40 [&_[data-icon=inline-end]]:ml-auto [&_[data-icon=inline-start]]:mr-2 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
  {
    variants: {
      variant: {
        default: 'bg-primary text-primary-foreground hover:bg-primary/90',
        outline:
          'border-primary bg-transparent text-primary hover:bg-primary hover:text-primary-foreground aria-expanded:bg-primary aria-expanded:text-primary-foreground',
        secondary:
          'bg-secondary text-secondary-foreground hover:bg-secondary/90 aria-expanded:bg-secondary aria-expanded:text-secondary-foreground',
        ghost:
          'border-transparent bg-transparent text-primary hover:bg-muted hover:text-primary aria-expanded:bg-muted aria-expanded:text-primary',
        destructive:
          'bg-destructive text-destructive-foreground hover:bg-destructive/90 focus-visible:border-destructive/40 focus-visible:ring-destructive/20 dark:focus-visible:ring-destructive/40',
        link: 'h-auto! min-w-0! bg-transparent px-0! py-0! text-primary underline underline-offset-4 hover:text-primary/80 hover:underline'
      },
      size: {
        default: 'h-12 gap-2 pl-4 pr-16 has-data-[icon=inline-end]:pr-4 has-data-[icon=inline-start]:pl-4',
        xs: "h-8 gap-2 pl-3 pr-10 text-xs leading-4 has-data-[icon=inline-end]:pr-3 has-data-[icon=inline-start]:pl-3 [&_svg:not([class*='size-'])]:size-3.5",
        sm: 'h-10 gap-2 pl-4 pr-12 has-data-[icon=inline-end]:pr-4 has-data-[icon=inline-start]:pl-4',
        lg: 'h-12 gap-2 pl-4 pr-16 has-data-[icon=inline-end]:pr-4 has-data-[icon=inline-start]:pl-4',
        icon: 'size-12 max-w-none justify-center p-0',
        'icon-xs': "size-8 max-w-none justify-center p-0 [&_svg:not([class*='size-'])]:size-3.5",
        'icon-sm': 'size-10 max-w-none justify-center p-0',
        'icon-lg': 'size-12 max-w-none justify-center p-0'
      }
    },
    defaultVariants: {
      variant: 'default',
      size: 'default'
    }
  }
)

function Button({
  children,
  className,
  variant = 'default',
  size = 'default',
  ...props
}: ButtonPrimitive.Props & VariantProps<typeof buttonVariants>) {
  const childNodes = React.Children.toArray(children).filter(child => {
    if (typeof child === 'string') return child.trim().length > 0
    return child !== null && child !== undefined
  })
  const ariaLabel = props['aria-label']
  const isImplicitIconButton =
    size === 'default' &&
    typeof ariaLabel === 'string' &&
    ariaLabel.trim().length > 0 &&
    childNodes.length === 1 &&
    React.isValidElement(childNodes[0])

  return (
    <ButtonPrimitive
      data-slot="button"
      data-icon-only={isImplicitIconButton ? true : undefined}
      className={cn(
        buttonVariants({ variant, size }),
        isImplicitIconButton && 'size-12 max-w-none justify-center p-0',
        className
      )}
      {...props}>
      {children}
    </ButtonPrimitive>
  )
}

export { Button, buttonVariants }
