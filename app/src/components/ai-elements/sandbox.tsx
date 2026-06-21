'use client'

import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@/uikit/components/collapsible'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/uikit/components/tabs'
import { cn } from '@/uikit/lib/utils'
import type { ToolUIPart } from '@/llm'
import { ChevronDownIcon, Code } from 'lucide-react'
import type { ComponentProps } from 'react'

import { getStatusBadge } from './tool'

// The Sandbox family renders a collapsible, tabbed card for a code-sandbox tool call (e.g. code on one
// tab, console/preview on another). The header reuses the shared tool status badge so it matches the
// {@link file://./tool.tsx} cards in the same stream.

export type SandboxRootProps = ComponentProps<typeof Collapsible>

/** Root collapsible card for a sandbox tool result. Open by default so output is visible immediately. */
export const Sandbox = ({ className, ...props }: SandboxRootProps) => (
  <Collapsible
    className={cn('not-prose group mb-4 w-full overflow-hidden rounded-md border', className)}
    defaultOpen
    {...props}
  />
)

export interface SandboxHeaderProps {
  title?: string
  /** Tool lifecycle state, used to render the shared status badge. */
  state: ToolUIPart['state']
  className?: string
}

/** Clickable header showing a code icon, title, and the tool status badge; toggles the card open/closed. */
export const SandboxHeader = ({ className, title, state, ...props }: SandboxHeaderProps) => (
  <CollapsibleTrigger className={cn('flex w-full items-center justify-between gap-4 p-3', className)} {...props}>
    <div className="flex items-center gap-2">
      <Code className="size-4 text-muted-foreground" />
      <span className="font-medium text-sm">{title}</span>
      {getStatusBadge(state)}
    </div>
    <ChevronDownIcon className="size-4 text-muted-foreground transition-transform group-data-[state=open]:rotate-180" />
  </CollapsibleTrigger>
)

export type SandboxContentProps = ComponentProps<typeof CollapsibleContent>

/** Animated expandable body of the sandbox card. */
export const SandboxContent = ({ className, ...props }: SandboxContentProps) => (
  <CollapsibleContent
    className={cn(
      'data-[state=closed]:fade-out-0 data-[state=closed]:slide-out-to-top-2 data-[state=open]:slide-in-from-top-2 outline-none data-[state=closed]:animate-out data-[state=open]:animate-in',
      className
    )}
    {...props}
  />
)

export type SandboxTabsProps = ComponentProps<typeof Tabs>

/** Tab group inside the sandbox card (e.g. Code / Output). */
export const SandboxTabs = ({ className, ...props }: SandboxTabsProps) => (
  <Tabs className={cn('w-full gap-0', className)} {...props} />
)

export type SandboxTabsBarProps = ComponentProps<'div'>

/** Horizontal bar that holds the tab triggers, bordered top and bottom. */
export const SandboxTabsBar = ({ className, ...props }: SandboxTabsBarProps) => (
  <div className={cn('flex w-full items-center border-border border-t border-b', className)} {...props} />
)

export type SandboxTabsListProps = ComponentProps<typeof TabsList>

/** Unstyled-by-default container for the tab triggers (borders/background come from the bar). */
export const SandboxTabsList = ({ className, ...props }: SandboxTabsListProps) => (
  <TabsList className={cn('h-auto rounded-none border-0 bg-transparent p-0', className)} {...props} />
)

export type SandboxTabsTriggerProps = ComponentProps<typeof TabsTrigger>

/** A single tab button; the active tab gets an underline and foreground text. */
export const SandboxTabsTrigger = ({ className, ...props }: SandboxTabsTriggerProps) => (
  <TabsTrigger
    className={cn(
      'rounded-none border-0 border-transparent border-b-2 px-4 py-2 font-medium text-muted-foreground text-sm transition-colors data-[state=active]:border-primary data-[state=active]:bg-transparent data-[state=active]:text-foreground data-[state=active]:shadow-none',
      className
    )}
    {...props}
  />
)

export type SandboxTabContentProps = ComponentProps<typeof TabsContent>

/** Body shown for the selected tab. */
export const SandboxTabContent = ({ className, ...props }: SandboxTabContentProps) => (
  <TabsContent className={cn('mt-0 text-sm', className)} {...props} />
)
