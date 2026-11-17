'use client'

import { mergeProps } from '@base-ui/react/merge-props'
import { useRender } from '@base-ui/react/use-render'
import { useCallback, useEffect, useRef, type ComponentProps, type Ref } from 'react'

import { cn } from '../lib/utils'

export type ScrollFadeAxis = 'x' | 'y'

export type ScrollFadeEdges = {
  moreStart: boolean
  moreEnd: boolean
}

export function supportsScrollTimeline(): boolean {
  return (
    typeof CSS !== 'undefined' && typeof CSS.supports === 'function' && CSS.supports('animation-timeline', 'scroll()')
  )
}

/**
 * Computes whether a scrollport has hidden content beyond its start or end edge.
 * Uses `Math.abs(scrollLeft)` so both LTR (`0 .. +max`) and RTL (`0 .. -max`) inline axes match.
 */
export function computeScrollFadeEdges(el: HTMLElement, axis: ScrollFadeAxis): ScrollFadeEdges {
  if (axis === 'x') {
    const maxScroll = el.scrollWidth - el.clientWidth
    const offset = Math.abs(el.scrollLeft)
    return {
      moreStart: maxScroll > 1 && offset > 1,
      moreEnd: maxScroll > 1 && offset < maxScroll - 1
    }
  }
  const maxScroll = el.scrollHeight - el.clientHeight
  return {
    moreStart: maxScroll > 1 && el.scrollTop > 1,
    moreEnd: maxScroll > 1 && el.scrollTop < maxScroll - 1
  }
}

export function applyScrollFadeAttributes(el: HTMLElement, edges: ScrollFadeEdges) {
  el.toggleAttribute('data-scroll-more-start', edges.moreStart)
  el.toggleAttribute('data-scroll-more-end', edges.moreEnd)
}

function assignRef<T>(ref: Ref<T> | undefined, value: T | null) {
  if (!ref) return
  if (typeof ref === 'function') ref(value)
  else (ref as { current: T | null }).current = value
}

/**
 * Synchronizes `data-scroll-more-start` and `data-scroll-more-end` on browsers without CSS
 * `animation-timeline: scroll()` (such as Safari 18). On engines with scroll-driven animations,
 * CSS drives the mask directly on the compositor with zero script work.
 */
export function useScrollFadeRef<T extends HTMLElement = HTMLDivElement>(
  axis: ScrollFadeAxis,
  forwardedRef?: Ref<T>,
  enabled = true
): (node: T | null) => void {
  const elementRef = useRef<T | null>(null)
  const cleanupRef = useRef<(() => void) | null>(null)

  useEffect(
    () => () => {
      cleanupRef.current?.()
      cleanupRef.current = null
    },
    []
  )

  return useCallback(
    (node: T | null) => {
      cleanupRef.current?.()
      cleanupRef.current = null
      elementRef.current = node
      assignRef(forwardedRef, node)

      if (!node || !enabled) {
        if (node) {
          node.removeAttribute('data-scroll-more-start')
          node.removeAttribute('data-scroll-more-end')
        }
        return
      }
      if (supportsScrollTimeline()) return

      let frame = 0
      const sync = () => {
        applyScrollFadeAttributes(node, computeScrollFadeEdges(node, axis))
      }
      const schedule = () => {
        cancelAnimationFrame(frame)
        frame = requestAnimationFrame(sync)
      }

      sync()
      node.addEventListener('scroll', schedule, { passive: true })
      const resizeObserver = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(schedule) : undefined
      resizeObserver?.observe(node)
      for (const child of node.children) resizeObserver?.observe(child)

      const mutationObserver =
        typeof MutationObserver !== 'undefined'
          ? new MutationObserver(() => {
              resizeObserver?.disconnect()
              resizeObserver?.observe(node)
              for (const child of node.children) resizeObserver?.observe(child)
              schedule()
            })
          : undefined
      mutationObserver?.observe(node, { childList: true, subtree: axis === 'y' })

      cleanupRef.current = () => {
        cancelAnimationFrame(frame)
        node.removeAttribute('data-scroll-more-start')
        node.removeAttribute('data-scroll-more-end')
        node.removeEventListener('scroll', schedule)
        resizeObserver?.disconnect()
        mutationObserver?.disconnect()
      }
    },
    [axis, enabled, forwardedRef]
  )
}

type ScrollFadeProps = useRender.ComponentProps<'div'> &
  ComponentProps<'div'> & {
    axis?: ScrollFadeAxis
    /** Reserves cross-axis padding negated by negative margin so hover shadows and focus rings never clip. */
    bleed?: boolean
  }

/**
 * Scrollable container whose edges fade out only while more content lies beyond that edge, with
 * optional cross-axis bleed room so card hover shadows and focus outlines are not clipped.
 */
function ScrollFade({ axis = 'x', bleed = axis === 'x', className, render, ref, ...props }: ScrollFadeProps) {
  const mergedRef = useScrollFadeRef<HTMLDivElement>(axis, ref)
  return useRender({
    defaultTagName: 'div',
    ref: mergedRef,
    props: mergeProps<'div'>(
      {
        className: cn(
          axis === 'x' ? 'overflow-x-auto scroll-fade-x' : 'overflow-y-auto scroll-fade-y',
          bleed && (axis === 'x' ? 'scroll-bleed-y' : 'scroll-bleed-x'),
          className
        )
      },
      props
    ),
    render,
    state: {
      slot: 'scroll-fade',
      axis
    }
  })
}

export { ScrollFade, type ScrollFadeProps }
