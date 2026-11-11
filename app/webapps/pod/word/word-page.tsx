import { t } from 'i18next'
import { Alert, AlertAction, AlertDescription, Button, cn, Input, Toggle, toast } from '@ankole/uikit'
import { useSignals } from '@preact/signals-react/runtime'
import { ChevronDownRegular, ChevronUpRegular, DismissRegular, ErrorCircleRegular } from '@ankole/uikit/icons'
import { useQueryClient } from '@tanstack/react-query'
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ClipboardEvent,
  type CompositionEvent,
  type FormEvent,
  type KeyboardEvent,
  type PointerEvent
} from 'react'
import { requestErrorMessage } from '../../common/request-errors'
import { contentKeys, type PageDetail } from '../content-api'
import { useContent, usePageHost } from '../content-context'
import { contentError } from '../content-errors'
import { ContentError, ContentSkeleton } from '../content-primitives'
import {
  loadOfficeBootstrap,
  OfficeCollaborationModel,
  type OfficeMember,
  type OfficeNotice
} from '../office/office-collaboration'
import { useOfficeFonts } from '../office/office-fonts'
import { findOfficeSearchMatch } from '../search-targets'
import { usePageMetadata } from '../use-page-metadata'
import {
  bytesToBase64,
  createWordEngine,
  MAX_WORD_PICTURE_BYTES,
  sameStoryRef,
  storyRefKey,
  type PageRect,
  type WordEngine,
  type WordFindMatch,
  type WordPageInfo,
  type WordSession,
  type WordSnapshot,
  type WordStoryRef
} from './word-engine'
import { WordToolbar } from './word-toolbar'

const WORD_WORKSPACE_ATTRIBUTE = 'data-word-workspace'

const POINTS_TO_CSS_PX = 96 / 72
const PAGE_GAP_PX = 20
const VIEWPORT_PAD_PX = 24
const BITMAP_CACHE_LIMIT = 24
const ZOOM_MIN = 0.5
const ZOOM_MAX = 2.0
const ZOOM_STEP = 0.15

const NAVIGATION_KEYS = new Set([
  'ArrowLeft',
  'ArrowRight',
  'ArrowUp',
  'ArrowDown',
  'Home',
  'End',
  'PageUp',
  'PageDown'
])

const textEncoder = new TextEncoder()

function utf8ByteOffset(text: string, utf16Offset: number): number {
  const clamped = Math.max(0, Math.min(text.length, utf16Offset))
  return textEncoder.encode(text.slice(0, clamped)).byteLength
}

function isNewerFormatError(error: unknown): boolean {
  const msg = error instanceof Error ? error.message : String(error)
  return msg.includes('model_version') || msg.includes('FutureVersion')
}

export function announceWordNotice(notice: OfficeNotice, model?: WordSession) {
  switch (notice.kind) {
    case 'conflict': {
      const block = model?.snapshot.peek()?.caretState.block
      const target =
        typeof block === 'number' ? t('pod.word.block_target', { index: block + 1 }) : t('pod.word.document_target')
      const reason = t(`pod.office.conflicts.${notice.reason}`, {
        defaultValue: notice.reason
      })
      toast.error(t('pod.office.edit_conflict', { target, reason }))
      return
    }
    case 'rejected':
      if (isNewerFormatError(notice.message)) {
        toast.error(t('pod.office.reload_newer_version'))
        return
      }
      toast.error(notice.message)
      return
    case 'discarded':
      toast.warning(t('pod.office.edits_discarded', { count: notice.count }))
      return
    case 'failed':
      if (isNewerFormatError(notice.error)) {
        toast.error(t('pod.office.reload_newer_version'))
        return
      }
      toast.error(requestErrorMessage(contentError(notice.error)))
      return
    case 'revoked':
      return
  }
}

type CollaboratorOverlay = {
  uid: string
  name: string
  color: string
  selectionRects: PageRect[]
  lockedBlocks: {
    story: WordStoryRef
    block: number
    rects: PageRect[]
  }[]
}

/**
 * Collaborative editor for `.docx` and `.docm` Word Pages.
 */
export default function WordPage({
  detail,
  initialPage,
  initialFind
}: {
  detail: PageDetail
  initialPage?: number
  initialFind?: string
}) {
  const { realtime } = useContent()
  const registerOfficeSession = usePageHost()?.registerOfficeSession
  const client = useQueryClient()
  const page = usePageMetadata(detail.page)
  const pageID = detail.page.id
  const canEdit = detail.actions.includes('node_edit')
  const [session, setSession] = useState<{ model: WordSession; generation: number }>()
  const generation = useRef(0)

  useEffect(() => {
    const refresh = () => void client.invalidateQueries({ queryKey: contentKeys.page(pageID) })
    const next: WordSession = new OfficeCollaborationModel<WordSnapshot>({
      canEdit,
      selfUID: () => realtime.principal?.uid,
      connect: () => realtime.join(`page:${pageID}`),
      load: () => loadOfficeBootstrap(pageID),
      createEngine: createWordEngine,
      notify: notice => {
        announceWordNotice(notice, next)
        if (notice.kind === 'failed' || notice.kind === 'revoked') refresh()
      }
    })
    const detach = registerOfficeSession?.(next)
    setSession({ model: next, generation: ++generation.current })
    void next.start()
    const unwatch = realtime.watchVersion('pages', pageID, version => {
      if (version === undefined) next.revoke()
      else if (version !== next.revision.peek()) next.sync()
    })
    return () => {
      detach?.()
      unwatch()
      next[Symbol.dispose]()
    }
  }, [pageID, canEdit, realtime, client, registerOfficeSession])

  if (!session) {
    return <ContentSkeleton variant="page" label={t('pod.word.loading')} immediate />
  }

  return (
    <WordDocumentSurface
      key={session.generation}
      model={session.model}
      pageID={pageID}
      title={page.title}
      canEdit={canEdit}
      initialPage={initialPage}
      initialFind={initialFind}
    />
  )
}

export function WordDocumentSurface({
  model,
  pageID,
  title,
  canEdit,
  initialPage,
  initialFind,
  preview = false
}: {
  model: WordSession
  pageID?: string
  title?: string
  canEdit: boolean
  initialPage?: number
  initialFind?: string
  preview?: boolean
}) {
  useSignals()
  const editorInputRef = useRef<HTMLTextAreaElement>(null)
  const scrollerRef = useRef<HTMLDivElement>(null)
  const workspaceRef = useRef<HTMLDivElement>(null)

  const status = model.status.value
  const editable = model.editable.value
  const snapshot = model.snapshot.value
  const version = model.version.value
  const members = model.members.value

  const pages = snapshot?.pages ?? []
  const caretState = snapshot?.caretState
  const missingPictures = snapshot?.missingPictures ?? []
  const substitutedFonts = snapshot?.substitutedFonts ?? []
  const missingGlyphFonts = snapshot?.missingGlyphFonts ?? []
  const requestedFonts = useMemo(
    () => [...substitutedFonts, ...missingGlyphFonts],
    [substitutedFonts, missingGlyphFonts]
  )

  const [missingDismissed, setMissingDismissed] = useState(false)
  const [zoom, setZoom] = useState(1)
  const [fitWidth, setFitWidth] = useState(false)
  const [viewportSize, setViewportSize] = useState({ width: 860, height: 640 })
  const [scrollTop, setScrollTop] = useState(0)
  const [dpr, setDpr] = useState(() => (typeof window !== 'undefined' ? Math.max(1, window.devicePixelRatio || 1) : 1))
  const fontEpoch = useOfficeFonts(requestedFonts, model)
  const [bitmapTick, setBitmapTick] = useState(0)

  const [findOpen, setFindOpen] = useState(false)
  const [findQuery, setFindQuery] = useState('')
  const [findMatchCase, setFindMatchCase] = useState(false)
  const [findMatches, setFindMatches] = useState<WordFindMatch[]>([])
  const [findIndex, setFindIndex] = useState(0)
  const findInputRef = useRef<HTMLInputElement>(null)

  const [collaboratorOverlays, setCollaboratorOverlays] = useState<CollaboratorOverlay[]>([])

  const bitmapCacheRef = useRef<Map<string, ImageData>>(new Map())
  const inflightRendersRef = useRef<Set<string>>(new Set())
  const composingRef = useRef(false)
  const blockedCompositionRef = useRef(false)
  const appliedInitialJumpRef = useRef<string | undefined>(undefined)
  const pointerGestureRef = useRef<{
    active: boolean
    moved: boolean
    moveInFlight: boolean
    queuedMove?: { pageIndex: number; xPt: number; yPt: number }
  }>({ active: false, moved: false, moveInFlight: false })

  // Flush pending local draft on browser pagehide.
  useEffect(() => {
    if (!canEdit) return
    const onPageHide = () => model.flushOnPageHide()
    window.addEventListener('pagehide', onPageHide)
    return () => window.removeEventListener('pagehide', onPageHide)
  }, [canEdit, model])

  // Track devicePixelRatio changes across displays or browser zoom.
  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return
    const updateDpr = () => setDpr(Math.max(1, window.devicePixelRatio || 1))
    const media = window.matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`)
    media.addEventListener('change', updateDpr)
    return () => media.removeEventListener('change', updateDpr)
  }, [dpr])

  // Measure scroll viewport width/height for virtualization and fit-width zoom.
  useEffect(() => {
    const el = scrollerRef.current
    if (!el) return
    const measure = () => {
      setViewportSize({
        width: Math.max(240, el.clientWidth),
        height: Math.max(240, el.clientHeight)
      })
      setScrollTop(el.scrollTop)
    }
    measure()
    if (typeof ResizeObserver === 'undefined') return
    const observer = new ResizeObserver(measure)
    observer.observe(el)
    return () => observer.disconnect()
  }, [status, pages.length])

  const maxPageWidthPt = useMemo(() => pages.reduce((acc, page) => Math.max(acc, page.width_pt), 612), [pages])

  const effectiveZoom = useMemo(() => {
    if (!fitWidth) return zoom
    const available = Math.max(200, viewportSize.width - VIEWPORT_PAD_PX * 2)
    const naturalPx = maxPageWidthPt * POINTS_TO_CSS_PX
    return Math.min(ZOOM_MAX, Math.max(0.35, available / Math.max(1, naturalPx)))
  }, [fitWidth, zoom, viewportSize.width, maxPageWidthPt])

  const cssScale = effectiveZoom * POINTS_TO_CSS_PX
  const rasterScale = cssScale * dpr
  const rasterScaleKey = rasterScale.toFixed(4)

  const pageLayout = useMemo(() => {
    const items: {
      page: WordPageInfo
      top: number
      cssWidth: number
      cssHeight: number
    }[] = []
    let cursorY = VIEWPORT_PAD_PX
    for (const page of pages) {
      const cssWidth = Math.max(1, page.width_pt * cssScale)
      const cssHeight = Math.max(1, page.height_pt * cssScale)
      items.push({ page, top: cursorY, cssWidth, cssHeight })
      cursorY += cssHeight + PAGE_GAP_PX
    }
    const totalHeight = Math.max(viewportSize.height, cursorY - (pages.length > 0 ? PAGE_GAP_PX : 0) + VIEWPORT_PAD_PX)
    return { items, totalHeight }
  }, [pages, cssScale, viewportSize.height])

  const { visibleStart, visibleEnd, activeVisiblePage } = useMemo(() => {
    const items = pageLayout.items
    if (items.length === 0) {
      return { visibleStart: 0, visibleEnd: -1, activeVisiblePage: 0 }
    }
    const viewTop = scrollTop
    const viewBottom = scrollTop + viewportSize.height
    const viewMid = scrollTop + viewportSize.height * 0.35

    let first = 0
    while (first < items.length - 1 && items[first]!.top + items[first]!.cssHeight < viewTop) {
      first++
    }
    let last = first
    while (last < items.length - 1 && items[last]!.top <= viewBottom) {
      last++
    }
    let current = first
    for (let i = first; i <= last; i++) {
      const entry = items[i]!
      if (entry.top <= viewMid) current = i
    }
    return {
      visibleStart: Math.max(0, first - 1),
      visibleEnd: Math.min(items.length - 1, last + 1),
      activeVisiblePage: current
    }
  }, [pageLayout.items, scrollTop, viewportSize.height])

  const scrollToRect = useCallback(
    (pageIndex: number, rect?: PageRect) => {
      const scroller = scrollerRef.current
      const entry = pageLayout.items[pageIndex]
      if (!scroller || !entry) return
      const targetTop = rect ? entry.top + rect.y * cssScale - 72 : entry.top - 16
      scroller.scrollTo({ top: Math.max(0, targetTop), behavior: 'instant' })
    },
    [pageLayout.items, cssScale]
  )

  // Apply initialPage / initialFind once pages have loaded.
  useEffect(() => {
    if ((status !== 'ready' && status !== 'read_only') || pages.length === 0) return
    const jumpKey = `${initialPage ?? ''}\0${initialFind ?? ''}`
    if ((initialPage === undefined && !initialFind) || appliedInitialJumpRef.current === jumpKey) {
      return
    }
    const target =
      initialPage === undefined ? undefined : Math.min(pages.length - 1, Math.max(0, Math.floor(initialPage) - 1))
    let cancelled = false
    void (async () => {
      const result = initialFind
        ? await model.read(engine =>
            findOfficeSearchMatch(
              initialFind,
              target,
              needle => (engine as WordEngine).find(needle, false),
              match => match.page_index
            )
          )
        : undefined
      if (cancelled) return
      appliedInitialJumpRef.current = jumpKey
      if (result) {
        const match = result.matches[result.index]!
        setFindQuery(result.needle)
        setFindMatchCase(false)
        setFindMatches(result.matches)
        setFindIndex(result.index)
        setFindOpen(true)
        scrollToRect(match.page_index, match.rects[0])
      } else if (target !== undefined) {
        scrollToRect(target)
      }
    })().catch(() => undefined)

    return () => {
      cancelled = true
    }
  }, [status, pages.length, initialPage, initialFind, model, scrollToRect])

  // Re-run find query when query, matchCase, or document version changes while Find is open.
  useEffect(() => {
    if (!findOpen) return
    const trimmed = findQuery.trim()
    if (!trimmed) {
      setFindMatches([])
      setFindIndex(0)
      return
    }
    let cancelled = false
    void model
      .read(eng => (eng as WordEngine).find(trimmed, findMatchCase))
      .then(matches => {
        if (cancelled || !matches) return
        setFindMatches(matches)
        setFindIndex(prev => (matches.length > 0 ? Math.min(prev, matches.length - 1) : 0))
      })
      .catch(() => undefined)
    return () => {
      cancelled = true
    }
  }, [findOpen, findQuery, findMatchCase, version, fontEpoch, model])

  // Rasterize visible pages (+ 1-page overscan) and cache bitmaps by (version, fontEpoch, scale, pageIndex).
  useEffect(() => {
    if (status === 'loading' || visibleEnd < visibleStart) return
    let cancelled = false
    const versionPrefix = `${version}:${fontEpoch}:${rasterScaleKey}:`

    // Drop bitmaps belonging to older document versions once cache grows beyond budget.
    if (bitmapCacheRef.current.size > BITMAP_CACHE_LIMIT) {
      for (const key of bitmapCacheRef.current.keys()) {
        if (!key.startsWith(versionPrefix)) {
          bitmapCacheRef.current.delete(key)
        }
        if (bitmapCacheRef.current.size <= BITMAP_CACHE_LIMIT / 2) break
      }
    }

    for (let pageIdx = visibleStart; pageIdx <= visibleEnd; pageIdx++) {
      const cacheKey = `${versionPrefix}${pageIdx}`
      if (bitmapCacheRef.current.has(cacheKey) || inflightRendersRef.current.has(cacheKey)) {
        continue
      }
      inflightRendersRef.current.add(cacheKey)
      void model
        .read(eng => (eng as WordEngine).renderPageRgba(pageIdx, rasterScale))
        .then(rendered => {
          inflightRendersRef.current.delete(cacheKey)
          if (cancelled || !rendered || rendered.width === 0 || rendered.height === 0) return
          const clamped =
            rendered.rgba.buffer instanceof ArrayBuffer
              ? new Uint8ClampedArray(rendered.rgba.buffer, rendered.rgba.byteOffset, rendered.rgba.byteLength)
              : new Uint8ClampedArray(rendered.rgba)
          const imageData = new ImageData(clamped, rendered.width, rendered.height)
          bitmapCacheRef.current.set(cacheKey, imageData)
          if (bitmapCacheRef.current.size > BITMAP_CACHE_LIMIT) {
            const oldest = bitmapCacheRef.current.keys().next().value
            if (oldest !== undefined && oldest !== cacheKey) {
              bitmapCacheRef.current.delete(oldest)
            }
          }
          setBitmapTick(t0 => t0 + 1)
        })
        .catch(() => {
          inflightRendersRef.current.delete(cacheKey)
        })
    }

    return () => {
      cancelled = true
    }
  }, [status, visibleStart, visibleEnd, version, fontEpoch, rasterScale, rasterScaleKey, model])

  // Resolve collaborator selection rectangles and Presence soft block locks.
  useEffect(() => {
    if (members.length === 0 || status === 'loading') {
      setCollaboratorOverlays([])
      return
    }
    let cancelled = false
    void (async () => {
      const overlays: CollaboratorOverlay[] = []
      for (const member of members) {
        const selectionRects: PageRect[] = []
        const lockedBlocks: { story: WordStoryRef; block: number; rects: PageRect[] }[] = []
        const seenLocks = new Set<string>()

        for (const entry of member.selections) {
          const sel = entry.selection
          const rects = await model.read(eng => (eng as WordEngine).presenceSelectionRects(sel))
          if (cancelled) return
          if (rects) selectionRects.push(...rects)

          const isEditingUnit = entry.mode === 'editing'
          const story = (sel.story as WordStoryRef | undefined) ?? 'body'
          const block = typeof sel.block === 'number' ? sel.block : null
          if (isEditingUnit && block !== null) {
            const lockKey = `${storyRefKey(story)}:${block}`
            if (!seenLocks.has(lockKey)) {
              seenLocks.add(lockKey)
              const bRects = (await model.read(eng => (eng as WordEngine).blockRects(story, block))) ?? []
              if (cancelled) return
              lockedBlocks.push({ story, block, rects: bRects })
            }
          }
        }
        overlays.push({
          uid: member.uid,
          name: member.name,
          color: member.color,
          selectionRects,
          lockedBlocks
        })
      }
      if (!cancelled) setCollaboratorOverlays(overlays)
    })()

    return () => {
      cancelled = true
    }
  }, [members, version, fontEpoch, status, model])

  const findLockHolder = useCallback(
    (story: WordStoryRef, block: number | null): OfficeMember | undefined => {
      if (block === null) return undefined
      for (const member of model.members.peek()) {
        for (const entry of member.selections) {
          const isEditingUnit = entry.mode === 'editing'
          if (!isEditingUnit) continue
          const selStory = (entry.selection.story as WordStoryRef | undefined) ?? 'body'
          const selBlock = typeof entry.selection.block === 'number' ? entry.selection.block : null
          if (selBlock === block && sameStoryRef(selStory, story)) {
            return member
          }
        }
      }
      return undefined
    },
    [model]
  )

  const guardBlockUnlocked = useCallback((): boolean => {
    const snap = model.snapshot.peek()
    if (!snap) return false
    const holder = findLockHolder(snap.caretState.story, snap.caretState.block)
    if (holder) {
      toast.warning(
        t('pod.office.locked_unit_notice', {
          name: holder.name,
          unit: t('pod.word.block_target', { index: (snap.caretState.block ?? 0) + 1 })
        })
      )
      return false
    }
    return true
  }, [findLockHolder, model])

  const copyActiveSelection = useCallback(async () => {
    const encoded = model.read(eng => (eng as WordEngine).selectedClipboard())
    try {
      await navigator.clipboard.write([
        new ClipboardItem({
          'text/plain': encoded.then(clip => new Blob([clip?.text ?? ''], { type: 'text/plain' })),
          'text/html': encoded.then(clip => new Blob([clip?.html ?? ''], { type: 'text/html' }))
        })
      ])
    } catch {
      const clip = await encoded
      try {
        if (clip && clip.text) await navigator.clipboard.writeText(clip.text)
      } catch {
        toast.error(t('pod.office.copy_failed'))
      }
    }
  }, [model])

  const runDiscreteCommand = useCallback(
    async (commandId: string, params: Record<string, unknown> = {}, mutates = true): Promise<void> => {
      if (!mutates) {
        await model.updateSelection(async eng => {
          const prev = model.snapshot.peek()
          const next = await (eng as WordEngine).executeCommand(commandId, params)
          const movedUnit =
            model.editable.peek() &&
            model.hasDraft.peek() &&
            !model.composing.peek() &&
            prev !== undefined &&
            (!sameStoryRef(prev.caretState.story, next.caretState.story) ||
              prev.caretState.block !== next.caretState.block)
          return { snapshot: next, commitBefore: movedUnit }
        })
        return
      }
      if (!model.editable.peek()) return
      if (!guardBlockUnlocked()) return
      await model.mutate(async eng => {
        const next = await (eng as WordEngine).executeCommand(commandId, params)
        return { result: true, snapshot: next, commit: true }
      })
    },
    [guardBlockUnlocked, model]
  )

  const pageCoordsFromEvent = (
    event: PointerEvent<HTMLDivElement>,
    page: WordPageInfo
  ): { xPt: number; yPt: number } => {
    const rect = event.currentTarget.getBoundingClientRect()
    const rawX = (event.clientX - rect.left) / cssScale
    const rawY = (event.clientY - rect.top) / cssScale
    return {
      xPt: Math.max(0, Math.min(page.width_pt, Number.isFinite(rawX) ? rawX : 0)),
      yPt: Math.max(0, Math.min(page.height_pt, Number.isFinite(rawY) ? rawY : 0))
    }
  }

  const handlePagePointerDown = (event: PointerEvent<HTMLDivElement>, page: WordPageInfo) => {
    if (event.button !== 0) return
    const { xPt, yPt } = pageCoordsFromEvent(event, page)
    const clicks = Math.min(3, Math.max(1, event.detail || 1))
    event.currentTarget.setPointerCapture(event.pointerId)
    pointerGestureRef.current = {
      active: true,
      moved: false,
      moveInFlight: false
    }

    const hadDraftBefore = model.hasDraft.peek()
    let clickedLink: string | undefined
    void model
      .updateSelection(async eng => {
        const prev = model.snapshot.peek()
        const next = await (eng as WordEngine).pointerDown(page.index, xPt, yPt, clicks, event.shiftKey, event.altKey)
        clickedLink = next.caretState.link
        const movedUnit =
          model.editable.peek() &&
          model.hasDraft.peek() &&
          !model.composing.peek() &&
          prev !== undefined &&
          (!sameStoryRef(prev.caretState.story, next.caretState.story) ||
            prev.caretState.block !== next.caretState.block)
        return { snapshot: next, commitBefore: movedUnit }
      })
      .then(next => {
        if (!next) return
        const link = next.caretState.link ?? clickedLink
        if ((event.metaKey || event.ctrlKey) && link) {
          window.open(link, '_blank', 'noopener,noreferrer')
        }
        if (model.editable.peek() && !hadDraftBefore && next.editing) {
          void model.commitNow()
        }
      })

    editorInputRef.current?.focus({ preventScroll: true })
  }

  const flushPointerMove = useCallback(async () => {
    const state = pointerGestureRef.current
    if (state.moveInFlight || !state.queuedMove) return
    state.moveInFlight = true
    while (state.queuedMove && state.active) {
      const target = state.queuedMove
      state.queuedMove = undefined
      await model.updateSelection(async eng => ({
        snapshot: await (eng as WordEngine).pointerMove(target.pageIndex, target.xPt, target.yPt)
      }))
    }
    state.moveInFlight = false
  }, [model])

  const handlePagePointerMove = (event: PointerEvent<HTMLDivElement>, page: WordPageInfo) => {
    const state = pointerGestureRef.current
    if (!state.active || (event.buttons & 1) === 0) return
    state.moved = true
    const { xPt, yPt } = pageCoordsFromEvent(event, page)
    state.queuedMove = { pageIndex: page.index, xPt, yPt }
    void flushPointerMove()
  }

  const handlePagePointerUp = (event: PointerEvent<HTMLDivElement>, page: WordPageInfo) => {
    const state = pointerGestureRef.current
    if (!state.active) return
    const wasMoved = state.moved
    state.active = false
    state.queuedMove = undefined
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }
    const { xPt, yPt } = pageCoordsFromEvent(event, page)
    const hadDraftBefore = model.hasDraft.peek()
    void model
      .updateSelection(async eng => ({
        snapshot: await (eng as WordEngine).pointerUp(page.index, xPt, yPt)
      }))
      .then(next => {
        if (model.editable.peek() && next?.editing && (!hadDraftBefore || wasMoved)) {
          void model.commitNow()
        }
      })
  }

  const handleCompositionStart = () => {
    if (!model.editable.peek()) return
    if (!guardBlockUnlocked()) {
      blockedCompositionRef.current = true
      if (editorInputRef.current) editorInputRef.current.value = ''
      return
    }
    blockedCompositionRef.current = false
    composingRef.current = true
    model.setExternalComposition(true)
  }

  const handleCompositionUpdate = (event: CompositionEvent<HTMLTextAreaElement>) => {
    if (blockedCompositionRef.current || !model.editable.peek()) return
    const text = event.data ?? event.currentTarget.value
    const selStart = event.currentTarget.selectionStart ?? text.length
    const selEnd = event.currentTarget.selectionEnd ?? selStart
    const startByte = utf8ByteOffset(text, selStart)
    const endByte = utf8ByteOffset(text, selEnd)
    void model.mutate(async eng => ({
      result: true,
      snapshot: await (eng as WordEngine).imePreedit(text, startByte, endByte)
    }))
  }

  const handleCompositionEnd = (event: CompositionEvent<HTMLTextAreaElement>) => {
    const wasBlocked = blockedCompositionRef.current
    blockedCompositionRef.current = false
    if (composingRef.current) model.setExternalComposition(false)
    composingRef.current = false
    const committedText = event.data ?? event.currentTarget.value
    event.currentTarget.value = ''
    if (wasBlocked || !model.editable.peek()) return
    void model.mutate(async eng => ({
      result: true,
      snapshot: committedText
        ? await (eng as WordEngine).imeCommit(committedText)
        : await (eng as WordEngine).imeCancel()
    }))
  }

  const handleEditorInput = (event: FormEvent<HTMLTextAreaElement>) => {
    const native = event.nativeEvent as InputEvent | undefined
    if (composingRef.current || native?.isComposing) return
    const value = event.currentTarget.value
    event.currentTarget.value = ''
    if (!value || !model.editable.peek()) return
    if (!guardBlockUnlocked()) return
    void model.mutate(async eng => ({
      result: true,
      snapshot: await (eng as WordEngine).insertText(value)
    }))
  }

  const openFind = useCallback(() => {
    setFindOpen(true)
    requestAnimationFrame(() => {
      findInputRef.current?.focus()
      findInputRef.current?.select()
    })
  }, [])

  const handleEditorKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.nativeEvent.isComposing || composingRef.current || event.key === 'Process' || event.keyCode === 229) {
      return
    }

    const ctrlOrMeta = event.metaKey || event.ctrlKey
    const lower = event.key.toLowerCase()

    if (ctrlOrMeta && !event.altKey && !event.shiftKey && lower === 'f') {
      event.preventDefault()
      openFind()
      return
    }
    if (ctrlOrMeta && !event.altKey && !event.shiftKey && lower === 's') {
      event.preventDefault()
      if (model.editable.peek()) void model.commitNow()
      return
    }
    if (ctrlOrMeta && !event.altKey && !event.shiftKey && lower === 'z') {
      event.preventDefault()
      if (model.editable.peek()) void model.undo()
      return
    }
    if (ctrlOrMeta && !event.altKey && ((lower === 'y' && !event.shiftKey) || (lower === 'z' && event.shiftKey))) {
      event.preventDefault()
      if (model.editable.peek()) void model.redo()
      return
    }

    // Native clipboard events (`onCopy`, `onCut`, `onPaste`) handle Mod+C / Mod+X / Mod+V.
    if (ctrlOrMeta && !event.altKey && (lower === 'c' || lower === 'x' || lower === 'v')) {
      return
    }

    const isPureNavigation =
      NAVIGATION_KEYS.has(event.key) ||
      event.key === 'Escape' ||
      (ctrlOrMeta && !event.altKey && !event.shiftKey && lower === 'a')

    if (isPureNavigation) {
      event.preventDefault()
      void model.updateSelection(async eng => {
        const prev = model.snapshot.peek()
        const res = await (eng as WordEngine).keyEvent(event.key, ctrlOrMeta, event.shiftKey, event.altKey)
        const movedUnit =
          model.editable.peek() &&
          model.hasDraft.peek() &&
          !model.composing.peek() &&
          prev !== undefined &&
          (!sameStoryRef(prev.caretState.story, res.snapshot.caretState.story) ||
            prev.caretState.block !== res.snapshot.caretState.block)
        return { snapshot: res.snapshot, commitBefore: movedUnit }
      })
      return
    }

    // Printable character typing without Ctrl/Meta/Alt flows through `onInput` / IME events.
    if (!ctrlOrMeta && !event.altKey && event.key.length === 1) {
      return
    }

    if (!model.editable.peek()) return

    const isMutatingOrShortcut =
      event.key === 'Backspace' ||
      event.key === 'Delete' ||
      event.key === 'Enter' ||
      event.key === 'Tab' ||
      ctrlOrMeta ||
      event.altKey ||
      event.key.startsWith('F')

    if (!isMutatingOrShortcut) return

    event.preventDefault()
    if (!guardBlockUnlocked()) return

    const key = event.key
    const shift = event.shiftKey
    const alt = event.altKey
    void model.mutate(async eng => {
      const prev = model.snapshot.peek()
      const hadDraft = model.hasDraft.peek()
      const res = await (eng as WordEngine).keyEvent(key, ctrlOrMeta, shift, alt)
      const movedUnit =
        hadDraft &&
        prev !== undefined &&
        (!sameStoryRef(prev.caretState.story, res.snapshot.caretState.story) ||
          prev.caretState.block !== res.snapshot.caretState.block)
      return {
        result: res,
        snapshot: res.snapshot,
        commit: Boolean(res.requestCommit) || movedUnit
      }
    })
  }

  const handleCopy = (event: ClipboardEvent<HTMLTextAreaElement>) => {
    event.preventDefault()
    void copyActiveSelection()
  }

  const handleCut = (event: ClipboardEvent<HTMLTextAreaElement>) => {
    event.preventDefault()
    if (!model.editable.peek()) return
    if (!guardBlockUnlocked()) return
    void (async () => {
      await copyActiveSelection()
      await model.mutate(async eng => ({
        result: true,
        snapshot: await (eng as WordEngine).executeCommand('edit.cut', {}),
        commit: true
      }))
    })()
  }

  const handlePaste = (event: ClipboardEvent<HTMLTextAreaElement>) => {
    if (!model.editable.peek()) return
    event.preventDefault()
    if (!guardBlockUnlocked()) return

    const items = Array.from(event.clipboardData.items ?? [])
    const imageItem = items.find(item => item.kind === 'file' && item.type.startsWith('image/'))
    const imageFile =
      imageItem?.getAsFile() ?? Array.from(event.clipboardData.files ?? []).find(file => file.type.startsWith('image/'))

    if (imageFile) {
      if (imageFile.size === 0 || imageFile.size > MAX_WORD_PICTURE_BYTES) {
        toast.error(t('pod.word.picture_too_large'))
        return
      }
      void (async () => {
        try {
          const bytes = new Uint8Array(await imageFile.arrayBuffer())
          if (bytes.byteLength === 0 || bytes.byteLength > MAX_WORD_PICTURE_BYTES) {
            toast.error(t('pod.word.picture_too_large'))
            return
          }
          const data = bytesToBase64(bytes)
          const alt = imageFile.name.replace(/\.[^.]+$/, '')
          await model.mutate(async eng => ({
            result: true,
            snapshot: await (eng as WordEngine).executeCommand('insert.picture', {
              data,
              ...(alt ? { alt } : {})
            }),
            commit: true
          }))
        } catch {
          toast.error(t('pod.word.picture_too_large'))
        }
      })()
      return
    }

    const html = event.clipboardData.getData('text/html')
    const text = event.clipboardData.getData('text/plain')
    if (!html && !text) return

    void model.mutate(async eng => {
      const wordEng = eng as WordEngine
      if (html.trim()) {
        try {
          const snap = await wordEng.executeCommand('edit.paste', { text, html })
          return { result: true, snapshot: snap, commit: true }
        } catch {
          // Fall back to plain text insertion when HTML paste fails.
        }
      }
      const snap = await wordEng.insertText(text)
      return { result: true, snapshot: snap }
    })
  }

  const stepFindMatch = (direction: 1 | -1) => {
    if (findMatches.length === 0) return
    const nextIdx = (findIndex + direction + findMatches.length) % findMatches.length
    const match = findMatches[nextIdx]
    setFindIndex(nextIdx)
    if (match) {
      scrollToRect(match.page_index, match.rects[0])
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
    if (isNewerFormatError(model.error.value)) {
      return <ContentError error={new Error(t('pod.office.reload_newer_version'))} retry={model.retry} />
    }
    return <ContentError error={model.error.value} retry={model.retry} />
  }
  if (status === 'loading' && pages.length === 0) {
    return (
      <ContentSkeleton
        variant="page"
        label={preview ? t('pod.word.preview_loading') : t('pod.word.loading')}
        immediate
      />
    )
  }

  const caretRect = caretState?.caret_rect ?? null
  const selectionRects = caretState?.selection_rects ?? []
  const caretPageLayout = caretRect ? pageLayout.items[caretRect.page] : undefined

  const maxCanvasWidth = pageLayout.items.reduce((acc, item) => Math.max(acc, item.cssWidth), 0)

  return (
    <div className="space-y-3">
      {missingPictures.length > 0 && !missingDismissed && (
        <Alert variant="warning">
          <ErrorCircleRegular aria-hidden />
          <AlertDescription>
            {t('pod.word.missing_pictures_warning', { count: missingPictures.length })}
          </AlertDescription>
          <AlertAction>
            <Button
              size="icon-xs"
              variant="ghost"
              aria-label={t('common.close')}
              title={t('common.close')}
              onClick={() => setMissingDismissed(true)}>
              <DismissRegular />
            </Button>
          </AlertAction>
        </Alert>
      )}

      <div
        ref={workspaceRef}
        {...{ [WORD_WORKSPACE_ATTRIBUTE]: '' }}
        aria-busy={status === 'loading'}
        className={cn(
          'flex flex-col overflow-hidden rounded-control border border-border bg-background',
          preview ? 'h-[min(68vh,720px)] min-h-[360px]' : 'h-[min(80vh,900px)] min-h-[460px]'
        )}>
        <WordToolbar
          model={model}
          pageID={pageID}
          title={title}
          canEdit={canEdit}
          editorInput={editorInputRef}
          zoom={effectiveZoom}
          fitWidth={fitWidth}
          onZoomIn={() => {
            setFitWidth(false)
            setZoom(z => Math.min(ZOOM_MAX, Number((z + ZOOM_STEP).toFixed(2))))
          }}
          onZoomOut={() => {
            setFitWidth(false)
            setZoom(z => Math.max(ZOOM_MIN, Number((z - ZOOM_STEP).toFixed(2))))
          }}
          onZoomReset={() => {
            setFitWidth(false)
            setZoom(1)
          }}
          onToggleFitWidth={() => setFitWidth(f => !f)}
          onOpenFind={openFind}
          onRunCommand={runDiscreteCommand}
        />

        {findOpen && (
          <div className="flex flex-wrap items-center gap-2 border-b border-border bg-background-secondary px-3 py-1.5">
            <Input
              ref={findInputRef}
              aria-label={t('pod.office.find_what')}
              placeholder={t('pod.office.find_what')}
              className="h-7 w-56 max-w-full text-sm"
              value={findQuery}
              onChange={event => setFindQuery(event.target.value)}
              onKeyDown={event => {
                if (event.key === 'Enter') {
                  event.preventDefault()
                  stepFindMatch(event.shiftKey ? -1 : 1)
                } else if (event.key === 'Escape') {
                  event.preventDefault()
                  setFindOpen(false)
                  editorInputRef.current?.focus({ preventScroll: true })
                }
              }}
            />
            <Toggle
              size="sm"
              aria-label={t('pod.office.find_match_case')}
              title={t('pod.office.find_match_case')}
              pressed={findMatchCase}
              onPressedChange={setFindMatchCase}>
              Aa
            </Toggle>
            <span role="status" className="min-w-24 text-xs text-fg-secondary">
              {findQuery.trim()
                ? findMatches.length > 0
                  ? t('pod.office.find_position', {
                      index: findIndex + 1,
                      count: findMatches.length
                    })
                  : t('pod.office.find_none')
                : ''}
            </span>
            <div className="flex items-center gap-0.5">
              <Button
                size="icon-xs"
                variant="ghost"
                aria-label={t('pod.office.find_previous')}
                title={t('pod.office.find_previous')}
                disabled={findMatches.length === 0}
                onClick={() => stepFindMatch(-1)}>
                <ChevronUpRegular />
              </Button>
              <Button
                size="icon-xs"
                variant="ghost"
                aria-label={t('pod.office.find_next')}
                title={t('pod.office.find_next')}
                disabled={findMatches.length === 0}
                onClick={() => stepFindMatch(1)}>
                <ChevronDownRegular />
              </Button>
              <Button
                size="icon-xs"
                variant="ghost"
                aria-label={t('pod.office.close_find')}
                title={t('pod.office.close_find')}
                onClick={() => {
                  setFindOpen(false)
                  editorInputRef.current?.focus({ preventScroll: true })
                }}>
                <DismissRegular />
              </Button>
            </div>
          </div>
        )}

        <div
          ref={scrollerRef}
          role="region"
          aria-label={t('pod.word.canvas_label')}
          className="relative min-h-0 flex-1 overflow-auto bg-background-secondary/60 select-none"
          onScroll={event => setScrollTop(event.currentTarget.scrollTop)}
          onMouseDown={event => {
            if (event.target === event.currentTarget) {
              editorInputRef.current?.focus({ preventScroll: true })
            }
          }}>
          <div
            className="relative mx-auto"
            style={{
              height: pageLayout.totalHeight,
              minWidth: Math.max(viewportSize.width, maxCanvasWidth + VIEWPORT_PAD_PX * 2)
            }}>
            {/* Hidden textarea positioned at the active caret so native IME candidate windows anchor accurately. */}
            <textarea
              ref={editorInputRef}
              data-office-editor-input=""
              aria-label={t('pod.word.editor_input_label')}
              readOnly={!editable}
              spellCheck={false}
              autoCapitalize="off"
              autoComplete="off"
              autoCorrect="off"
              rows={1}
              className="pointer-events-none absolute z-20 m-0 h-4 w-px resize-none overflow-hidden border-0 bg-transparent p-0 opacity-0 outline-none"
              style={{
                top: caretPageLayout && caretRect ? caretPageLayout.top + caretRect.y * cssScale : scrollTop + 24,
                left:
                  caretPageLayout && caretRect
                    ? `calc(50% - ${caretPageLayout.cssWidth / 2}px + ${caretRect.x * cssScale}px)`
                    : '50%'
              }}
              onCompositionStart={handleCompositionStart}
              onCompositionUpdate={handleCompositionUpdate}
              onCompositionEnd={handleCompositionEnd}
              onInput={handleEditorInput}
              onKeyDown={handleEditorKeyDown}
              onCopy={handleCopy}
              onCut={handleCut}
              onPaste={handlePaste}
              onBlur={event => {
                const nextTarget = event.relatedTarget as Node | null
                if (nextTarget && workspaceRef.current?.contains(nextTarget)) return
                if (
                  nextTarget instanceof Element &&
                  nextTarget.closest(
                    '[data-slot="popover-content"], [data-slot="dropdown-menu-content"], [data-slot="select-content"], [data-slot="dialog-content"], [data-slot="drawer-content"]'
                  )
                ) {
                  return
                }
                if (model.editable.peek() && model.pending.peek() > 0 && !model.composing.peek()) {
                  void model.commitNow()
                }
                model.blur()
              }}
            />

            {pageLayout.items.map((entry, idx) => {
              const isVisible = idx >= visibleStart && idx <= visibleEnd
              const bitmap = isVisible
                ? (bitmapCacheRef.current.get(`${version}:${fontEpoch}:${rasterScaleKey}:${idx}`) ??
                  findFallbackBitmap(bitmapCacheRef.current, rasterScaleKey, idx))
                : undefined

              return (
                <div
                  key={entry.page.index}
                  role="group"
                  aria-label={t('pod.word.page_label', {
                    page: idx + 1,
                    count: pages.length
                  })}
                  className={cn(
                    'absolute left-1/2 -translate-x-1/2 bg-white shadow-sm ring-1 ring-border/70',
                    editable ? 'cursor-text' : 'cursor-default'
                  )}
                  style={{
                    top: entry.top,
                    width: entry.cssWidth,
                    height: entry.cssHeight
                  }}
                  onPointerDown={event => handlePagePointerDown(event, entry.page)}
                  onPointerMove={event => handlePagePointerMove(event, entry.page)}
                  onPointerUp={event => handlePagePointerUp(event, entry.page)}>
                  {isVisible && (
                    <>
                      <WordPageCanvas
                        bitmap={bitmap}
                        bitmapTick={bitmapTick}
                        cssWidth={entry.cssWidth}
                        cssHeight={entry.cssHeight}
                      />

                      {/* Find match highlights */}
                      {findOpen &&
                        findMatches.map((match, mIdx) =>
                          match.rects
                            .filter(rect => rect.page === idx)
                            .map((rect, rIdx) => (
                              <div
                                key={`find-${mIdx}-${rIdx}`}
                                aria-hidden
                                className={cn(
                                  'pointer-events-none absolute rounded-[2px]',
                                  mIdx === findIndex ? 'bg-amber-400/55 ring-1 ring-amber-600' : 'bg-yellow-300/40'
                                )}
                                style={{
                                  left: rect.x * cssScale,
                                  top: rect.y * cssScale,
                                  width: Math.max(2, rect.w * cssScale),
                                  height: Math.max(2, rect.h * cssScale)
                                }}
                              />
                            ))
                        )}

                      {/* Collaborator Presence soft block locks & selection highlights */}
                      {collaboratorOverlays.map(collab => (
                        <div key={collab.uid} aria-hidden className="pointer-events-none">
                          {collab.selectionRects
                            .filter(rect => rect.page === idx)
                            .map((rect, rIdx) => (
                              <div
                                key={`sel-${rIdx}`}
                                className="absolute"
                                style={{
                                  left: rect.x * cssScale,
                                  top: rect.y * cssScale,
                                  width: Math.max(2, rect.w * cssScale),
                                  height: Math.max(4, rect.h * cssScale),
                                  backgroundColor: `var(${collab.color})`,
                                  opacity: rect.w <= 2.5 ? 0.85 : 0.22
                                }}
                              />
                            ))}

                          {collab.lockedBlocks.map((locked, lIdx) => {
                            const pageRects = locked.rects.filter(rect => rect.page === idx)
                            return pageRects.map((rect, rIdx) => (
                              <div
                                key={`lock-${lIdx}-${rIdx}`}
                                className="absolute rounded-[3px]"
                                style={{
                                  left: Math.max(0, rect.x * cssScale - 3),
                                  top: Math.max(0, rect.y * cssScale - 2),
                                  width: rect.w * cssScale + 6,
                                  height: rect.h * cssScale + 4,
                                  border: `1.5px dashed var(${collab.color})`
                                }}>
                                {rIdx === 0 && (
                                  <span
                                    className="absolute -top-5 right-0 rounded-xs px-1.5 py-0.5 text-[10px] leading-none font-medium whitespace-nowrap text-white shadow-xs"
                                    style={{ backgroundColor: `var(${collab.color})` }}>
                                    {t('pod.office.locked_by', { name: collab.name })}
                                  </span>
                                )}
                              </div>
                            ))
                          })}
                        </div>
                      ))}

                      {/* Local selection highlight rectangles */}
                      {selectionRects
                        .filter(rect => rect.page === idx)
                        .map((rect, rIdx) => (
                          <div
                            key={`local-sel-${rIdx}`}
                            aria-hidden
                            className="pointer-events-none absolute bg-blue-60/22"
                            style={{
                              left: rect.x * cssScale,
                              top: rect.y * cssScale,
                              width: Math.max(2, rect.w * cssScale),
                              height: Math.max(2, rect.h * cssScale)
                            }}
                          />
                        ))}

                      {/* Active blinking caret */}
                      {editable && selectionRects.length === 0 && caretRect && caretRect.page === idx && (
                        <div
                          aria-hidden
                          className="pointer-events-none absolute w-[2px] animate-pulse bg-blue-60"
                          style={{
                            left: caretRect.x * cssScale,
                            top: caretRect.y * cssScale,
                            height: Math.max(12, caretRect.h * cssScale)
                          }}
                        />
                      )}
                    </>
                  )}
                </div>
              )
            })}
          </div>

          {pages.length > 0 && (
            <div className="pointer-events-none sticky bottom-2 left-0 flex justify-end px-3">
              <span className="rounded-control border border-border bg-background/90 px-2 py-0.5 text-xs text-fg-secondary shadow-xs backdrop-blur-xs">
                {t('pod.word.page_label', {
                  page: activeVisiblePage + 1,
                  count: pages.length
                })}
              </span>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

function findFallbackBitmap(
  cache: Map<string, ImageData>,
  rasterScaleKey: string,
  pageIndex: number
): ImageData | undefined {
  const suffix = `:${rasterScaleKey}:${pageIndex}`
  let found: ImageData | undefined
  for (const [key, value] of cache.entries()) {
    if (key.endsWith(suffix)) {
      found = value
    }
  }
  return found
}

function WordPageCanvas({
  bitmap,
  bitmapTick,
  cssWidth,
  cssHeight
}: {
  bitmap: ImageData | undefined
  bitmapTick: number
  cssWidth: number
  cssHeight: number
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    void bitmapTick
    const canvas = canvasRef.current
    if (!canvas || !bitmap) return
    if (canvas.width !== bitmap.width) canvas.width = bitmap.width
    if (canvas.height !== bitmap.height) canvas.height = bitmap.height
    const ctx = canvas.getContext('2d')
    if (!ctx) return
    ctx.putImageData(bitmap, 0, 0)
  }, [bitmap, bitmapTick])

  return (
    <canvas
      ref={canvasRef}
      aria-hidden
      className="pointer-events-none block"
      style={{ width: cssWidth, height: cssHeight }}
    />
  )
}
