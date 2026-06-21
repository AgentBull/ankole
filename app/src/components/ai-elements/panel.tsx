import { cn } from '@/uikit/lib/utils'
import { Panel as PanelPrimitive } from '@xyflow/react'
import type { ComponentProps } from 'react'

type PanelProps = ComponentProps<typeof PanelPrimitive>

/**
 * Floating overlay panel anchored inside a React Flow canvas. Thin styling wrapper around the
 * `@xyflow/react` Panel primitive; used to surface controls or legends on top of a node graph.
 */
export const Panel = ({ className, ...props }: PanelProps) => (
  <PanelPrimitive className={cn('m-4 overflow-hidden rounded-md border bg-card p-1', className)} {...props} />
)
