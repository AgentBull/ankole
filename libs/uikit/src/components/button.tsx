import { Button as ButtonPrimitive } from '@base-ui/react/button'
import { cva, type VariantProps } from 'class-variance-authority'
import { Children } from 'react'

import { cn } from '@ankole/uikit/lib/utils'

const buttonVariants = cva(
  "group/button inline-flex shrink-0 items-center justify-center gap-2 rounded-control border border-transparent bg-clip-padding text-[13px] leading-none font-medium whitespace-nowrap transition-[background-color,border-color,color] duration-(--duration-feedback) ease-productive select-none focus-visible:outline-offset-1 disabled:pointer-events-none aria-invalid:border-destructive [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
  {
    variants: {
      variant: {
        // The one solid button of a view: brand-60 with a darker bottom edge. Disabled, it keeps a faint brand fill so
        // it still reads as the primary action that cannot be pressed now.
        default:
          'border-primary border-b-primary-edge bg-primary text-primary-foreground hover:border-primary-hover hover:border-b-primary-edge hover:bg-primary-hover active:border-primary-active active:bg-primary-active disabled:border-primary-disabled disabled:bg-primary-disabled disabled:text-primary-disabled-foreground',
        // The normal button is a paper object. Pressed, it sinks into a slot. Disabled, it keeps its outline and drops
        // its fill, so it still reads as a button rather than an empty field.
        outline:
          'border-control-edge border-b-control-base bg-control text-foreground shadow-control hover:bg-control-hover active:bg-field active:shadow-none aria-expanded:bg-field aria-expanded:shadow-none disabled:border-border disabled:bg-transparent disabled:text-fg-disabled disabled:shadow-none',
        ghost:
          'text-muted-foreground hover:bg-accent hover:text-foreground active:bg-layer-pressed aria-expanded:bg-accent aria-expanded:text-foreground disabled:text-fg-disabled',
        // The confirmation of an action that cannot be undone. Deep red sits darker than the brand primary, so the two
        // solid buttons differ in lightness as well as hue; the white label stays above 7:1 in both themes.
        destructive:
          'border-red-70 border-b-red-80 bg-red-70 text-white hover:border-red-80 hover:bg-red-80 active:bg-red-80 disabled:border-border disabled:bg-transparent disabled:text-fg-disabled',
        link: 'link border-0 disabled:text-fg-disabled disabled:decoration-border'
      },
      size: {
        // 32px by default, 28px in toolbars and rows, 24px inside another control.
        default: 'h-8 px-3 has-data-[icon=inline-end]:pr-2.5 has-data-[icon=inline-start]:pl-2.5',
        sm: 'h-7 gap-1.5 px-2.5 has-data-[icon=inline-end]:pr-2 has-data-[icon=inline-start]:pl-2',
        xs: "h-6 gap-1 px-2 text-xs has-data-[icon=inline-end]:pr-1.5 has-data-[icon=inline-start]:pl-1.5 [&_svg:not([class*='size-'])]:size-3.5",
        icon: 'size-8',
        'icon-sm': 'size-7',
        'icon-xs': "size-6 [&_svg:not([class*='size-'])]:size-3.5"
      }
    },
    defaultVariants: {
      variant: 'default',
      size: 'default'
    }
  }
)

function Button({
  className,
  children,
  'aria-busy': busy,
  incomplete = false,
  variant = 'default',
  size = 'default',
  ...props
}: ButtonPrimitive.Props & VariantProps<typeof buttonVariants> & { incomplete?: boolean }) {
  const isBusy = busy === true || busy === 'true'

  return (
    <ButtonPrimitive
      aria-busy={busy}
      data-incomplete={incomplete || undefined}
      data-slot="button"
      className={cn(
        buttonVariants({ variant, size }),
        'motion-safe:button-press',
        incomplete &&
          'border-border border-b-border bg-muted text-muted-foreground hover:border-border hover:bg-muted/80 hover:text-muted-foreground',
        className
      )}
      {...props}>
      {isBusy
        ? Children.map(children, child =>
            typeof child === 'string' && child.trim() ? (
              <span
                data-busy-label={child}
                className={cn(
                  "relative motion-safe:text-current/55 group-disabled/button:text-current group-aria-disabled/button:text-current forced-colors:text-current motion-safe:after:pointer-events-none motion-safe:after:absolute motion-safe:after:inset-0 motion-safe:after:bg-[linear-gradient(90deg,transparent_38%,var(--button-shine)_50%,transparent_62%)] motion-safe:after:bg-size-[300%_100%] motion-safe:after:bg-position-[100%_0] motion-safe:after:bg-clip-text motion-safe:after:bg-no-repeat motion-safe:after:text-transparent motion-safe:after:animate-button-shimmer motion-safe:after:content-[attr(data-busy-label)/''] forced-colors:after:hidden",
                  variant === 'default'
                    ? '[--button-shine:rgb(255_255_255/0.95)]'
                    : '[--button-shine:rgb(255_255_255/0.82)]'
                )}>
                {child}
              </span>
            ) : (
              child
            )
          )
        : children}
    </ButtonPrimitive>
  )
}

export { Button, buttonVariants }
