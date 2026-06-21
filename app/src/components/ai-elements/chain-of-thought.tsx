'use client'

import { useControllableState } from '@radix-ui/react-use-controllable-state'
import { Badge } from '@/uikit/components/badge'
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@/uikit/components/collapsible'
import { cn } from '@/uikit/lib/utils'
import type { LucideIcon } from 'lucide-react'
import { BrainIcon, ChevronDownIcon, DotIcon } from 'lucide-react'
import type { ComponentProps, ReactNode } from 'react'
import { createContext, memo, useContext, useMemo } from 'react'

// Shared open/closed state for the whole block. The header (trigger) and the content live in separate
// subcomponents, so the expanded state is held here in context rather than locally in either one.
interface ChainOfThoughtContextValue {
  isOpen: boolean
  setIsOpen: (open: boolean) => void
}

const ChainOfThoughtContext = createContext<ChainOfThoughtContextValue | null>(null)

const useChainOfThought = () => {
  const context = useContext(ChainOfThoughtContext)
  if (!context) {
    throw new Error('ChainOfThought components must be used within ChainOfThought')
  }
  return context
}

export type ChainOfThoughtProps = ComponentProps<'div'> & {
  open?: boolean
  defaultOpen?: boolean
  onOpenChange?: (open: boolean) => void
}

/**
 * Collapsible panel that surfaces an agent's intermediate reasoning ("chain of thought") in the console:
 * a header, a vertical list of steps, optional search-result chips and images.
 *
 * Open state works in both controlled and uncontrolled modes: pass `open`/`onOpenChange` to drive it, or
 * leave them off and it manages its own state seeded from `defaultOpen`.
 */
export const ChainOfThought = memo(
  ({ className, open, defaultOpen = false, onOpenChange, children, ...props }: ChainOfThoughtProps) => {
    const [isOpen, setIsOpen] = useControllableState({
      defaultProp: defaultOpen,
      onChange: onOpenChange,
      prop: open
    })

    const chainOfThoughtContext = useMemo(() => ({ isOpen, setIsOpen }), [isOpen, setIsOpen])

    return (
      <ChainOfThoughtContext.Provider value={chainOfThoughtContext}>
        <div className={cn('not-prose w-full space-y-4', className)} {...props}>
          {children}
        </div>
      </ChainOfThoughtContext.Provider>
    )
  }
)

export type ChainOfThoughtHeaderProps = ComponentProps<typeof CollapsibleTrigger>

/** Clickable header that toggles the panel; the chevron rotates to reflect the shared open state. */
export const ChainOfThoughtHeader = memo(({ className, children, ...props }: ChainOfThoughtHeaderProps) => {
  const { isOpen, setIsOpen } = useChainOfThought()

  return (
    <Collapsible onOpenChange={setIsOpen} open={isOpen}>
      <CollapsibleTrigger
        className={cn(
          'flex w-full items-center gap-2 text-muted-foreground text-sm transition-colors hover:text-foreground',
          className
        )}
        {...props}>
        <BrainIcon className="size-4" />
        <span className="flex-1 text-left">{children ?? 'Chain of Thought'}</span>
        <ChevronDownIcon className={cn('size-4 transition-transform', isOpen ? 'rotate-180' : 'rotate-0')} />
      </CollapsibleTrigger>
    </Collapsible>
  )
})

export type ChainOfThoughtStepProps = ComponentProps<'div'> & {
  icon?: LucideIcon
  label: ReactNode
  description?: ReactNode
  status?: 'complete' | 'active' | 'pending'
}

// Status drives only the text emphasis: the in-progress step is full-strength, finished steps are muted,
// not-yet-reached steps are dimmest.
const stepStatusStyles = {
  active: 'text-foreground',
  complete: 'text-muted-foreground',
  pending: 'text-muted-foreground/50'
}

/** One step in the reasoning timeline: an icon, a label, optional description, and any nested detail. The
 * small absolutely-positioned line under the icon is the connector that visually links steps into a thread. */
export const ChainOfThoughtStep = memo(
  ({
    className,
    icon: Icon = DotIcon,
    label,
    description,
    status = 'complete',
    children,
    ...props
  }: ChainOfThoughtStepProps) => (
    <div
      className={cn(
        'flex gap-2 text-sm',
        stepStatusStyles[status],
        'fade-in-0 slide-in-from-top-2 animate-in',
        className
      )}
      {...props}>
      <div className="relative mt-0.5">
        <Icon className="size-4" />
        <div className="absolute top-7 bottom-0 left-1/2 -mx-px w-px bg-border" />
      </div>
      <div className="flex-1 space-y-2 overflow-hidden">
        <div>{label}</div>
        {description && <div className="text-muted-foreground text-xs">{description}</div>}
        {children}
      </div>
    </div>
  )
)

export type ChainOfThoughtSearchResultsProps = ComponentProps<'div'>

/** Row that wraps the search-result chips produced while the agent was searching during a step. */
export const ChainOfThoughtSearchResults = memo(({ className, ...props }: ChainOfThoughtSearchResultsProps) => (
  <div className={cn('flex flex-wrap items-center gap-2', className)} {...props} />
))

export type ChainOfThoughtSearchResultProps = ComponentProps<typeof Badge>

/** A single search-result chip (e.g. a queried source) shown inside a step. */
export const ChainOfThoughtSearchResult = memo(({ className, children, ...props }: ChainOfThoughtSearchResultProps) => (
  <Badge className={cn('gap-1 px-2 py-0.5 font-normal text-xs', className)} variant="secondary" {...props}>
    {children}
  </Badge>
))

export type ChainOfThoughtContentProps = ComponentProps<typeof CollapsibleContent>

/** Collapsible body holding the steps; its visibility follows the shared open state set by the header. */
export const ChainOfThoughtContent = memo(({ className, children, ...props }: ChainOfThoughtContentProps) => {
  const { isOpen } = useChainOfThought()

  return (
    <Collapsible open={isOpen}>
      <CollapsibleContent
        className={cn(
          'mt-2 space-y-3',
          'data-[state=closed]:fade-out-0 data-[state=closed]:slide-out-to-top-2 data-[state=open]:slide-in-from-top-2 text-popover-foreground outline-none data-[state=closed]:animate-out data-[state=open]:animate-in',
          className
        )}
        {...props}>
        {children}
      </CollapsibleContent>
    </Collapsible>
  )
})

export type ChainOfThoughtImageProps = ComponentProps<'div'> & {
  caption?: string
}

/** Framed image slot inside a step (e.g. a screenshot the agent looked at), with an optional caption. */
export const ChainOfThoughtImage = memo(({ className, children, caption, ...props }: ChainOfThoughtImageProps) => (
  <div className={cn('mt-2 space-y-2', className)} {...props}>
    <div className="relative flex max-h-[22rem] items-center justify-center overflow-hidden rounded-lg bg-muted p-3">
      {children}
    </div>
    {caption && <p className="text-muted-foreground text-xs">{caption}</p>}
  </div>
))

ChainOfThought.displayName = 'ChainOfThought'
ChainOfThoughtHeader.displayName = 'ChainOfThoughtHeader'
ChainOfThoughtStep.displayName = 'ChainOfThoughtStep'
ChainOfThoughtSearchResults.displayName = 'ChainOfThoughtSearchResults'
ChainOfThoughtSearchResult.displayName = 'ChainOfThoughtSearchResult'
ChainOfThoughtContent.displayName = 'ChainOfThoughtContent'
ChainOfThoughtImage.displayName = 'ChainOfThoughtImage'
