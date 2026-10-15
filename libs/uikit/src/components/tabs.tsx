'use client'

import { Tabs as TabsPrimitive } from '@base-ui/react/tabs'
import { cva, type VariantProps } from 'class-variance-authority'

import { cn } from '../lib/utils'

function Tabs({ className, orientation = 'horizontal', ...props }: TabsPrimitive.Root.Props) {
  return (
    <TabsPrimitive.Root
      data-slot="tabs"
      data-orientation={orientation}
      data-horizontal={orientation === 'horizontal' ? '' : undefined}
      data-vertical={orientation === 'vertical' ? '' : undefined}
      orientation={orientation}
      className={cn('group/tabs flex gap-2 data-horizontal:flex-col', className)}
      {...props}
    />
  )
}

const tabsListVariants = cva(
  'group/tabs-list inline-flex w-fit items-center justify-center text-muted-foreground group-data-horizontal/tabs:h-8 group-data-vertical/tabs:h-fit group-data-vertical/tabs:flex-col',
  {
    variants: {
      variant: {
        default: 'border-b border-border bg-transparent',
        line: 'border-b border-border bg-transparent',
        // Tabs on the ground: a ghost control for each tab and a paper object for the active tab.
        object: 'gap-0.5 bg-transparent group-data-horizontal/tabs:h-7'
      }
    },
    defaultVariants: {
      variant: 'default'
    }
  }
)

function TabsList({
  className,
  variant = 'default',
  ...props
}: TabsPrimitive.List.Props & VariantProps<typeof tabsListVariants>) {
  return (
    <TabsPrimitive.List
      data-slot="tabs-list"
      data-variant={variant}
      className={cn(tabsListVariants({ variant }), className)}
      {...props}
    />
  )
}

function TabsTrigger({ className, ...props }: TabsPrimitive.Tab.Props) {
  return (
    <TabsPrimitive.Tab
      data-slot="tabs-trigger"
      className={cn(
        "relative inline-flex h-full flex-1 cursor-pointer items-center justify-center gap-2 border border-transparent px-3 py-0 text-sm font-normal whitespace-nowrap text-muted-foreground transition-colors group-data-vertical/tabs:w-full group-data-vertical/tabs:justify-start group-data-vertical/tabs:px-3 group-data-vertical/tabs:py-1.5 hover:text-foreground focus-visible:-outline-offset-2 disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-50 has-data-[icon=inline-end]:pr-2.5 has-data-[icon=inline-start]:pl-2.5 aria-disabled:pointer-events-none aria-disabled:cursor-not-allowed aria-disabled:opacity-50 dark:text-muted-foreground dark:hover:text-foreground [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        'group-data-[variant=line]/tabs-list:bg-transparent group-data-[variant=line]/tabs-list:data-active:bg-transparent dark:group-data-[variant=line]/tabs-list:data-active:border-transparent dark:group-data-[variant=line]/tabs-list:data-active:bg-transparent',
        'data-active:text-foreground',
        'after:absolute after:bg-foreground after:opacity-0 after:transition-opacity group-data-horizontal/tabs:after:inset-x-0 group-data-horizontal/tabs:after:bottom-[-1px] group-data-horizontal/tabs:after:h-0.5 group-data-vertical/tabs:after:inset-y-0 group-data-vertical/tabs:after:-right-1 group-data-vertical/tabs:after:w-0.5 data-active:after:opacity-100',
        'group-data-[variant=object]/tabs-list:flex-none group-data-[variant=object]/tabs-list:gap-1.5 group-data-[variant=object]/tabs-list:rounded-control group-data-[variant=object]/tabs-list:px-2 group-data-[variant=object]/tabs-list:text-[13px] group-data-[variant=object]/tabs-list:text-fg-tertiary group-data-[variant=object]/tabs-list:after:hidden group-data-[variant=object]/tabs-list:focus-visible:outline-offset-1 group-data-[variant=object]/tabs-list:hover:bg-accent group-data-[variant=object]/tabs-list:hover:text-foreground group-data-[variant=object]/tabs-list:data-active:border-control-edge group-data-[variant=object]/tabs-list:data-active:border-b-control-base group-data-[variant=object]/tabs-list:data-active:bg-control group-data-[variant=object]/tabs-list:data-active:font-medium group-data-[variant=object]/tabs-list:data-active:text-foreground group-data-[variant=object]/tabs-list:data-active:hover:bg-control',
        className
      )}
      {...props}
    />
  )
}

function TabsContent({ className, ...props }: TabsPrimitive.Panel.Props) {
  return (
    <TabsPrimitive.Panel data-slot="tabs-content" className={cn('flex-1 text-sm outline-none', className)} {...props} />
  )
}

export { Tabs, TabsContent, TabsList, TabsTrigger, tabsListVariants }
