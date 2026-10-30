import { Button as ButtonPrimitive } from '@base-ui/react/button'
import { cva, type VariantProps } from 'class-variance-authority'

import { cn } from '@ankole/uikit/lib/utils'

const buttonVariants = cva(
  "group/button inline-flex shrink-0 items-center justify-center gap-2 rounded-control border border-transparent bg-clip-padding text-[13px] leading-none font-medium whitespace-nowrap transition-[background-color,border-color,color] duration-(--duration-feedback) ease-productive select-none focus-visible:outline-offset-1 disabled:pointer-events-none aria-invalid:border-destructive [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
  {
    variants: {
      variant: {
        // A disabled button keeps its outline and drops its fill, so it still reads as a button that cannot be pressed
        // now. A grey fill would make it read as an empty field.
        // The one solid button of a view: brand coral-crimson with a darker bottom edge, distinct from warm vermilion destructive actions.
        default:
          'border-primary border-b-primary-edge bg-primary text-primary-foreground hover:border-primary-hover hover:border-b-primary-edge hover:bg-primary-hover active:border-primary-active active:bg-primary-active disabled:border-border disabled:bg-transparent disabled:text-fg-disabled',
        // The normal button is a paper object. Pressed, it sinks into a slot.
        outline:
          'border-control-edge border-b-control-base bg-control text-foreground shadow-control hover:bg-control-hover active:bg-field active:shadow-none aria-expanded:bg-field aria-expanded:shadow-none disabled:border-border disabled:bg-transparent disabled:text-fg-disabled disabled:shadow-none',
        ghost:
          'text-muted-foreground hover:bg-accent hover:text-foreground active:bg-muted aria-expanded:bg-accent aria-expanded:text-foreground disabled:text-fg-disabled',
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
  incomplete = false,
  variant = 'default',
  size = 'default',
  ...props
}: ButtonPrimitive.Props & VariantProps<typeof buttonVariants> & { incomplete?: boolean }) {
  return (
    <ButtonPrimitive
      data-incomplete={incomplete || undefined}
      data-slot="button"
      className={cn(
        buttonVariants({ variant, size }),
        incomplete &&
          'border-border border-b-border bg-muted text-muted-foreground hover:border-border hover:bg-muted/80 hover:text-muted-foreground',
        className
      )}
      {...props}
    />
  )
}

export { Button, buttonVariants }
