import { cn } from '@/uikit/lib/utils'
import { NodeToolbar, Position } from '@xyflow/react'
import type { ComponentProps } from 'react'

type ToolbarProps = ComponentProps<typeof NodeToolbar>

/**
 * Action bar that hangs off a React Flow node (defaults to below it). Wraps the `@xyflow/react`
 * NodeToolbar primitive and only applies house styling; visibility/anchoring stay with the primitive.
 */
export const Toolbar = ({ className, ...props }: ToolbarProps) => (
  <NodeToolbar
    className={cn('flex items-center gap-1 rounded-sm border bg-background p-1.5', className)}
    position={Position.Bottom}
    {...props}
  />
)
