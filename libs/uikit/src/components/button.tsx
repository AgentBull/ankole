import { Button as ButtonPrimitive } from '@base-ui/react/button'
import { cva, type VariantProps } from 'class-variance-authority'
import { Children, isValidElement, type MouseEvent, type ReactNode } from 'react'

import { cn } from '@ankole/uikit/lib/utils'
import { Spinner } from './spinner'

const buttonVariantClasses = cva(
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
          'border-red-80 border-b-red-90 bg-red-80 text-white hover:border-red-90 hover:bg-red-90 active:bg-red-90 disabled:border-border disabled:bg-transparent disabled:text-fg-disabled',
        link: 'link border-0 disabled:text-fg-disabled disabled:decoration-border'
      },
      size: {
        // 32px by default, 28px in rows, 24px inside another control. A shell toolbar, such as the top bar or the
        // composer's tools, takes 36px controls: an icon button that holds a 20px icon, and a label of 12px text with
        // a 12px arrow. The action row under content, such as a chat message's, takes 32px icon buttons that hold a
        // 20px icon 6px inside their edge.
        default: 'h-8 px-3 has-data-[icon=inline-end]:pr-2.5 has-data-[icon=inline-start]:pl-2.5',
        sm: 'h-7 gap-1.5 px-2.5 has-data-[icon=inline-end]:pr-2 has-data-[icon=inline-start]:pl-2',
        xs: "h-6 gap-1 px-2 text-50 has-data-[icon=inline-end]:pr-1.5 has-data-[icon=inline-start]:pl-1.5 [&_svg:not([class*='size-'])]:size-3.5",
        icon: 'size-8',
        'icon-md': "size-8 p-1.25 [&_svg:not([class*='size-'])]:size-5",
        'icon-sm': 'size-7',
        'icon-xs': "size-6 [&_svg:not([class*='size-'])]:size-3.5",
        'icon-lg': "size-9 p-1.75 [&_svg:not([class*='size-'])]:size-5",
        toolbar: "h-9 gap-1 p-1.75 text-50 font-normal [&_svg:not([class*='size-'])]:size-3"
      }
    },
    compoundVariants: [
      // A ghost toolbar control tints only the box that holds its icon or label. The fill clips to the content box,
      // 8px inside the button's edge (its 1px border and 7px of padding), and the outer radius adds those 8px, so the
      // tinted box keeps the micro radius.
      {
        variant: 'ghost',
        size: ['icon-lg', 'toolbar'],
        className: 'bg-clip-content rounded-[calc(var(--radius-micro)+var(--spacing)*2)]'
      },
      // The action row's ghost icon button tints its 20px icon box the same way, 6px inside its edge (its 1px border
      // and 5px of padding).
      {
        variant: 'ghost',
        size: 'icon-md',
        className: 'bg-clip-content rounded-[calc(var(--radius-micro)+var(--spacing)*1.5)]'
      }
    ],
    defaultVariants: {
      variant: 'default',
      size: 'default'
    }
  }
)

/**
 * The classes of a button, for an element that looks like one, such as a link. A size or variant that replaces a
 * base class, like the toolbar sizes' content-box fill and radius or their 12px label, removes the base class from
 * the result, so a caller that styles its own element gets the same button as `Button`.
 */
function buttonVariants(props?: Parameters<typeof buttonVariantClasses>[0]) {
  return cn(buttonVariantClasses(props))
}

/** An icon child: an element with no content of its own that the caller hid from assistive technology. */
function isIcon(child: ReactNode, loading: boolean) {
  if (!isValidElement<Record<string, unknown>>(child) || child.props.children != null) return false
  const hidden = child.props['aria-hidden']
  return loading || hidden === true || hidden === 'true' || child.props['data-icon'] !== undefined
}

function ignoreClick(event: MouseEvent) {
  event.preventDefault()
}

/**
 * The action control.
 *
 * `loading` marks an action that is running: the button reports `aria-busy`, ignores clicks, and stays focusable,
 * so keyboard focus does not jump while the work finishes. A busy button keeps its width: a leading icon turns
 * into the spinner, a text label shimmers, and nothing is added beside them. Setting `aria-busy` alone gives the
 * same look and leaves click handling to the caller.
 */
function Button({
  className,
  children,
  'aria-busy': busy,
  loading = false,
  incomplete = false,
  variant = 'default',
  size = 'default',
  onClick,
  ...props
}: ButtonPrimitive.Props & VariantProps<typeof buttonVariants> & { incomplete?: boolean; loading?: boolean }) {
  const isBusy = loading || busy === true || busy === 'true'
  const items = isBusy ? Children.toArray(children) : []
  const firstText = items.findIndex(child => typeof child === 'string' && child.trim())
  const firstIcon = items.findIndex(child => isIcon(child, loading))
  const spinnerAt = firstIcon !== -1 && (firstText === -1 || firstIcon < firstText) ? firstIcon : -1

  return (
    <ButtonPrimitive
      aria-busy={loading ? true : busy}
      data-incomplete={incomplete || undefined}
      data-loading={loading || undefined}
      data-slot="button"
      onClick={loading ? ignoreClick : onClick}
      className={cn(
        buttonVariants({ variant, size }),
        'motion-safe:button-press',
        incomplete &&
          'border-border border-b-border bg-muted text-muted-foreground hover:border-border hover:bg-muted/80 hover:text-muted-foreground',
        className
      )}
      {...props}>
      {isBusy
        ? items.map((child, index) =>
            index === spinnerAt && isValidElement<{ className?: string; 'data-icon'?: string }>(child) ? (
              // The button already reports `aria-busy`, so its spinner is decoration and not a second status.
              <Spinner
                key="spinner"
                aria-hidden
                aria-label={undefined}
                role="presentation"
                className={child.props.className}
                data-icon={child.props['data-icon']}
              />
            ) : typeof child === 'string' && child.trim() ? (
              <span
                key={index}
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
