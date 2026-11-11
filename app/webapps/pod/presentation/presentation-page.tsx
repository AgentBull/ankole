import { Avatar, AvatarFallback, cn, Textarea, toast, useIsMobile } from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import { LockClosedRegular } from '@ankole/uikit/icons'
import { useQueryClient } from '@tanstack/react-query'
import { t } from 'i18next'
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ClipboardEvent,
  type CompositionEvent,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent
} from 'react'
import { downloadBlob } from '../../common/browser-files'
import { requestErrorMessage } from '../../common/request-errors'
import { contentKeys, type PageDetail } from '../content-api'
import { useContent, usePageHost } from '../content-context'
import { contentError } from '../content-errors'
import { ContentError, ContentSkeleton } from '../content-primitives'
import { loadOfficeBootstrap, type OfficeMember, type OfficeNotice } from '../office/office-collaboration'
import { useOfficeFonts } from '../office/office-fonts'
import { findOfficeSearchMatch } from '../search-targets'
import {
  createPresentationEngine,
  type PresentationEngine,
  type PresentationFindMatch,
  type PresentationSlideInfo
} from './presentation-engine'
import { paintRenderedSlide, PresentationPresent } from './presentation-present'
import {
  PRESENTATION_TEXT_NAVIGATION_KEYS,
  PresentationTextHighlight,
  useReadOnlyPresentationPointer
} from './presentation-selection'
import {
  createPresentationSession,
  PresentationFindBar,
  PresentationToolbar,
  type PresentationSession
} from './presentation-toolbar'

const isMac = typeof navigator !== 'undefined' && /Mac|iPhone|iPad/.test(navigator.platform)

const ZOOM_STEPS = [0.5, 0.75, 1, 1.25, 1.5, 2] as const
const STRUCTURAL_SLIDE_COMMANDS = new Set(['slide.new', 'slide.duplicate', 'slide.delete', 'slide.move'])

/**
 * Returns the first collaborator currently holding a soft edit lock on `slideId`, if any.
 */
export function findSlideLockHolder(
  members: readonly OfficeMember[],
  slideId: number | null | undefined
): OfficeMember | undefined {
  if (slideId === null || slideId === undefined) return undefined
  return members.find(member =>
    member.selections.some(entry => entry.mode === 'editing' && entry.selection.slide_id === slideId)
  )
}

function slidePresenceBadges(
  members: readonly OfficeMember[],
  slideId: number
): { member: OfficeMember; editing: boolean }[] {
  const result: { member: OfficeMember; editing: boolean }[] = []
  for (const member of members) {
    const onSlide = member.selections.filter(entry => entry.selection.slide_id === slideId)
    if (onSlide.length > 0) {
      result.push({
        member,
        editing: onSlide.some(entry => entry.mode === 'editing')
      })
    }
  }
  return result
}

function pdfDownloadFilename(title: string | null | undefined): string {
  const raw = (title ?? '').trim() || t('pod.presentation.presentation')
  const stripped = raw.replace(/\.pptx$/i, '').replace(/[\\/]+/g, '-')
  return `${stripped || 'presentation'}.pdf`
}

function announceOfficeNotice(notice: OfficeNotice, activeSlideIndex: number | undefined) {
  switch (notice.kind) {
    case 'conflict': {
      const deckWide =
        notice.reason === 'slides_reordered' ||
        notice.reason === 'field_changed' ||
        notice.reason === 'identifier_taken'
      const target =
        !deckWide && activeSlideIndex !== undefined
          ? t('pod.presentation.slide_target', { index: activeSlideIndex + 1 })
          : t('pod.presentation.deck_target')
      const reason = t(`pod.office.conflicts.${notice.reason}`, {
        defaultValue: notice.reason
      })
      toast.error(t('pod.office.edit_conflict', { target, reason }))
      return
    }
    case 'discarded':
      toast.warning(t('pod.office.edits_discarded', { count: notice.count }))
      return
    case 'rejected':
      if (notice.message.includes('future_model_version') || notice.message.includes('exceeds supported version')) {
        toast.error(t('pod.office.reload_newer_version'))
        return
      }
      toast.error(notice.message)
      return
    case 'failed': {
      const msg = notice.error instanceof Error ? notice.error.message : String(notice.error)
      if (msg.includes('future_model_version') || msg.includes('exceeds supported version')) {
        toast.error(t('pod.office.reload_newer_version'))
        return
      }
      toast.error(requestErrorMessage(contentError(notice.error)))
      return
    }
    case 'revoked':
      return
  }
}

function SlideThumbnailItem({
  slide,
  isActive,
  slideSizePt,
  badges,
  stamp,
  compact,
  renderSlide,
  onSelect
}: {
  slide: PresentationSlideInfo
  isActive: boolean
  slideSizePt: { width: number; height: number }
  badges: { member: OfficeMember; editing: boolean }[]
  stamp: string
  compact: boolean
  renderSlide(
    slideIndex: number,
    scale: number
  ): Promise<import('./presentation-engine').PresentationRenderedSlide | undefined>
  onSelect(slideIndex: number): void
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const thumbWidth = compact ? 108 : 140
  const safePtW = Math.max(1, slideSizePt.width)
  const safePtH = Math.max(1, slideSizePt.height)
  const thumbHeight = Math.max(48, Math.round((thumbWidth * safePtH) / safePtW))
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
  }, [slide.index, scale, stamp, renderSlide])

  const lockEntry = badges.find(item => item.editing)

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
          'group relative flex w-full items-start gap-1.5 rounded-control p-1.5 text-left transition-colors focus-visible:outline-offset-1',
          isActive ? 'bg-accent ring-2 ring-primary' : 'hover:bg-accent/60'
        )}>
        <span className="w-5 shrink-0 pt-0.5 text-right font-mono text-xs tabular-nums text-fg-secondary">
          {slide.index + 1}
        </span>
        <div
          style={{ width: `${thumbWidth}px`, height: `${thumbHeight}px` }}
          className="relative shrink-0 overflow-hidden rounded-xs border border-border bg-white shadow-2xs">
          <canvas ref={canvasRef} aria-hidden="true" className="block size-full" />
          {lockEntry && (
            <span
              title={t('pod.office.locked_by', { name: lockEntry.member.name })}
              aria-label={t('pod.office.locked_by', {
                name: lockEntry.member.name
              })}
              style={{ background: `var(${lockEntry.member.color})` }}
              className="absolute top-1 right-1 flex size-4 items-center justify-center rounded-full text-white shadow-xs">
              <LockClosedRegular className="size-2.5" />
            </span>
          )}
          {badges.length > 0 && (
            <div className="absolute right-1 bottom-1 flex -space-x-1">
              {badges.slice(0, 3).map(({ member }) => (
                <Avatar key={member.uid} size="sm" title={member.name} className="size-4 ring-1 ring-background">
                  <AvatarFallback className="text-[9px] text-white" style={{ background: `var(${member.color})` }}>
                    {member.name.slice(0, 1).toUpperCase()}
                  </AvatarFallback>
                </Avatar>
              ))}
            </div>
          )}
        </div>
      </button>
    </li>
  )
}

/**
 * Collaborative Presentation Page editor backed by `ankole_presentation_wasm` in a Web Worker and
 * `OfficeCollaborationModel` over the `page:{id}` Realtime channel.
 */
export default function PresentationPage({
  detail,
  initialSlide,
  initialFind
}: {
  detail: PageDetail
  initialSlide?: number
  initialFind?: string
}) {
  const { realtime } = useContent()
  const registerOfficeSession = usePageHost()?.registerOfficeSession
  const client = useQueryClient()
  const pageID = detail.page.id
  const canEdit = detail.actions.includes('node_edit')

  const [session, setSession] = useState<{
    model: PresentationSession
    generation: number
  }>()
  const generation = useRef(0)

  useEffect(() => {
    const refresh = () => void client.invalidateQueries({ queryKey: contentKeys.page(pageID) })
    const next = createPresentationSession({
      canEdit,
      selfUID: () => realtime.principal?.uid,
      connect: () => realtime.join(`page:${pageID}`),
      load: () => loadOfficeBootstrap(pageID),
      createEngine: createPresentationEngine,
      notify: notice => {
        announceOfficeNotice(notice, next.snapshot.peek()?.selection.slide_index)
        if (notice.kind === 'failed' || notice.kind === 'revoked') {
          refresh()
        }
      }
    })
    const detach = registerOfficeSession?.(next)
    setSession({ model: next, generation: ++generation.current })
    void next.start()

    const unwatch = realtime.watchVersion('pages', pageID, version => {
      if (version === undefined) next.revoke()
      else if (version !== next.revision.peek()) next.sync()
    })
    const handlePageHide = () => {
      next.flushOnPageHide()
    }
    window.addEventListener('pagehide', handlePageHide)

    return () => {
      detach?.()
      window.removeEventListener('pagehide', handlePageHide)
      unwatch()
      next[Symbol.dispose]()
    }
  }, [pageID, canEdit, realtime, client, registerOfficeSession])

  if (!session) {
    return <ContentSkeleton variant="page" label={t('pod.presentation.loading')} immediate />
  }

  return (
    <PresentationWorkspace
      key={session.generation}
      model={session.model}
      pageID={pageID}
      pageTitle={detail.page.title}
      canEdit={canEdit}
      initialSlide={initialSlide}
      initialFind={initialFind}
    />
  )
}

function PresentationWorkspace({
  model,
  pageID,
  pageTitle,
  canEdit,
  initialSlide,
  initialFind
}: {
  model: PresentationSession
  pageID: string
  pageTitle: string | null | undefined
  canEdit: boolean
  initialSlide?: number
  initialFind?: string
}) {
  useSignals()
  const isMobile = useIsMobile()

  const stageRef = useRef<HTMLDivElement>(null)
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const editorInputRef = useRef<HTMLTextAreaElement>(null)
  const composingRef = useRef(false)
  const appliedJumpRef = useRef<string | undefined>(undefined)

  const pointerGestureRef = useRef<{
    pointerId: number
    startClientX: number
    startClientY: number
    startPtX: number
    startPtY: number
    dragging: boolean
    lockBlocked: boolean
  } | null>(null)
  const dragInFlightRef = useRef(false)
  const queuedDragEventRef = useRef<Record<string, unknown> | null>(null)

  const [railOpen, setRailOpen] = useState(true)
  const [notesOpen, setNotesOpen] = useState(false)
  const [zoomMode, setZoomMode] = useState<'fit' | number>('fit')
  const [stageSize, setStageSize] = useState<{ width: number; height: number }>({
    width: 960,
    height: 540
  })
  const [activeThumbStamp, setActiveThumbStamp] = useState(0)
  const [exportingPdf, setExportingPdf] = useState(false)
  const [presentOpen, setPresentOpen] = useState(false)

  const [findOpen, setFindOpen] = useState(false)
  const [findQuery, setFindQuery] = useState('')
  const [findMatchCase, setFindMatchCase] = useState(false)
  const [findMatches, setFindMatches] = useState<PresentationFindMatch[]>([])
  const [activeMatchIndex, setActiveMatchIndex] = useState(0)

  const status = model.status.value
  const editable = model.editable.value
  const snapshot = model.snapshot.value
  const requestedFonts = useMemo(
    () => [...(snapshot?.substitutedFonts.map(entry => entry.requested) ?? []), ...(snapshot?.missingGlyphFonts ?? [])],
    [snapshot?.substitutedFonts, snapshot?.missingGlyphFonts]
  )
  const fontEpoch = useOfficeFonts(requestedFonts, model)
  const members = model.members.value
  const version = model.version.value
  const revision = model.revision.value

  const slides = snapshot?.slides ?? []
  const selection = snapshot?.selection
  const activeSlideIndex = Math.min(Math.max(0, selection?.slide_index ?? 0), Math.max(0, slides.length - 1))
  const activeSlide = slides[activeSlideIndex]
  const activeSlideId = selection?.slide_id ?? activeSlide?.slide_id ?? null
  const slideSizePt = snapshot?.slideSizePt ?? { width: 960, height: 540 }
  const selectedShapeBoxes = snapshot?.selectedShapeBoxes ?? []
  const viewPointer = useReadOnlyPresentationPointer(model, slideSizePt, () =>
    editorInputRef.current?.focus({ preventScroll: true })
  )

  const activeSlideLockHolder = useMemo(() => findSlideLockHolder(members, activeSlideId), [members, activeSlideId])

  // Debounce active slide thumbnail rasterization while typing or dragging.
  useEffect(() => {
    const timer = setTimeout(() => {
      setActiveThumbStamp(prev => prev + 1)
    }, 220)
    return () => clearTimeout(timer)
  }, [version, fontEpoch])

  // Measure the central stage viewport for fit-to-stage zoom.
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
  }, [status, railOpen, notesOpen, findOpen, isMobile])

  const safePtW = Math.max(1, slideSizePt.width)
  const safePtH = Math.max(1, slideSizePt.height)
  const fitZoom = useMemo(() => {
    const padX = Math.max(80, stageSize.width - 32)
    const padY = Math.max(60, stageSize.height - 32)
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

  // Rasterize the active slide onto the main `<canvas>`.
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

  const warnIfSlideLocked = useCallback(
    (targetSlideId?: number): boolean => {
      const snap = model.snapshot.peek()
      const slideId = targetSlideId ?? snap?.selection.slide_id
      const holder = findSlideLockHolder(model.members.peek(), slideId)
      if (!holder) return false
      const idx = snap?.slides.find(slide => slide.slide_id === slideId)?.index ?? 0
      toast.warning(
        t('pod.office.locked_unit_notice', {
          name: holder.name,
          unit: t('pod.presentation.slide_target', { index: idx + 1 })
        })
      )
      return true
    },
    [model]
  )

  const goToSlide = useCallback(
    async (nextIndex: number) => {
      const list = model.snapshot.peek()?.slides ?? []
      if (list.length === 0) return
      const clamped = Math.min(Math.max(0, nextIndex), list.length - 1)
      const currentIdx = model.snapshot.peek()?.selection.slide_index ?? 0
      if (clamped !== currentIdx && model.composing.peek()) return
      await model.updateSelection(
        async eng => ({
          snapshot: await (eng as PresentationEngine).setActiveSlide(clamped)
        }),
        { commitBefore: clamped !== currentIdx }
      )
    },
    [model]
  )

  // Initial deep-link slide jump (`initialSlide` is 1-based) and search highlight (`initialFind`).
  useEffect(() => {
    if ((status !== 'ready' && status !== 'read_only') || slides.length === 0) return
    const key = `${initialSlide ?? ''}\0${initialFind ?? ''}`
    if ((initialSlide === undefined && !initialFind) || appliedJumpRef.current === key) {
      return
    }
    const targetSlideIndex =
      initialSlide !== undefined && Number.isFinite(initialSlide)
        ? Math.min(Math.max(0, Math.trunc(initialSlide) - 1), slides.length - 1)
        : undefined

    let cancelled = false
    void (async () => {
      const result = initialFind
        ? await model.read(engine =>
            findOfficeSearchMatch(
              initialFind,
              targetSlideIndex,
              needle => (engine as PresentationEngine).find(needle, false),
              match => match.slide_index
            )
          )
        : undefined
      if (cancelled) return
      appliedJumpRef.current = key
      if (result) {
        const match = result.matches[result.index]!
        setFindQuery(result.needle)
        setFindMatchCase(false)
        setFindMatches(result.matches)
        setActiveMatchIndex(result.index)
        setFindOpen(true)
        if (match.in_notes) setNotesOpen(true)
        await goToSlide(match.slide_index)
      } else if (targetSlideIndex !== undefined) {
        await goToSlide(targetSlideIndex)
      }
    })().catch(() => undefined)

    return () => {
      cancelled = true
    }
  }, [status, slides.length, initialSlide, initialFind, model, goToSlide])

  // Re-run deck search whenever Find bar query, case sensitivity, or document version changes.
  useEffect(() => {
    if (!findOpen) return
    const trimmed = findQuery.trim()
    if (!trimmed) {
      setFindMatches([])
      setActiveMatchIndex(0)
      return
    }
    let cancelled = false
    void model
      .read(eng => (eng as PresentationEngine).find(trimmed, findMatchCase))
      .then(results => {
        if (cancelled) return
        const items = results ?? []
        setFindMatches(items)
        setActiveMatchIndex(prev => (items.length === 0 ? 0 : Math.min(prev, items.length - 1)))
      })
    return () => {
      cancelled = true
    }
  }, [findOpen, findQuery, findMatchCase, version, model])

  const stepFindMatch = useCallback(
    (delta: 1 | -1) => {
      if (findMatches.length === 0) return
      const nextIdx = (activeMatchIndex + delta + findMatches.length) % findMatches.length
      setActiveMatchIndex(nextIdx)
      const match = findMatches[nextIdx]
      if (match) {
        if (match.in_notes) setNotesOpen(true)
        void goToSlide(match.slide_index)
      }
    },
    [findMatches, activeMatchIndex, goToSlide]
  )

  const handleRunCommand = useCallback(
    async (commandId: string, params: Record<string, unknown>, options?: { allowWhenSlideLocked?: boolean }) => {
      if (!model.editable.peek()) return
      if (!options?.allowWhenSlideLocked && warnIfSlideLocked()) {
        return
      }
      if (STRUCTURAL_SLIDE_COMMANDS.has(commandId) && model.hasDraft.peek() && !model.composing.peek()) {
        await model.commitNow()
      }
      await model.mutate(async eng => {
        const snap = await (eng as PresentationEngine).executeCommand(commandId, params)
        return { result: snap, snapshot: snap, commit: true }
      })
    },
    [model, warnIfSlideLocked]
  )

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
        downloadBlob(new Blob([pdfBytes.slice()], { type: 'application/pdf' }), pdfDownloadFilename(pageTitle))
      }
    } catch (failure) {
      toast.error(requestErrorMessage(contentError(failure)))
    } finally {
      setExportingPdf(false)
    }
  }, [exportingPdf, model, pageTitle])

  const clientToSlideCoords = useCallback(
    (clientX: number, clientY: number): { x: number; y: number; tol: number } => {
      const canvas = canvasRef.current
      if (!canvas) {
        return { x: 0, y: 0, tol: 4 }
      }
      const rect = canvas.getBoundingClientRect()
      const scaleX = rect.width > 0 ? safePtW / rect.width : 1
      const scaleY = rect.height > 0 ? safePtH / rect.height : 1
      return {
        x: (clientX - rect.left) * scaleX,
        y: (clientY - rect.top) * scaleY,
        tol: Math.max(2, 6 * scaleX)
      }
    },
    [safePtW, safePtH]
  )

  const flushQueuedDrag = useCallback(() => {
    if (dragInFlightRef.current || !queuedDragEventRef.current) return
    const nextEvent = queuedDragEventRef.current
    queuedDragEventRef.current = null
    dragInFlightRef.current = true
    void model
      .mutate(async eng => {
        const snap = await (eng as PresentationEngine).pointerEvent(nextEvent)
        return { result: snap, snapshot: snap, commit: false }
      })
      .finally(() => {
        dragInFlightRef.current = false
        if (queuedDragEventRef.current) {
          flushQueuedDrag()
        }
      })
  }, [model])

  const handleCanvasPointerDown = (event: ReactPointerEvent<HTMLCanvasElement>) => {
    if (event.button !== 0) return
    event.currentTarget.setPointerCapture(event.pointerId)
    editorInputRef.current?.focus({ preventScroll: true })
    const coords = clientToSlideCoords(event.clientX, event.clientY)
    pointerGestureRef.current = {
      pointerId: event.pointerId,
      startClientX: event.clientX,
      startClientY: event.clientY,
      startPtX: coords.x,
      startPtY: coords.y,
      dragging: false,
      lockBlocked: false
    }
    const payload = {
      kind: 'down',
      x: coords.x,
      y: coords.y,
      tol: coords.tol,
      mods: {
        shift: event.shiftKey,
        alt: event.altKey,
        ctrl: event.ctrlKey,
        meta: event.metaKey
      }
    }
    if (editable) {
      void model.mutate(async eng => {
        const snap = await (eng as PresentationEngine).pointerEvent(payload)
        return { result: snap, snapshot: snap, commit: false }
      })
    } else {
      void model.updateSelection(async eng => ({
        snapshot: await (eng as PresentationEngine).pointerEvent(payload)
      }))
    }
  }

  const handleCanvasPointerMove = (event: ReactPointerEvent<HTMLCanvasElement>) => {
    const gesture = pointerGestureRef.current
    if (!gesture || gesture.pointerId !== event.pointerId) return
    const dist = Math.hypot(event.clientX - gesture.startClientX, event.clientY - gesture.startClientY)
    if (!gesture.dragging && dist < 3) return
    gesture.dragging = true
    if (!editable || gesture.lockBlocked) return

    if (warnIfSlideLocked()) {
      gesture.lockBlocked = true
      queuedDragEventRef.current = null
      void model.updateSelection(async eng => ({
        snapshot: await (eng as PresentationEngine).pointerEvent({
          kind: 'up',
          x: gesture.startPtX,
          y: gesture.startPtY,
          tol: 4
        })
      }))
      return
    }

    const coords = clientToSlideCoords(event.clientX, event.clientY)
    queuedDragEventRef.current = {
      kind: 'drag',
      x: coords.x,
      y: coords.y,
      tol: coords.tol,
      mods: {
        shift: event.shiftKey,
        alt: event.altKey,
        ctrl: event.ctrlKey,
        meta: event.metaKey
      }
    }
    flushQueuedDrag()
  }

  const finishPointerGesture = (event: ReactPointerEvent<HTMLCanvasElement>) => {
    const gesture = pointerGestureRef.current
    if (!gesture || gesture.pointerId !== event.pointerId) return
    pointerGestureRef.current = null
    queuedDragEventRef.current = null
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }
    if (gesture.lockBlocked) return

    const coords = clientToSlideCoords(event.clientX, event.clientY)
    const payload = {
      kind: 'up',
      x: coords.x,
      y: coords.y,
      tol: coords.tol,
      mods: {
        shift: event.shiftKey,
        alt: event.altKey,
        ctrl: event.ctrlKey,
        meta: event.metaKey
      }
    }
    if (editable) {
      void model.mutate(async eng => {
        const snap = await (eng as PresentationEngine).pointerEvent(payload)
        return { result: snap, snapshot: snap, commit: snap.editing }
      })
    } else {
      void model.updateSelection(async eng => ({
        snapshot: await (eng as PresentationEngine).pointerEvent(payload)
      }))
    }
  }

  const handleCanvasDoubleClick = (event: React.MouseEvent<HTMLCanvasElement>) => {
    editorInputRef.current?.focus({ preventScroll: true })
    if (!editable) return
    if (warnIfSlideLocked()) return
    const coords = clientToSlideCoords(event.clientX, event.clientY)
    void model.mutate(async eng => {
      const snap = await (eng as PresentationEngine).pointerEvent({
        kind: 'doubleclick',
        x: coords.x,
        y: coords.y,
        tol: coords.tol,
        mods: {
          shift: event.shiftKey,
          alt: event.altKey,
          ctrl: event.ctrlKey,
          meta: event.metaKey
        }
      })
      return { result: snap, snapshot: snap, commit: false }
    })
  }

  const handleEditorKeyDown = (event: ReactKeyboardEvent<HTMLTextAreaElement>) => {
    if (event.nativeEvent.isComposing || event.keyCode === 229 || composingRef.current) {
      return
    }

    const mod = isMac ? event.metaKey : event.ctrlKey
    const lower = event.key.toLowerCase()

    if (mod && !event.altKey) {
      if (lower === 's') {
        event.preventDefault()
        if (editable) void model.commitNow()
        return
      }
      if (lower === 'f') {
        event.preventDefault()
        setFindOpen(true)
        return
      }
      if (lower === 'c') {
        event.preventDefault()
        void handleCopy()
        return
      }
      if (lower === 'z') {
        event.preventDefault()
        if (editable) {
          void (event.shiftKey ? model.redo() : model.undo())
        }
        return
      }
      if (!isMac && lower === 'y') {
        event.preventDefault()
        if (editable) void model.redo()
        return
      }
      if (lower === 'b' || lower === 'i' || lower === 'u') {
        event.preventDefault()
        const cmd = lower === 'b' ? 'format.bold' : lower === 'i' ? 'format.italic' : 'format.underline'
        void handleRunCommand(cmd, {})
        return
      }
    }

    const curSel = model.snapshot.peek()?.selection
    const editingText = Boolean(curSel?.text_sel)
    const hasShapes = (curSel?.shapes.length ?? 0) > 0

    // Slide-switching keys commit any departing slide draft before navigating.
    if (!editingText && !mod && !event.altKey) {
      if (event.key === 'PageDown') {
        event.preventDefault()
        void goToSlide(activeSlideIndex + 1)
        return
      }
      if (event.key === 'PageUp') {
        event.preventDefault()
        void goToSlide(activeSlideIndex - 1)
        return
      }
      if (!hasShapes) {
        if (event.key === 'ArrowDown' || event.key === 'ArrowRight') {
          event.preventDefault()
          void goToSlide(activeSlideIndex + 1)
          return
        }
        if (event.key === 'ArrowUp' || event.key === 'ArrowLeft') {
          event.preventDefault()
          void goToSlide(activeSlideIndex - 1)
          return
        }
        if (event.key === 'Home') {
          event.preventDefault()
          void goToSlide(0)
          return
        }
        if (event.key === 'End') {
          event.preventDefault()
          void goToSlide(slides.length - 1)
          return
        }
      }
    }

    if (!editable) {
      if ((event.key === 'Escape' && hasShapes) || (editingText && PRESENTATION_TEXT_NAVIGATION_KEYS.has(event.key))) {
        event.preventDefault()
        void model.updateSelection(async eng => ({
          snapshot: await (eng as PresentationEngine).keyEvent(event.key, { shift: event.shiftKey })
        }))
      }
      return
    }

    // Non-mutating Escape / Tab selection cycling stays allowed even on locked slides.
    if (!editingText && (event.key === 'Escape' || event.key === 'Tab')) {
      event.preventDefault()
      void model.updateSelection(async eng => ({
        snapshot: await (eng as PresentationEngine).keyEvent(event.key, {
          shift: event.shiftKey
        })
      }))
      return
    }

    const isPlainPrintable = event.key.length === 1 && !event.ctrlKey && !event.metaKey
    const isMutatingKey =
      isPlainPrintable ||
      event.key === 'Backspace' ||
      event.key === 'Delete' ||
      event.key === 'Enter' ||
      (editingText && event.key === 'Tab') ||
      (!editingText &&
        hasShapes &&
        (event.key === 'ArrowLeft' ||
          event.key === 'ArrowRight' ||
          event.key === 'ArrowUp' ||
          event.key === 'ArrowDown'))

    if (isMutatingKey && warnIfSlideLocked()) {
      event.preventDefault()
      return
    }

    if (!editingText && !hasShapes && event.key === 'Enter') {
      event.preventDefault()
      void handleRunCommand('slide.new', {}, { allowWhenSlideLocked: true })
      return
    }

    const commitImmediately = !editingText && hasShapes && (event.key === 'Backspace' || event.key === 'Delete')

    event.preventDefault()
    const keyName = event.key
    const mods = {
      shift: event.shiftKey,
      alt: event.altKey,
      ctrl: event.ctrlKey,
      meta: event.metaKey
    }
    void model.mutate(async eng => {
      const snap = await (eng as PresentationEngine).keyEvent(keyName, mods)
      return { result: snap, snapshot: snap, commit: commitImmediately }
    })
  }

  const handleCompositionStart = () => {
    composingRef.current = true
    model.setExternalComposition(true)
  }

  const handleCompositionEnd = (event: CompositionEvent<HTMLTextAreaElement>) => {
    composingRef.current = false
    model.setExternalComposition(false)
    const text = event.data
    event.currentTarget.value = ''
    if (!text || !model.editable.peek()) return
    if (warnIfSlideLocked()) return
    void model.mutate(async eng => {
      const snap = await (eng as PresentationEngine).executeCommand('text.insert', { text })
      return { result: snap, snapshot: snap, commit: false }
    })
  }

  const handleEditorPaste = (event: ClipboardEvent<HTMLTextAreaElement>) => {
    if (!editable) return
    const text = event.clipboardData.getData('text/plain')
    event.preventDefault()
    event.currentTarget.value = ''
    if (!text) return
    if (warnIfSlideLocked()) return
    void model.mutate(async eng => {
      const snap = await (eng as PresentationEngine).executeCommand('edit.paste', { text })
      return { result: snap, snapshot: snap, commit: true }
    })
  }

  // Controlled Speaker Notes state synced to the active slide.
  const serverNotes = selection?.notes ?? activeSlide?.notes ?? ''
  const [notesDraft, setNotesDraft] = useState(serverNotes)
  const notesFocusedRef = useRef(false)
  const notesCompositionSlide = useRef<number | null>(null)
  const prevNotesSlideIdRef = useRef<number | null>(activeSlideId)

  useEffect(() => {
    if (prevNotesSlideIdRef.current !== activeSlideId) {
      prevNotesSlideIdRef.current = activeSlideId
      setNotesDraft(serverNotes)
      return
    }
    if (!notesFocusedRef.current) {
      setNotesDraft(serverNotes)
    }
  }, [activeSlideId, serverNotes])

  const updateNotes = (slideId: number, text: string, commit = false) => {
    void model.mutate(async eng => {
      const snap = await (eng as PresentationEngine).setSlideNotes(slideId, text)
      return { result: snap, snapshot: snap, commit }
    })
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
  if (model.revoked.value) {
    return <ContentError error={new Error(t('pod.content.you_no_longer_have_access_to_this_file'))} />
  }
  if (status === 'error') {
    const rawErr = model.error.value
    const errText = rawErr instanceof Error ? rawErr.message : String(rawErr ?? '')
    if (errText.includes('future_model_version') || errText.includes('exceeds supported version')) {
      return (
        <ContentError error={new Error(t('pod.office.reload_newer_version'))} retry={() => window.location.reload()} />
      )
    }
    return <ContentError error={rawErr} retry={model.retry} />
  }
  if (status === 'loading' && slides.length === 0) {
    return <ContentSkeleton variant="page" label={t('pod.presentation.loading')} immediate />
  }

  return (
    <div className="space-y-3">
      <div
        data-office-workspace=""
        aria-busy={status === 'loading'}
        className="flex h-[min(78vh,880px)] min-h-[420px] flex-col overflow-hidden rounded-control border border-border bg-background">
        <PresentationToolbar
          model={model}
          pageID={pageID}
          canEdit={canEdit}
          railOpen={railOpen}
          onToggleRail={() => setRailOpen(prev => !prev)}
          notesOpen={notesOpen}
          onToggleNotes={() => setNotesOpen(prev => !prev)}
          zoomMode={zoomMode}
          effectiveZoom={effectiveZoom}
          onZoomIn={() => handleZoomStep(1)}
          onZoomOut={() => handleZoomStep(-1)}
          onZoomFit={() => setZoomMode('fit')}
          exportingPdf={exportingPdf}
          onDownloadPdf={() => void handleDownloadPdf()}
          onPresent={() => setPresentOpen(true)}
          onOpenFind={() => setFindOpen(true)}
          onCopy={() => void handleCopy()}
          onRunCommand={handleRunCommand}
          editorInputRef={editorInputRef}
        />

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
              editorInputRef.current?.focus({ preventScroll: true })
            }}
          />
        )}

        <div className="flex min-h-0 flex-1 flex-col md:flex-row">
          {!isMobile && railOpen && (
            <aside className="w-48 shrink-0 overflow-y-auto border-r border-border bg-muted/20 p-2">
              <ol aria-label={t('pod.presentation.slides_rail')} className="flex flex-col gap-1.5">
                {slides.map(slide => {
                  const isActive = slide.index === activeSlideIndex
                  const stamp = isActive
                    ? `active:${slide.slide_id}:${activeThumbStamp}`
                    : `idle:${slide.slide_id}:${slide.shapes_count}:${slide.title}:${revision}:${fontEpoch}`
                  return (
                    <SlideThumbnailItem
                      key={slide.slide_id}
                      slide={slide}
                      isActive={isActive}
                      slideSizePt={slideSizePt}
                      badges={slidePresenceBadges(members, slide.slide_id)}
                      stamp={stamp}
                      compact={false}
                      renderSlide={renderSlide}
                      onSelect={idx => {
                        void goToSlide(idx).finally(() => editorInputRef.current?.focus({ preventScroll: true }))
                      }}
                    />
                  )
                })}
              </ol>
            </aside>
          )}

          <div className="flex min-h-0 min-w-0 flex-1 flex-col">
            <div
              ref={stageRef}
              className="relative flex min-h-0 flex-1 items-center justify-center overflow-auto bg-muted/40 p-4"
              onClick={event => {
                if (event.target === event.currentTarget) {
                  editorInputRef.current?.focus({ preventScroll: true })
                }
              }}>
              {activeSlideLockHolder && (
                <div
                  role="status"
                  className="pointer-events-none absolute top-2.5 left-1/2 z-20 flex -translate-x-1/2 items-center gap-1.5 rounded-full border border-border bg-background/95 px-3 py-1 text-xs font-medium text-foreground shadow-sm">
                  <span
                    className="flex size-4 items-center justify-center rounded-full text-white"
                    style={{ background: `var(${activeSlideLockHolder.color})` }}>
                    <LockClosedRegular className="size-2.5" />
                  </span>
                  <span>
                    {t('pod.office.locked_by', {
                      name: activeSlideLockHolder.name
                    })}
                  </span>
                </div>
              )}

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
                  {...(editable
                    ? {
                        onPointerDown: handleCanvasPointerDown,
                        onPointerMove: handleCanvasPointerMove,
                        onPointerUp: finishPointerGesture,
                        onPointerCancel: finishPointerGesture,
                        onDoubleClick: handleCanvasDoubleClick
                      }
                    : viewPointer)}
                />
                <PresentationTextHighlight selection={selection} size={slideSizePt} />

                {selectedShapeBoxes.length > 0 && (
                  <div aria-hidden="true" className="pointer-events-none absolute inset-0 overflow-visible">
                    {selectedShapeBoxes.map(box => {
                      const left = box.x * effectiveZoom
                      const top = box.y * effectiveZoom
                      const width = Math.max(2, box.w * effectiveZoom)
                      const height = Math.max(2, box.h * effectiveZoom)
                      const isTextEditing = selection?.text_sel?.shape_id === box.id
                      return (
                        <div
                          key={box.id}
                          style={{
                            left: `${left}px`,
                            top: `${top}px`,
                            width: `${width}px`,
                            height: `${height}px`,
                            transform: box.rot ? `rotate(${box.rot}deg)` : undefined
                          }}
                          className={cn('absolute border-2 border-primary', isTextEditing && 'border-dashed')}>
                          {editable && !isTextEditing && (
                            <>
                              <span className="absolute -top-1 -left-1 size-2 border border-primary bg-background" />
                              <span className="absolute -top-1 left-1/2 size-2 -translate-x-1/2 border border-primary bg-background" />
                              <span className="absolute -top-1 -right-1 size-2 border border-primary bg-background" />
                              <span className="absolute top-1/2 -left-1 size-2 -translate-y-1/2 border border-primary bg-background" />
                              <span className="absolute top-1/2 -right-1 size-2 -translate-y-1/2 border border-primary bg-background" />
                              <span className="absolute -bottom-1 -left-1 size-2 border border-primary bg-background" />
                              <span className="absolute -bottom-1 left-1/2 size-2 -translate-x-1/2 border border-primary bg-background" />
                              <span className="absolute -right-1 -bottom-1 size-2 border border-primary bg-background" />
                            </>
                          )}
                        </div>
                      )
                    })}
                  </div>
                )}
              </div>

              <textarea
                ref={editorInputRef}
                data-office-editor-input=""
                aria-label={t('pod.presentation.editor_input_label')}
                autoCapitalize="off"
                autoComplete="off"
                autoCorrect="off"
                spellCheck={false}
                rows={1}
                defaultValue=""
                readOnly={!editable}
                onKeyDown={handleEditorKeyDown}
                onCompositionStart={handleCompositionStart}
                onCompositionEnd={handleCompositionEnd}
                onPaste={handleEditorPaste}
                onInput={event => {
                  if (composingRef.current) return
                  const raw = event.currentTarget.value
                  event.currentTarget.value = ''
                  if (!raw || !editable) return
                  if (warnIfSlideLocked()) return
                  void model.mutate(async eng => {
                    const snap = await (eng as PresentationEngine).executeCommand('text.insert', { text: raw })
                    return { result: snap, snapshot: snap, commit: false }
                  })
                }}
                className="pointer-events-none absolute top-0 left-0 h-px w-px resize-none overflow-hidden opacity-0"
              />
            </div>

            <div className="flex items-center justify-between border-t border-border bg-muted/20 px-3 py-1 text-xs text-fg-secondary">
              <span>
                {slides.length > 0
                  ? t('pod.presentation.slide_of_total', {
                      index: activeSlideIndex + 1,
                      count: slides.length
                    })
                  : ''}
              </span>
              {activeSlide?.title && <span className="max-w-xs truncate text-fg-tertiary">{activeSlide.title}</span>}
            </div>

            {notesOpen && (
              <div className="shrink-0 border-t border-border bg-background p-2.5">
                <Textarea
                  aria-label={t('pod.presentation.speaker_notes')}
                  placeholder={t('pod.presentation.speaker_notes_placeholder')}
                  readOnly={!editable || Boolean(activeSlideLockHolder)}
                  rows={3}
                  value={notesDraft}
                  onFocus={() => {
                    notesFocusedRef.current = true
                  }}
                  onBlur={() => {
                    notesFocusedRef.current = false
                    if (model.editable.peek() && model.pending.peek() > 0 && !model.composing.peek()) {
                      void model.commitNow()
                    }
                  }}
                  onCompositionStart={() => {
                    notesCompositionSlide.current = activeSlideId
                    handleCompositionStart()
                  }}
                  onCompositionEnd={event => {
                    const slideId = notesCompositionSlide.current
                    notesCompositionSlide.current = null
                    composingRef.current = false
                    model.setExternalComposition(false)
                    if (slideId === null || !model.editable.peek() || warnIfSlideLocked(slideId)) return
                    const nextNotes = event.currentTarget.value
                    setNotesDraft(nextNotes)
                    updateNotes(slideId, nextNotes, !notesFocusedRef.current)
                  }}
                  onKeyDown={event => {
                    if (event.nativeEvent.isComposing || event.keyCode === 229 || composingRef.current) return
                    if ((isMac ? event.metaKey : event.ctrlKey) && event.key.toLowerCase() === 's') {
                      event.preventDefault()
                      void model.commitNow()
                    }
                  }}
                  onChange={event => {
                    if (!editable || activeSlideId === null) return
                    if (warnIfSlideLocked()) return
                    const nextNotes = event.target.value
                    setNotesDraft(nextNotes)
                    if (!composingRef.current) updateNotes(activeSlideId, nextNotes)
                  }}
                />
              </div>
            )}
          </div>

          {isMobile && railOpen && (
            <aside className="shrink-0 overflow-x-auto border-t border-border bg-muted/20 p-2">
              <ol aria-label={t('pod.presentation.slides_rail')} className="flex items-center gap-2">
                {slides.map(slide => {
                  const isActive = slide.index === activeSlideIndex
                  const stamp = isActive
                    ? `active:${slide.slide_id}:${activeThumbStamp}`
                    : `idle:${slide.slide_id}:${slide.shapes_count}:${slide.title}:${revision}:${fontEpoch}`
                  return (
                    <SlideThumbnailItem
                      key={slide.slide_id}
                      slide={slide}
                      isActive={isActive}
                      slideSizePt={slideSizePt}
                      badges={slidePresenceBadges(members, slide.slide_id)}
                      stamp={stamp}
                      compact
                      renderSlide={renderSlide}
                      onSelect={idx => void goToSlide(idx)}
                    />
                  )
                })}
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
