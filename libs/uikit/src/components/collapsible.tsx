import {
  CollapsiblePanel,
  Collapsible as CollapsiblePrimitive,
  CollapsibleTrigger as CollapsibleTriggerPrimitive
} from '@ui-sdk/react/collapsible'
import type * as React from 'react'
import { cn } from '../lib/utils'

function Collapsible(props: React.ComponentProps<typeof CollapsiblePrimitive>) {
  return <CollapsiblePrimitive {...props} />
}

function CollapsibleTrigger(props: React.ComponentProps<typeof CollapsibleTriggerPrimitive>) {
  return <CollapsibleTriggerPrimitive {...props} />
}

function CollapsibleContent({ className, ...props }: React.ComponentProps<typeof CollapsiblePanel>) {
  return (
    <CollapsiblePanel
      className={cn(
        'h-(--collapsible-panel-height) overflow-hidden motion-safe:transition-[height] motion-safe:duration-(--duration-dialog) motion-safe:ease-out data-ending-style:h-0 data-starting-style:h-0',
        className
      )}
      {...props}
    />
  )
}

export { Collapsible, CollapsibleContent, CollapsibleTrigger }
