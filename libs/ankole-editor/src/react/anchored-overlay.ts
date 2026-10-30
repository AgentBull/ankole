import { useEffect, useLayoutEffect, useRef, useState, type RefObject } from 'react'

export type AnchoredOverlayOptions = {
  /** Whether the overlay is mounted and should be placed. */
  open: boolean
  /** The overlay element, measured for width and height. */
  panelRef: RefObject<HTMLElement | null>
  /** The rectangle the overlay is anchored to, usually a button or a caret. */
  anchor: () => DOMRect | null
  /** Close the overlay when a pointer goes down outside it. Omit for overlays without outside dismissal. */
  onClose?: () => void
  /** Elements that belong to the trigger and must not count as outside clicks. */
  shouldIgnore?: (target: Element) => boolean
  /** Align the overlay's left edge with the anchor, or its right edge for `end`. */
  align?: 'start' | 'end'
  /** Gap between the anchor and the overlay. */
  sideOffset?: number
  /** An element whose size changes should re-place the overlay, such as the block it belongs to. */
  observe?: () => Element | null
  /** Re-place when these values change, for example the block position or option count. */
  dependencies?: readonly unknown[]
}

export type OverlayPosition = { left: number; top: number } | null

/**
 * Owns the shared behavior of an overlay anchored inside the editor: viewport-clamped placement,
 * flipping above the anchor when needed, scroll and resize tracking, size observation, and outside
 * dismissal. Components keep their own content, focus, and keyboard handling.
 */
export function useAnchoredOverlay(options: AnchoredOverlayOptions): OverlayPosition {
  const { open, panelRef, align = 'start', sideOffset = 4, dependencies = [] } = options
  const latest = useRef(options)
  latest.current = options
  const [position, setPosition] = useState<OverlayPosition>(null)

  useLayoutEffect(() => {
    if (!open) {
      setPosition(null)
      return
    }
    let frame = 0
    const place = () => {
      const panel = panelRef.current
      const rect = latest.current.anchor()
      if (!panel || !rect) {
        setPosition(null)
        return
      }
      const { width, height } = panel.getBoundingClientRect()
      const viewport = window.visualViewport
      const minX = (viewport?.offsetLeft ?? 0) + 8
      const maxX = minX + (viewport?.width ?? window.innerWidth) - 16
      const minY = (viewport?.offsetTop ?? 0) + 8
      const maxY = minY + (viewport?.height ?? window.innerHeight) - 16
      const below = rect.bottom + sideOffset
      const left = align === 'end' ? rect.right - width : rect.left
      setPosition({
        left: Math.max(minX, Math.min(left, maxX - width)),
        top: below + height <= maxY ? below : Math.max(minY, rect.top - height - sideOffset)
      })
    }
    const schedule = () => {
      cancelAnimationFrame(frame)
      frame = requestAnimationFrame(place)
    }
    place()
    window.addEventListener('scroll', schedule, true)
    window.addEventListener('resize', schedule)
    window.visualViewport?.addEventListener('resize', schedule)
    window.visualViewport?.addEventListener('scroll', schedule)
    let observer: ResizeObserver | undefined
    if (typeof ResizeObserver != 'undefined') {
      observer = new ResizeObserver(schedule)
      if (panelRef.current) observer.observe(panelRef.current)
      const observed = latest.current.observe?.()
      if (observed) observer.observe(observed)
    }
    return () => {
      cancelAnimationFrame(frame)
      window.removeEventListener('scroll', schedule, true)
      window.removeEventListener('resize', schedule)
      window.visualViewport?.removeEventListener('resize', schedule)
      window.visualViewport?.removeEventListener('scroll', schedule)
      observer?.disconnect()
    }
    // The caller owns the dimensions that affect placement; see `dependencies`.
  }, [open, panelRef, ...dependencies])

  useEffect(() => {
    if (!open || !latest.current.onClose) return
    const outside = (event: PointerEvent) => {
      const target = event.target as Element | null
      if (!target || panelRef.current?.contains(target) || latest.current.shouldIgnore?.(target)) return
      latest.current.onClose?.()
    }
    document.addEventListener('pointerdown', outside, true)
    return () => document.removeEventListener('pointerdown', outside, true)
  }, [open, panelRef])

  return position
}
