'use client'

import { Badge } from '@/uikit/components/badge'
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@/uikit/components/collapsible'
import { cn } from '@/uikit/lib/utils'
import type { DynamicToolUIPart, ToolUIPart } from '@/llm'
import { CheckCircleIcon, ChevronDownIcon, CircleIcon, ClockIcon, WrenchIcon, XCircleIcon } from 'lucide-react'
import type { ComponentProps, ReactNode } from 'react'
import { isValidElement } from 'react'

import { CodeBlock } from './code-block'

export type ToolProps = ComponentProps<typeof Collapsible>

/**
 * Collapsible card representing a single tool call in the message stream — header with the tool name
 * and live status, expandable to show the JSON input and the result/error.
 */
export const Tool = ({ className, ...props }: ToolProps) => (
  <Collapsible className={cn('group not-prose mb-4 w-full rounded-md border', className)} {...props} />
)

export type ToolPart = ToolUIPart | DynamicToolUIPart

export type ToolHeaderProps = {
  title?: string
  className?: string
} & (
  | { type: ToolUIPart['type']; state: ToolUIPart['state']; toolName?: never }
  | {
      type: DynamicToolUIPart['type']
      state: DynamicToolUIPart['state']
      toolName: string
    }
)

// Maps each tool-call lifecycle state from the AI SDK to a human label. Note the states are the SDK's
// internal stages, not user words: `input-streaming` (arguments still arriving) reads as "Pending",
// `input-available` (args complete, tool executing) reads as "Running".
const statusLabels: Record<ToolPart['state'], string> = {
  'approval-requested': 'Awaiting Approval',
  'approval-responded': 'Responded',
  'input-available': 'Running',
  'input-streaming': 'Pending',
  'output-available': 'Completed',
  'output-denied': 'Denied',
  'output-error': 'Error'
}

const statusIcons: Record<ToolPart['state'], ReactNode> = {
  'approval-requested': <ClockIcon className="size-4 text-yellow-600" />,
  'approval-responded': <CheckCircleIcon className="size-4 text-blue-600" />,
  'input-available': <ClockIcon className="size-4 animate-pulse" />,
  'input-streaming': <CircleIcon className="size-4" />,
  'output-available': <CheckCircleIcon className="size-4 text-green-600" />,
  'output-denied': <XCircleIcon className="size-4 text-orange-600" />,
  'output-error': <XCircleIcon className="size-4 text-red-600" />
}

/**
 * Renders the status pill (icon + label) for a tool state. Exported because sibling renderers such as
 * {@link file://./sandbox.tsx} reuse the exact same badge so tool status looks identical everywhere.
 */
export const getStatusBadge = (status: ToolPart['state']) => (
  <Badge className="gap-1.5 rounded-full text-xs" variant="secondary">
    {statusIcons[status]}
    {statusLabels[status]}
  </Badge>
)

/** Header row of a {@link Tool} card: wrench icon, tool name, status badge, and the expand chevron. */
export const ToolHeader = ({ className, title, type, state, toolName, ...props }: ToolHeaderProps) => {
  // Static tools carry their name encoded in `type` as `tool-<name>` (the SDK's part type), so the
  // leading "tool" segment is stripped to recover the display name. Dynamic tools instead pass an
  // explicit `toolName` because their name is only known at runtime.
  const derivedName = type === 'dynamic-tool' ? toolName : type.split('-').slice(1).join('-')

  return (
    <CollapsibleTrigger className={cn('flex w-full items-center justify-between gap-4 p-3', className)} {...props}>
      <div className="flex items-center gap-2">
        <WrenchIcon className="size-4 text-muted-foreground" />
        <span className="font-medium text-sm">{title ?? derivedName}</span>
        {getStatusBadge(state)}
      </div>
      <ChevronDownIcon className="size-4 text-muted-foreground transition-transform group-data-[state=open]:rotate-180" />
    </CollapsibleTrigger>
  )
}

export type ToolContentProps = ComponentProps<typeof CollapsibleContent>

/** Expandable body of the tool card; holds {@link ToolInput} and {@link ToolOutput}. */
export const ToolContent = ({ className, ...props }: ToolContentProps) => (
  <CollapsibleContent
    className={cn(
      'data-[state=closed]:fade-out-0 data-[state=closed]:slide-out-to-top-2 data-[state=open]:slide-in-from-top-2 space-y-4 p-4 text-popover-foreground outline-none data-[state=closed]:animate-out data-[state=open]:animate-in',
      className
    )}
    {...props}
  />
)

export type ToolInputProps = ComponentProps<'div'> & {
  input: ToolPart['input']
}

/** "Parameters" section: pretty-prints the tool's call arguments as a JSON code block. */
export const ToolInput = ({ className, input, ...props }: ToolInputProps) => (
  <div className={cn('space-y-2 overflow-hidden', className)} {...props}>
    <h4 className="font-medium text-muted-foreground text-xs uppercase tracking-wide">Parameters</h4>
    <div className="rounded-md bg-muted/50">
      <CodeBlock code={JSON.stringify(input, null, 2)} language="json" />
    </div>
  </div>
)

export type ToolOutputProps = ComponentProps<'div'> & {
  output: ToolPart['output']
  errorText: ToolPart['errorText']
}

/**
 * "Result" / "Error" section of a tool card. Renders nothing until the call produces either an output
 * or an error, so a still-running tool shows just its parameters.
 */
export const ToolOutput = ({ className, output, errorText, ...props }: ToolOutputProps) => {
  // Hide the whole section while there is nothing to show yet.
  if (!(output || errorText)) {
    return null
  }

  // Pick a renderer by output shape: a ready React element is shown as-is; a plain object/array is
  // serialised to a JSON code block; a string is also treated as JSON (tool results are usually JSON
  // text). The element check guards against JSON-stringifying something already meant to be rendered.
  let Output = <div>{output as ReactNode}</div>

  if (typeof output === 'object' && !isValidElement(output)) {
    Output = <CodeBlock code={JSON.stringify(output, null, 2)} language="json" />
  } else if (typeof output === 'string') {
    Output = <CodeBlock code={output} language="json" />
  }

  return (
    <div className={cn('space-y-2', className)} {...props}>
      <h4 className="font-medium text-muted-foreground text-xs uppercase tracking-wide">
        {errorText ? 'Error' : 'Result'}
      </h4>
      <div
        className={cn(
          'overflow-x-auto rounded-md text-xs [&_table]:w-full',
          errorText ? 'bg-destructive/10 text-destructive' : 'bg-muted/50 text-foreground'
        )}>
        {errorText && <div>{errorText}</div>}
        {Output}
      </div>
    </div>
  )
}
