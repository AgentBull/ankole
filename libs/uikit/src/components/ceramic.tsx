import { mergeProps, renderElement, type RenderProp } from '@ui-sdk/react/primitive'
import { cva, type VariantProps } from 'class-variance-authority'
import type * as React from 'react'

import { cn } from '../lib/utils'

/**
 * The classes of the ceramic material, for an element that draws its own surface. `tier` picks the body:
 * `secondary` (the default) is the body of dialogs, sheets, drawers, and toasts; `primary` is the more translucent
 * body of menus and of display surfaces that float over the ground, such as a sign-in card or a pill; `tertiary`
 * is the gray body. `attention` tints the body amber for a decision that waits for a person. `radius` keeps the
 * surface radius by default; `control` suits a list whose rows run from edge to edge, `tip` a tooltip-sized pill,
 * and `full` a pill. `size` sets the weight of the rim and shadow: `lg` is for a dialog-sized surface.
 */
const ceramicVariants = cva('ceramic', {
  variants: {
    tier: {
      secondary: '',
      primary: 'ceramic-primary',
      tertiary: 'ceramic-tertiary'
    },
    attention: {
      true: 'ceramic-attention',
      false: ''
    },
    radius: {
      surface: '',
      control: 'ceramic-tight',
      tip: '[--ceramic-radius:var(--ceramic-radius-tip)]',
      full: '[--ceramic-radius:9999px]'
    },
    size: {
      default: '',
      lg: '[--ceramic-offset:1px]'
    }
  },
  defaultVariants: {
    tier: 'secondary',
    attention: false,
    radius: 'surface',
    size: 'default'
  }
})

/**
 * A ceramic surface. It renders a `div` by default; `render` puts the material on another element or component,
 * such as a `Card` or a `Badge`, which keeps its own behaviour and layout and gives up its own fill and edge.
 */
function Ceramic({
  className,
  tier,
  attention,
  radius,
  size,
  render,
  ...props
}: React.ComponentProps<'div'> & { render?: RenderProp } & VariantProps<typeof ceramicVariants>) {
  // A rendered component keeps its own slot name; `data-ceramic` marks the tier on either element.
  return renderElement(
    'div',
    mergeProps(
      {
        ...(render ? {} : { 'data-slot': 'ceramic' }),
        'data-ceramic': tier ?? 'secondary',
        className: cn(ceramicVariants({ tier, attention, radius, size }), className)
      },
      props
    ),
    render
  )
}

export { Ceramic, ceramicVariants }
