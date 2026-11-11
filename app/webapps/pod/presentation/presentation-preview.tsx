import { Button, cn, Spinner, Toggle, toast, useIsMobile } from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import {
  ChevronLeftRegular,
  ChevronRightRegular,
  CopyRegular,
  DocumentPdfRegular,
  PanelLeftRegular,
  SearchRegular,
  SlidePlayRegular,
  ZoomInRegular,
  ZoomOutRegular
} from '@ankole/uikit/icons'
import { t } from 'i18next'
import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from 'react'
import { downloadBlob, readPrefix } from '../../common/browser-files'
import { createClientConfig } from '../../common/internal-api-client'
import { requestErrorMessage } from '../../common/request-errors'
import { contentError } from '../content-errors'
import { ContentError, ContentSkeleton } from '../content-primitives'
import { inertOfficeChannel, type OfficeSource } from '../office/office-collaboration'
import { useOfficeFonts } from '../office/office-fonts'
import { findOfficeSearchMatch } from '../search-targets'
import {
  createPresentationEngine,
  type PresentationEngine,
  type PresentationFindMatch,
  type PresentationRenderedSlide,
  type PresentationSlideInfo
} from './presentation-engine'
import { paintRenderedSlide, PresentationPresent } from './presentation-present'
import {
  PRESENTATION_TEXT_NAVIGATION_KEYS,
  PresentationTextHighlight,
  useReadOnlyPresentationPointer
} from './presentation-selection'
import { createPresentationSession, PresentationFindBar, type PresentationSession } from './presentation-toolbar'

const transport = createClientConfig({}).fetch!
const MAX_PREVIEW_BYTES = 25 * 1024 * 1024
const ZOOM_STEPS = [0.5, 0.75, 1, 1.25, 1.5, 2] as const
const isMac = typeof navigator !== 'undefined' && /Mac|iPhone|iPad/.test(navigator.platform)

async function loadPreviewPresentation(url: string, local: boolean, signal: AbortSignal): Promise<OfficeSource> {
  const response = await (local ? fetch : transport)(url, {
    credentials: 'same-origin',
    signal
  })
  if (!response.ok || !response.body) {
    await response.body?.cancel().catch(() => undefined)
    throw new Error(`HTTP ${response.status}`)
  }
  const result = await readPrefix(response, MAX_PREVIEW_BYTES, signal)
  if (result.truncated) {
    return { kind: 'too_large' }
  }
  const buffer = result.bytes.buffer.slice(
    result.bytes.byteOffset,
    result.bytes.byteOffset + result.bytes.byteLength
  ) as ArrayBuffer
  return {
    kind: 'loaded',
    format: 'presentation',
    revision: 0,
    ops: [],
    bytes: buffer,
    metadata: null
  }
}

function pdfFilenameFromUrl(url: string): string {
  try {
    const parsed = new URL(url, window.location.origin)
    const lastSegment = decodeURIComponent(parsed.pathname.split('/').filter(Boolean).at(-1) ?? '')
    const stripped = lastSegment.replace(/\.pptx$/i, '').replace(/[\\/]+/g, '-')
    if (stripped) return `${stripped}.pdf`
  } catch {
    // Fall back to localized default filename.
  }
  return `${t('pod.presentation.presentation')}.pdf`
}

function PreviewThumbnailItem({
  slide,
  isActive,
  slideSizePt,
  fontEpoch,
  compact,
  renderSlide,
  onSelect
}: {
  slide: PresentationSlideInfo
  isActive: boolean
  slideSizePt: { width: number; height: number }
  fontEpoch: number
  compact: boolean
  renderSlide(slideIndex: number, scale: number): Promise<PresentationRenderedSlide | undefined>
  onSelect(slideIndex: number): void
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const thumbWidth = compact ? 100 : 128
  const safePtW = Math.max(1, slideSizePt.width)
  const safePtH = Math.max(1, slideSizePt.height)
  const thumbHeight = Math.max(44, Math.round((thumbWidth * safePtH) / safePtW))
  const dpr = typeof window !== 'undefined' ? window.devicePixelRatio || 1 : 1
  const scale = Math.min(1.5, Math.max(0.12, Number(((thumbWidth / safePtW) * Math.min(2, dpr)).toFixed(3))))

  useEffect(() => {
    let cancelled = false
    void renderSlide(slide.index, scale).then(rendered => {
      if (cancelled || !rendered || !canvasRef.current) return
      paintRenderedSlide(canvasRef.current, rendered)
    })
    return () => {
      cancelled = true
    }
  }, [slide.index, scale, fontEpoch, renderSlide])

  return (
    <li className="shrink-0">
      <button
        type="button"
        aria-label={t('pod.presentation.slide_number', {
          index: slide.index + 1
        })}
        aria-current={isActive ? 'step' : undefined}
        onClick={() => onSelect(slide.index)}
        className={cn(
          'flex w-full items-start gap-1.5 rounded-control p-1.5 text-left transition-colors focus-visible:outline-offset-1',
          isActive ? 'bg-accent ring-2 ring-primary' : 'hover:bg-accent/60'
        )}>
        <span className="w-5 shrink-0 pt-0.5 text-right font-mono text-xs tabular-nums text-fg-secondary">
          {slide.index + 1}
        </span>
        <div
          style={{ width: `${thumbWidth}px`, height: `${thumbHeight}px` }}
          className="overflow-hidden rounded-xs border border-border bg-white shadow-2xs">
          <canvas ref={canvasRef} aria-hidden="true" className="block size-full" />
        </div>
      </button>
    </li>
  )
}

/**
 * Read-only `.pptx` attachment preview backed by `ankole_presentation_wasm` in a dedicated Web
 * Worker so chat attachment previews match collaborative Presentation Pages byte-for-byte.
 */
export default function PresentationPreview({
  url,
  local = false,
  initialSlide,
  initialPage,
  initialFind
}: {
  url: string
  local?: boolean
  initialSlide?: number
  initialPage?: number
  initialFind?: string
}) {
  const [session, setSession] = useState<{
    model: PresentationSession
    generation: number
  }>()
  const generation = useRef(0)

  useEffect(() => {
    let activeController: AbortController | undefined
    const next = createPresentationSession({
      canEdit: false,
      selfUID: () => undefined,
      connect: async () => inertOfficeChannel(),
      load: () => {
        activeController?.abort()
        activeController = new AbortController()
        return loadPreviewPresentation(url, local, activeController.signal)
      },
      createEngine: createPresentationEngine,
      notify: () => {}
    })
    setSession({ model: next, generation: ++generation.current })
    void next.start()
    return () => {
      activeController?.abort()
      next[Symbol.dispose]()
    }
  }, [url, local])

  if (!session) {
    return <ContentSkeleton variant="page" label={t('pod.presentation.preview_loading')} immediate />
  }

  return (
    <PresentationPreviewWorkspace
      key={session.generation}
      model={session.model}
      url={url}
      initialSlide={initialSlide ?? initialPage}
      initialFind={initialFind}
    />
  )
}

function PresentationPreviewWorkspace({
  model,
  url,
  initialSlide,
  initialFind
}: {
  model: PresentationSession
  url: string
  initialSlide?: number
  initialFind?: string
}) {
  useSignals()
  const isMobile = useIsMobile()

  const workspaceRef = useRef<HTMLDivElement>(null)
  const stageRef = useRef<HTMLDivElement>(null)
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const appliedJump = useRef<string | undefined>(undefined)
  const activeFind = useRef<string | undefined>(undefined)

  const [railOpen, setRailOpen] = useState(true)
  const [zoomMode, setZoomMode] = useState<'fit' | number>('fit')
  const [stageSize, setStageSize] = useState<{ width: number; height: number }>({
    width: 800,
    height: 450
  })
  const [exportingPdf, setExportingPdf] = useState(false)
  const [presentOpen, setPresentOpen] = useState(false)

  const [findOpen, setFindOpen] = useState(false)
  const [findQuery, setFindQuery] = useState('')
  const [findMatchCase, setFindMatchCase] = useState(false)
  const [findMatches, setFindMatches] = useState<PresentationFindMatch[]>([])
  const [activeMatchIndex, setActiveMatchIndex] = useState(0)

  const status = model.status.value
  const snapshot = model.snapshot.value
  const requestedFonts = useMemo(
    () => [...(snapshot?.substitutedFonts.map(entry => entry.requested) ?? []), ...(snapshot?.missingGlyphFonts ?? [])],
    [snapshot?.substitutedFonts, snapshot?.missingGlyphFonts]
  )
  const fontEpoch = useOfficeFonts(requestedFonts, model)
  const version = model.version.value

  const slides = snapshot?.slides ?? []
  const selection = snapshot?.selection
  const activeSlideIndex = Math.min(Math.max(0, selection?.slide_index ?? 0), Math.max(0, slides.length - 1))
  const activeSlide = slides[activeSlideIndex]
  const slideSizePt = snapshot?.slideSizePt ?? { width: 960, height: 540 }
  const selectedShapeBoxes = snapshot?.selectedShapeBoxes ?? []
  const viewPointer = useReadOnlyPresentationPointer(model, slideSizePt, () =>
    workspaceRef.current?.focus({ preventScroll: true })
  )
  const hasSelection = (selection?.shapes.length ?? 0) > 0 || Boolean(selection?.text_sel)

  const goToSlide = useCallback(
    async (nextIndex: number) => {
      const list = model.snapshot.peek()?.slides ?? []
      if (list.length === 0) return
      const clamped = Math.min(Math.max(0, nextIndex), list.length - 1)
      await model.updateSelection(async eng => ({
        snapshot: await (eng as PresentationEngine).setActiveSlide(clamped)
      }))
    },
    [model]
  )

  useEffect(() => {
    if (status !== 'read_only' || slides.length === 0) return
    const key = `${initialSlide ?? ''}\0${initialFind ?? ''}`
    if ((initialSlide === undefined && !initialFind) || appliedJump.current === key) return
    const target =
      initialSlide === undefined ? undefined : Math.min(Math.max(0, Math.trunc(initialSlide) - 1), slides.length - 1)
    let cancelled = false
    void (async () => {
      const result = initialFind
        ? await model.read(engine =>
            findOfficeSearchMatch(
              initialFind,
              target,
              needle => (engine as PresentationEngine).find(needle, false),
              match => match.slide_index
            )
          )
        : undefined
      if (cancelled) return
      appliedJump.current = key
      if (result) {
        activeFind.current = `${result.needle}\0false`
        setFindQuery(result.needle)
        setFindMatchCase(false)
        setFindMatches(result.matches)
        setActiveMatchIndex(result.index)
        setFindOpen(true)
        await goToSlide(result.matches[result.index]!.slide_index)
      } else if (target !== undefined) {
        await goToSlide(target)
      }
    })().catch(() => undefined)
    return () => {
      cancelled = true
    }
  }, [status, slides.length, initialSlide, initialFind, model, goToSlide])

  // Measure the preview stage viewport for fit zoom.
  useEffect(() => {
    const stage = stageRef.current
    if (!stage) return
    const update = () => {
      const rect = stage.getBoundingClientRect()
      if (rect.width > 0 && rect.height > 0) {
        setStageSize({ width: rect.width, height: rect.height })
      }
    }
    update()
    const observer = new ResizeObserver(update)
    observer.observe(stage)
    return () => observer.disconnect()
  }, [status, railOpen, findOpen, isMobile, activeSlide?.notes])

  const safePtW = Math.max(1, slideSizePt.width)
  const safePtH = Math.max(1, slideSizePt.height)
  const fitZoom = useMemo(() => {
    const padX = Math.max(80, stageSize.width - 28)
    const padY = Math.max(60, stageSize.height - 28)
    return Math.min(2, Math.max(0.2, Math.min(padX / safePtW, padY / safePtH)))
  }, [stageSize.width, stageSize.height, safePtW, safePtH])

  const effectiveZoom = zoomMode === 'fit' ? fitZoom : zoomMode
  const cssWidth = Math.max(1, Math.round(safePtW * effectiveZoom))
  const cssHeight = Math.max(1, Math.round(safePtH * effectiveZoom))
  const dpr = typeof window !== 'undefined' ? window.devicePixelRatio || 1 : 1
  const mainRenderScale = Math.min(4, Math.max(0.25, Number((effectiveZoom * dpr).toFixed(3))))

  const renderSlide = useCallback(
    (slideIndex: number, scale: number) =>
      model.read(eng => (eng as PresentationEngine).renderSlideRgba(slideIndex, scale)),
    [model]
  )

  useEffect(() => {
    if (!slides.length) return
    let cancelled = false
    void renderSlide(activeSlideIndex, mainRenderScale).then(rendered => {
      if (cancelled || !rendered || !canvasRef.current) return
      paintRenderedSlide(canvasRef.current, rendered)
    })
    return () => {
      cancelled = true
    }
  }, [slides.length, activeSlideIndex, mainRenderScale, version, fontEpoch, renderSlide])

  useEffect(() => {
    if (!findOpen) return
    const trimmed = findQuery.trim()
    if (!trimmed) {
      activeFind.current = undefined
      setFindMatches([])
      setActiveMatchIndex(0)
      return
    }
    const key = `${trimmed}\0${findMatchCase}`
    if (activeFind.current === key) return
    let cancelled = false
    void model
      .read(eng => (eng as PresentationEngine).find(trimmed, findMatchCase))
      .then(results => {
        if (cancelled) return
        activeFind.current = key
        const items = results ?? []
        setFindMatches(items)
        setActiveMatchIndex(0)
        if (items[0]) {
          void goToSlide(items[0].slide_index)
        }
      })
    return () => {
      cancelled = true
    }
  }, [findOpen, findQuery, findMatchCase, model, goToSlide])

  const stepFindMatch = (delta: 1 | -1) => {
    if (findMatches.length === 0) return
    const nextIdx = (activeMatchIndex + delta + findMatches.length) % findMatches.length
    setActiveMatchIndex(nextIdx)
    const match = findMatches[nextIdx]
    if (match) {
      void goToSlide(match.slide_index)
    }
  }

  const handleCopy = useCallback(async () => {
    const text = await model.read(eng => (eng as PresentationEngine).selectedText())
    if (!text) return
    try {
      await navigator.clipboard.writeText(text)
    } catch {
      toast.error(t('pod.office.copy_failed'))
    }
  }, [model])

  const handleDownloadPdf = useCallback(async () => {
    if (exportingPdf) return
    setExportingPdf(true)
    try {
      const pdfBytes = await model.read(eng => (eng as PresentationEngine).exportPdf())
      if (pdfBytes && pdfBytes.byteLength > 0) {
        downloadBlob(new Blob([pdfBytes.slice()], { type: 'application/pdf' }), pdfFilenameFromUrl(url))
      }
    } catch (failure) {
      toast.error(requestErrorMessage(contentError(failure)))
    } finally {
      setExportingPdf(false)
    }
  }, [exportingPdf, model, url])

  const handleWorkspaceKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    if (event.target instanceof HTMLInputElement) return
    const mod = isMac ? event.metaKey : event.ctrlKey
    const lower = event.key.toLowerCase()
    if (mod && !event.altKey) {
      if (lower === 'f') {
        event.preventDefault()
        setFindOpen(true)
        return
      }
      if (lower === 'c') {
        if (window.getSelection()?.toString()) return
        event.preventDefault()
        void handleCopy()
        return
      }
    }
    if (!mod && !event.altKey) {
      if (selection?.text_sel && (PRESENTATION_TEXT_NAVIGATION_KEYS.has(event.key) || event.key === 'Escape')) {
        event.preventDefault()
        void model.updateSelection(async engine => ({
          snapshot: await (engine as PresentationEngine).keyEvent(event.key, { shift: event.shiftKey })
        }))
      } else if (event.key === 'ArrowRight' || event.key === 'ArrowDown' || event.key === 'PageDown') {
        event.preventDefault()
        void goToSlide(activeSlideIndex + 1)
      } else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp' || event.key === 'PageUp') {
        event.preventDefault()
        void goToSlide(activeSlideIndex - 1)
      } else if (event.key === 'Home') {
        event.preventDefault()
        void goToSlide(0)
      } else if (event.key === 'End') {
        event.preventDefault()
        void goToSlide(slides.length - 1)
      }
    }
  }

  const handleZoomStep = (direction: 1 | -1) => {
    const current = effectiveZoom
    if (direction > 0) {
      const next = ZOOM_STEPS.find(step => step > current + 0.02) ?? Math.min(3, Number((current + 0.25).toFixed(2)))
      setZoomMode(next)
    } else {
      const prev =
        [...ZOOM_STEPS].reverse().find(step => step < current - 0.02) ??
        Math.max(0.25, Number((current - 0.25).toFixed(2)))
      setZoomMode(prev)
    }
  }

  if (status === 'too_large') {
    return (
      <p className="rounded-control border border-dashed border-border px-6 py-10 text-center text-sm text-fg-secondary">
        {t('pod.office.too_large')}
      </p>
    )
  }
  if (status === 'error') {
    return <ContentError error={model.error.value} retry={model.retry} />
  }
  if (status === 'loading' && slides.length === 0) {
    return <ContentSkeleton variant="page" label={t('pod.presentation.preview_loading')} immediate />
  }

  const speakerNotes = (selection?.notes ?? activeSlide?.notes ?? '').trim()

  return (
    <div className="space-y-3">
      <div
        ref={workspaceRef}
        data-office-workspace=""
        tabIndex={0}
        aria-label={t('pod.presentation.presentation')}
        aria-busy={status === 'loading'}
        onKeyDown={handleWorkspaceKeyDown}
        className="flex h-[min(68vh,720px)] min-h-[360px] flex-col overflow-hidden rounded-control border border-border bg-background outline-none">
        <div className="flex min-h-10 flex-wrap items-center gap-1 border-b border-border bg-background px-2 py-1">
          <Toggle
            size="sm"
            aria-label={t('pod.presentation.toggle_slides_rail')}
            title={t('pod.presentation.toggle_slides_rail')}
            pressed={railOpen}
            onPressedChange={() => setRailOpen(prev => !prev)}>
            <PanelLeftRegular />
          </Toggle>

          <Button
            size="icon-sm"
            variant="ghost"
            aria-label={t('pod.presentation.previous_slide')}
            title={t('pod.presentation.previous_slide')}
            disabled={activeSlideIndex <= 0}
            onClick={() => void goToSlide(activeSlideIndex - 1)}>
            <ChevronLeftRegular />
          </Button>

          <span role="status" className="px-1 text-xs font-medium tabular-nums text-fg-secondary">
            {slides.length > 0
              ? t('pod.presentation.slide_of_total', {
                  index: activeSlideIndex + 1,
                  count: slides.length
                })
              : ''}
          </span>

          <Button
            size="icon-sm"
            variant="ghost"
            aria-label={t('pod.presentation.next_slide')}
            title={t('pod.presentation.next_slide')}
            disabled={activeSlideIndex >= slides.length - 1}
            onClick={() => void goToSlide(activeSlideIndex + 1)}>
            <ChevronRightRegular />
          </Button>

          <div className="ml-auto flex flex-wrap items-center gap-0.5">
            <Button
              size="icon-sm"
              variant="ghost"
              aria-label={t('pod.office.zoom_out')}
              title={t('pod.office.zoom_out')}
              onClick={() => handleZoomStep(-1)}>
              <ZoomOutRegular />
            </Button>
            <Button
              size="xs"
              variant="ghost"
              aria-label={zoomMode === 'fit' ? t('pod.office.fit_width') : t('pod.office.zoom_reset')}
              title={zoomMode === 'fit' ? t('pod.office.fit_width') : t('pod.office.zoom_reset')}
              className="px-1.5 font-mono text-xs tabular-nums"
              onClick={() => setZoomMode('fit')}>
              {zoomMode === 'fit' ? t('pod.office.fit_width') : `${Math.round(effectiveZoom * 100)}%`}
            </Button>
            <Button
              size="icon-sm"
              variant="ghost"
              aria-label={t('pod.office.zoom_in')}
              title={t('pod.office.zoom_in')}
              onClick={() => handleZoomStep(1)}>
              <ZoomInRegular />
            </Button>

            <Button
              size="icon-sm"
              variant="ghost"
              aria-label={t('pod.office.find')}
              title={t('pod.office.find')}
              onClick={() => setFindOpen(true)}>
              <SearchRegular />
            </Button>

            <Button
              size="icon-sm"
              variant="ghost"
              aria-label={t('pod.office.copy')}
              title={t('pod.office.copy')}
              disabled={!hasSelection}
              onClick={() => void handleCopy()}>
              <CopyRegular />
            </Button>

            <Button
              size="icon-sm"
              variant="ghost"
              aria-label={exportingPdf ? t('pod.office.exporting_pdf') : t('pod.office.download_pdf')}
              title={exportingPdf ? t('pod.office.exporting_pdf') : t('pod.office.download_pdf')}
              disabled={exportingPdf || slides.length === 0}
              onClick={() => void handleDownloadPdf()}>
              {exportingPdf ? <Spinner className="size-4" /> : <DocumentPdfRegular />}
            </Button>

            <Button
              size="xs"
              variant="outline"
              aria-label={t('pod.presentation.present')}
              title={t('pod.presentation.present')}
              disabled={slides.length === 0}
              onClick={() => setPresentOpen(true)}>
              <SlidePlayRegular />
              <span className="hidden sm:inline">{t('pod.presentation.present')}</span>
            </Button>
          </div>
        </div>

        {findOpen && (
          <PresentationFindBar
            query={findQuery}
            matchCase={findMatchCase}
            matchCount={findMatches.length}
            activeMatchIndex={activeMatchIndex}
            onQueryChange={setFindQuery}
            onMatchCaseChange={setFindMatchCase}
            onNext={() => stepFindMatch(1)}
            onPrevious={() => stepFindMatch(-1)}
            onClose={() => {
              setFindOpen(false)
              workspaceRef.current?.focus({ preventScroll: true })
            }}
          />
        )}

        <div className="flex min-h-0 flex-1 flex-col md:flex-row">
          {!isMobile && railOpen && (
            <aside className="w-44 shrink-0 overflow-y-auto border-r border-border bg-muted/20 p-2">
              <ol aria-label={t('pod.presentation.slides_rail')} className="flex flex-col gap-1.5">
                {slides.map(slide => (
                  <PreviewThumbnailItem
                    key={slide.slide_id}
                    slide={slide}
                    isActive={slide.index === activeSlideIndex}
                    slideSizePt={slideSizePt}
                    fontEpoch={fontEpoch}
                    compact={false}
                    renderSlide={renderSlide}
                    onSelect={idx => void goToSlide(idx)}
                  />
                ))}
              </ol>
            </aside>
          )}

          <div className="flex min-h-0 min-w-0 flex-1 flex-col">
            <div
              ref={stageRef}
              className="relative flex min-h-0 flex-1 items-center justify-center overflow-auto bg-muted/40 p-3">
              <div
                style={{ width: `${cssWidth}px`, height: `${cssHeight}px` }}
                className="relative shrink-0 bg-white shadow-md">
                <canvas
                  ref={canvasRef}
                  role="img"
                  aria-label={t('pod.presentation.slide_canvas', {
                    index: activeSlideIndex + 1
                  })}
                  className="block size-full touch-none select-none"
                  {...viewPointer}
                />
                <PresentationTextHighlight selection={selection} size={slideSizePt} />

                {selectedShapeBoxes.length > 0 && (
                  <div aria-hidden="true" className="pointer-events-none absolute inset-0 overflow-visible">
                    {selectedShapeBoxes.map(box => (
                      <div
                        key={box.id}
                        style={{
                          left: `${box.x * effectiveZoom}px`,
                          top: `${box.y * effectiveZoom}px`,
                          width: `${Math.max(2, box.w * effectiveZoom)}px`,
                          height: `${Math.max(2, box.h * effectiveZoom)}px`,
                          transform: box.rot ? `rotate(${box.rot}deg)` : undefined
                        }}
                        className="absolute border border-primary/80"
                      />
                    ))}
                  </div>
                )}
              </div>
            </div>

            {speakerNotes.length > 0 && (
              <section
                aria-label={t('pod.presentation.speaker_notes')}
                className="max-h-28 shrink-0 overflow-y-auto border-t border-border bg-background px-3 py-2">
                <p className="mb-0.5 text-xs font-medium text-fg-tertiary">{t('pod.presentation.speaker_notes')}</p>
                <p className="whitespace-pre-wrap text-xs text-fg-secondary">{speakerNotes}</p>
              </section>
            )}
          </div>

          {isMobile && railOpen && (
            <aside className="shrink-0 overflow-x-auto border-t border-border bg-muted/20 p-2">
              <ol aria-label={t('pod.presentation.slides_rail')} className="flex items-center gap-2">
                {slides.map(slide => (
                  <PreviewThumbnailItem
                    key={slide.slide_id}
                    slide={slide}
                    isActive={slide.index === activeSlideIndex}
                    slideSizePt={slideSizePt}
                    fontEpoch={fontEpoch}
                    compact
                    renderSlide={renderSlide}
                    onSelect={idx => void goToSlide(idx)}
                  />
                ))}
              </ol>
            </aside>
          )}
        </div>
      </div>

      <PresentationPresent
        open={presentOpen}
        slideCount={slides.length}
        initialSlideIndex={activeSlideIndex}
        slideSizePt={slideSizePt}
        renderVersion={version + fontEpoch}
        renderSlide={renderSlide}
        onSlideChange={idx => void goToSlide(idx)}
        onClose={() => setPresentOpen(false)}
      />
    </div>
  )
}
