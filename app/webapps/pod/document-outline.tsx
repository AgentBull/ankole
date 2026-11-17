import { cn } from '@ankole/uikit'
import { useEffect, useId, useLayoutEffect, useRef, useState, type MouseEvent, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'

export type OutlineHeading = {
  id: string
  index: number
  level: 1 | 2 | 3
  depth: 0 | 1 | 2
  title: string
  element: HTMLElement
}

const HEADING_SELECTOR = '.ankole-editor .editor-content :is(h1, h2, h3)'
const EXCLUDED_ANCESTOR =
  '.embed, .editor-content [contenteditable="false"], details .knowledge-reader, .pod-subpages, .heading-hidden'

/**
 * Extracts visible H1–H3 section headings from the primary document body, skipping embedded pages,
 * folded sections, and revision-comparison previews.
 */
export function collectOutlineHeadings(root: ParentNode | null): OutlineHeading[] {
  if (!root) return []
  const raw: { level: 1 | 2 | 3; title: string; element: HTMLElement }[] = []
  const nodes = root.querySelectorAll<HTMLElement>(HEADING_SELECTOR)
  for (const el of nodes) {
    if (el.classList.contains('heading-hidden') || el.closest(EXCLUDED_ANCESTOR)) continue
    const title = (el.textContent ?? '').replace(/\s+/g, ' ').trim()
    if (!title) continue
    const tag = el.tagName.toLowerCase()
    const level: 1 | 2 | 3 = tag === 'h1' ? 1 : tag === 'h2' ? 2 : 3
    raw.push({ level, title, element: el })
  }
  if (raw.length < 2) return []
  const minLevel = Math.min(...raw.map(item => item.level))
  return raw.map((item, index) => ({
    id: `outline-${index}`,
    index,
    level: item.level,
    depth: Math.min(2, Math.max(0, item.level - minLevel)) as 0 | 1 | 2,
    title: item.title,
    element: item.element
  }))
}

/**
 * Resolves which heading is currently being read from the scroll container's geometry:
 * the last heading at or above the reading line (top quarter, capped at 140px), or the final
 * heading once scrolled to the bottom of the page.
 */
export function activeOutlineIndex(scroller: HTMLElement, headings: readonly OutlineHeading[]): number {
  if (!headings.length) return -1
  const scrollerRect = scroller.getBoundingClientRect()
  const readingLine = scrollerRect.top + Math.min(140, scroller.clientHeight * 0.25)
  let active = 0
  for (let i = 0; i < headings.length; i++) {
    const top = headings[i]!.element.getBoundingClientRect().top
    if (top <= readingLine + 2) active = i
    else break
  }
  if (
    scroller.scrollTop > 0 &&
    scroller.scrollHeight > scroller.clientHeight &&
    scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 2
  ) {
    const last = headings.at(-1)!
    if (last.element.getBoundingClientRect().top < scrollerRect.bottom) {
      active = headings.length - 1
    }
  }
  return active
}

/**
 * Scrolls `scroller` to `top` and resolves once scrolling settles. Uses native scroll-method
 * Promises where supported, falling back to `scrollend` plus a 100ms idle timer when the target
 * is already in view or `scrollend` does not fire.
 */
export function scrollToOffsetAsync(
  scroller: HTMLElement,
  top: number,
  behavior: ScrollBehavior = 'smooth'
): Promise<void> {
  const result: unknown = scroller.scrollTo({ top, behavior })
  if (result instanceof Promise) {
    return result.then(() => undefined)
  }
  if (behavior === 'instant') return Promise.resolve()

  return new Promise(resolve => {
    let timerId: ReturnType<typeof setTimeout> | undefined
    const finish = () => {
      if (timerId !== undefined) clearTimeout(timerId)
      scroller.removeEventListener('scrollend', finish)
      scroller.removeEventListener('scroll', onScroll)
      resolve()
    }
    const onScroll = () => {
      if (timerId !== undefined) clearTimeout(timerId)
      timerId = setTimeout(finish, 100)
    }
    scroller.addEventListener('scrollend', finish, { once: true })
    scroller.addEventListener('scroll', onScroll, { passive: true })
    timerId = setTimeout(finish, 100)
  })
}

function tickWidth(depth: 0 | 1 | 2, active: boolean): number {
  const base = depth === 0 ? 18 : depth === 1 ? 13 : 9
  return active ? base + 4 : base
}

function focusHeadingWithoutScroll(element: HTMLElement) {
  const hadTabIndex = element.hasAttribute('tabindex')
  if (!hadTabIndex) {
    element.setAttribute('tabindex', '-1')
    element.addEventListener(
      'blur',
      () => {
        element.removeAttribute('tabindex')
      },
      { once: true }
    )
  }
  element.focus({ preventScroll: true })
}

export function DocumentOutline({
  scroller,
  content,
  hidden = false
}: {
  scroller: RefObject<HTMLElement | null>
  content: RefObject<HTMLElement | null>
  hidden?: boolean
}) {
  const { t } = useTranslation()
  const panelId = useId()
  const rootRef = useRef<HTMLElement>(null)
  const triggerRef = useRef<HTMLButtonElement>(null)
  const cardRef = useRef<HTMLDivElement>(null)
  const closeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const pointerInsideRef = useRef(false)
  const revealGenerationRef = useRef(0)
  const lockedIndexRef = useRef<number | null>(null)
  const headingsRef = useRef<OutlineHeading[]>([])

  const [headings, setHeadings] = useState<OutlineHeading[]>([])
  const [activeIndex, setActiveIndex] = useState(0)
  const [open, setOpen] = useState(false)
  const [focusOnOpen, setFocusOnOpen] = useState(false)

  const clearCloseTimer = () => {
    if (closeTimerRef.current !== null) {
      clearTimeout(closeTimerRef.current)
      closeTimerRef.current = null
    }
  }

  useEffect(() => () => clearCloseTimer(), [])

  useEffect(() => {
    if (hidden) {
      headingsRef.current = []
      setHeadings([])
      setOpen(false)
      return
    }
    const contentEl = content.current
    const scrollerEl = scroller.current
    if (!contentEl || !scrollerEl) return

    let syncFrame = 0
    let scrollFrame = 0
    const sync = () => {
      const next = collectOutlineHeadings(contentEl)
      const prev = headingsRef.current
      const unchanged =
        prev.length === next.length &&
        prev.every(
          (item, idx) =>
            item.element === next[idx]!.element &&
            item.title === next[idx]!.title &&
            item.level === next[idx]!.level &&
            item.depth === next[idx]!.depth
        )
      const current = unchanged ? prev : next
      headingsRef.current = current
      setHeadings(prevState => (prevState === current ? prevState : current))
      if (current.length >= 2 && lockedIndexRef.current === null) {
        setActiveIndex(activeOutlineIndex(scrollerEl, current))
      }
    }

    const scheduleSync = () => {
      cancelAnimationFrame(syncFrame)
      syncFrame = requestAnimationFrame(sync)
    }

    sync()

    const mutationObserver = new MutationObserver(scheduleSync)
    mutationObserver.observe(contentEl, {
      subtree: true,
      childList: true,
      characterData: true,
      attributes: true,
      attributeFilter: ['class']
    })

    const onScroll = () => {
      if (lockedIndexRef.current !== null) return
      cancelAnimationFrame(scrollFrame)
      scrollFrame = requestAnimationFrame(() => {
        const current = headingsRef.current
        if (current.length >= 2) {
          setActiveIndex(activeOutlineIndex(scrollerEl, current))
        }
      })
    }

    scrollerEl.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('resize', scheduleSync)

    return () => {
      cancelAnimationFrame(syncFrame)
      cancelAnimationFrame(scrollFrame)
      mutationObserver.disconnect()
      scrollerEl.removeEventListener('scroll', onScroll)
      window.removeEventListener('resize', scheduleSync)
    }
  }, [content, scroller, hidden])

  useLayoutEffect(() => {
    if (!open) return
    const activeButton = cardRef.current?.querySelector<HTMLButtonElement>('[aria-current="location"]')
    activeButton?.scrollIntoView({ block: 'nearest' })
    if (focusOnOpen) {
      setFocusOnOpen(false)
      ;(activeButton ?? cardRef.current?.querySelector<HTMLButtonElement>('button'))?.focus({ preventScroll: true })
    }
  }, [open, focusOnOpen])

  useEffect(() => {
    if (!open) return
    const onPointerDown = (event: PointerEvent) => {
      const target = event.target as Node | null
      if (target && !rootRef.current?.contains(target)) {
        clearCloseTimer()
        pointerInsideRef.current = false
        setOpen(false)
      }
    }
    document.addEventListener('pointerdown', onPointerDown, true)
    return () => document.removeEventListener('pointerdown', onPointerDown, true)
  }, [open])

  if (hidden || headings.length < 2) return null

  const clampedActive = Math.min(Math.max(0, activeIndex), headings.length - 1)
  const activeHeading = headings[clampedActive]
  const tickGapClass = headings.length > 28 ? 'gap-[5px]' : headings.length > 16 ? 'gap-[7px]' : 'gap-2.5'

  const handleJump = async (entry: OutlineHeading, event: MouseEvent<HTMLButtonElement>) => {
    const scrollerEl = scroller.current
    if (!scrollerEl) return
    const viaKeyboard = event.detail === 0
    const generation = ++revealGenerationRef.current
    lockedIndexRef.current = entry.index
    setActiveIndex(entry.index)

    const scrollerRect = scrollerEl.getBoundingClientRect()
    const headingRect = entry.element.getBoundingClientRect()
    const maxScroll = Math.max(0, scrollerEl.scrollHeight - scrollerEl.clientHeight)
    const targetTop = Math.max(0, Math.min(maxScroll, scrollerEl.scrollTop + headingRect.top - scrollerRect.top - 28))
    const reducedMotion =
      typeof window.matchMedia === 'function' && window.matchMedia('(prefers-reduced-motion: reduce)').matches

    await scrollToOffsetAsync(scrollerEl, targetTop, reducedMotion ? 'instant' : 'smooth')
    if (generation !== revealGenerationRef.current) return

    lockedIndexRef.current = null
    setActiveIndex(activeOutlineIndex(scrollerEl, headingsRef.current))
    if (viaKeyboard) {
      setOpen(false)
      focusHeadingWithoutScroll(entry.element)
    }
  }

  return (
    <aside
      ref={rootRef}
      data-slot="document-outline"
      data-open={open || undefined}
      aria-label={t('pod.document.outline')}
      className="pod-document-outline"
      onPointerEnter={event => {
        if (event.pointerType === 'touch') return
        pointerInsideRef.current = true
        clearCloseTimer()
        setOpen(true)
      }}
      onPointerLeave={event => {
        if (event.pointerType === 'touch') return
        pointerInsideRef.current = false
        clearCloseTimer()
        closeTimerRef.current = setTimeout(() => {
          closeTimerRef.current = null
          if (!rootRef.current?.contains(document.activeElement)) {
            setOpen(false)
          }
        }, 120)
      }}
      onBlurCapture={event => {
        const next = event.relatedTarget as Node | null
        if (!pointerInsideRef.current && (!next || !rootRef.current?.contains(next))) {
          clearCloseTimer()
          setOpen(false)
        }
      }}
      onKeyDown={event => {
        if (event.key === 'Escape' && open) {
          event.preventDefault()
          event.stopPropagation()
          clearCloseTimer()
          const focusInside = rootRef.current?.contains(document.activeElement)
          setOpen(false)
          if (focusInside) {
            queueMicrotask(() => triggerRef.current?.focus({ preventScroll: true }))
          }
        }
      }}>
      <button
        ref={triggerRef}
        type="button"
        data-slot="document-outline-trigger"
        aria-label={
          activeHeading ? t('pod.document.outline_current', { title: activeHeading.title }) : t('pod.document.outline')
        }
        aria-expanded={open}
        aria-controls={open ? panelId : undefined}
        onClick={() => {
          clearCloseTimer()
          if (!open) {
            setFocusOnOpen(true)
            setOpen(true)
          } else {
            setOpen(false)
          }
        }}
        className={cn(
          'pod-document-outline-rail flex flex-col items-end ps-7 pe-2.5 py-3.5 cursor-pointer outline-none focus-visible:rounded-control focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-ring motion-safe:transition-opacity motion-safe:duration-150',
          tickGapClass,
          open && 'pointer-events-none opacity-0'
        )}>
        {headings.map((entry, idx) => {
          const isActive = idx === clampedActive
          return (
            <span
              key={entry.id}
              aria-hidden
              data-active={isActive || undefined}
              style={{ width: `${tickWidth(entry.depth, isActive)}px` }}
              className={cn(
                'block h-0.5 rounded-full motion-safe:transition-[width,background-color,opacity] motion-safe:duration-200',
                isActive ? 'bg-fg-primary/82' : 'bg-fg-primary/18'
              )}
            />
          )
        })}
      </button>

      {open && (
        <nav
          id={panelId}
          ref={cardRef}
          aria-label={t('pod.document.outline')}
          data-slot="document-outline-card"
          className="pod-document-outline-card ceramic ceramic-primary menu-scrollbar max-h-[min(440px,62vh)] w-62 origin-right overflow-y-auto p-1.5">
          <ul className="m-0 flex list-none flex-col gap-0.5 p-0">
            {headings.map((entry, idx) => {
              const isActive = idx === clampedActive
              return (
                <li key={entry.id}>
                  <button
                    type="button"
                    aria-current={isActive ? 'location' : undefined}
                    title={entry.title}
                    style={{ paddingInlineStart: `${10 + entry.depth * 12}px` }}
                    onClick={event => void handleJump(entry, event)}
                    className={cn(
                      // Keep font-weight constant per depth so text never reflows as active state moves.
                      'relative flex min-h-7 w-full cursor-pointer items-center rounded-control pe-2.5 text-start leading-4.5 transition-colors duration-120 focus-visible:-outline-offset-2',
                      entry.depth === 0 ? 'text-65 font-medium' : 'text-65 font-normal',
                      isActive
                        ? 'bg-layer-hover/65 text-fg-primary'
                        : entry.depth === 0
                          ? 'text-fg-secondary hover:bg-layer-hover hover:text-fg-primary'
                          : 'text-fg-tertiary hover:bg-layer-hover hover:text-fg-primary'
                    )}>
                    {isActive && (
                      <span
                        aria-hidden
                        className="absolute inset-s-1 top-1/2 h-3 w-[2px] -translate-y-1/2 rounded-full bg-fg-primary"
                      />
                    )}
                    <span className="min-w-0 flex-1 truncate">{entry.title}</span>
                  </button>
                </li>
              )
            })}
          </ul>
        </nav>
      )}
    </aside>
  )
}
