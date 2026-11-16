import { useCopyFeedback } from '@ankole/uikit/hooks/use-copy-feedback'
import {
  Button,
  buttonVariants,
  cn,
  Dialog,
  DialogContent,
  DialogTitle,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
  toast
} from '@ankole/uikit'
import {
  ArrowClockwiseRegular,
  CheckmarkRegular,
  CopyRegular,
  FullScreenMaximizeRegular,
  FullScreenMinimizeRegular,
  TextWrapRegular
} from '@ankole/uikit/icons'
import { useQuery } from '@tanstack/react-query'
import { useCallback, useEffect, useImperativeHandle, useMemo, useRef, useState, type ReactNode, type Ref } from 'react'
import { flushSync } from 'react-dom'
import { useTranslation } from 'react-i18next'
import { sanitizeFileName } from '../common/bidi'
import { readPrefix } from '../common/browser-files'
import { formatFileBytes } from '../common/file-format'
import { CODE_SOURCE_PREVIEW_BYTES, HTML_PREVIEW_BYTES } from '../common/file-preview'
import { createClientConfig } from '../common/internal-api-client'
import { ContentError, ContentSkeleton } from './content-primitives'
import {
  clampCommentQuote,
  type FileCommentAnchor,
  type FileCommentSelection,
  type FilePreviewHandle
} from './file-comment-anchors'
import { captureLineSelectionFromDom, FileSelectionToolbar, SourceCodeLinesView } from './page-file-previews'

const transport = createClientConfig({}).fetch!

export const HTML_SANDBOX_ALLOW =
  'allow-scripts allow-forms allow-modals allow-popups allow-popups-to-escape-sandbox allow-downloads'

const HTML_SANDBOX_SHIM = `<script>(function(){function s(){var d=Object.create(null);return{get length(){return Object.keys(d).length},key:function(i){return Object.keys(d)[i]??null},getItem:function(k){return Object.prototype.hasOwnProperty.call(d,String(k))?d[String(k)]:null},setItem:function(k,v){d[String(k)]=String(v)},removeItem:function(k){delete d[String(k)]},clear:function(){d=Object.create(null)}}}for(var n of['localStorage','sessionStorage']){try{void window[n]}catch(_){try{Object.defineProperty(window,n,{value:s(),configurable:true})}catch(__){}}}try{void document.cookie}catch(_){try{Object.defineProperty(document,'cookie',{get:function(){return''},set:function(){},configurable:true})}catch(__){}}document.addEventListener('click',function(e){if(e.defaultPrevented)return;var a=e.target&&e.target.closest?e.target.closest('a[href]'):null;if(!a||a.hasAttribute('target')||a.hasAttribute('download'))return;var h=a.getAttribute('href')||'';if(/^(https?:|mailto:|tel:)/i.test(h)){a.setAttribute('target','_blank');a.setAttribute('rel','noopener noreferrer')}})})();</script>`

/**
 * Prepares an untrusted HTML document for `<iframe sandbox={HTML_SANDBOX_ALLOW} referrerPolicy="no-referrer" srcDoc>`:
 * preserves any leading `<!doctype>` so Standards Mode stays intact, shims `localStorage` / `sessionStorage` / `cookie`
 * so scripts do not crash with `SecurityError` inside the opaque origin, and opens external links in a new tab while
 * keeping `#hash` anchor navigation inside the frame.
 */
export function buildSandboxedHtmlSrcDoc(rawHtml: string): string {
  const html = rawHtml.startsWith('\uFEFF') ? rawHtml.slice(1) : rawHtml
  const firstBodyOrScript = html.search(/<(?:body|script)\b/i)

  const headMatch = /<head\b[^>]*>/i.exec(html)
  if (headMatch && (firstBodyOrScript === -1 || headMatch.index < firstBodyOrScript)) {
    const insertAt = headMatch.index + headMatch[0].length
    return `${html.slice(0, insertAt)}${HTML_SANDBOX_SHIM}${html.slice(insertAt)}`
  }

  const htmlMatch = /<html\b[^>]*>/i.exec(html)
  if (htmlMatch && (firstBodyOrScript === -1 || htmlMatch.index < firstBodyOrScript)) {
    const insertAt = htmlMatch.index + htmlMatch[0].length
    return `${html.slice(0, insertAt)}<head>${HTML_SANDBOX_SHIM}</head>${html.slice(insertAt)}`
  }

  const doctypeMatch = /^\s*<!doctype\b[^>]*>/i.exec(html)
  if (doctypeMatch) {
    const insertAt = doctypeMatch[0].length
    return `${html.slice(0, insertAt)}${HTML_SANDBOX_SHIM}${html.slice(insertAt)}`
  }

  return `<!doctype html>${HTML_SANDBOX_SHIM}${html}`
}

/**
 * Sandboxed HTML viewer shared by Pod File Pages, inline document embeds, and Chat attachment previews.
 * Defaults to a live opaque-origin `<iframe srcDoc>` preview (up to 16 MiB) alongside a Shiki-highlighted
 * Source tab (up to 256 KiB) with line-level comment selection and cross-tab anchor reveals.
 */
export function HtmlFilePreview({
  cacheKey,
  url,
  downloadURL = url,
  name,
  size,
  local = false,
  canComment,
  onRequestComment,
  previewRef,
  initialAnchor,
  fileMeta,
  fileActions,
  layout = 'embed',
  className
}: {
  cacheKey: readonly unknown[]
  url: string
  downloadURL?: string
  name: string
  size?: number
  local?: boolean
  canComment: boolean
  onRequestComment?: (selection: FileCommentSelection) => void
  previewRef?: Ref<FilePreviewHandle | null>
  initialAnchor?: Extract<FileCommentAnchor, { kind: 'lines' }>
  fileMeta?: ReactNode
  fileActions?: ReactNode
  layout?: 'fill' | 'embed' | 'dialog'
  className?: string
}) {
  const { t } = useTranslation()
  const containerRef = useRef<HTMLDivElement>(null)
  const previewStageRef = useRef<HTMLDivElement>(null)
  const fullscreenTriggerRef = useRef<HTMLButtonElement>(null)
  const [activeTab, setActiveTab] = useState<'preview' | 'source'>(() => (initialAnchor ? 'source' : 'preview'))
  const [wrap, setWrap] = useState(false)
  const [copied, markCopied] = useCopyFeedback(false)
  const [reloadRevision, setReloadRevision] = useState(0)
  const [isNativeFullscreen, setIsNativeFullscreen] = useState(false)
  const [dialogFullscreenOpen, setDialogFullscreenOpen] = useState(false)
  const [lineRange, setLineRange] = useState<{ anchorLine: number; startLine: number; endLine: number } | null>(null)
  const [highlightedLines, setHighlightedLines] = useState<{ start: number; end: number } | null>(null)
  const pendingAnchorLineRef = useRef<number | null>(null)

  const knownTooLarge = size !== undefined && size > HTML_PREVIEW_BYTES
  const query = useQuery({
    queryKey: [...cacheKey, 'file-html-preview', url, knownTooLarge ? 'source-only' : 'full'],
    queryFn: async ({ signal }) => {
      const response = await (local ? fetch : transport)(url, { credentials: 'same-origin', signal })
      if (!response.body) {
        throw new Error(t('pod.chat_attachments.preview_unavailable'))
      }
      const result = await readPrefix(response, knownTooLarge ? CODE_SOURCE_PREVIEW_BYTES : HTML_PREVIEW_BYTES, signal)
      const tooLarge = knownTooLarge || result.truncated
      const sourceTruncated = result.truncated || result.bytes.byteLength > CODE_SOURCE_PREVIEW_BYTES
      const sourceBytes =
        result.bytes.byteLength > CODE_SOURCE_PREVIEW_BYTES
          ? result.bytes.subarray(0, CODE_SOURCE_PREVIEW_BYTES)
          : result.bytes
      const sourceText = new TextDecoder().decode(sourceBytes, { stream: sourceTruncated })
      const previewHtml = tooLarge ? null : sourceTruncated ? new TextDecoder().decode(result.bytes) : sourceText
      return {
        previewHtml,
        sourceText,
        tooLarge,
        sourceTruncated,
        empty: result.bytes.byteLength === 0
      }
    },
    gcTime: 0,
    retry: false,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false
  })

  const lines = useMemo(
    () => (query.data ? query.data.sourceText.replace(/\r\n?/g, '\n').split('\n') : []),
    [query.data]
  )
  const srcDoc = useMemo(
    () =>
      query.data?.previewHtml !== null && query.data?.previewHtml !== undefined && !query.data.empty
        ? buildSandboxedHtmlSrcDoc(query.data.previewHtml)
        : null,
    [query.data]
  )

  const activeSelection = useMemo<FileCommentSelection | null>(() => {
    if (activeTab !== 'source' || !lineRange || lines.length === 0) return null
    const quote = clampCommentQuote(lines.slice(lineRange.startLine - 1, lineRange.endLine).join('\n'))
    return {
      anchor: {
        kind: 'lines',
        start_line: lineRange.startLine,
        end_line: lineRange.endLine
      },
      quote
    }
  }, [activeTab, lineRange, lines])

  const scrollToSourceLine = useCallback((startLine: number): HTMLElement | null => {
    const lineEl = containerRef.current?.querySelector<HTMLElement>(`[data-file-line="${startLine}"]`) ?? null
    lineEl?.scrollIntoView({ behavior: 'smooth', block: 'center' })
    return lineEl
  }, [])

  const revealHtmlAnchor = useCallback(
    (anchor: FileCommentAnchor): HTMLElement | null => {
      if (anchor.kind !== 'lines') return null
      setHighlightedLines({ start: anchor.start_line, end: anchor.end_line })
      if (activeTab !== 'source') {
        pendingAnchorLineRef.current = anchor.start_line
        try {
          flushSync(() => setActiveTab('source'))
        } catch {
          setActiveTab('source')
        }
      }
      const lineEl = scrollToSourceLine(anchor.start_line)
      if (lineEl) pendingAnchorLineRef.current = null
      return lineEl
    },
    [activeTab, scrollToSourceLine]
  )

  useImperativeHandle(
    previewRef,
    () => ({
      currentSelection() {
        return activeSelection
      },
      revealAnchor: revealHtmlAnchor
    }),
    [activeSelection, revealHtmlAnchor]
  )

  useEffect(() => {
    if (activeTab !== 'source' || pendingAnchorLineRef.current === null || !query.data) return
    const targetLine = pendingAnchorLineRef.current
    pendingAnchorLineRef.current = null
    scrollToSourceLine(targetLine)
  }, [activeTab, query.data, scrollToSourceLine])

  useEffect(() => {
    if (!highlightedLines) return
    const timer = window.setTimeout(() => setHighlightedLines(null), 3500)
    return () => window.clearTimeout(timer)
  }, [highlightedLines])

  const appliedAnchorKey = useRef<string | undefined>(undefined)
  useEffect(() => {
    if (!initialAnchor || !query.data) return
    const key = `lines:${initialAnchor.start_line}-${initialAnchor.end_line}`
    if (appliedAnchorKey.current === key) return
    appliedAnchorKey.current = key
    if (initialAnchor.start_line <= lines.length) {
      revealHtmlAnchor(initialAnchor)
    }
  }, [initialAnchor, lines.length, query.data, revealHtmlAnchor])

  useEffect(() => {
    if (typeof document === 'undefined') return
    const onFullscreenChange = () => {
      const active = document.fullscreenElement === previewStageRef.current
      setIsNativeFullscreen(active)
      if (!active) {
        fullscreenTriggerRef.current?.focus({ preventScroll: true })
      }
    }
    document.addEventListener('fullscreenchange', onFullscreenChange)
    return () => document.removeEventListener('fullscreenchange', onFullscreenChange)
  }, [])

  const enterFullscreen = () => {
    const node = previewStageRef.current
    if (
      node &&
      typeof document !== 'undefined' &&
      document.fullscreenEnabled &&
      typeof node.requestFullscreen === 'function'
    ) {
      void node.requestFullscreen().catch(() => setDialogFullscreenOpen(true))
    } else {
      setDialogFullscreenOpen(true)
    }
  }

  const exitFullscreen = () => {
    if (typeof document !== 'undefined' && document.fullscreenElement === previewStageRef.current) {
      void document.exitFullscreen().catch(() => undefined)
    }
    setDialogFullscreenOpen(false)
  }

  const canRenderPreview = Boolean(srcDoc)
  const frameTitle = t('pod.content.html_preview_frame_title', { name })
  const targetBeyondPreview = Boolean(
    query.data?.sourceTruncated && initialAnchor && initialAnchor.start_line > lines.length
  )

  const selectLine = (lineNum: number, shiftKey: boolean) => {
    if (!canComment) return
    setLineRange(prev => {
      if (shiftKey && prev) {
        return {
          anchorLine: prev.anchorLine,
          startLine: Math.min(prev.anchorLine, lineNum),
          endLine: Math.max(prev.anchorLine, lineNum)
        }
      }
      return { anchorLine: lineNum, startLine: lineNum, endLine: lineNum }
    })
  }

  const fill = layout === 'fill'
  const fixedStageHeight =
    layout === 'dialog' ? 'h-[min(65dvh,calc(100dvh-14rem))] min-h-[280px]' : 'h-[min(68dvh,640px)] min-h-[360px]'

  return (
    <div
      ref={containerRef}
      data-html-file-preview={fill ? '' : undefined}
      className={cn('flex flex-col', fill && 'min-h-0 flex-1', className)}>
      <Tabs
        value={activeTab}
        onValueChange={value => setActiveTab(value as 'preview' | 'source')}
        className={cn('flex flex-col gap-3', fill ? 'min-h-0 flex-1' : 'flex-none')}>
        <div className="flex shrink-0 flex-wrap items-center justify-between gap-x-3 gap-y-2">
          <div className="flex min-w-0 items-center gap-3 sm:flex-1">
            <TabsList variant="object" aria-label={t('pod.content.html_view_mode')}>
              <TabsTrigger value="preview">{t('pod.content.html_tab_preview')}</TabsTrigger>
              <TabsTrigger value="source">{t('pod.content.html_tab_source')}</TabsTrigger>
            </TabsList>
            {fileMeta && (
              <div className="hidden min-w-0 flex-1 truncate text-sm text-fg-secondary sm:block">{fileMeta}</div>
            )}
          </div>
          <div className="flex min-w-0 flex-wrap items-center gap-1.5">
            {activeTab === 'preview' ? (
              <>
                <Button
                  type="button"
                  variant="ghost"
                  size="icon-sm"
                  disabled={!canRenderPreview}
                  aria-label={t('pod.content.reload_preview')}
                  title={t('pod.content.reload_preview')}
                  onClick={() => setReloadRevision(rev => rev + 1)}>
                  <ArrowClockwiseRegular aria-hidden className="size-4" />
                </Button>
                <Button
                  ref={fullscreenTriggerRef}
                  type="button"
                  variant="ghost"
                  size="icon-sm"
                  disabled={!canRenderPreview}
                  aria-label={t('pod.content.full_screen_preview')}
                  title={t('pod.content.full_screen_preview')}
                  onClick={enterFullscreen}>
                  <FullScreenMaximizeRegular aria-hidden className="size-4" />
                </Button>
              </>
            ) : (
              <>
                <Button
                  type="button"
                  variant="ghost"
                  size="icon-sm"
                  aria-pressed={wrap}
                  disabled={!query.data}
                  aria-label={t('pod.chat_timeline.wrap_code')}
                  title={t('pod.chat_timeline.wrap_code')}
                  onClick={() => setWrap(prev => !prev)}>
                  <TextWrapRegular aria-hidden className="size-4" />
                </Button>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  disabled={!query.data}
                  onClick={async () => {
                    if (!query.data) return
                    try {
                      await navigator.clipboard.writeText(query.data.sourceText)
                      markCopied(true)
                    } catch {
                      toast.error(t('pod.chat.copy_failed'))
                    }
                  }}>
                  {copied ? <CheckmarkRegular aria-hidden /> : <CopyRegular aria-hidden />}
                  {t(copied ? 'pod.chat_timeline.copied' : 'pod.chat.copy_code')}
                </Button>
              </>
            )}
            {fileActions && (
              <>
                <span aria-hidden className="mx-0.5 hidden h-4 w-px bg-border sm:inline-block" />
                {fileActions}
              </>
            )}
          </div>
          {fileMeta && <div className="w-full truncate text-xs text-fg-secondary sm:hidden">{fileMeta}</div>}
        </div>

        {query.isPending ? (
          <ContentSkeleton
            variant="block"
            label={t('pod.content.loading_file')}
            className={fill ? 'min-h-[360px] flex-1' : fixedStageHeight}
          />
        ) : query.error ? (
          <ContentError error={query.error} retry={() => void query.refetch()} />
        ) : (
          <>
            <TabsContent
              value="preview"
              keepMounted
              className={cn('flex flex-col [&[hidden]]:hidden', fill ? 'min-h-0 flex-1' : 'flex-none')}>
              {query.data.empty ? (
                <p className="rounded-control border border-border p-8 text-center text-sm text-fg-tertiary">
                  {t('pod.content.empty_file', { defaultValue: 'Empty file' })}
                </p>
              ) : query.data.tooLarge || !srcDoc ? (
                <div className="flex flex-col items-center justify-center gap-3 rounded-control border border-border bg-card px-6 py-12 text-center">
                  <p className="max-w-md text-sm text-fg-secondary">
                    {t('pod.content.html_preview_too_large', { limit: formatFileBytes(HTML_PREVIEW_BYTES) })}
                  </p>
                  <div className="flex flex-wrap items-center justify-center gap-2">
                    <a
                      className={cn(buttonVariants({ variant: 'default', size: 'sm' }))}
                      href={downloadURL}
                      download={sanitizeFileName(name)}>
                      {t('pod.content.download_original')}
                    </a>
                    <Button type="button" variant="outline" size="sm" onClick={() => setActiveTab('source')}>
                      {t('pod.content.html_tab_source')}
                    </Button>
                  </div>
                </div>
              ) : (
                <div
                  ref={previewStageRef}
                  data-testid="html-file-preview-stage"
                  className={cn(
                    'relative flex w-full flex-col overflow-hidden rounded-control border border-border bg-white',
                    fill ? 'min-h-[360px] flex-1' : cn('flex-none', fixedStageHeight),
                    '[&:fullscreen]:h-dvh [&:fullscreen]:w-dvw [&:fullscreen]:rounded-none [&:fullscreen]:border-0'
                  )}>
                  {isNativeFullscreen && (
                    <div className="ceramic absolute top-3 right-3 z-20 flex items-center gap-1 p-1">
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon-sm"
                        aria-label={t('pod.content.reload_preview')}
                        title={t('pod.content.reload_preview')}
                        onClick={() => setReloadRevision(rev => rev + 1)}>
                        <ArrowClockwiseRegular aria-hidden className="size-4" />
                      </Button>
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon-sm"
                        aria-label={t('pod.content.exit_full_screen')}
                        title={t('pod.content.exit_full_screen')}
                        onClick={exitFullscreen}>
                        <FullScreenMinimizeRegular aria-hidden className="size-4" />
                      </Button>
                    </div>
                  )}
                  <iframe
                    key={`${url}:${reloadRevision}`}
                    title={frameTitle}
                    sandbox={HTML_SANDBOX_ALLOW}
                    referrerPolicy="no-referrer"
                    allow="fullscreen"
                    srcDoc={srcDoc}
                    style={{ colorScheme: 'light' }}
                    className="block min-h-0 w-full flex-1 border-0 bg-white text-neutral-950"
                  />
                </div>
              )}
            </TabsContent>

            <TabsContent
              value="source"
              className={cn('flex flex-col gap-2 [&[hidden]]:hidden', fill ? 'min-h-0 flex-1' : 'flex-none')}>
              {query.data.sourceTruncated && (
                <div
                  role="status"
                  data-testid="search-truncated-notice"
                  className={cn(
                    'flex shrink-0 flex-wrap items-center justify-between gap-2 rounded-control px-2.5 py-1.5 text-xs',
                    targetBeyondPreview
                      ? 'border border-primary/50 bg-selection/60 text-foreground'
                      : 'text-fg-tertiary'
                  )}>
                  <span>
                    {targetBeyondPreview
                      ? t('pod.content.find_truncated_download')
                      : t('pod.content.source_preview_truncated', {
                          limit: formatFileBytes(CODE_SOURCE_PREVIEW_BYTES)
                        })}
                  </span>
                  {targetBeyondPreview && (
                    <a
                      className={cn(buttonVariants({ variant: 'outline', size: 'xs' }))}
                      href={downloadURL}
                      download={sanitizeFileName(name)}>
                      {t('pod.content.download_original')}
                    </a>
                  )}
                </div>
              )}
              {activeSelection && (
                <FileSelectionToolbar
                  selection={activeSelection}
                  canComment={canComment}
                  onComment={onRequestComment}
                  onClear={() => setLineRange(null)}
                />
              )}
              <div
                className={cn(
                  'overflow-hidden rounded-control border border-border bg-card',
                  fill && 'flex min-h-0 flex-1 flex-col'
                )}>
                <SourceCodeLinesView
                  lines={lines}
                  language="html"
                  wrap={wrap}
                  canComment={canComment}
                  isLineSelected={lineNum =>
                    lineRange !== null && lineNum >= lineRange.startLine && lineNum <= lineRange.endLine
                  }
                  isLineHighlighted={lineNum =>
                    highlightedLines !== null && lineNum >= highlightedLines.start && lineNum <= highlightedLines.end
                  }
                  onSelectLine={selectLine}
                  onCaptureDomRange={root =>
                    captureLineSelectionFromDom(root, (lo, hi) =>
                      setLineRange({ anchorLine: lo, startLine: lo, endLine: hi })
                    )
                  }
                  className={
                    fill
                      ? 'contain-size max-h-none min-h-[360px] flex-1'
                      : layout === 'dialog'
                        ? 'max-h-[min(65dvh,calc(100dvh-14rem))]'
                        : undefined
                  }
                />
              </div>
            </TabsContent>
          </>
        )}
      </Tabs>

      {srcDoc && (
        <Dialog open={dialogFullscreenOpen} onOpenChange={setDialogFullscreenOpen}>
          <DialogContent
            style={{
              width: 'calc(100dvw - 24px)',
              maxWidth: 'calc(100dvw - 24px)',
              height: 'calc(100dvh - 24px)',
              maxHeight: 'calc(100dvh - 24px)'
            }}
            className="flex flex-col gap-3 p-3"
            closeLabel={t('pod.content.exit_full_screen')}
            finalFocus={fullscreenTriggerRef}>
            <div className="flex items-center justify-between gap-2 pr-8">
              <DialogTitle className="truncate text-sm font-medium">{name}</DialogTitle>
              <Button
                type="button"
                variant="ghost"
                size="icon-sm"
                aria-label={t('pod.content.reload_preview')}
                title={t('pod.content.reload_preview')}
                onClick={() => setReloadRevision(rev => rev + 1)}>
                <ArrowClockwiseRegular aria-hidden className="size-4" />
              </Button>
            </div>
            <div className="min-h-0 flex-1 overflow-hidden rounded-control border border-border bg-white">
              {dialogFullscreenOpen && (
                <iframe
                  key={`dialog:${url}:${reloadRevision}`}
                  title={frameTitle}
                  sandbox={HTML_SANDBOX_ALLOW}
                  referrerPolicy="no-referrer"
                  allow="fullscreen"
                  srcDoc={srcDoc}
                  style={{ colorScheme: 'light' }}
                  className="block h-full w-full border-0 bg-white text-neutral-950"
                />
              )}
            </div>
          </DialogContent>
        </Dialog>
      )}
    </div>
  )
}
