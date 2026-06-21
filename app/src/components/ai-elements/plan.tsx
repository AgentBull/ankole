'use client'

import { Button } from '@/uikit/components/button'
import {
  Card,
  CardAction,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle
} from '@/uikit/components/card'
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@/uikit/components/collapsible'
import { cn } from '@/uikit/lib/utils'
import { ChevronsUpDownIcon } from 'lucide-react'
import type { ComponentProps } from 'react'
import { createContext, useContext, useMemo } from 'react'

import { Shimmer } from './shimmer'

interface PlanContextValue {
  isStreaming: boolean
}

// `isStreaming` is shared through context so the title/description parts can apply the shimmer effect
// without each call site having to thread the flag down by hand.
const PlanContext = createContext<PlanContextValue | null>(null)

/** Reads the Plan context; throws if a Plan part is rendered outside a {@link Plan} root. */
const usePlan = () => {
  const context = useContext(PlanContext)
  if (!context) {
    throw new Error('Plan components must be used within Plan')
  }
  return context
}

export type PlanProps = ComponentProps<typeof Collapsible> & {
  /** True while the plan text is still being generated; drives the shimmer on title/description. */
  isStreaming?: boolean
}

/**
 * Collapsible card that presents an agent's plan (a titled card with description and body). The whole
 * subtree shows a shimmer animation while `isStreaming` is set, signalling the plan is still arriving.
 */
export const Plan = ({ className, isStreaming = false, children, ...props }: PlanProps) => {
  const contextValue = useMemo(() => ({ isStreaming }), [isStreaming])

  return (
    <PlanContext.Provider value={contextValue}>
      <Collapsible data-slot="plan" {...props} render={<Card className={cn('shadow-none', className)} />}>
        {children}
      </Collapsible>
    </PlanContext.Provider>
  )
}

export type PlanHeaderProps = ComponentProps<typeof CardHeader>

/** Header row of the plan card, laying out the title/description against the action slot. */
export const PlanHeader = ({ className, ...props }: PlanHeaderProps) => (
  <CardHeader className={cn('flex items-start justify-between', className)} data-slot="plan-header" {...props} />
)

export type PlanTitleProps = Omit<ComponentProps<typeof CardTitle>, 'children'> & {
  // `children` is narrowed to a string because the streaming branch feeds it to {@link Shimmer},
  // which animates plain text rather than arbitrary nodes.
  children: string
}

/** Plan title; shimmers while the plan is still streaming, otherwise renders the text plainly. */
export const PlanTitle = ({ children, ...props }: PlanTitleProps) => {
  const { isStreaming } = usePlan()

  return (
    <CardTitle data-slot="plan-title" {...props}>
      {isStreaming ? <Shimmer>{children}</Shimmer> : children}
    </CardTitle>
  )
}

export type PlanDescriptionProps = Omit<ComponentProps<typeof CardDescription>, 'children'> & {
  children: string
}

/** Plan subtitle/description; like the title, shimmers while streaming. */
export const PlanDescription = ({ className, children, ...props }: PlanDescriptionProps) => {
  const { isStreaming } = usePlan()

  return (
    <CardDescription className={cn('text-balance', className)} data-slot="plan-description" {...props}>
      {isStreaming ? <Shimmer>{children}</Shimmer> : children}
    </CardDescription>
  )
}

export type PlanActionProps = ComponentProps<typeof CardAction>

/** Top-right action slot of the header (e.g. holds the {@link PlanTrigger} toggle). */
export const PlanAction = (props: PlanActionProps) => <CardAction data-slot="plan-action" {...props} />

export type PlanContentProps = ComponentProps<typeof CardContent>

/** Collapsible body of the plan card; shown/hidden by the trigger. */
export const PlanContent = (props: PlanContentProps) => (
  <CollapsibleContent render={<CardContent data-slot="plan-content" {...props} />}></CollapsibleContent>
)

export type PlanFooterProps = ComponentProps<'div'>

/** Footer region of the plan card. */
export const PlanFooter = (props: PlanFooterProps) => <CardFooter data-slot="plan-footer" {...props} />

export type PlanTriggerProps = ComponentProps<typeof CollapsibleTrigger>

/** Icon button that expands/collapses the plan body; carries an sr-only label for assistive tech. */
export const PlanTrigger = ({ className, ...props }: PlanTriggerProps) => (
  <CollapsibleTrigger
    render={
      <Button className={cn('size-8', className)} data-slot="plan-trigger" size="icon" variant="ghost" {...props} />
    }>
    <ChevronsUpDownIcon className="size-4" />
    <span className="sr-only">Toggle plan</span>
  </CollapsibleTrigger>
)
