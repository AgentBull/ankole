'use client'

import { CopyRegular } from '../icons'
import { useState, type ComponentProps, type ReactNode } from 'react'

import { useCopyFeedback } from '../hooks/use-copy-feedback'
import { cn } from '../lib/utils'
import { Button } from './button'

/**
 * The copy mark. After a copy it turns into a check that draws itself, and it turns back when the caller clears
 * `copied`. Every copy control shows this mark, so a copy is confirmed the same way wherever it happens.
 */
function CopyIcon({ copied, className, ...props }: ComponentProps<'span'> & { copied: boolean }) {
  return (
    <span
      aria-hidden
      data-slot="copy-icon"
      data-copied={copied || undefined}
      className={cn('grid size-4 shrink-0 place-items-center', className)}
      {...props}>
      <CopyRegular data-part="copy" />
      <svg
        data-part="check"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2.4"
        strokeLinecap="round"
        strokeLinejoin="round">
        <path d="M5 12l4 4L19 6" pathLength={1} />
      </svg>
    </span>
  )
}

type CopyButtonProps = Omit<ComponentProps<typeof Button>, 'children' | 'onClick' | 'value'> & {
  /** The text to copy, or a function that produces it when the person clicks. */
  value: string | (() => string | Promise<string>)
  /** The accessible name before a copy, such as "Copy link". */
  label: string
  /** The accessible name and the announcement after a copy, such as "Copied". */
  copiedLabel: string
  /** A visible label beside the mark. Without it the button shows the mark alone. */
  children?: ReactNode
  /** The visible label after a copy. It defaults to `copiedLabel` when `children` is set. */
  copiedChildren?: ReactNode
  /** How long the confirmation stays before the button returns to rest. */
  resetAfter?: number
  onCopied?: () => void
  onCopyError?: (error: unknown) => void
}

/**
 * Copies text and confirms it in place: the mark becomes a check, the label changes, and the result is announced.
 * A failed copy leaves the button at rest and calls `onCopyError`, so the caller decides how to report it.
 */
function CopyButton({
  value,
  label,
  copiedLabel,
  children,
  copiedChildren,
  resetAfter = 1600,
  onCopied,
  onCopyError,
  variant = 'ghost',
  size,
  ...props
}: CopyButtonProps) {
  const [copied, markCopied] = useCopyFeedback(false, resetAfter)
  // The label animates only when it changes, so a page of copy buttons loads still.
  const [swapped, setSwapped] = useState(false)
  const visibleLabel = copied ? (copiedChildren ?? copiedLabel) : children

  return (
    <Button
      type="button"
      variant={variant}
      size={size ?? (children === undefined ? 'icon-sm' : 'sm')}
      aria-label={copied ? copiedLabel : label}
      title={children === undefined ? (copied ? copiedLabel : label) : undefined}
      data-copied={copied || undefined}
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(typeof value === 'function' ? await value() : value)
          setSwapped(true)
          markCopied(true)
          onCopied?.()
        } catch (error) {
          onCopyError?.(error)
        }
      }}
      {...props}>
      <CopyIcon copied={copied} />
      {children === undefined ? null : (
        <span key={copied ? 'copied' : 'rest'} className={swapped ? 'motion-safe:animate-label-swap' : undefined}>
          {visibleLabel}
        </span>
      )}
      <span className="sr-only" aria-live="polite">
        {copied ? copiedLabel : ''}
      </span>
    </Button>
  )
}

export { CopyButton, CopyIcon }
