'use client'

import { Button } from '@/uikit/components/button'
import { cn } from '@/uikit/lib/utils'
import Ansi from 'ansi-to-react'
import { CheckIcon, CopyIcon, TerminalIcon, Trash2Icon } from 'lucide-react'
import type { ComponentProps, HTMLAttributes } from 'react'
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'

interface TerminalContextType {
  output: string
  isStreaming: boolean
  autoScroll: boolean
  onClear?: () => void
}

// Terminal output and flags are shared through context so the header buttons (copy/clear), the status
// indicator, and the scrolling content body can each read what they need without prop-drilling.
const TerminalContext = createContext<TerminalContextType>({
  autoScroll: true,
  isStreaming: false,
  output: ''
})

export type TerminalHeaderProps = HTMLAttributes<HTMLDivElement>

/** Title bar of the terminal card; holds the title on the left and status/actions on the right. */
export const TerminalHeader = ({ className, children, ...props }: TerminalHeaderProps) => (
  <div className={cn('flex items-center justify-between border-zinc-800 border-b px-4 py-2', className)} {...props}>
    {children}
  </div>
)

export type TerminalTitleProps = HTMLAttributes<HTMLDivElement>

/** Terminal label with a terminal icon; defaults to "Terminal" when no children are given. */
export const TerminalTitle = ({ className, children, ...props }: TerminalTitleProps) => (
  <div className={cn('flex items-center gap-2 text-sm text-zinc-400', className)} {...props}>
    <TerminalIcon className="size-4" />
    {children ?? 'Terminal'}
  </div>
)

export type TerminalStatusProps = HTMLAttributes<HTMLDivElement>

/** "Running" indicator slot; renders only while the terminal is streaming, otherwise nothing. */
export const TerminalStatus = ({ className, children, ...props }: TerminalStatusProps) => {
  const { isStreaming } = useContext(TerminalContext)

  // No standing status when idle — the indicator exists only to signal live output.
  if (!isStreaming) {
    return null
  }

  return (
    <div className={cn('flex items-center gap-2 text-xs text-zinc-400', className)} {...props}>
      {children}
    </div>
  )
}

export type TerminalActionsProps = HTMLAttributes<HTMLDivElement>

/** Row holding the terminal's action buttons (copy, clear). */
export const TerminalActions = ({ className, children, ...props }: TerminalActionsProps) => (
  <div className={cn('flex items-center gap-1', className)} {...props}>
    {children}
  </div>
)

export type TerminalCopyButtonProps = ComponentProps<typeof Button> & {
  onCopy?: () => void
  onError?: (error: Error) => void
  /** How long (ms) the icon stays in the "copied" check state before reverting. */
  timeout?: number
}

/**
 * Copies the full terminal output to the clipboard, flipping to a check icon for `timeout` ms. Like
 * the other copy buttons, a missing Clipboard API is reported via `onError` rather than thrown.
 */
export const TerminalCopyButton = ({
  onCopy,
  onError,
  timeout = 2000,
  children,
  className,
  ...props
}: TerminalCopyButtonProps) => {
  const [isCopied, setIsCopied] = useState(false)
  const timeoutRef = useRef<number>(0)
  const { output } = useContext(TerminalContext)

  const copyToClipboard = useCallback(async () => {
    // Clipboard is unavailable under SSR and on non-secure origins; surface it as a soft error.
    if (typeof window === 'undefined' || !navigator?.clipboard?.writeText) {
      onError?.(new Error('Clipboard API not available'))
      return
    }

    try {
      await navigator.clipboard.writeText(output)
      setIsCopied(true)
      onCopy?.()
      timeoutRef.current = window.setTimeout(() => setIsCopied(false), timeout)
    } catch (error) {
      onError?.(error as Error)
    }
  }, [output, onCopy, onError, timeout])

  // Drop the pending revert timer if the button unmounts before it fires.
  useEffect(
    () => () => {
      window.clearTimeout(timeoutRef.current)
    },
    []
  )

  const Icon = isCopied ? CheckIcon : CopyIcon

  return (
    <Button
      className={cn('size-7 shrink-0 text-zinc-400 hover:bg-zinc-800 hover:text-zinc-100', className)}
      onClick={copyToClipboard}
      size="icon"
      variant="ghost"
      {...props}>
      {children ?? <Icon size={14} />}
    </Button>
  )
}

export type TerminalClearButtonProps = ComponentProps<typeof Button>

/** Clear button; renders only when the host supplied an `onClear` handler via the {@link Terminal} root. */
export const TerminalClearButton = ({ children, className, ...props }: TerminalClearButtonProps) => {
  const { onClear } = useContext(TerminalContext)

  // Without a clear handler there is nothing to do, so the button hides itself entirely.
  if (!onClear) {
    return null
  }

  return (
    <Button
      className={cn('size-7 shrink-0 text-zinc-400 hover:bg-zinc-800 hover:text-zinc-100', className)}
      onClick={onClear}
      size="icon"
      variant="ghost"
      {...props}>
      {children ?? <Trash2Icon size={14} />}
    </Button>
  )
}

export type TerminalContentProps = HTMLAttributes<HTMLDivElement>

/**
 * Scrolling output body. Renders the raw output through `ansi-to-react` so shell colour/style escape
 * codes show as real formatting, and keeps the newest line in view while output streams.
 */
export const TerminalContent = ({ className, children, ...props }: TerminalContentProps) => {
  const { output, isStreaming, autoScroll } = useContext(TerminalContext)
  const containerRef = useRef<HTMLDivElement>(null)

  // Follow the tail: every time output grows, pin the scroll to the bottom. Tied to `output` so it
  // re-runs on each streamed chunk. A reader who scrolls up is overridden on the next chunk — a simple
  // "always tail" tradeoff rather than tracking whether the user scrolled away.
  useEffect(() => {
    if (autoScroll && containerRef.current) {
      containerRef.current.scrollTop = containerRef.current.scrollHeight
    }
  }, [output, autoScroll])

  return (
    <div
      className={cn('max-h-96 overflow-auto p-4 font-mono text-sm leading-relaxed', className)}
      ref={containerRef}
      {...props}>
      {children ?? (
        <pre className="whitespace-pre-wrap break-words">
          <Ansi>{output}</Ansi>
          {/* Blinking block caret, shown only while live, to mimic a real terminal cursor. */}
          {isStreaming && <span className="ml-0.5 inline-block h-4 w-2 animate-pulse bg-zinc-100" />}
        </pre>
      )}
    </div>
  )
}

export type TerminalProps = HTMLAttributes<HTMLDivElement> & {
  output: string
  /** True while output is still being produced; shows the status indicator and the blinking caret. */
  isStreaming?: boolean
  /** Keep the view pinned to the latest output (default true). */
  autoScroll?: boolean
  /** Optional clear handler; when omitted the clear button does not appear. */
  onClear?: () => void
}

/**
 * Self-contained terminal card for command output. Publishes its props via context and, when no
 * children are supplied, renders the default header + scrolling body layout. Pass children to take
 * full control of the composition.
 */
export const Terminal = ({
  output,
  isStreaming = false,
  autoScroll = true,
  onClear,
  className,
  children,
  ...props
}: TerminalProps) => {
  const contextValue = useMemo(
    () => ({ autoScroll, isStreaming, onClear, output }),
    [autoScroll, isStreaming, onClear, output]
  )

  return (
    <TerminalContext.Provider value={contextValue}>
      <div
        className={cn('flex flex-col overflow-hidden rounded-lg border bg-zinc-950 text-zinc-100', className)}
        {...props}>
        {children ?? (
          <>
            <TerminalHeader>
              <TerminalTitle />
              <div className="flex items-center gap-1">
                <TerminalStatus />
                <TerminalActions>
                  <TerminalCopyButton />
                  {onClear && <TerminalClearButton />}
                </TerminalActions>
              </div>
            </TerminalHeader>
            <TerminalContent />
          </>
        )}
      </div>
    </TerminalContext.Provider>
  )
}
