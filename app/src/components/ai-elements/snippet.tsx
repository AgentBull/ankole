'use client'

import {
  InputGroup,
  InputGroupAddon,
  InputGroupButton,
  InputGroupInput,
  InputGroupText
} from '@/uikit/components/input-group'
import { cn } from '@/uikit/lib/utils'
import { CheckIcon, CopyIcon } from 'lucide-react'
import type { ComponentProps } from 'react'
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'

interface SnippetContextType {
  code: string
}

// The snippet's `code` is shared through context so child parts (the read-only input, the copy button)
// can read it without prop-drilling, letting callers compose the layout freely.
const SnippetContext = createContext<SnippetContextType>({
  code: ''
})

export type SnippetProps = ComponentProps<typeof InputGroup> & {
  code: string
}

/**
 * A one-line "copyable command" block — e.g. an install command shown to the user. Owns the snippet
 * text and publishes it via context; the visible field and copy button are composed as children.
 */
export const Snippet = ({ code, className, children, ...props }: SnippetProps) => {
  const contextValue = useMemo(() => ({ code }), [code])

  return (
    <SnippetContext.Provider value={contextValue}>
      <InputGroup className={cn('font-mono', className)} {...props}>
        {children}
      </InputGroup>
    </SnippetContext.Provider>
  )
}

export type SnippetAddonProps = ComponentProps<typeof InputGroupAddon>

export const SnippetAddon = (props: SnippetAddonProps) => <InputGroupAddon {...props} />

export type SnippetTextProps = ComponentProps<typeof InputGroupText>

export const SnippetText = ({ className, ...props }: SnippetTextProps) => (
  <InputGroupText className={cn('pl-2 font-normal text-muted-foreground', className)} {...props} />
)

export type SnippetInputProps = Omit<ComponentProps<typeof InputGroupInput>, 'readOnly' | 'value'>

/**
 * Read-only field that displays the snippet text from context. `readOnly`/`value` are removed from the
 * prop type on purpose: the field always mirrors the snippet and must not be turned into an editable input.
 */
export const SnippetInput = ({ className, ...props }: SnippetInputProps) => {
  const { code } = useContext(SnippetContext)

  return <InputGroupInput className={cn('text-foreground', className)} readOnly value={code} {...props} />
}

export type SnippetCopyButtonProps = ComponentProps<typeof InputGroupButton> & {
  onCopy?: () => void
  onError?: (error: Error) => void
  /** How long (ms) the icon stays in the "copied" check state before reverting. */
  timeout?: number
}

/**
 * Copy-to-clipboard button for a {@link Snippet}. Flips to a check icon on success, then back to the
 * copy icon after `timeout`. Reports failures through `onError` instead of throwing so a missing
 * Clipboard API (insecure context / SSR) degrades quietly rather than crashing the render tree.
 */
export const SnippetCopyButton = ({
  onCopy,
  onError,
  timeout = 2000,
  children,
  className,
  ...props
}: SnippetCopyButtonProps) => {
  const [isCopied, setIsCopied] = useState(false)
  const timeoutRef = useRef<number>(0)
  const { code } = useContext(SnippetContext)

  const copyToClipboard = useCallback(async () => {
    // Clipboard is unavailable under SSR and on non-secure origins; surface it as a soft error.
    if (typeof window === 'undefined' || !navigator?.clipboard?.writeText) {
      onError?.(new Error('Clipboard API not available'))
      return
    }

    try {
      // Ignore repeat clicks while already showing "copied", so the revert timer is not reset and
      // the check icon does not flicker.
      if (!isCopied) {
        await navigator.clipboard.writeText(code)
        setIsCopied(true)
        onCopy?.()
        timeoutRef.current = window.setTimeout(() => setIsCopied(false), timeout)
      }
    } catch (error) {
      onError?.(error as Error)
    }
  }, [code, onCopy, onError, timeout, isCopied])

  // Clear the pending revert timer if the button unmounts mid-countdown.
  useEffect(
    () => () => {
      window.clearTimeout(timeoutRef.current)
    },
    []
  )

  const Icon = isCopied ? CheckIcon : CopyIcon

  return (
    <InputGroupButton
      aria-label="Copy"
      className={className}
      onClick={copyToClipboard}
      size="icon-sm"
      title="Copy"
      {...props}>
      {children ?? <Icon className="size-3.5" size={14} />}
    </InputGroupButton>
  )
}
