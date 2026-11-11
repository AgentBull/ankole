import { Button, Input } from '@ankole/uikit'
import { ChevronDownRegular, ChevronUpRegular, DismissRegular } from '@ankole/uikit/icons'
import { useEffect, useRef, useState, type KeyboardEvent, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import {
  collectRawMatchSpans,
  normalizeSearchQuery,
  normalizeSearchText,
  resolveFindNeedleSets,
  type NormalizedSearchText
} from './search-targets'

const HIDDEN_ELEMENT_SELECTOR =
  'button, script, style, noscript, template, [aria-hidden="true"], [hidden], .pod-chat-find, .pod-page-find'

const BLOCK_BOUNDARY_TAGS = new Set([
  'ADDRESS',
  'ARTICLE',
  'ASIDE',
  'BLOCKQUOTE',
  'BR',
  'DD',
  'DETAILS',
  'DIALOG',
  'DIV',
  'DL',
  'DT',
  'FIELDSET',
  'FIGCAPTION',
  'FIGURE',
  'FOOTER',
  'FORM',
  'H1',
  'H2',
  'H3',
  'H4',
  'H5',
  'H6',
  'HEADER',
  'HGROUP',
  'HR',
  'LI',
  'MAIN',
  'NAV',
  'OL',
  'P',
  'PRE',
  'SECTION',
  'SUMMARY',
  'TABLE',
  'TBODY',
  'TD',
  'TFOOT',
  'TH',
  'THEAD',
  'TR',
  'UL'
])

type IndexedTextSegment = {
  node: Text
  start: number
  end: number
}

export type SearchableTextIndex = {
  segments: IndexedTextSegment[]
  normalized: NormalizedSearchText
}

export function isImeComposingKey(event: KeyboardEvent<HTMLElement>): boolean {
  return event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229
}

const OPEN_OVERLAY_SELECTOR =
  '[data-slot="dialog-content"]:not([data-ending-style]), [data-slot="sheet-content"]:not([data-ending-style]), [role="dialog"]:not([data-ending-style]), [role="alertdialog"]:not([data-ending-style]), [aria-modal="true"]:not([data-ending-style])'

const SEPARATE_SHORTCUT_REGION_SELECTOR =
  '[role="dialog"], [role="alertdialog"], [aria-modal="true"], .pod-page-chat, .pod-page-chat-sheet, .pod-chat'

function isPassiveNavigationFocus(element: Element, ownerDoc: Document): boolean {
  if (element === ownerDoc.body || element === ownerDoc.documentElement) return true
  if (!element.closest('[data-sidebar]')) return false
  return !element.matches('input, textarea, select, [contenteditable="true"]')
}

function isElementLike(value: unknown): value is Element {
  return typeof value === 'object' && value !== null && typeof (value as Element).closest === 'function'
}

export function shouldHandlePageFindShortcut(
  event: Pick<
    globalThis.KeyboardEvent,
    'key' | 'metaKey' | 'ctrlKey' | 'shiftKey' | 'altKey' | 'isComposing' | 'defaultPrevented' | 'repeat' | 'target'
  >,
  pageColumn: HTMLElement | null,
  activeElement: Element | null = typeof document !== 'undefined' ? document.activeElement : null
): boolean {
  if (event.defaultPrevented || event.isComposing || event.repeat) return false
  if (!(event.metaKey || event.ctrlKey) || event.shiftKey || event.altKey) return false
  if (event.key.toLowerCase() !== 'f') return false
  if (!pageColumn || !pageColumn.isConnected) return false

  const ownerDoc = pageColumn.ownerDocument
  if (ownerDoc.querySelector(OPEN_OVERLAY_SELECTOR)) return false

  const targetEl = isElementLike(event.target) ? event.target : null
  if (targetEl?.closest(SEPARATE_SHORTCUT_REGION_SELECTOR)) return false
  if (activeElement?.closest(SEPARATE_SHORTCUT_REGION_SELECTOR)) return false

  if (targetEl && !pageColumn.contains(targetEl) && !isPassiveNavigationFocus(targetEl, ownerDoc)) {
    return false
  }
  if (activeElement && !pageColumn.contains(activeElement) && !isPassiveNavigationFocus(activeElement, ownerDoc)) {
    return false
  }
  return true
}

export function readSingleLineSelectionInContainer(
  container: HTMLElement | null,
  excludeSelector = '.pod-page-find, .pod-chat-find, .pod-chat-composer'
): string | undefined {
  if (!container || typeof window === 'undefined' || typeof window.getSelection !== 'function') return undefined
  const selection = window.getSelection()
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return undefined
  const range = selection.getRangeAt(0)
  const ancestor = range.commonAncestorContainer
  const ancestorEl = isElementLike(ancestor) ? ancestor : ancestor.parentElement
  if (!ancestorEl || !container.contains(ancestorEl)) return undefined
  if (excludeSelector && ancestorEl.closest(excludeSelector)) return undefined
  const raw = selection.toString().trim()
  if (!raw || raw.length > 120 || /[\r\n]/.test(raw)) return undefined
  return raw
}

function isBlockBoundaryElement(element: Element): boolean {
  return BLOCK_BOUNDARY_TAGS.has(element.tagName.toUpperCase()) || element.hasAttribute('data-file-line')
}

function isSkippedElement(element: Element): boolean {
  if (element.matches(HIDDEN_ELEMENT_SELECTOR)) return true
  const parent = element.parentElement
  if (
    parent &&
    parent.tagName.toUpperCase() === 'DETAILS' &&
    !(parent as HTMLDetailsElement).open &&
    element.tagName.toUpperCase() !== 'SUMMARY'
  ) {
    return true
  }
  return false
}

export function buildSearchableTextIndex(container: Element): SearchableTextIndex {
  const segments: IndexedTextSegment[] = []
  let rawText = ''
  let pendingBoundary = false

  const visit = (node: Node) => {
    if (node.nodeType === 3) {
      const content = node.textContent ?? ''
      if (!content) return
      if (pendingBoundary) {
        if (rawText.length > 0 && !/\s$/.test(rawText) && !/^\s/.test(content)) {
          rawText += ' '
        }
        pendingBoundary = false
      }
      const start = rawText.length
      rawText += content
      segments.push({ node: node as Text, start, end: rawText.length })
      return
    }
    if (node.nodeType !== 1) return
    const element = node as Element
    if (element !== container && isSkippedElement(element)) return
    const isBoundary = element !== container && isBlockBoundaryElement(element)
    if (isBoundary) pendingBoundary = true
    for (let child = element.firstChild; child; child = child.nextSibling) {
      visit(child)
    }
    if (isBoundary) pendingBoundary = true
  }

  visit(container)

  return {
    segments,
    normalized: rawText
      ? normalizeSearchText(rawText)
      : { text: '', rawStart: new Uint32Array(0), rawEnd: new Uint32Array(0) }
  }
}

function findFirstSegmentAfter(segments: readonly IndexedTextSegment[], rawOffset: number): number {
  let lo = 0
  let hi = segments.length - 1
  let ans = -1
  while (lo <= hi) {
    const mid = (lo + hi) >>> 1
    if (segments[mid]!.end > rawOffset) {
      ans = mid
      hi = mid - 1
    } else {
      lo = mid + 1
    }
  }
  return ans
}

function findLastSegmentBefore(segments: readonly IndexedTextSegment[], rawOffset: number): number {
  let lo = 0
  let hi = segments.length - 1
  let ans = -1
  while (lo <= hi) {
    const mid = (lo + hi) >>> 1
    if (segments[mid]!.start < rawOffset) {
      ans = mid
      lo = mid + 1
    } else {
      hi = mid - 1
    }
  }
  return ans
}

export function collectRangesFromTextIndex(
  index: SearchableTextIndex,
  query: string,
  options?: { searchSyntax?: boolean }
): Range[] {
  const { primary, fallback } = resolveFindNeedleSets(query, options)
  if (!index.normalized.text || primary.length === 0) return []
  let spans = collectRawMatchSpans(index.normalized, primary)
  if (spans.length === 0 && fallback.length > 0) {
    spans = collectRawMatchSpans(index.normalized, fallback)
  }
  if (spans.length === 0) return []
  const doc = index.segments[0]?.node.ownerDocument ?? (typeof document !== 'undefined' ? document : undefined)
  if (!doc) return []
  const ranges: Range[] = []
  for (const span of spans) {
    const startIdx = findFirstSegmentAfter(index.segments, span.start)
    const endIdx = findLastSegmentBefore(index.segments, span.end)
    if (startIdx < 0 || endIdx < 0 || startIdx > endIdx) continue
    const startSeg = index.segments[startIdx]!
    const endSeg = index.segments[endIdx]!
    const startOffset = Math.max(0, Math.min(startSeg.node.length, span.start - startSeg.start))
    const endOffset = Math.max(0, Math.min(endSeg.node.length, span.end - endSeg.start))
    if (startIdx === endIdx && endOffset <= startOffset) continue
    const range = doc.createRange()
    range.setStart(startSeg.node, startOffset)
    range.setEnd(endSeg.node, endOffset)
    ranges.push(range)
  }
  return ranges
}

export function applyCustomHighlights(
  baseKey: string,
  currentKey: string,
  ranges: readonly Range[],
  currentIndex: number
): void {
  if (typeof CSS === 'undefined' || !('highlights' in CSS) || typeof Highlight === 'undefined') return
  if (!ranges.length) {
    CSS.highlights.delete(baseKey)
    CSS.highlights.delete(currentKey)
    return
  }
  const all = new Highlight(...ranges)
  all.priority = 0
  const active = new Highlight(...ranges.slice(currentIndex, currentIndex + 1))
  active.priority = 1
  CSS.highlights.set(baseKey, all)
  CSS.highlights.set(currentKey, active)
}

export function updateActiveHighlight(
  baseKey: string,
  currentKey: string,
  ranges: readonly Range[],
  currentIndex: number
): void {
  if (typeof CSS === 'undefined' || !('highlights' in CSS) || typeof Highlight === 'undefined') return
  if (!ranges.length) {
    CSS.highlights.delete(baseKey)
    CSS.highlights.delete(currentKey)
    return
  }
  if (!CSS.highlights.has(baseKey)) {
    const all = new Highlight(...ranges)
    all.priority = 0
    CSS.highlights.set(baseKey, all)
  }
  const active = new Highlight(...ranges.slice(currentIndex, currentIndex + 1))
  active.priority = 1
  CSS.highlights.set(currentKey, active)
}

export function clearCustomHighlights(baseKey: string, currentKey: string): void {
  if (typeof CSS === 'undefined' || !('highlights' in CSS)) return
  CSS.highlights.delete(baseKey)
  CSS.highlights.delete(currentKey)
}

export type UseDomFindControllerOptions = {
  root: RefObject<HTMLElement | null>
  inputRef?: RefObject<HTMLInputElement | null>
  initialQuery?: string
  seededQuery?: string
  focusTrigger?: number
  targetKey?: string
  highlightKeys: readonly [baseKey: string, currentKey: string]
  attributeFilter?: string[]
  debounceMs?: number
  invalidateCache: () => void
  collectRanges: (element: HTMLElement, query: string, step: 'new' | 'refresh' | number) => Range[]
  resolveInitialIndex?: (
    element: HTMLElement,
    ranges: readonly Range[],
    step: 'new' | 'refresh' | number
  ) => number | undefined
  scrollToRange: (range: Range) => void
}

export function useDomFindController({
  root,
  inputRef: externalInputRef,
  initialQuery = '',
  seededQuery,
  focusTrigger = 0,
  targetKey,
  highlightKeys: [baseKey, currentKey],
  attributeFilter = ['open', 'hidden', 'aria-hidden', 'class'],
  debounceMs = 120,
  invalidateCache,
  collectRanges,
  resolveInitialIndex,
  scrollToRange
}: UseDomFindControllerOptions) {
  const internalInputRef = useRef<HTMLInputElement>(null)
  const inputRef = externalInputRef ?? internalInputRef
  const [query, setQuery] = useState(seededQuery || initialQuery)
  const [index, setIndex] = useState(0)
  const [count, setCount] = useState(0)
  const indexRef = useRef(0)
  const selected = useRef<Range | undefined>(undefined)
  const located = useRef(false)
  const rangesRef = useRef<Range[]>([])

  useEffect(() => {
    if (!initialQuery) return
    setQuery(initialQuery)
    located.current = false
  }, [initialQuery])

  useEffect(() => {
    if (!focusTrigger) return
    if (seededQuery) {
      setQuery(seededQuery)
      located.current = false
    }
    const input = inputRef.current
    if (input) {
      input.focus()
      requestAnimationFrame(() => input.select())
    }
  }, [focusTrigger, inputRef, seededQuery])

  useEffect(() => {
    located.current = false
  }, [targetKey])

  const search = (step: number | 'new' | 'refresh') => {
    const element = root.current
    if (!element || !query.trim()) {
      rangesRef.current = []
      indexRef.current = 0
      selected.current = undefined
      setIndex(0)
      setCount(0)
      clearCustomHighlights(baseKey, currentKey)
      return
    }

    if (
      typeof step === 'number' &&
      rangesRef.current.length > 0 &&
      rangesRef.current.every(range => range.startContainer.isConnected)
    ) {
      const ranges = rangesRef.current
      const next = (indexRef.current + step + ranges.length) % ranges.length
      indexRef.current = next
      selected.current = ranges[next]
      located.current = true
      setIndex(next)
      updateActiveHighlight(baseKey, currentKey, ranges, next)
      if (ranges[next]) scrollToRange(ranges[next]!)
      return
    }

    if (step === 'refresh') {
      invalidateCache()
    }
    const ranges = collectRanges(element, query, step)
    rangesRef.current = ranges

    const current = selected.current
    const retained = current
      ? ranges.findIndex(
          range =>
            range.startContainer === current.startContainer &&
            range.startOffset === current.startOffset &&
            range.endContainer === current.endContainer &&
            range.endOffset === current.endOffset
        )
      : -1
    let next = retained >= 0 ? retained : Math.min(indexRef.current, Math.max(0, ranges.length - 1))
    if (step === 'new') {
      located.current = false
      next = 0
    } else if (typeof step === 'number' && ranges.length) {
      next = (next + step + ranges.length) % ranges.length
    }

    if (!located.current && ranges.length > 0 && resolveInitialIndex) {
      const resolved = resolveInitialIndex(element, ranges, step)
      if (resolved !== undefined && resolved >= 0 && resolved < ranges.length) {
        next = resolved
      }
    }

    indexRef.current = next
    selected.current = ranges[next]
    const firstMatch = !located.current && Boolean(ranges[next])
    if (ranges[next]) located.current = true
    setIndex(next)
    setCount(ranges.length)
    applyCustomHighlights(baseKey, currentKey, ranges, next)
    if ((step !== 'refresh' || firstMatch) && ranges[next]) {
      scrollToRange(ranges[next]!)
    }
  }

  const searchRef = useRef(search)
  searchRef.current = search

  const invalidateRef = useRef(invalidateCache)
  invalidateRef.current = invalidateCache

  useEffect(() => {
    searchRef.current('new')
  }, [query, targetKey])

  useEffect(() => {
    const element = root.current
    if (!element) return
    invalidateRef.current()
    let timer: ReturnType<typeof setTimeout> | undefined
    const observer = new MutationObserver(() => {
      invalidateRef.current()
      timer ??= setTimeout(() => {
        timer = undefined
        searchRef.current('refresh')
      }, debounceMs)
    })
    observer.observe(element, {
      characterData: true,
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter
    })
    return () => {
      observer.disconnect()
      clearTimeout(timer)
      clearCustomHighlights(baseKey, currentKey)
    }
  }, [baseKey, currentKey, debounceMs, root])

  return {
    query,
    setQuery,
    index,
    count,
    inputRef,
    search
  }
}

function findHeadingElement(root: HTMLElement, headingText: string): HTMLElement | undefined {
  const normalized = normalizeSearchQuery(headingText.trim())
  if (!normalized) return undefined
  const candidates = root.querySelectorAll<HTMLElement>('h1, h2, h3, h4, h5, h6, [data-heading]')
  let prefixMatch: HTMLElement | undefined
  for (const el of candidates) {
    const text = normalizeSearchQuery((el.textContent ?? '').trim())
    if (!text) continue
    if (text === normalized) return el
    if (!prefixMatch && text.includes(normalized)) prefixMatch = el
  }
  return prefixMatch
}

function scrollRangeIntoView(range: Range): void {
  const parent = range.startContainer.parentElement
  if (!parent) return
  if (typeof parent.scrollIntoView === 'function') {
    parent.scrollIntoView({ block: 'center', inline: 'nearest' })
  }
}

export function PageFindBar({
  root,
  initialQuery = '',
  seededQuery,
  focusTrigger = 0,
  targetHeading,
  autoFocus = false,
  onBeforeSearch,
  onClose
}: {
  root: RefObject<HTMLElement | null>
  initialQuery?: string
  seededQuery?: string
  focusTrigger?: number
  targetHeading?: string
  autoFocus?: boolean
  onBeforeSearch?: () => boolean | void
  onClose: () => void
}) {
  const { t } = useTranslation()
  const pendingHeading = useRef(targetHeading)
  const textIndexRef = useRef<SearchableTextIndex | null>(null)

  useEffect(() => {
    pendingHeading.current = targetHeading
  }, [targetHeading])

  const { query, setQuery, index, count, inputRef, search } = useDomFindController({
    root,
    initialQuery,
    seededQuery,
    focusTrigger,
    targetKey: targetHeading ?? '',
    highlightKeys: ['pod-page-find', 'pod-page-find-current'],
    invalidateCache: () => {
      textIndexRef.current = null
    },
    collectRanges: (element, activeQuery) => {
      if (onBeforeSearch?.()) {
        textIndexRef.current = null
      }
      textIndexRef.current ??= buildSearchableTextIndex(element)
      return collectRangesFromTextIndex(textIndexRef.current, activeQuery, {
        searchSyntax: Boolean(initialQuery) && activeQuery === initialQuery
      })
    },
    resolveInitialIndex: (element, ranges) => {
      if (!pendingHeading.current) return 0
      const headingEl = findHeadingElement(element, pendingHeading.current)
      if (!headingEl) return 0
      const afterHeading = ranges.findIndex(range => {
        const relation = headingEl.compareDocumentPosition(range.startContainer)
        return headingEl.contains(range.startContainer) || Boolean(relation & Node.DOCUMENT_POSITION_FOLLOWING)
      })
      pendingHeading.current = undefined
      return afterHeading >= 0 ? afterHeading : 0
    },
    scrollToRange: scrollRangeIntoView
  })

  return (
    <div className="pod-page-find" role="search" data-page-find-bar="">
      <Input
        ref={inputRef}
        variant="overlay"
        autoFocus={autoFocus}
        value={query}
        autoCorrect="off"
        autoCapitalize="off"
        spellCheck={false}
        aria-label={t('pod.content.find_in_page')}
        placeholder={t('pod.content.find_in_page')}
        onChange={event => setQuery(event.target.value)}
        onKeyDown={event => {
          if (isImeComposingKey(event)) return
          if (event.key === 'Escape') {
            event.stopPropagation()
            onClose()
          }
          if (event.key === 'Enter') {
            event.preventDefault()
            search(event.shiftKey ? -1 : 1)
          }
        }}
      />
      <span aria-live="polite">
        {count ? index + 1 : 0}/{count}
      </span>
      <Button
        size="icon-xs"
        variant="ghost"
        disabled={!count}
        aria-label={t('pod.content.find_previous')}
        onClick={() => search(-1)}>
        <ChevronUpRegular aria-hidden />
      </Button>
      <Button
        size="icon-xs"
        variant="ghost"
        disabled={!count}
        aria-label={t('pod.content.find_next')}
        onClick={() => search(1)}>
        <ChevronDownRegular aria-hidden />
      </Button>
      <Button size="icon-xs" variant="ghost" aria-label={t('pod.content.find_close')} onClick={onClose}>
        <DismissRegular aria-hidden />
      </Button>
    </div>
  )
}
