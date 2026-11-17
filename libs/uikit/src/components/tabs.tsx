'use client'

import {
  TabsIndicator,
  TabsList as TabsListPrimitive,
  TabsPanel,
  Tabs as TabsPrimitive,
  TabsTab
} from '@ui-sdk/react/tabs'
import { cva, type VariantProps } from 'class-variance-authority'
import { useLayoutEffect, useRef, type ComponentProps, type ReactNode } from 'react'

import { cn } from '../lib/utils'

/** Arrow keys move focus between tabs and Enter or Space opens one, unless the caller asks for `activation="automatic"`. */
function Tabs<T extends string = string>({
  className,
  orientation = 'horizontal',
  activation = 'manual',
  ...props
}: ComponentProps<typeof TabsPrimitive<T>>) {
  return (
    <TabsPrimitive
      data-horizontal={orientation === 'horizontal' ? '' : undefined}
      data-vertical={orientation === 'vertical' ? '' : undefined}
      orientation={orientation}
      activation={activation}
      className={cn('group/tabs flex gap-2 data-horizontal:flex-col', className)}
      {...props}
    />
  )
}

const tabsListVariants = cva(
  'group/tabs-list relative isolate inline-flex w-fit items-center justify-center text-fg-secondary group-data-horizontal/tabs:h-control-md group-data-vertical/tabs:h-fit group-data-vertical/tabs:flex-col',
  {
    variants: {
      variant: {
        default: 'border-b border-border-subtle bg-transparent',
        // Tabs that name a place, like a segmented control: the open tab sits on the selected fill, which slides
        // and stretches to the next tab when the selection changes.
        object: 'gap-0.5 bg-transparent group-data-horizontal/tabs:h-control-sm',
        // Tabs that name the sections of a navigation column: the current tab is a chip that shows its `TabsLabel`
        // on the selected fill, and every other tab is its bare 24px icon. The fill travels like the object fill.
        // In a sidebar's phone sheet the chips grow to 36px for touch.
        chip: 'gap-2 bg-transparent group-data-horizontal/tabs:h-control-sm in-data-[mobile=true]:group-data-horizontal/tabs:h-control-lg'
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
}: Omit<ComponentProps<typeof TabsListPrimitive>, 'children'> & { children?: ReactNode } & VariantProps<
    typeof tabsListVariants
  >) {
  return (
    <TabsListPrimitive
      data-variant={variant ?? 'default'}
      className={cn(tabsListVariants({ variant }), className)}
      {...props}>
      {children}
      {variant === 'object' || variant === 'chip' ? (
        <SegmentIndicator />
      ) : (
        <TabsIndicator aria-hidden className="pointer-events-none absolute bg-(--tab-indicator)" />
      )}
    </TabsListPrimitive>
  )
}

type SegmentBox = { tab: Element; left: number; top: number; width: number; height: number }

// Where the open tab ends up once its content settles. Tab content may still be animating (a label opening or
// closing), so the list is cloned with transitions turned off and the open tab is measured in the clone.
function settledBox(list: HTMLElement): SegmentBox | null {
  const tabs = [...list.querySelectorAll<HTMLElement>('[role="tab"]')].filter(
    tab => tab.closest('[role="tablist"]') === list
  )
  const index = tabs.findIndex(tab => tab.hasAttribute('data-selected'))
  if (index < 0 || !list.parentElement || list.offsetWidth === 0) return null
  const ghost = list.cloneNode(true) as HTMLElement
  ghost.setAttribute('data-tabs-measure', '')
  ghost.setAttribute('aria-hidden', 'true')
  ghost.removeAttribute('id')
  ghost.inert = true
  Object.assign(ghost.style, { position: 'absolute', left: '0', top: '0', visibility: 'hidden', pointerEvents: 'none' })
  // The absolute clone resolves a percentage or stretched width against another containing block, so a vertical
  // list, whose tabs fill its width, keeps the live list's width in the clone.
  if (list.getAttribute('aria-orientation') === 'vertical') ghost.style.width = `${list.offsetWidth}px`
  list.parentElement.appendChild(ghost)
  const ghostTabs = [...ghost.querySelectorAll<HTMLElement>('[role="tab"]')].filter(
    tab => tab.closest('[role="tablist"]') === ghost
  )
  const frame = ghost.getBoundingClientRect()
  const rect = ghostTabs[index]?.getBoundingClientRect()
  const { clientLeft, clientTop } = ghost
  ghost.remove()
  const tab = tabs[index]
  if (!rect || !tab || (rect.width === 0 && rect.height === 0)) return null
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
        const durations = getComputedStyle(indicator)
          .transitionDuration.split(',')
          .map(Number.parseFloat)
          .filter(Number.isFinite)
        travellingUntil = performance.now() + (durations.length > 0 ? Math.max(...durations) * 1000 : 0)
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
    mutations.observe(list, { subtree: true, attributes: true, attributeFilter: ['data-selected', 'data-open'] })
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

function TabsTrigger({ className, ...props }: ComponentProps<typeof TabsTab>) {
  return (
    <TabsTab
      className={cn(
        "group/tabs-trigger relative inline-flex h-full flex-1 cursor-pointer items-center justify-center gap-2 border border-transparent px-3 py-0 text-65 font-normal whitespace-nowrap text-(--tab-idle) transition-colors group-data-vertical/tabs:w-full group-data-vertical/tabs:justify-start group-data-vertical/tabs:px-3 group-data-vertical/tabs:py-1.5 hover:text-fg-primary focus-visible:-outline-offset-2 disabled:pointer-events-none disabled:cursor-not-allowed disabled:text-fg-disabled has-data-[icon=inline-end]:pr-2.5 has-data-[icon=inline-start]:pl-2.5 aria-disabled:pointer-events-none aria-disabled:cursor-not-allowed aria-disabled:text-fg-disabled [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        'data-selected:text-(--tab-current)',
        'group-data-[variant=object]/tabs-list:flex-none group-data-[variant=object]/tabs-list:gap-1.5 group-data-[variant=object]/tabs-list:rounded-control group-data-[variant=object]/tabs-list:px-2 group-data-[variant=object]/tabs-list:focus-visible:outline-offset-1 group-data-[variant=object]/tabs-list:border-0 group-data-[variant=object]/tabs-list:fine-hover:hover:bg-layer-hover group-data-[variant=object]/tabs-list:hover:text-fg-primary group-data-[variant=object]/tabs-list:data-selected:text-(--tab-current) group-data-[variant=object]/tabs-list:data-selected:fine-hover:hover:bg-transparent',
        // A chip keeps 2px and 4px of padding around a 24px icon and 15px text, so the bare icon of a closed tab holds
        // still when the tab opens. A closed tab draws in the secondary colour; the open tab draws its icon and its
        // Medium label in the primary colour.
        "group-data-[variant=chip]/tabs-list:flex-none group-data-[variant=chip]/tabs-list:gap-0 group-data-[variant=chip]/tabs-list:rounded-control group-data-[variant=chip]/tabs-list:border-0 group-data-[variant=chip]/tabs-list:px-1 group-data-[variant=chip]/tabs-list:py-0.5 in-data-[mobile=true]:group-data-[variant=chip]/tabs-list:py-1.5 group-data-[variant=chip]/tabs-list:text-85 group-data-[variant=chip]/tabs-list:text-fg-secondary group-data-[variant=chip]/tabs-list:focus-visible:outline-offset-1 group-data-[variant=chip]/tabs-list:fine-hover:hover:bg-layer-hover group-data-[variant=chip]/tabs-list:data-selected:font-medium group-data-[variant=chip]/tabs-list:data-selected:text-fg-primary group-data-[variant=chip]/tabs-list:data-selected:fine-hover:hover:bg-transparent group-data-[variant=chip]/tabs-list:[&_svg:not([class*='size-'])]:size-6",
        className
      )}
      {...props}
    />
  )
}

/**
 * The label of a chip tab. It opens beside the icon while its tab is current and closes on every other tab: the old
 * text blurs away while the column closes, and the new text comes into focus a moment later, so the two fades
 * overlap briefly and no frame shows a blank tab.
 */
function TabsLabel({ className, children, ...props }: ComponentProps<'span'>) {
  return (
    <span
      data-slot="tabs-label"
      className={cn(
        'grid grid-cols-[minmax(0,0fr)] transition-[grid-template-columns] duration-(--duration-segment) ease-segment group-data-selected/tabs-trigger:grid-cols-[minmax(0,1fr)] motion-reduce:transition-none',
        className
      )}
      {...props}>
      <span className="min-w-0 overflow-hidden ps-1 whitespace-nowrap opacity-0 blur-[2px] transition-[opacity,filter] duration-160 ease-out group-data-selected/tabs-trigger:opacity-100 group-data-selected/tabs-trigger:blur-none group-data-selected/tabs-trigger:delay-60 group-data-selected/tabs-trigger:duration-240 motion-reduce:transition-none">
        {children}
      </span>
    </span>
  )
}

function TabsContent({ className, ...props }: ComponentProps<typeof TabsPanel>) {
  // ui-sdk keeps a closing panel in layout while it animates out; tabs have no exit animation, so the closing panel
  // leaves at once instead of pushing the opening one down meanwhile.
  return <TabsPanel className={cn('flex-1 text-sm outline-none data-ending-style:hidden', className)} {...props} />
}

export { Tabs, TabsContent, TabsLabel, TabsList, TabsTrigger, tabsListVariants }
