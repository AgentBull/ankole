import { Button, Dialog, DialogContent, DialogTitle } from '@ankole/uikit'
import { RiRestartLine, RiZoomInLine, RiZoomOutLine } from '@remixicon/react'
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent
} from 'react'
import { useTranslation } from 'react-i18next'
import { buildMermaidSrcDoc } from './mermaid/mermaid-frame'
import type { MermaidThemeMode } from './mermaid/mermaid-renderer'

const MIN_ZOOM = 0.5
const MAX_ZOOM = 4
const ZOOM_STEP = 0.5
const SETTLE_DELAY_MS = 120
const PREPARED_PAINT_FRAMES = 2
const RETIRING_HOLD_FRAMES = 6

export interface Point2D {
  x: number
  y: number
}

export interface PinchStartState {
  startDist: number
  startZoom: number
  startMidX: number
  startMidY: number
  panX: number
  panY: number
}

export interface BufferedScaleSlot {
  key: number
  scale: number
}

export interface ActiveBufferedSlot extends BufferedScaleSlot {
  role: 'prepared' | 'committed' | 'retiring'
  zIndex: number
}

export function clampZoom(next: number): number {
  return Math.round(Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, next)) * 100) / 100
}

export function computePinchTransform(
  start: PinchStartState,
  p1: Point2D,
  p2: Point2D
): { zoom: number; pan: Point2D } {
  const dist = Math.max(1, Math.hypot(p2.x - p1.x, p2.y - p1.y))
  const midX = (p1.x + p2.x) / 2
  const midY = (p1.y + p2.y) / 2
  return {
    zoom: clampZoom(start.startZoom * (dist / Math.max(1, start.startDist))),
    pan: {
      x: start.panX + (midX - start.startMidX),
      y: start.panY + (midY - start.startMidY)
    }
  }
}

export function orderBufferedSlots(
  committed: BufferedScaleSlot,
  prepared: BufferedScaleSlot | null,
  retiring: BufferedScaleSlot | null
): ActiveBufferedSlot[] {
  const byKey = new Map<number, ActiveBufferedSlot>()
  if (prepared) {
    byKey.set(prepared.key, { ...prepared, role: 'prepared', zIndex: 0 })
  }
  if (retiring) {
    byKey.set(retiring.key, { ...retiring, role: 'retiring', zIndex: 2 })
  }
  byKey.set(committed.key, { ...committed, role: 'committed', zIndex: 1 })
  return [...byKey.values()].sort((a, b) => a.key - b.key)
}

export function scheduleAnimationFrames(count: number, done: () => void): () => void {
  let cancelled = false
  let handle: number | ReturnType<typeof setTimeout> | null = null
  const useRaf = typeof requestAnimationFrame === 'function' && typeof cancelAnimationFrame === 'function'
  let remaining = count

  const step = () => {
    if (cancelled) return
    if (remaining <= 0) {
      done()
      return
    }
    remaining -= 1
    handle = useRaf ? requestAnimationFrame(step) : setTimeout(step, 16)
  }

  handle = useRaf ? requestAnimationFrame(step) : setTimeout(step, 16)
  return () => {
    cancelled = true
    if (handle !== null) {
      if (useRaf) cancelAnimationFrame(handle as number)
      else clearTimeout(handle as ReturnType<typeof setTimeout>)
    }
  }
}

export function ZoomableImage({ src, alt = '' }: { src: string; alt?: string }) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const trigger = useRef<HTMLButtonElement>(null)
  return (
    <>
      <button
        type="button"
        ref={trigger}
        className="pod-chat-image-trigger"
        aria-label={t('pod.chat_timeline.enlarge_image', { name: alt })}
        onClick={event => {
          event.preventDefault()
          event.stopPropagation()
          setOpen(true)
        }}>
        <img src={src} alt={alt} loading="lazy" referrerPolicy="no-referrer" />
      </button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="pod-chat-lightbox" closeLabel={t('common.close')} finalFocus={trigger}>
          <DialogTitle className="sr-only">{alt || t('pod.chat_timeline.image')}</DialogTitle>
          {open && <ImageZoomView src={src} alt={alt} />}
        </DialogContent>
      </Dialog>
    </>
  )
}

function useDoubleBufferedScale(targetZoom: number, interacting: boolean) {
  const seqRef = useRef(1)
  const [committed, setCommitted] = useState<BufferedScaleSlot>(() => ({ key: 1, scale: 1 }))
  const [prepared, setPrepared] = useState<BufferedScaleSlot | null>(null)
  const [retiring, setRetiring] = useState<BufferedScaleSlot | null>(null)

  const committedRef = useRef(committed)
  committedRef.current = committed
  const promotionCleanupRef = useRef<(() => void) | null>(null)
  const retireCleanupRef = useRef<(() => void) | null>(null)

  useEffect(
    () => () => {
      promotionCleanupRef.current?.()
      retireCleanupRef.current?.()
    },
    []
  )

  useEffect(() => {
    if (interacting || Math.abs(targetZoom - committed.scale) < 0.01) {
      promotionCleanupRef.current?.()
      promotionCleanupRef.current = null
      setPrepared(null)
      return
    }
    const timer = setTimeout(() => {
      promotionCleanupRef.current?.()
      promotionCleanupRef.current = null
      seqRef.current += 1
      setPrepared({ key: seqRef.current, scale: targetZoom })
    }, SETTLE_DELAY_MS)
    return () => clearTimeout(timer)
  }, [targetZoom, interacting, committed.scale])

  const onPreparedReady = useCallback((readySlot: BufferedScaleSlot) => {
    promotionCleanupRef.current?.()
    promotionCleanupRef.current = scheduleAnimationFrames(PREPARED_PAINT_FRAMES, () => {
      promotionCleanupRef.current = null
      const outgoing = committedRef.current
      if (outgoing.key === readySlot.key) return
      setRetiring(outgoing)
      setCommitted(readySlot)
      setPrepared(curr => (curr?.key === readySlot.key ? null : curr))
      retireCleanupRef.current?.()
      retireCleanupRef.current = scheduleAnimationFrames(RETIRING_HOLD_FRAMES, () => {
        retireCleanupRef.current = null
        setRetiring(curr => (curr?.key === outgoing.key ? null : curr))
      })
    })
  }, [])

  const slots = useMemo(() => orderBufferedSlots(committed, prepared, retiring), [committed, prepared, retiring])

  return { committed, slots, onPreparedReady }
}

function useZoomPanControls() {
  const [zoom, setZoom] = useState(1)
  const [pan, setPan] = useState<Point2D>({ x: 0, y: 0 })
  const [interacting, setInteracting] = useState(false)

  const viewportRef = useRef<HTMLDivElement>(null)
  const zoomRef = useRef(zoom)
  zoomRef.current = zoom
  const panRef = useRef(pan)
  panRef.current = pan

  const pointersRef = useRef(new Map<number, Point2D>())
  const dragRef = useRef<{ startX: number; startY: number; panX: number; panY: number } | null>(null)
  const pinchRef = useRef<PinchStartState | null>(null)

  const resetView = useCallback(() => {
    setZoom(1)
    setPan({ x: 0, y: 0 })
  }, [])

  useEffect(() => {
    const viewport = viewportRef.current
    if (!viewport) return
    const onWheel = (event: WheelEvent) => {
      event.preventDefault()
      const delta = event.deltaY < 0 ? 0.25 : -0.25
      setZoom(v => clampZoom(v + delta))
    }
    viewport.addEventListener('wheel', onWheel, { passive: false })
    return () => viewport.removeEventListener('wheel', onWheel)
  }, [])

  const onKeyDown = useCallback(
    (event: ReactKeyboardEvent<HTMLDivElement>) => {
      if (event.key === '+' || event.key === '=') setZoom(v => clampZoom(v + ZOOM_STEP))
      else if (event.key === '-') setZoom(v => clampZoom(v - ZOOM_STEP))
      else if (event.key === '0') resetView()
      else return
      event.preventDefault()
    },
    [resetView]
  )

  const onDoubleClick = useCallback(() => {
    if (zoomRef.current === 1) setZoom(2)
    else resetView()
  }, [resetView])

  const endPointer = useCallback((pointerId: number) => {
    pointersRef.current.delete(pointerId)
    if (pointersRef.current.size === 1) {
      const [remaining] = [...pointersRef.current.values()]
      if (remaining) {
        pinchRef.current = null
        dragRef.current = {
          startX: remaining.x,
          startY: remaining.y,
          panX: panRef.current.x,
          panY: panRef.current.y
        }
      }
      return
    }
    if (pointersRef.current.size === 0) {
      pinchRef.current = null
      dragRef.current = null
      setInteracting(false)
    }
  }, [])

  const onPointerDown = useCallback((event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.pointerType === 'mouse' && event.button !== 0) return
    pointersRef.current.set(event.pointerId, { x: event.clientX, y: event.clientY })
    try {
      event.currentTarget.setPointerCapture(event.pointerId)
    } catch {
      // Synthetic test events may omit pointer capture support.
    }
    event.currentTarget.focus()
    setInteracting(true)

    if (pointersRef.current.size === 1) {
      pinchRef.current = null
      dragRef.current = {
        startX: event.clientX,
        startY: event.clientY,
        panX: panRef.current.x,
        panY: panRef.current.y
      }
    } else if (pointersRef.current.size >= 2) {
      const [p1, p2] = [...pointersRef.current.values()]
      if (p1 && p2) {
        dragRef.current = null
        pinchRef.current = {
          startDist: Math.max(1, Math.hypot(p2.x - p1.x, p2.y - p1.y)),
          startZoom: zoomRef.current,
          startMidX: (p1.x + p2.x) / 2,
          startMidY: (p1.y + p2.y) / 2,
          panX: panRef.current.x,
          panY: panRef.current.y
        }
      }
    }
  }, [])

  const onPointerMove = useCallback((event: ReactPointerEvent<HTMLDivElement>) => {
    if (!pointersRef.current.has(event.pointerId)) return
    pointersRef.current.set(event.pointerId, { x: event.clientX, y: event.clientY })

    if (pointersRef.current.size >= 2 && pinchRef.current) {
      const [p1, p2] = [...pointersRef.current.values()]
      if (p1 && p2) {
        const next = computePinchTransform(pinchRef.current, p1, p2)
        setZoom(next.zoom)
        setPan(next.pan)
      }
      return
    }

    if (pointersRef.current.size === 1 && dragRef.current) {
      setPan({
        x: dragRef.current.panX + (event.clientX - dragRef.current.startX),
        y: dragRef.current.panY + (event.clientY - dragRef.current.startY)
      })
    }
  }, [])

  const onPointerUp = useCallback(
    (event: ReactPointerEvent<HTMLDivElement>) => endPointer(event.pointerId),
    [endPointer]
  )
  const onPointerCancel = useCallback(
    (event: ReactPointerEvent<HTMLDivElement>) => endPointer(event.pointerId),
    [endPointer]
  )
  const onLostPointerCapture = useCallback(
    (event: ReactPointerEvent<HTMLDivElement>) => endPointer(event.pointerId),
    [endPointer]
  )

  return {
    zoom,
    setZoom,
    pan,
    interacting,
    viewportRef,
    resetView,
    viewportProps: {
      onKeyDown,
      onDoubleClick,
      onPointerDown,
      onPointerMove,
      onPointerUp,
      onPointerCancel,
      onLostPointerCapture
    }
  }
}

export function ImageZoomView({ src, alt, onError }: { src: string; alt: string; onError?: () => void }) {
  const { t } = useTranslation()
  const { zoom, setZoom, pan, interacting, viewportRef, resetView, viewportProps } = useZoomPanControls()
  const { committed, slots, onPreparedReady } = useDoubleBufferedScale(zoom, interacting)
  const compositorScale = zoom / committed.scale

  return (
    <div className="pod-chat-image-view">
      <div className="pod-chat-lightbox-tools" role="toolbar" aria-label={t('pod.chat_timeline.image_zoom')}>
        <Button
          variant="ghost"
          size="icon-sm"
          disabled={zoom <= MIN_ZOOM}
          aria-label={t('pod.chat_timeline.zoom_out')}
          onClick={() => setZoom(v => clampZoom(v - ZOOM_STEP))}>
          <RiZoomOutLine aria-hidden />
        </Button>
        <span>{Math.round(zoom * 100)}%</span>
        <Button
          variant="ghost"
          size="icon-sm"
          disabled={zoom >= MAX_ZOOM}
          aria-label={t('pod.chat_timeline.zoom_in')}
          onClick={() => setZoom(v => clampZoom(v + ZOOM_STEP))}>
          <RiZoomInLine aria-hidden />
        </Button>
        {(zoom !== 1 || pan.x !== 0 || pan.y !== 0) && (
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label={t('pod.chat_timeline.reset_zoom', { defaultValue: 'Reset zoom' })}
            onClick={resetView}>
            <RiRestartLine aria-hidden />
          </Button>
        )}
      </div>
      <div
        ref={viewportRef}
        className="pod-chat-lightbox-image relative overflow-hidden select-none"
        tabIndex={0}
        role="region"
        aria-label={alt}
        style={{ cursor: interacting ? 'grabbing' : zoom > 1 ? 'grab' : undefined, touchAction: 'none' }}
        {...viewportProps}>
        <div
          className="relative flex items-center justify-center will-change-transform"
          style={{
            transform: `translate3d(${pan.x}px, ${pan.y}px, 0) scale(${compositorScale})`,
            transformOrigin: 'center center'
          }}>
          {slots.map(slot => {
            const isCommitted = slot.role === 'committed'
            const slotScaleRatio = committed.scale / slot.scale
            return (
              <img
                key={slot.key}
                src={src}
                alt={isCommitted ? alt : ''}
                aria-hidden={!isCommitted || undefined}
                draggable={false}
                referrerPolicy="no-referrer"
                data-buffer-role={slot.role}
                onError={isCommitted ? onError : undefined}
                onLoad={slot.role === 'prepared' ? () => onPreparedReady(slot) : undefined}
                className={isCommitted ? 'block' : 'pointer-events-none absolute top-0 left-0'}
                style={{
                  width: `${slot.scale * 100}%`,
                  maxWidth: 'none',
                  zIndex: slot.zIndex,
                  opacity: slot.role === 'prepared' ? 0.004 : 1,
                  transform: isCommitted ? undefined : `scale(${slotScaleRatio})`,
                  transformOrigin: 'top left'
                }}
              />
            )
          })}
        </div>
      </div>
    </div>
  )
}

export function MermaidSandboxZoomView({
  svg,
  width,
  height,
  theme,
  title
}: {
  svg: string
  width: number
  height: number
  theme: MermaidThemeMode
  title: string
}) {
  const { t } = useTranslation()
  const { zoom, setZoom, pan, interacting, viewportRef, resetView, viewportProps } = useZoomPanControls()
  const { committed, slots, onPreparedReady } = useDoubleBufferedScale(zoom, interacting)

  const compositorScale = zoom / committed.scale
  const committedWidth = Math.max(1, Math.round(width * committed.scale))
  const committedHeight = Math.max(1, Math.round(height * committed.scale))

  return (
    <div className="pod-chat-image-view" data-testid="mermaid-zoom-viewer">
      <div className="pod-chat-lightbox-tools" role="toolbar" aria-label={t('pod.chat_timeline.image_zoom')}>
        <Button
          variant="ghost"
          size="icon-sm"
          disabled={zoom <= MIN_ZOOM}
          aria-label={t('pod.chat_timeline.zoom_out')}
          onClick={() => setZoom(v => clampZoom(v - ZOOM_STEP))}>
          <RiZoomOutLine aria-hidden />
        </Button>
        <span data-testid="mermaid-zoom-percent">{Math.round(zoom * 100)}%</span>
        <Button
          variant="ghost"
          size="icon-sm"
          disabled={zoom >= MAX_ZOOM}
          aria-label={t('pod.chat_timeline.zoom_in')}
          onClick={() => setZoom(v => clampZoom(v + ZOOM_STEP))}>
          <RiZoomInLine aria-hidden />
        </Button>
        {(zoom !== 1 || pan.x !== 0 || pan.y !== 0) && (
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label={t('pod.chat_timeline.reset_zoom', { defaultValue: 'Reset zoom' })}
            onClick={resetView}>
            <RiRestartLine aria-hidden />
          </Button>
        )}
      </div>
      <div
        ref={viewportRef}
        className="pod-chat-lightbox-image relative flex min-h-[65vh] w-full items-center justify-center overflow-hidden select-none"
        tabIndex={0}
        role="region"
        aria-label={title}
        style={{ cursor: interacting ? 'grabbing' : 'grab', touchAction: 'none' }}
        {...viewportProps}>
        <div
          className="relative will-change-transform"
          style={{
            width: `${committedWidth}px`,
            height: `${committedHeight}px`,
            transform: `translate3d(${pan.x}px, ${pan.y}px, 0) scale(${compositorScale})`,
            transformOrigin: 'center center'
          }}>
          {slots.map(slot => {
            const isCommitted = slot.role === 'committed'
            const frameWidth = Math.max(1, Math.round(width * slot.scale))
            const frameHeight = Math.max(1, Math.round(height * slot.scale))
            const slotScaleRatio = committed.scale / slot.scale
            return (
              <iframe
                key={slot.key}
                title={isCommitted ? title : `${title} (${slot.role})`}
                sandbox=""
                referrerPolicy="no-referrer"
                aria-hidden={!isCommitted || undefined}
                tabIndex={isCommitted ? undefined : -1}
                data-buffer-role={slot.role}
                onLoad={slot.role === 'prepared' ? () => onPreparedReady(slot) : undefined}
                srcDoc={buildMermaidSrcDoc({
                  svg,
                  theme,
                  width,
                  height,
                  scale: slot.scale,
                  fitContainer: false
                })}
                className="pointer-events-none absolute top-0 left-0 border-0"
                style={{
                  width: `${frameWidth}px`,
                  height: `${frameHeight}px`,
                  zIndex: slot.zIndex,
                  opacity: 1,
                  transform: Math.abs(slotScaleRatio - 1) < 0.001 ? undefined : `scale(${slotScaleRatio})`,
                  transformOrigin: 'top left'
                }}
              />
            )
          })}
        </div>
      </div>
    </div>
  )
}
