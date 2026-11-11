import { mergeProps } from '@base-ui/react/merge-props'
import { useRender } from '@base-ui/react/use-render'
import type { ReactNode } from 'react'

import { ChevronRightRegular } from '../icons'
import { cn } from '../lib/utils'

/**
 * A reference to a Page, wherever it stands: the smallest outline card, a chip 28px tall and at most 318px wide
 * that stands inside a sentence. The Page's 20px mark in the secondary colour 8px from the chip's edge, 6px, the
 * title in the 14px Medium step on one line, and a 16px chevron at the end. Under the pointer it takes the hover
 * wash and its chevron darkens.
 *
 * The chip is inline, and its line grows 4px to hold it. It takes its baseline from the bottom of its mark, 4px
 * above its own bottom, and it lowers that baseline so that its middle meets the middle of the text around it:
 * 0.38em above the baseline in the kit's sans face, whose glyphs rise 0.983em and fall 0.223em. It renders a link
 * by default; `render` gives it the caller's own link element, such as a router link.
 */
function ReferenceCard({
  mark,
  children,
  className,
  render,
  ...props
}: useRender.ComponentProps<'a'> & {
  /** The Page's 20px mark. */
  mark: ReactNode
  /** The Page's title. */
  children?: ReactNode
}) {
  return useRender({
    defaultTagName: 'a',
    render,
    props: mergeProps<'a'>(
      {
        className: cn(
          'group/reference surface-outline inline-flex h-7 max-w-[min(318px,100%)] min-w-0 items-center gap-1.5 py-0 ps-[7px] pe-[5px] align-[calc(0.38em-10px)] text-75 leading-5 text-foreground no-underline transition-colors duration-(--duration-feedback) hover:bg-layer-hover active:bg-layer-pressed',
          className
        ),
        children: (
          <>
            <span
              data-slot="reference-card-mark"
              aria-hidden
              className="flex size-5 shrink-0 items-center justify-center text-fg-secondary [&>svg]:size-5">
              {mark}
            </span>
            <span data-slot="reference-card-title" className="min-w-0 flex-1 truncate font-medium">
              {children}
            </span>
            <ChevronRightRegular
              aria-hidden
              data-slot="reference-card-chevron"
              className="size-4 shrink-0 text-fg-tertiary transition-colors duration-(--duration-feedback) group-hover/reference:text-foreground"
            />
          </>
        )
      },
      props
    ),
    state: { slot: 'reference-card' }
  })
}

export { ReferenceCard }
