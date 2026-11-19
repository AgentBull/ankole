import {
  AccordionHeader,
  AccordionItem as AccordionItemPrimitive,
  AccordionPanel,
  Accordion as AccordionPrimitive,
  AccordionTrigger as AccordionTriggerPrimitive
} from '@ui-sdk/react/accordion'
import type * as React from 'react'
import { ChevronDownRegular, ChevronUpRegular } from '../icons'
import { cn } from '../lib/utils'

function Accordion({ className, ...props }: React.ComponentProps<typeof AccordionPrimitive>) {
  return <AccordionPrimitive className={cn('flex w-full flex-col', className)} {...props} />
}

function AccordionItem({ className, ...props }: React.ComponentProps<typeof AccordionItemPrimitive>) {
  return <AccordionItemPrimitive className={cn('not-last:border-b', className)} {...props} />
}

function AccordionTrigger({
  className,
  children,
  ...props
}: Omit<React.ComponentProps<typeof AccordionTriggerPrimitive>, 'children'> & { children?: React.ReactNode }) {
  return (
    <AccordionHeader className="flex">
      <AccordionTriggerPrimitive
        className={cn(
          'group/accordion-trigger relative flex flex-1 items-start justify-between gap-6 rounded-none border border-transparent py-4 text-left text-sm font-semibold transition-[border-color,color] hover:**:data-[slot=accordion-trigger-icon]:text-fg-primary focus-visible:-outline-offset-2 aria-disabled:pointer-events-none aria-disabled:text-fg-disabled data-disabled:pointer-events-none data-disabled:text-fg-disabled **:data-[slot=accordion-trigger-icon]:ml-auto **:data-[slot=accordion-trigger-icon]:size-3.5 **:data-[slot=accordion-trigger-icon]:text-fg-secondary',
          className
        )}
        {...props}>
        {children}
        <ChevronDownRegular
          data-slot="accordion-trigger-icon"
          className="pointer-events-none shrink-0 group-aria-expanded/accordion-trigger:hidden"
        />
        <ChevronUpRegular
          data-slot="accordion-trigger-icon"
          className="pointer-events-none hidden shrink-0 group-aria-expanded/accordion-trigger:inline"
        />
      </AccordionTriggerPrimitive>
    </AccordionHeader>
  )
}

function AccordionContent({
  className,
  children,
  ...props
}: Omit<React.ComponentProps<typeof AccordionPanel>, 'children'> & { children?: React.ReactNode }) {
  return (
    <AccordionPanel
      className="h-(--accordion-panel-height) overflow-hidden text-sm motion-safe:transition-[height] motion-safe:duration-(--duration-dialog) motion-safe:ease-out data-ending-style:h-0 data-starting-style:h-0"
      {...props}>
      <div
        className={cn(
          'pt-0 pb-4 [&_a]:underline [&_a]:underline-offset-3 [&_a]:hover:text-fg-primary [&_p:not(:last-child)]:mb-4',
          className
        )}>
        {children}
      </div>
    </AccordionPanel>
  )
}

export { Accordion, AccordionContent, AccordionItem, AccordionTrigger }
