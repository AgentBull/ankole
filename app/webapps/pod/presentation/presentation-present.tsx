import { Button } from '@ankole/uikit'
import { RiArrowLeftSLine, RiArrowRightSLine, RiFullscreenExitLine } from '@remixicon/react'
import { t } from 'i18next'
import { useCallback, useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { PresentationRenderedSlide } from './presentation-engine'

export type PresentationPresentProps = {
  open: boolean
  slideCount: number
  initialSlideIndex: number
  slideSizePt: { width: number; height: number }
  renderVersion: number
  renderSlide(slideIndex: number, scale: number): Promise<PresentationRenderedSlide | undefined>
  onSlideChange?(slideIndex: number): void
  onClose(): void
}

/**
 * Paints straight RGBA8 slide pixels onto a 2D `<canvas>` without copying the transferred buffer.
 */
export function paintRenderedSlide(canvas: HTMLCanvasElement, rendered: PresentationRenderedSlide): void {
  if (
    rendered.width <= 0 ||
    rendered.height <= 0 ||
    rendered.rgba.byteLength !== rendered.width * rendered.height * 4
  ) {
    return
  }
  if (canvas.width !== rendered.width) canvas.width = rendered.width
  if (canvas.height !== rendered.height) canvas.height = rendered.height
  const context = canvas.getContext('2d')
  if (!context) return
  const pixels = new Uint8ClampedArray(
    rendered.rgba.buffer as ArrayBuffer,
    rendered.rgba.byteOffset,
    rendered.rgba.byteLength
  )
  context.putImageData(new ImageData(pixels, rendered.width, rendered.height), 0, 0)
}

/**
 * Full-screen slideshow overlay shared by collaborative Presentation Pages and read-only `.pptx`
 * attachment previews. Renders the active slide crisp at viewport × device-pixel scale.
 */
export function PresentationPresent({
  open,
  slideCount,
  initialSlideIndex,
  slideSizePt,
  renderVersion,
  renderSlide,
  onSlideChange,
  onClose
}: PresentationPresentProps) {
  const overlayRef = useRef<HTMLDivElement>(null)
  const stageRef = useRef<HTMLDivElement>(null)
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const enteredFullscreenRef = useRef(false)
  const closingRef = useRef(false)
  const [currentIndex, setCurrentIndex] = useState(() =>
    Math.min(Math.max(0, initialSlideIndex), Math.max(0, slideCount - 1))
  )
  const [stageSize, setStageSize] = useState<{ width: number; height: number }>({
    width: 1280,
    height: 720
  })

  useEffect(() => {
    if (!open) return
    closingRef.current = false
    enteredFullscreenRef.current = false
    setCurrentIndex(Math.min(Math.max(0, initialSlideIndex), Math.max(0, slideCount - 1)))
  }, [open, initialSlideIndex, slideCount])

  useEffect(() => {
    if (!open) return
    setCurrentIndex(prev => Math.min(prev, Math.max(0, slideCount - 1)))
  }, [open, slideCount])

  const exitPresent = useCallback(() => {
    if (closingRef.current) return
    closingRef.current = true
    if (typeof document !== 'undefined' && document.fullscreenElement) {
      void document.exitFullscreen?.().catch(() => undefined)
    }
    onClose()
  }, [onClose])

  const goToIndex = useCallback(
    (next: number) => {
      if (slideCount <= 0) return
      const clamped = Math.min(Math.max(0, next), slideCount - 1)
      setCurrentIndex(clamped)
      onSlideChange?.(clamped)
    },
    [slideCount, onSlideChange]
  )

  // Request browser Fullscreen when available and exit Present mode if the user leaves Fullscreen.
  useEffect(() => {
    if (!open) return
    const previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null
    const node = overlayRef.current
    node?.focus({ preventScroll: true })
    void node?.requestFullscreen?.().then(
      () => {
        if (document.fullscreenElement === node) {
          enteredFullscreenRef.current = true
        }
      },
      () => undefined
    )

    const handleFullscreenChange = () => {
      if (document.fullscreenElement === node) {
        enteredFullscreenRef.current = true
      } else if (enteredFullscreenRef.current && !document.fullscreenElement) {
        enteredFullscreenRef.current = false
        if (!closingRef.current) {
          closingRef.current = true
          onClose()
        }
      }
    }
    document.addEventListener('fullscreenchange', handleFullscreenChange)
    return () => {
      document.removeEventListener('fullscreenchange', handleFullscreenChange)
      if (document.fullscreenElement === node) {
        void document.exitFullscreen?.().catch(() => undefined)
      }
      previousFocus?.focus?.({ preventScroll: true })
    }
  }, [open, onClose])

  // Track available stage dimensions so slides stay sharp across window and fullscreen resizes.
  useEffect(() => {
    if (!open) return
    const stage = stageRef.current
    if (!stage) return
    const updateSize = () => {
      const rect = stage.getBoundingClientRect()
      if (rect.width > 0 && rect.height > 0) {
        setStageSize({ width: rect.width, height: rect.height })
      }
    }
    updateSize()
    const observer = new ResizeObserver(updateSize)
    observer.observe(stage)
    return () => observer.disconnect()
  }, [open])

  // Keyboard navigation across the slideshow regardless of which button inside the overlay has focus.
  useEffect(() => {
    if (!open) return
    const handleKeyDown = (event: KeyboardEvent) => {
      switch (event.key) {
        case 'Escape':
          event.preventDefault()
          event.stopPropagation()
          exitPresent()
          return
        case 'ArrowRight':
        case 'ArrowDown':
        case 'PageDown':
        case ' ':
          event.preventDefault()
          event.stopPropagation()
          goToIndex(currentIndex + 1)
          return
        case 'Enter':
          if (event.target instanceof HTMLButtonElement) return
          event.preventDefault()
          event.stopPropagation()
          goToIndex(currentIndex + 1)
          return
        case 'ArrowLeft':
        case 'ArrowUp':
        case 'PageUp':
        case 'Backspace':
          event.preventDefault()
          event.stopPropagation()
          goToIndex(currentIndex - 1)
          return
        case 'Home':
          event.preventDefault()
          event.stopPropagation()
          goToIndex(0)
          return
        case 'End':
          event.preventDefault()
          event.stopPropagation()
          goToIndex(slideCount - 1)
          return
      }
    }
    window.addEventListener('keydown', handleKeyDown, true)
    return () => window.removeEventListener('keydown', handleKeyDown, true)
  }, [open, currentIndex, slideCount, exitPresent, goToIndex])

  const safePtWidth = Math.max(1, slideSizePt.width)
  const safePtHeight = Math.max(1, slideSizePt.height)
  const availableWidth = Math.max(120, stageSize.width - 24)
  const availableHeight = Math.max(90, stageSize.height - 24)
  const fitScale = Math.max(0.1, Math.min(availableWidth / safePtWidth, availableHeight / safePtHeight))
  const cssWidth = Math.max(1, Math.round(safePtWidth * fitScale))
  const cssHeight = Math.max(1, Math.round(safePtHeight * fitScale))
  const dpr = typeof window !== 'undefined' ? window.devicePixelRatio || 1 : 1
  const renderScale = Math.min(4, Math.max(0.25, Number((fitScale * dpr).toFixed(3))))

  useEffect(() => {
    if (!open || slideCount <= 0) return
    let cancelled = false
    void renderSlide(currentIndex, renderScale).then(rendered => {
      if (cancelled || !rendered || !canvasRef.current) return
      paintRenderedSlide(canvasRef.current, rendered)
    })
    return () => {
      cancelled = true
    }
  }, [open, slideCount, currentIndex, renderScale, renderVersion, renderSlide])

  if (!open || slideCount <= 0 || typeof document === 'undefined') {
    return null
  }

  const clampedIndex = Math.min(Math.max(0, currentIndex), slideCount - 1)

  return createPortal(
    <div
      ref={overlayRef}
      role="dialog"
      aria-modal="true"
      aria-label={t('pod.presentation.present')}
      tabIndex={-1}
      className="fixed inset-0 z-50 flex flex-col bg-black text-white outline-none select-none">
      <div
        ref={stageRef}
        className="flex min-h-0 flex-1 cursor-pointer items-center justify-center overflow-hidden p-3"
        onClick={() => {
          if (clampedIndex < slideCount - 1) {
            goToIndex(clampedIndex + 1)
          }
        }}>
        <canvas
          ref={canvasRef}
          role="img"
          aria-label={t('pod.presentation.slide_canvas', { index: clampedIndex + 1 })}
          style={{ width: `${cssWidth}px`, height: `${cssHeight}px` }}
          className="bg-white shadow-2xl"
        />
      </div>

      <div
        className="flex items-center justify-center gap-2 border-t border-white/15 bg-black/90 px-4 py-2"
        onClick={event => event.stopPropagation()}>
        <Button
          size="icon-sm"
          variant="ghost"
          className="text-white hover:bg-white/15 hover:text-white"
          aria-label={t('pod.presentation.previous_slide')}
          title={t('pod.presentation.previous_slide')}
          disabled={clampedIndex <= 0}
          onClick={() => goToIndex(clampedIndex - 1)}>
          <RiArrowLeftSLine />
        </Button>

        <span
          role="status"
          aria-live="polite"
          className="min-w-28 text-center text-xs font-medium tabular-nums text-white/90">
          {t('pod.presentation.slide_of_total', {
            index: clampedIndex + 1,
            count: slideCount
          })}
        </span>

        <Button
          size="icon-sm"
          variant="ghost"
          className="text-white hover:bg-white/15 hover:text-white"
          aria-label={t('pod.presentation.next_slide')}
          title={t('pod.presentation.next_slide')}
          disabled={clampedIndex >= slideCount - 1}
          onClick={() => goToIndex(clampedIndex + 1)}>
          <RiArrowRightSLine />
        </Button>

        <div className="ml-4">
          <Button
            size="sm"
            variant="outline"
            className="border-white/25 bg-white/10 text-white hover:bg-white/20 hover:text-white"
            aria-label={t('pod.presentation.exit_present')}
            title={t('pod.presentation.exit_present')}
            onClick={exitPresent}>
            <RiFullscreenExitLine />
            <span>{t('pod.presentation.exit_present')}</span>
          </Button>
        </div>
      </div>
    </div>,
    document.body
  )
}
