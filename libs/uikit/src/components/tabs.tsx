'use client'

import { Tabs as TabsPrimitive } from '@base-ui/react/tabs'
import { cva, type VariantProps } from 'class-variance-authority'
import { useLayoutEffect, useRef } from 'react'

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
  'group/tabs-list relative isolate inline-flex w-fit items-center justify-center text-muted-foreground group-data-horizontal/tabs:h-8 group-data-vertical/tabs:h-fit group-data-vertical/tabs:flex-col',
  {
    variants: {
      variant: {
        default: 'border-b border-border bg-transparent',
        // Tabs that name a place, like a segmented control: the open tab sits on the selected fill, which slides
        // and stretches to the next tab when the selection changes.
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
  children,
  ...props
}: TabsPrimitive.List.Props & VariantProps<typeof tabsListVariants>) {
  return (
    <TabsPrimitive.List
      data-slot="tabs-list"
      data-variant={variant ?? 'default'}
      className={cn(tabsListVariants({ variant }), className)}
      {...props}>
      {children}
      {variant === 'object' ? (
        <SegmentIndicator />
      ) : (
        <TabsPrimitive.Indicator
          data-slot="tabs-indicator"
          aria-hidden
          className="pointer-events-none absolute bg-foreground"
        />
      )}
    </TabsPrimitive.List>
  )
}

type SegmentBox = { tab: Element; left: number; top: number; width: number; height: number }

// Where the open tab ends up once its content settles. Tab content may still be animating (a label opening or
// closing), so the list is cloned with transitions turned off and the open tab is measured in the clone.
function settledBox(list: HTMLElement): SegmentBox | null {
  const tabs = [...list.querySelectorAll<HTMLElement>('[role="tab"]')].filter(
    tab => tab.closest('[role="tablist"]') === list
  )
  const index = tabs.findIndex(tab => tab.hasAttribute('data-active'))
  if (index < 0 || !list.parentElement || list.offsetWidth === 0) return null
  const ghost = list.cloneNode(true) as HTMLElement
  ghost.setAttribute('data-tabs-measure', '')
  ghost.setAttribute('aria-hidden', 'true')
  ghost.removeAttribute('id')
  ghost.inert = true
  Object.assign(ghost.style, { position: 'absolute', left: '0', top: '0', visibility: 'hidden', pointerEvents: 'none' })
  list.parentElement.appendChild(ghost)
  const ghostTabs = [...ghost.querySelectorAll<HTMLElement>('[role="tab"]')].filter(
    tab => tab.closest('[role="tablist"]') === ghost
  )
  const frame = ghost.getBoundingClientRect()
  const rect = ghostTabs[index]?.getBoundingClientRect()
  const { clientLeft, clientTop } = ghost
  ghost.remove()
  const tab = tabs[index]
  if (!rect || !tab) return null
  return {
    tab,
    left: rect.left - frame.left - clientLeft,
    top: rect.top - frame.top - clientTop,
    width: rect.width,
    height: rect.height
  }
}

// Object tabs aim their fill at the new tab's settled box, even while the label is still opening. A size change
// alone (first layout, fonts, a narrower window) moves the fill without motion.
function SegmentIndicator() {
  const ref = useRef<HTMLSpanElement>(null)
  useLayoutEffect(() => {
    const indicator = ref.current
    const list = indicator?.parentElement
    if (!indicator || !list) return
    let placed: SegmentBox | null = null
    let travellingUntil = 0
    const place = () => {
      const box = settledBox(list)
      if (!box) {
        indicator.hidden = true
        placed = null
        return
      }
      if (
        placed &&
        placed.tab === box.tab &&
        placed.left === box.left &&
        placed.top === box.top &&
        placed.width === box.width &&
        placed.height === box.height
      ) {
        return
      }
      const travel = placed !== null && (placed.tab !== box.tab || performance.now() < travellingUntil)
      indicator.toggleAttribute('data-instant', !travel)
      if (placed && placed.tab !== box.tab) {
        const vertical = list.closest('[data-slot="tabs"]')?.hasAttribute('data-vertical')
        if (vertical) indicator.dataset.activationDirection = box.top < placed.top ? 'up' : 'down'
        else indicator.dataset.activationDirection = box.left < placed.left ? 'left' : 'right'
        const durations = getComputedStyle(indicator).transitionDuration.split(',').map(Number.parseFloat)
        travellingUntil = performance.now() + Math.max(...durations) * 1000
      }
      indicator.hidden = false
      indicator.style.setProperty('--segment-left', `${box.left}px`)
      indicator.style.setProperty('--segment-top', `${box.top}px`)
      indicator.style.setProperty('--segment-width', `${box.width}px`)
      indicator.style.setProperty('--segment-height', `${box.height}px`)
      placed = box
    }
    place()
    const mutations = new MutationObserver(place)
    mutations.observe(list, { subtree: true, attributes: true, attributeFilter: ['data-active', 'data-open'] })
    const resizes = new ResizeObserver(place)
    resizes.observe(list)
    return () => {
      mutations.disconnect()
      resizes.disconnect()
    }
  }, [])
  return (
    <span
      ref={ref}
      data-slot="tabs-indicator"
      aria-hidden
      hidden
      className="pointer-events-none absolute -z-10 rounded-control selected-surface"
    />
  )
}

function TabsTrigger({ className, ...props }: TabsPrimitive.Tab.Props) {
  return (
    <TabsPrimitive.Tab
      data-slot="tabs-trigger"
      className={cn(
        "relative inline-flex h-full flex-1 cursor-pointer items-center justify-center gap-2 border border-transparent px-3 py-0 text-[13px] font-normal whitespace-nowrap text-muted-foreground transition-colors group-data-vertical/tabs:w-full group-data-vertical/tabs:justify-start group-data-vertical/tabs:px-3 group-data-vertical/tabs:py-1.5 hover:text-foreground focus-visible:-outline-offset-2 disabled:pointer-events-none disabled:cursor-not-allowed disabled:text-fg-disabled has-data-[icon=inline-end]:pr-2.5 has-data-[icon=inline-start]:pl-2.5 aria-disabled:pointer-events-none aria-disabled:cursor-not-allowed aria-disabled:text-fg-disabled dark:text-muted-foreground dark:hover:text-foreground [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        'data-active:text-foreground',
        'group-data-[variant=object]/tabs-list:flex-none group-data-[variant=object]/tabs-list:gap-1.5 group-data-[variant=object]/tabs-list:rounded-control group-data-[variant=object]/tabs-list:px-2 group-data-[variant=object]/tabs-list:focus-visible:outline-offset-1 group-data-[variant=object]/tabs-list:border-0 group-data-[variant=object]/tabs-list:fine-hover:hover:bg-accent group-data-[variant=object]/tabs-list:hover:text-foreground group-data-[variant=object]/tabs-list:data-active:text-foreground group-data-[variant=object]/tabs-list:data-active:fine-hover:hover:bg-transparent',
        className
      )}
      {...props}
    />
  )
}

function TabsContent({ className, ...props }: TabsPrimitive.Panel.Props) {
  // Base UI keeps a closing panel in layout for one frame to finish exit animations; tabs have none, so the closing
  // panel leaves at once instead of pushing the opening one down for that frame.
  return (
    <TabsPrimitive.Panel
      data-slot="tabs-content"
      className={cn('flex-1 text-sm outline-none data-ending-style:hidden', className)}
      {...props}
    />
  )
}

export { Tabs, TabsContent, TabsList, TabsTrigger, tabsListVariants }
