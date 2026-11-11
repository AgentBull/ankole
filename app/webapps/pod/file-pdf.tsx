import { Button, cn, Input } from '@ankole/uikit'
import {
  ChevronDownRegular,
  ChevronLeftRegular,
  ChevronRightRegular,
  ChevronUpRegular,
  DismissRegular,
  SearchRegular,
  ZoomInRegular,
  ZoomOutRegular
} from '@ankole/uikit/icons'
import type { EventBus, PDFViewer } from 'pdfjs-dist/legacy/web/pdf_viewer.mjs'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ContentError, ContentSkeleton } from './content-primitives'
import { isImeComposingKey } from './find-bar'
import 'pdfjs-dist/web/pdf_viewer.css'
import './file-pdf.css'

/**
 * A read-only PDF viewer. The pdf.js viewer component draws the pages near the scroll position with selectable
 * text and working links, and the toolbar drives its paging, zoom, and whole-document find with Ankole controls.
 */
export default function PdfPreview({
  url,
  title,
  initialPage,
  className
}: {
  url: string
  title: string
  initialPage?: number
  className?: string
}) {
  const { t } = useTranslation()
  const root = useRef<HTMLDivElement>(null)
  const container = useRef<HTMLDivElement>(null)
  const findInput = useRef<HTMLInputElement>(null)
  const pdf = useRef<{ viewer: PDFViewer; eventBus: EventBus }>(undefined)
  const [view, setView] = useState({ page: 1, pages: 0, scale: 1 })
  const [failed, setFailed] = useState(false)
  const [finding, setFinding] = useState(false)
  const [query, setQuery] = useState('')
  const queryRef = useRef(query)
  queryRef.current = query
  const [matches, setMatches] = useState({ current: 0, total: 0 })
  useEffect(() => {
    let closed = false
    let close = () => {}
    setFailed(false)
    setView({ page: 1, pages: 0, scale: 1 })
    setMatches({ current: 0, total: 0 })
    void (async () => {
      // The viewer component reads pdf.js from `globalThis.pdfjsLib`, so it loads after `./pdfjs` has run.
      const { openPdf } = await import('./pdfjs')
      const { EventBus, LinkTarget, PDFFindController, PDFLinkService, PDFViewer } =
        await import('pdfjs-dist/legacy/web/pdf_viewer.mjs')
      if (closed || !container.current) return
      const eventBus = new EventBus()
      const linkService = new PDFLinkService({
        eventBus,
        externalLinkTarget: LinkTarget.BLANK,
        externalLinkRel: 'noopener noreferrer'
      })
      const findController = new PDFFindController({ eventBus, linkService })
      const viewer = new PDFViewer({
        container: container.current,
        eventBus,
        linkService,
        findController,
        annotationEditorMode: -1
      })
      linkService.setViewer(viewer)
      eventBus.on('pagesinit', () => {
        // `auto` fits the page to the width up to 125%, and fits a landscape page whole.
        viewer.currentScaleValue = 'auto'
        // Setting the scale scrolls the first page flush with the toolbar; the document opens with its top gutter.
        if (container.current) container.current.scrollTop = 0
        setView(current => ({ ...current, pages: viewer.pagesCount }))
        if (queryRef.current) {
          eventBus.dispatch('find', {
            source: null,
            type: '',
            query: queryRef.current,
            caseSensitive: false,
            entireWord: false,
            highlightAll: true,
            findPrevious: false,
            matchDiacritics: false
          })
        }
      })
      eventBus.on('pagechanging', ({ pageNumber }: { pageNumber: number }) =>
        setView(current => ({ ...current, page: pageNumber }))
      )
      eventBus.on('scalechanging', ({ scale }: { scale: number }) => setView(current => ({ ...current, scale })))
      const count = ({ matchesCount }: { matchesCount: { current: number; total: number } }) => setMatches(matchesCount)
      eventBus.on('updatefindmatchescount', count)
      eventBus.on('updatefindcontrolstate', count)
      // Until the reader zooms, the page keeps fitting when the dialog or the window changes size.
      const resize = new ResizeObserver(() => {
        if (viewer.currentScaleValue === 'auto') viewer.currentScaleValue = 'auto'
      })
      resize.observe(container.current)
      const task = openPdf({ url })
      close = () => {
        resize.disconnect()
        viewer.setDocument(null as never)
        linkService.setDocument(null)
        void task.destroy()
      }
      const document = await task.promise
      if (closed) return
      viewer.setDocument(document)
      linkService.setDocument(document)
      pdf.current = { viewer, eventBus }
    })().catch(() => closed || setFailed(true))
    return () => {
      closed = true
      pdf.current = undefined
      close()
    }
  }, [url])
  useEffect(() => {
    if (initialPage && view.pages > 0 && pdf.current) {
      pdf.current.viewer.currentPageNumber = Math.min(Math.max(1, initialPage), view.pages)
    }
  }, [initialPage, view.pages])
  useEffect(() => {
    // The browser's own find reaches only the pages drawn so far, so the shortcut opens the whole-document find
    // while the focus is in the viewer, in its dialog, or nowhere. Inside a chat's right sidebar, focus on
    // document.body stays with the chat room's own search.
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key.toLowerCase() !== 'f' || !(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey) return
      const active = document.activeElement
      const dialog = root.current?.closest('[role="dialog"]')
      const scope = dialog ?? root.current
      const inChatSidebar = !dialog && Boolean(root.current?.closest('.pod-chat'))
      if (!scope || (inChatSidebar ? !scope.contains(active) : active !== document.body && !scope.contains(active))) {
        return
      }
      event.preventDefault()
      event.stopPropagation()
      setFinding(true)
      requestAnimationFrame(() => {
        findInput.current?.focus()
        findInput.current?.select()
      })
    }
    document.addEventListener('keydown', onKeyDown, true)
    return () => document.removeEventListener('keydown', onKeyDown, true)
  }, [])
  const find = (text: string, type: '' | 'again', findPrevious = false) =>
    pdf.current?.eventBus.dispatch('find', {
      source: null,
      type,
      query: text,
      caseSensitive: false,
      entireWord: false,
      highlightAll: true,
      findPrevious,
      matchDiacritics: false
    })
  const closeFind = () => {
    setFinding(false)
    setQuery('')
    setMatches({ current: 0, total: 0 })
    pdf.current?.eventBus.dispatch('findbarclose', { source: null })
    container.current?.focus()
  }
  if (failed) return <ContentError error={new Error(t('pod.chat_attachments.preview_unavailable'))} />
  const ready = view.pages > 0
  return (
    <div
      ref={root}
      className={cn('flex h-[70dvh] flex-col overflow-hidden rounded-control border border-border', className)}>
      <div className="flex items-center gap-1 border-b border-border px-2 py-1">
        <Button
          type="button"
          size="icon-sm"
          variant="ghost"
          aria-label={t('pod.content.previous_page')}
          title={t('pod.content.previous_page')}
          disabled={view.page <= 1}
          onClick={() => pdf.current?.viewer.previousPage()}>
          <ChevronLeftRegular aria-hidden className="size-4" />
        </Button>
        <Button
          type="button"
          size="icon-sm"
          variant="ghost"
          aria-label={t('pod.content.next_page')}
          title={t('pod.content.next_page')}
          disabled={view.page >= view.pages}
          onClick={() => pdf.current?.viewer.nextPage()}>
          <ChevronRightRegular aria-hidden className="size-4" />
        </Button>
        {ready && (
          <span className="ml-1 shrink-0 text-xs tabular-nums text-fg-tertiary">
            {view.page} / {view.pages}
          </span>
        )}
        {finding ? (
          <div role="search" className="ml-2 flex min-w-0 flex-1 items-center gap-1">
            <Input
              ref={findInput}
              autoFocus
              value={query}
              autoCorrect="off"
              autoCapitalize="off"
              spellCheck={false}
              className="h-7 min-w-0 flex-1"
              aria-label={t('pod.content.find_in_page')}
              placeholder={t('pod.content.find_in_page')}
              onChange={event => {
                setQuery(event.target.value)
                find(event.target.value, '')
              }}
              onKeyDown={event => {
                if (isImeComposingKey(event)) return
                if (event.key === 'Escape') {
                  event.stopPropagation()
                  closeFind()
                }
                if (event.key === 'Enter') {
                  event.preventDefault()
                  find(query, 'again', event.shiftKey)
                }
              }}
            />
            <span aria-live="polite" className="min-w-10 shrink-0 text-center text-xs tabular-nums text-fg-tertiary">
              {matches.current}/{matches.total}
            </span>
            <Button
              type="button"
              size="icon-sm"
              variant="ghost"
              disabled={!matches.total}
              aria-label={t('pod.content.find_previous')}
              title={t('pod.content.find_previous')}
              onClick={() => find(query, 'again', true)}>
              <ChevronUpRegular aria-hidden className="size-4" />
            </Button>
            <Button
              type="button"
              size="icon-sm"
              variant="ghost"
              disabled={!matches.total}
              aria-label={t('pod.content.find_next')}
              title={t('pod.content.find_next')}
              onClick={() => find(query, 'again')}>
              <ChevronDownRegular aria-hidden className="size-4" />
            </Button>
            <Button
              type="button"
              size="icon-sm"
              variant="ghost"
              aria-label={t('pod.content.find_close')}
              title={t('pod.content.find_close')}
              onClick={closeFind}>
              <DismissRegular aria-hidden className="size-4" />
            </Button>
          </div>
        ) : (
          <>
            <span className="flex-1" />
            <Button
              type="button"
              size="icon-sm"
              variant="ghost"
              aria-label={t('pod.content.find_in_page')}
              title={t('pod.content.find_in_page')}
              disabled={!ready}
              onClick={() => setFinding(true)}>
              <SearchRegular aria-hidden className="size-4" />
            </Button>
          </>
        )}
        <Button
          type="button"
          size="icon-sm"
          variant="ghost"
          aria-label={t('pod.chat_timeline.zoom_out')}
          title={t('pod.chat_timeline.zoom_out')}
          disabled={!ready}
          onClick={() => pdf.current?.viewer.decreaseScale()}>
          <ZoomOutRegular aria-hidden className="size-4" />
        </Button>
        {ready && (
          <span className="min-w-10 shrink-0 text-center text-xs tabular-nums text-fg-tertiary">
            {Math.round(view.scale * 100)}%
          </span>
        )}
        <Button
          type="button"
          size="icon-sm"
          variant="ghost"
          aria-label={t('pod.chat_timeline.zoom_in')}
          title={t('pod.chat_timeline.zoom_in')}
          disabled={!ready}
          onClick={() => pdf.current?.viewer.increaseScale()}>
          <ZoomInRegular aria-hidden className="size-4" />
        </Button>
      </div>
      <div className="relative min-h-0 flex-1 bg-background-secondary">
        {!ready && <ContentSkeleton variant="block" label={t('pod.content.loading_file')} className="h-full p-4" />}
        {/* pdf.js requires an absolutely positioned scroll container around the page list. It measures text
            without a language unless the PDF declares one, which it then sets on the page list. The undetermined
            language here keeps the text layer on the fonts it measured; under the app's language the browser
            picks CJK fonts for Latin text, which shifts selections and find matches away from the drawn words. */}
        <div
          ref={container}
          lang="und"
          role="region"
          aria-label={title}
          tabIndex={0}
          className="pod-pdf-pages absolute inset-0 overflow-auto outline-none">
          <div className="pdfViewer" />
        </div>
      </div>
    </div>
  )
}
