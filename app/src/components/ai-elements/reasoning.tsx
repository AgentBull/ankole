'use client'

import { useControllableState } from '@radix-ui/react-use-controllable-state'
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@/uikit/components/collapsible'
import { cn } from '@/uikit/lib/utils'
import { cjk } from '@streamdown/cjk'
import { code } from '@streamdown/code'
import { math } from '@streamdown/math'
import { mermaid } from '@streamdown/mermaid'
import { BrainIcon, ChevronDownIcon } from 'lucide-react'
import type { ComponentProps, ReactNode } from 'react'
import { createContext, memo, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import { Streamdown } from 'streamdown'

import { Shimmer } from './shimmer'

interface ReasoningContextValue {
  isStreaming: boolean
  isOpen: boolean
  setIsOpen: (open: boolean) => void
  /** Total seconds the model spent thinking, once streaming has finished. */
  duration: number | undefined
}

// Streaming state, open state, and the measured think-duration are shared so the trigger can show
// "Thinking..." vs "Thought for N seconds" and the content can reveal/hide in step with streaming.
const ReasoningContext = createContext<ReasoningContextValue | null>(null)

/** Reads the Reasoning context; throws if a Reasoning part is used outside a {@link Reasoning} root. */
export const useReasoning = () => {
  const context = useContext(ReasoningContext)
  if (!context) {
    throw new Error('Reasoning components must be used within Reasoning')
  }
  return context
}

export type ReasoningProps = ComponentProps<typeof Collapsible> & {
  /** True while reasoning tokens are still arriving; drives auto-open, the timer, and the label. */
  isStreaming?: boolean
  open?: boolean
  defaultOpen?: boolean
  onOpenChange?: (open: boolean) => void
  /** Externally supplied think-duration (seconds); when omitted it is measured from the stream. */
  duration?: number
}

const AUTO_CLOSE_DELAY = 1000
const MS_IN_S = 1000

/**
 * Collapsible "chain of thought" panel for a model's reasoning tokens. Behaves like a live indicator:
 * it pops open while the model is thinking, times how long that took, then collapses itself shortly
 * after thinking ends so finished reasoning does not clutter the transcript. All three behaviours can
 * be overridden by controlling `open`/`defaultOpen` or passing an explicit `duration`.
 */
export const Reasoning = memo(
  ({
    className,
    isStreaming = false,
    open,
    defaultOpen,
    onOpenChange,
    duration: durationProp,
    children,
    ...props
  }: ReasoningProps) => {
    // With no explicit `defaultOpen`, start open exactly when the panel mounts mid-stream.
    const resolvedDefaultOpen = defaultOpen ?? isStreaming
    // A caller passing `defaultOpen={false}` is opting out of the auto-open below; remember that intent.
    const isExplicitlyClosed = defaultOpen === false

    const [isOpen, setIsOpen] = useControllableState<boolean>({
      defaultProp: resolvedDefaultOpen,
      onChange: onOpenChange,
      prop: open
    })
    const [duration, setDuration] = useControllableState<number | undefined>({
      defaultProp: undefined,
      prop: durationProp
    })

    // Survives re-renders: whether this panel has *ever* streamed. The auto-close must not fire for a
    // panel that mounted already-finished (e.g. when scrolling back through history).
    const hasEverStreamedRef = useRef(isStreaming)
    const [hasAutoClosed, setHasAutoClosed] = useState(false)
    // Wall-clock mark for when the current think started; null while not timing.
    const startTimeRef = useRef<number | null>(null)

    // Measure think-duration: stamp the start on the streaming edge, and on the falling edge convert
    // the elapsed time to whole seconds (rounded up so a sub-second think still reads as "1 second").
    useEffect(() => {
      if (isStreaming) {
        hasEverStreamedRef.current = true
        if (startTimeRef.current === null) {
          startTimeRef.current = Date.now()
        }
      } else if (startTimeRef.current !== null) {
        setDuration(Math.ceil((Date.now() - startTimeRef.current) / MS_IN_S))
        startTimeRef.current = null
      }
    }, [isStreaming, setDuration])

    // Reveal the panel as soon as streaming begins, unless the caller explicitly asked it to stay closed.
    useEffect(() => {
      if (isStreaming && !isOpen && !isExplicitlyClosed) {
        setIsOpen(true)
      }
    }, [isStreaming, isOpen, setIsOpen, isExplicitlyClosed])

    // Collapse shortly after streaming ends — but only once, and only for a panel that actually
    // streamed. The short delay lets the reader see the final tokens land before it tucks away; the
    // `hasAutoClosed` latch means a user who re-opens it afterwards is not fought by this effect.
    useEffect(() => {
      if (hasEverStreamedRef.current && !isStreaming && isOpen && !hasAutoClosed) {
        const timer = setTimeout(() => {
          setIsOpen(false)
          setHasAutoClosed(true)
        }, AUTO_CLOSE_DELAY)

        return () => clearTimeout(timer)
      }
    }, [isStreaming, isOpen, setIsOpen, hasAutoClosed])

    const handleOpenChange = useCallback(
      (newOpen: boolean) => {
        setIsOpen(newOpen)
      },
      [setIsOpen]
    )

    const contextValue = useMemo(
      () => ({ duration, isOpen, isStreaming, setIsOpen }),
      [duration, isOpen, isStreaming, setIsOpen]
    )

    return (
      <ReasoningContext.Provider value={contextValue}>
        <Collapsible
          className={cn('not-prose mb-4', className)}
          onOpenChange={handleOpenChange}
          open={isOpen}
          {...props}>
          {children}
        </Collapsible>
      </ReasoningContext.Provider>
    )
  }
)

export type ReasoningTriggerProps = ComponentProps<typeof CollapsibleTrigger> & {
  /** Overrides the default "Thinking..." / "Thought for N seconds" caption. */
  getThinkingMessage?: (isStreaming: boolean, duration?: number) => ReactNode
}

// Default caption logic:
//  - still streaming (or a measured-as-zero duration) → animated "Thinking..." shimmer;
//  - finished but duration unknown (e.g. mounted from history) → vague "a few seconds";
//  - finished with a measured duration → the exact second count.
const defaultGetThinkingMessage = (isStreaming: boolean, duration?: number) => {
  if (isStreaming || duration === 0) {
    return <Shimmer duration={1}>Thinking...</Shimmer>
  }
  if (duration === undefined) {
    return <p>Thought for a few seconds</p>
  }
  return <p>Thought for {duration} seconds</p>
}

/** Toggle row for the reasoning panel: brain icon, the thinking caption, and a chevron that flips when open. */
export const ReasoningTrigger = memo(
  ({ className, children, getThinkingMessage = defaultGetThinkingMessage, ...props }: ReasoningTriggerProps) => {
    const { isStreaming, isOpen, duration } = useReasoning()

    return (
      <CollapsibleTrigger
        className={cn(
          'flex w-full items-center gap-2 text-muted-foreground text-sm transition-colors hover:text-foreground',
          className
        )}
        {...props}>
        {children ?? (
          <>
            <BrainIcon className="size-4" />
            {getThinkingMessage(isStreaming, duration)}
            <ChevronDownIcon className={cn('size-4 transition-transform', isOpen ? 'rotate-180' : 'rotate-0')} />
          </>
        )}
      </CollapsibleTrigger>
    )
  }
)

export type ReasoningContentProps = ComponentProps<typeof CollapsibleContent> & {
  // `children` is the raw reasoning markdown string; it is rendered through Streamdown rather than
  // placed as nodes so it can format incrementally as tokens stream in.
  children: string
}

// Streamdown plugins enabled for reasoning markdown: CJK handling, code highlighting, math, mermaid.
const streamdownPlugins = { cjk, code, math, mermaid }

/** Expandable body that renders the reasoning markdown (streaming-aware) with a slide animation. */
export const ReasoningContent = memo(({ className, children, ...props }: ReasoningContentProps) => (
  <CollapsibleContent
    className={cn(
      'mt-4 text-sm',
      'data-[state=closed]:fade-out-0 data-[state=closed]:slide-out-to-top-2 data-[state=open]:slide-in-from-top-2 text-muted-foreground outline-none data-[state=closed]:animate-out data-[state=open]:animate-in',
      className
    )}
    {...props}>
    <Streamdown plugins={streamdownPlugins}>{children}</Streamdown>
  </CollapsibleContent>
))

Reasoning.displayName = 'Reasoning'
ReasoningTrigger.displayName = 'ReasoningTrigger'
ReasoningContent.displayName = 'ReasoningContent'
