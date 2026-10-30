import { cn, useReducedMotion } from '@ankole/uikit'
import { AnimatePresence, domAnimation, LazyMotion, MotionConfig, useIsPresent, usePresenceData } from 'motion/react'
import * as m from 'motion/react-m'
import { useLayoutEffect, useRef, useState, type ComponentProps, type ReactNode } from 'react'

export type PanelInputEvent = Event | { detail: number }

const popupContents = [
  'dialog-content',
  'sheet-content',
  'select-content',
  'dropdown-menu-content',
  'dropdown-menu-sub-content',
  'context-menu-content',
  'popover-content',
  'hover-card-content',
  'tooltip-content'
]
  .map(slot => `[data-slot='${slot}']`)
  .join(',')

// Intent belongs to one visibility change, not to the last input device used in the app.
export function usePanelMotion(open: boolean) {
  const pending = useRef<boolean | null>(null)
  const [edge, setEdge] = useState({ open, animate: false })
  let current = edge
  if (edge.open !== open) {
    current = { open, animate: pending.current === open }
    pending.current = null
    setEdge(current)
  }
  const prepare = (next: boolean, event?: PanelInputEvent) => {
    const pointer = event && 'detail' in event && typeof event.detail === 'number' && event.detail > 0
    // Unmount portals with their owner instead of retaining an interactive popup during exit.
    pending.current = next !== open && pointer && (next || !document.querySelector(popupContents)) ? next : null
  }
  return { animate: current.animate, prepare }
}

function panelTokens() {
  const style = getComputedStyle(document.documentElement)
  const duration = (name: string) => {
    const value = style.getPropertyValue(name).trim()
    const time = value.match(/^(\d*\.?\d+)(ms|s)$/)
    if (!time) throw new Error(`Expected a CSS time motion token: ${name}`)
    return Number(time[1]) / (time[2] === 'ms' ? 1000 : 1)
  }
  const curve = style
    .getPropertyValue('--ease-out')
    .trim()
    .match(/^cubic-bezier\(([^)]+)\)$/)
  const ease = curve?.[1]?.split(',').map(Number)
  if (!ease || ease.length !== 4 || ease.some(value => !Number.isFinite(value))) {
    throw new Error('Expected --ease-out to contain four cubic-bezier coordinates')
  }
  return {
    duration: duration('--duration-dialog'),
    reducedDuration: duration('--duration-feedback'),
    ease: ease as [number, number, number, number]
  }
}

type PanelPolicy = { tokens: ReturnType<typeof panelTokens> | null; animate: boolean }

export function PodPanelPresence({ animate, children }: { animate: boolean; children: ReactNode }) {
  const [tokens, setTokens] = useState<ReturnType<typeof panelTokens> | null>(null)
  useLayoutEffect(() => setTokens(panelTokens()), [])
  return (
    <LazyMotion features={domAnimation} strict>
      <MotionConfig reducedMotion="user">
        <AnimatePresence initial={false} custom={{ tokens, animate }}>
          {children}
        </AnimatePresence>
      </MotionConfig>
    </LazyMotion>
  )
}

export function PodPanelSurface({ style, className, ...props }: ComponentProps<typeof m.aside>) {
  const present = useIsPresent()
  const policy = usePresenceData() as PanelPolicy
  // The uikit hook subscribes to changes; Motion 14's hook snapshots the preference on mount.
  const reduce = useReducedMotion()
  if (!present && !policy.animate) return null
  const { tokens } = policy
  const transition = {
    type: 'tween' as const,
    duration: policy.animate && tokens ? (reduce ? tokens.reducedDuration : tokens.duration) : 0,
    ease: tokens?.ease
  }
  return (
    <m.aside
      {...props}
      // The media rule also overrides a WAAPI transform that was already running when the preference changed.
      className={cn(className, 'motion-reduce:transform-[translateX(0px)]!')}
      style={{ ...style, ...(!present && { pointerEvents: 'none' }) }}
      inert={!present || undefined}
      aria-hidden={!present || undefined}
      initial={policy.animate ? 'exit' : false}
      animate="enter"
      exit="exit"
      variants={{
        enter: { opacity: 1, transform: 'translateX(0px)', transition },
        exit: { opacity: 0, transform: reduce ? 'translateX(0px)' : 'translateX(8px)', transition }
      }}
    />
  )
}
