'use client'

import { Button } from '@/uikit/components/button'
import { ScrollArea, ScrollBar } from '@/uikit/components/scroll-area'
import { cn } from '@/uikit/lib/utils'
import type { ComponentProps } from 'react'
import { useCallback } from 'react'

export type SuggestionsProps = ComponentProps<typeof ScrollArea>

/**
 * Horizontal, scrollable row of suggestion chips shown above/below the composer (e.g. prompt starters).
 * The scrollbar is hidden by design — overflow is reached by swipe/trackpad rather than a visible bar.
 */
export const Suggestions = ({ className, children, ...props }: SuggestionsProps) => (
  <ScrollArea className="w-full overflow-x-auto whitespace-nowrap" {...props}>
    <div className={cn('flex w-max flex-nowrap items-center gap-2', className)}>{children}</div>
    <ScrollBar className="hidden" orientation="horizontal" />
  </ScrollArea>
)

export type SuggestionProps = Omit<ComponentProps<typeof Button>, 'onClick'> & {
  suggestion: string
  // `onClick` is re-typed to hand back the suggestion string instead of the raw mouse event, so a
  // caller can wire one handler that just receives the chosen text.
  onClick?: (suggestion: string) => void
}

/**
 * A single suggestion chip. Renders `suggestion` as its label by default and reports that text (not the
 * DOM event) through `onClick` when pressed, so the parent can feed it straight into the composer.
 */
export const Suggestion = ({
  suggestion,
  onClick,
  className,
  variant = 'outline',
  size = 'sm',
  children,
  ...props
}: SuggestionProps) => {
  const handleClick = useCallback(() => {
    onClick?.(suggestion)
  }, [onClick, suggestion])

  return (
    <Button
      className={cn('cursor-pointer rounded-full px-4', className)}
      onClick={handleClick}
      size={size}
      type="button"
      variant={variant}
      {...props}>
      {children || suggestion}
    </Button>
  )
}
