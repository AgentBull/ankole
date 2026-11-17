'use client'

import { CopyRegular, LinkRegular } from '../icons'
import { useEffect, useRef, useState, type ComponentProps, type ReactNode } from 'react'

import { useCopyFeedback } from '../hooks/use-copy-feedback'
import { cn } from '../lib/utils'
import { Button } from './button'

let lastLiveAnnouncement = ''

function nextLiveAnnouncement(message: string): string {
  const next = message === lastLiveAnnouncement ? `${message}\u00A0` : message
  lastLiveAnnouncement = next
  return next
}

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

export type SplitLinkParts = {
  host: string
  path: string
}

/**
 * Splits a URL the way people scan it: the host in primary ink, followed by the decoded path,
 * query, and fragment in secondary ink.
 */
export function splitLinkURL(url: string): SplitLinkParts {
  const trimmed = url.trim()
  if (!trimmed) return { host: '', path: '' }
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed)) {
    try {
      const parsed = new URL(trimmed)
      if (parsed.host) {
        const rawRest = `${parsed.pathname === '/' && !parsed.search && !parsed.hash ? '' : parsed.pathname}${parsed.search}${parsed.hash}`
        let decoded = rawRest
        try {
          decoded = decodeURI(rawRest)
        } catch {
          // Malformed percent-encoding keeps the original path text.
        }
        return { host: parsed.host, path: decoded }
      }
    } catch {
      // Fall through to schemeless host/path split.
    }
  }
  const slash = trimmed.indexOf('/')
  if (slash > 0) {
    const rawRest = trimmed.slice(slash)
    let decoded = rawRest
    try {
      decoded = decodeURI(rawRest)
    } catch {
      // Keep original path text when percent-encoding is malformed.
    }
    return { host: trimmed.slice(0, slash), path: decoded === '/' ? '' : decoded }
  }
  return { host: trimmed, path: '' }
}

type SplitLinkFieldProps = Omit<ComponentProps<'div'>, 'children'> & {
  /** The displayed URL (split into host + path). */
  url: string
  /** Optional async resolver when copying (defaults to `url`). */
  resolveValue?: () => string | Promise<string>
  /** Accessible name of the copy action, such as "Copy link". */
  label: string
  /** Announcement and tooltip once copied, such as "Copied". */
  copiedLabel: string
  /** Announcement when clipboard access is denied. */
  failedLabel?: string
  /** Leading icon (defaults to a link glyph). */
  icon?: ReactNode
  resetAfter?: number
  onCopied?: () => void
  onCopyError?: (error: unknown) => void
}

/**
 * Full-width clickable address row showing the host in primary text and the path in secondary text.
 * Clicking anywhere copies the link without disabling focus, swaps the trailing mark to a check, and
 * announces the result through a sibling live region outside the button.
 */
function SplitLinkField({
  url,
  resolveValue,
  label,
  copiedLabel,
  failedLabel = 'Copy failed',
  icon,
  resetAfter = 1600,
  onCopied,
  onCopyError,
  className,
  ...props
}: SplitLinkFieldProps) {
  const { host, path } = splitLinkURL(url)
  const [state, setState] = useState<'idle' | 'copied' | 'failed'>('idle')
  const [announcement, setAnnouncement] = useState('')
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(
    () => () => {
      if (timerRef.current !== null) clearTimeout(timerRef.current)
    },
    []
  )

  const report = (ok: boolean) => {
    if (timerRef.current !== null) clearTimeout(timerRef.current)
    setState(ok ? 'copied' : 'failed')
    setAnnouncement(nextLiveAnnouncement(ok ? copiedLabel : failedLabel))
    timerRef.current = setTimeout(() => {
      timerRef.current = null
      setState('idle')
      setAnnouncement('')
    }, resetAfter)
  }

  const copied = state === 'copied'
  const failed = state === 'failed'

  return (
    <div data-slot="split-link-field" className={cn('relative flex min-w-0 items-center', className)} {...props}>
      <button
        type="button"
        aria-label={label}
        title={copied ? copiedLabel : `${label} (${url})`}
        data-copied={copied || undefined}
        data-failed={failed || undefined}
        onClick={async () => {
          try {
            const text = resolveValue ? await resolveValue() : url
            if (!text) return
            await navigator.clipboard.writeText(text)
            report(true)
            onCopied?.()
          } catch (error) {
            report(false)
            onCopyError?.(error)
          }
        }}
        className="group/split-link flex min-h-8 w-full min-w-0 cursor-pointer items-center gap-2 rounded-control border border-border-subtle/80 bg-layer-01/65 px-2.5 py-1 text-start text-65 leading-5 transition-[background-color,border-color,scale] duration-(--duration-feedback) hover:border-control-edge hover:bg-layer-hover active:scale-[0.99] focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-ring motion-reduce:transition-none">
        <span aria-hidden className="flex size-4 shrink-0 items-center justify-center text-fg-secondary [&>svg]:size-4">
          {icon ?? <LinkRegular />}
        </span>
        <bdi className="flex min-w-0 flex-1 items-baseline overflow-hidden whitespace-nowrap">
          <span data-slot="split-link-host" className="max-w-[62%] shrink-0 truncate font-medium text-fg-primary">
            {host}
          </span>
          {path && (
            <span data-slot="split-link-path" className="min-w-0 truncate text-fg-secondary">
              {path}
            </span>
          )}
        </bdi>
        <CopyIcon
          copied={copied}
          className={cn(
            'ms-1 transition-colors duration-(--duration-feedback)',
            copied
              ? 'text-success'
              : failed
                ? 'text-destructive'
                : 'text-fg-secondary group-hover/split-link:text-fg-primary'
          )}
        />
      </button>
      <span role="status" className="sr-only">
        {announcement}
      </span>
    </div>
  )
}

export { CopyButton, CopyIcon, SplitLinkField, type SplitLinkFieldProps }
