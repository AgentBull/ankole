'use client'

import { useState, type ComponentProps, type CSSProperties } from 'react'

import { cn } from '../lib/utils'

/** The number a formatted figure stands for, so a change knows whether it went up or down. */
function magnitude(text: string) {
  const parsed = Number.parseFloat(text.replace(/[^\d.-]/g, ''))
  return Number.isFinite(parsed) ? parsed : 0
}

/**
 * A figure that changes in place. When `value` changes, only the characters that differ roll: they rise into
 * place when the figure grows and drop into place when it shrinks, so a reader sees which digits moved and in
 * which direction. Characters are compared from the right, so the units stay still when the figure gains a digit.
 *
 * The first render is one plain text node. The figure is read as ordinary text at every moment, so it needs no
 * separate label for assistive technology.
 */
function RollingNumber({
  value,
  className,
  ...props
}: Omit<ComponentProps<'span'>, 'children'> & { value: string | number }) {
  const text = String(value)
  const [shown, setShown] = useState<{ text: string; previous?: string; generation: number }>({ text, generation: 0 })
  // React renders again at once with the new state, so the rest of this pass may read the old one.
  if (shown.text !== text) setShown({ text, previous: shown.text, generation: shown.generation + 1 })

  const { previous, generation } = shown
  const from = previous === undefined || magnitude(text) >= magnitude(previous) ? '60%' : '-60%'

  return (
    <span data-slot="rolling-number" className={cn('tabular-nums', className)} {...props}>
      {previous === undefined
        ? text
        : Array.from(text, (character, index) => {
            const fromRight = text.length - 1 - index
            const changed = previous[previous.length - 1 - fromRight] !== character
            return (
              <span
                key={changed ? `${fromRight}:${generation}` : fromRight}
                className={cn('inline-block whitespace-pre', changed && 'motion-safe:animate-number-roll')}
                style={changed ? ({ '--number-roll-from': from } as CSSProperties) : undefined}>
                {character}
              </span>
            )
          })}
    </span>
  )
}

export { RollingNumber }
