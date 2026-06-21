'use client'

import { cn } from '@/uikit/lib/utils'
import type { MotionProps } from 'motion/react'
import { motion } from 'motion/react'
import type { CSSProperties, ElementType, JSX } from 'react'
import { memo, useMemo } from 'react'

type MotionHTMLProps = MotionProps & Record<string, unknown>

// `motion.create(tag)` builds a brand-new component type each call. Doing that during render would
// remount the element on every pass (losing the animation) and leak component identities, so the
// generated motion component is memoised per tag at module scope and reused.
const motionComponentCache = new Map<keyof JSX.IntrinsicElements, React.ComponentType<MotionHTMLProps>>()

/** Returns the motion-wrapped component for an intrinsic tag, creating it once and caching it. */
const getMotionComponent = (element: keyof JSX.IntrinsicElements) => {
  let component = motionComponentCache.get(element)
  if (!component) {
    component = motion.create(element)
    motionComponentCache.set(element, component)
  }
  return component
}

export interface TextShimmerProps {
  children: string
  /** Tag (or component) to render as; defaults to `p`. */
  as?: ElementType
  className?: string
  /** Seconds for one sweep of the highlight across the text. */
  duration?: number
  /** Per-character multiplier for the bright band's width (see `dynamicSpread`). */
  spread?: number
}

const ShimmerComponent = ({ children, as: Component = 'p', className, duration = 2, spread = 2 }: TextShimmerProps) => {
  const MotionComponent = getMotionComponent(Component as keyof JSX.IntrinsicElements)

  // The shimmer is a moving gradient highlight; its bright band must stay the same visual width no
  // matter how long the text is. Scaling the spread by character count keeps the highlight from
  // looking too narrow on long strings and too wide on short ones.
  const dynamicSpread = useMemo(() => (children?.length ?? 0) * spread, [children, spread])

  return (
    <MotionComponent
      animate={{ backgroundPosition: '0% center' }}
      className={cn(
        'relative inline-block bg-[length:250%_100%,auto] bg-clip-text text-transparent',
        '[--bg:linear-gradient(90deg,#0000_calc(50%-var(--spread)),var(--color-background),#0000_calc(50%+var(--spread)))] [background-repeat:no-repeat,padding-box]',
        className
      )}
      initial={{ backgroundPosition: '100% center' }}
      style={
        {
          '--spread': `${dynamicSpread}px`,
          backgroundImage: 'var(--bg), linear-gradient(var(--color-muted-foreground), var(--color-muted-foreground))'
        } as CSSProperties
      }
      transition={{
        duration,
        ease: 'linear',
        repeat: Number.POSITIVE_INFINITY
      }}>
      {children}
    </MotionComponent>
  )
}

/**
 * Animated "shimmering text" used as a lightweight loading/streaming indicator — e.g. a plan title or
 * the "Thinking..." label while the agent is still producing tokens. Renders the text with a gradient
 * highlight that sweeps across it on an infinite loop. Memoised because it usually re-renders on every
 * streaming tick from its parent while its own props rarely change.
 */
export const Shimmer = memo(ShimmerComponent)
