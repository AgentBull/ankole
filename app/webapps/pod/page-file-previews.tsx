import { useCopyFeedback } from '@ankole/uikit/hooks/use-copy-feedback'
import {
  CODE_SOURCE_PREVIEW_BYTES,
  codeLanguageFromFileName,
  HTML_PREVIEW_BYTES,
  TEXT_PREVIEW_BYTES
} from '../common/file-preview'
import { formatFileBytes } from '../common/file-format'
import { readPrefix } from '../common/browser-files'
import { useTranslation } from 'react-i18next'
import {
  Badge,
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
  TextQuoteRegular,
  TextWrapRegular
} from '@ankole/uikit/icons'
import { useQuery } from '@tanstack/react-query'
import {
  useCallback,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
  type Ref
} from 'react'
import { flushSync } from 'react-dom'
import { createClientConfig } from '../common/internal-api-client'
import { sanitizeFileName } from '../common/bidi'
import { contentKeys } from './content-api'
import { ContentError, ContentSkeleton } from './content-primitives'
import {
  clampCommentQuote,
  extractMarkdownSections,
  formatFileAnchorLabel,
  formatMediaTimestamp,
  parseDelimitedTable,
  type FileCommentAnchor,
  type FileCommentSelection,
  type FilePreviewHandle
} from './file-comment-anchors'
import { normalizeSearchQuery } from './search-targets'

const transport = createClientConfig({}).fetch!
const MAX_CSV_PREVIEW_ROWS = 500

export function FileSelectionToolbar({
  selection,
  canComment,
  onComment,
  onClear
}: {
  selection: FileCommentSelection
  canComment: boolean
  onComment?: (selection: FileCommentSelection) => void
  onClear: () => void
}) {
  const { t } = useTranslation()
  if (!canComment || !onComment) return null
  return (
    <div
      data-testid="file-comment-selection-bar"
      className="flex flex-wrap items-center justify-between gap-2 rounded-control border border-border bg-accent/40 px-3 py-1.5 text-xs">
      <span className="inline-flex items-center gap-2 font-medium text-foreground">
        <Badge variant="outline">{formatFileAnchorLabel(selection.anchor, t)}</Badge>
        {selection.quote && (
          <span className="max-w-[36ch] truncate text-fg-secondary">{selection.quote.replace(/\s+/g, ' ').trim()}</span>
        )}
      </span>
      <span className="inline-flex items-center gap-1.5">
        <Button size="xs" variant="default" onClick={() => onComment(selection)}>
          <TextQuoteRegular aria-hidden />
          {t('pod.document.comment_selection', { defaultValue: 'Comment on selection' })}
        </Button>
        <Button size="xs" variant="ghost" onClick={onClear}>
          {t('pod.document.clear_selection')}
        </Button>
      </span>
    </div>
  )
}

/** Shows an image File, or a download fallback when the browser cannot decode or load it. */
export function ImageFilePreview({ url, name }: { url: string; name: string }) {
  const { t } = useTranslation()
  const [failed, setFailed] = useState(false)
  if (failed) {
    return (
      <div
        role="alert"
        className="flex flex-col items-center justify-center gap-3 rounded-control border border-border bg-card px-6 py-12 text-center">
        <p className="max-w-md text-sm text-fg-secondary">{t('pod.content.image_preview_failed')}</p>
        <a
          className={cn(buttonVariants({ variant: 'default', size: 'sm' }))}
          href={url}
          download={sanitizeFileName(name)}>
          {t('pod.content.download_original')}
        </a>
      </div>
    )
  }
  return (
    <img
      className="mx-auto max-h-[70vh] max-w-full object-contain"
      alt={name}
      src={url}
      onError={() => setFailed(true)}
    />
  )
}

export function MediaFilePreview({
  url,
  kind,
  canComment,
  onRequestComment,
  previewRef
}: {
  url: string
  kind: 'video' | 'audio'
  canComment: boolean
  onRequestComment?: (selection: FileCommentSelection) => void
  previewRef?: Ref<FilePreviewHandle | null>
}) {
  const { t } = useTranslation()
  const mediaRef = useRef<HTMLVideoElement & HTMLAudioElement>(null)
  const [currentTime, setCurrentTime] = useState(0)
  const [highlightedTime, setHighlightedTime] = useState<number | null>(null)

  useEffect(() => {
    if (highlightedTime === null) return
    const timer = window.setTimeout(() => setHighlightedTime(null), 3500)
    return () => window.clearTimeout(timer)
  }, [highlightedTime])

  const buildSelection = (sec: number): FileCommentSelection => {
    const rounded = Math.max(0, Math.round(sec * 1000) / 1000)
    return {
      anchor: { kind: 'media_timestamp', time_sec: rounded },
      quote: `@ ${formatMediaTimestamp(rounded)}`
    }
  }

  useImperativeHandle(
    previewRef,
    () => ({
      currentSelection() {
        return buildSelection(mediaRef.current?.currentTime ?? currentTime)
      },
      revealAnchor(anchor: FileCommentAnchor) {
        if (anchor.kind !== 'media_timestamp') return null
        const element = mediaRef.current
        if (!element) return null
        try {
          element.currentTime = anchor.time_sec
          element.pause()
        } catch {
          // Media metadata may still be loading; highlight and scroll regardless.
        }
        setCurrentTime(anchor.time_sec)
        setHighlightedTime(anchor.time_sec)
        element.scrollIntoView({ behavior: 'smooth', block: 'center' })
        return element
      }
    }),
    [currentTime]
  )

  const syncTime = () => {
    if (mediaRef.current) setCurrentTime(mediaRef.current.currentTime)
  }

  return (
    <div
      className={cn(
        'space-y-2 rounded-control p-1 transition-colors',
        highlightedTime !== null && 'bg-selection/50 ring-2 ring-primary'
      )}>
      {kind === 'video' ? (
        <video
          ref={mediaRef}
          controls
          className="max-h-[70vh] w-full rounded"
          src={url}
          onTimeUpdate={syncTime}
          onSeeked={syncTime}
          onPause={syncTime}
        />
      ) : (
        <audio
          ref={mediaRef}
          controls
          className="w-full"
          src={url}
          onTimeUpdate={syncTime}
          onSeeked={syncTime}
          onPause={syncTime}
        />
      )}
      {canComment && onRequestComment && (
        <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-fg-secondary">
          <span className="tabular-nums">
            {t('pod.document.media_position', {
              defaultValue: 'Current timestamp: {$time}',
              time: formatMediaTimestamp(currentTime)
            })}
          </span>
          <Button
            size="xs"
            variant="outline"
            onClick={() => {
              mediaRef.current?.pause()
              onRequestComment(buildSelection(mediaRef.current?.currentTime ?? currentTime))
            }}>
            <TextQuoteRegular aria-hidden />
            {t('pod.document.comment_at_timestamp', {
              defaultValue: 'Comment at {$time}',
              time: formatMediaTimestamp(currentTime)
            })}
          </Button>
        </div>
      )}
    </div>
  )
}

/**
 * Renders the first 64 KiB of a UTF-8 CSV or TSV file as a table. `cacheKey` names the owning page or conversation
 * cache, and `local` reads a composer draft's object URL with the browser's own fetch.
 */
export function DelimitedTablePreview({
  cacheKey,
  url,
  name,
  local = false,
  canComment,
  onRequestComment,
  previewRef,
  initialAnchor
}: {
  cacheKey: readonly unknown[]
  url: string
  name: string
  local?: boolean
  canComment: boolean
  onRequestComment?: (selection: FileCommentSelection) => void
  previewRef?: Ref<FilePreviewHandle | null>
  initialAnchor?: Extract<FileCommentAnchor, { kind: 'csv_rows' }>
}) {
  const { t } = useTranslation()
  const containerRef = useRef<HTMLDivElement>(null)
  const [selectedRange, setSelectedRange] = useState<{
    anchorRow: number
    startRow: number
    endRow: number
    column?: string
  } | null>(null)
  const [highlightedRows, setHighlightedRows] = useState<{ start: number; end: number } | null>(null)

  const query = useQuery({
    queryKey: [...cacheKey, 'file-delimited-preview', url],
    queryFn: async ({ signal }) => {
      const response = await (local ? fetch : transport)(url, { credentials: 'same-origin', signal })
      if (!response.body) throw new Error(t('pod.chat_attachments.preview_unavailable'))
      const result = await readPrefix(response, TEXT_PREVIEW_BYTES, signal)
      const decoder = new TextDecoder()
      return {
        text: decoder.decode(result.bytes, { stream: result.truncated }),
        truncated: result.truncated
      }
    },
    gcTime: 0,
    retry: false,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false
  })

  const delimiter: ',' | '\t' = /\.tsv$/i.test(name) ? '\t' : ','
  const parsed = useMemo(
    () => (query.data ? parseDelimitedTable(query.data.text, delimiter) : null),
    [query.data, delimiter]
  )
  const visibleRows = useMemo(() => parsed?.rows.slice(0, MAX_CSV_PREVIEW_ROWS) ?? [], [parsed])

  const activeSelection = useMemo<FileCommentSelection | null>(() => {
    if (!selectedRange || !parsed) return null
    const slice = visibleRows.slice(selectedRange.startRow - 1, selectedRange.endRow)
    const quote = clampCommentQuote(
      slice
        .map((cells, idx) => {
          const row = selectedRange.startRow + idx
          if (selectedRange.column) {
            const colIdx = parsed.headers.indexOf(selectedRange.column)
            const value = colIdx >= 0 ? (cells[colIdx] ?? '') : cells.join(' | ')
            return t('pod.document.csv_row_column_quote', { row, column: selectedRange.column, value })
          }
          return t('pod.document.csv_row_quote', { row, value: cells.join(' | ') })
        })
        .join('\n')
    )
    return {
      anchor: {
        kind: 'csv_rows',
        start_row: selectedRange.startRow,
        end_row: selectedRange.endRow,
        ...(selectedRange.column ? { column: selectedRange.column } : {})
      },
      quote
    }
  }, [selectedRange, parsed, visibleRows, t])

  const revealCsvAnchor = useCallback((anchor: FileCommentAnchor): HTMLElement | null => {
    if (anchor.kind !== 'csv_rows') return null
    setHighlightedRows({ start: anchor.start_row, end: anchor.end_row })
    const rowEl = containerRef.current?.querySelector<HTMLElement>(`[data-csv-row="${anchor.start_row}"]`) ?? null
    rowEl?.scrollIntoView({ behavior: 'smooth', block: 'center' })
    return rowEl
  }, [])

  useImperativeHandle(
    previewRef,
    () => ({
      currentSelection() {
        return activeSelection
      },
      revealAnchor: revealCsvAnchor
    }),
    [activeSelection, revealCsvAnchor]
  )

  useEffect(() => {
    if (!highlightedRows) return
    const timer = window.setTimeout(() => setHighlightedRows(null), 3500)
    return () => window.clearTimeout(timer)
  }, [highlightedRows])

  const appliedAnchorKey = useRef<string | undefined>(undefined)
  useEffect(() => {
    if (!initialAnchor || !query.data) return
    const key = `${initialAnchor.start_row}-${initialAnchor.end_row}`
    if (appliedAnchorKey.current === key) return
    appliedAnchorKey.current = key
    if (initialAnchor.start_row <= visibleRows.length) {
      revealCsvAnchor(initialAnchor)
    }
  }, [initialAnchor, query.data, revealCsvAnchor, visibleRows.length])

  if (query.isPending) return <ContentSkeleton variant="table" label={t('pod.content.loading_file')} />
  if (query.error) return <ContentError error={query.error} retry={() => void query.refetch()} />
  if (!parsed || (parsed.headers.length === 0 && visibleRows.length === 0)) {
    return (
      <p className="text-sm text-fg-tertiary">{t('pod.content.empty_file', { defaultValue: 'Empty table file' })}</p>
    )
  }

  const anchorBeyondPreview = Boolean(initialAnchor && initialAnchor.start_row > visibleRows.length)

  const selectRow = (rowNum: number, shiftKey: boolean, column?: string) => {
    if (!canComment) return
    setSelectedRange(prev => {
      if (shiftKey && prev) {
        return {
          anchorRow: prev.anchorRow,
          startRow: Math.min(prev.anchorRow, rowNum),
          endRow: Math.max(prev.anchorRow, rowNum),
          column: column ?? prev.column
        }
      }
      return { anchorRow: rowNum, startRow: rowNum, endRow: rowNum, column }
    })
  }

  return (
    <div ref={containerRef} className="space-y-2">
      {activeSelection && (
        <FileSelectionToolbar
          selection={activeSelection}
          canComment={canComment}
          onComment={onRequestComment}
          onClear={() => setSelectedRange(null)}
        />
      )}
      {(query.data.truncated || parsed.rows.length > MAX_CSV_PREVIEW_ROWS) && (
        <div
          role="status"
          data-testid="search-truncated-notice"
          className={cn(
            'flex flex-wrap items-center justify-between gap-2 rounded-control px-2.5 py-1.5 text-xs',
            anchorBeyondPreview ? 'border border-primary/50 bg-selection/60 text-foreground' : 'text-fg-tertiary'
          )}>
          <span>
            {anchorBeyondPreview
              ? t('pod.content.find_truncated_download')
              : t('pod.chat_attachments.preview_truncated')}
          </span>
          {anchorBeyondPreview && (
            <a
              className={cn(buttonVariants({ variant: 'outline', size: 'xs' }))}
              href={url}
              download={sanitizeFileName(name)}>
              {t('pod.content.download_original')}
            </a>
          )}
        </div>
      )}
      <div className="max-h-[65vh] overflow-auto rounded-control border border-border">
        <table className="w-full border-collapse text-left text-xs">
          <thead className="sticky top-0 z-10 bg-muted/90 backdrop-blur">
            <tr>
              <th className="w-12 border-b border-r border-border px-2 py-1.5 text-right font-mono text-fg-tertiary">
                #
              </th>
              {parsed.headers.map((header, colIdx) => (
                <th
                  key={colIdx}
                  className="border-b border-r border-border px-2.5 py-1.5 font-semibold text-foreground">
                  {header || `Col ${colIdx + 1}`}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {visibleRows.map((cells, index) => {
              const rowNum = index + 1
              const selected =
                selectedRange !== null && rowNum >= selectedRange.startRow && rowNum <= selectedRange.endRow
              const highlighted =
                highlightedRows !== null && rowNum >= highlightedRows.start && rowNum <= highlightedRows.end
              return (
                <tr
                  key={rowNum}
                  data-csv-row={rowNum}
                  className={cn(
                    'border-b border-border/70 transition-colors',
                    selected && 'bg-accent/65',
                    highlighted &&
                      locatedRunClassName(rowNum === highlightedRows?.start, rowNum === highlightedRows?.end)
                  )}>
                  <td className="border-r border-border px-2 py-1 text-right font-mono text-fg-tertiary">
                    <button
                      type="button"
                      disabled={!canComment}
                      onClick={event => selectRow(rowNum, event.shiftKey)}
                      className="w-full text-right enabled:cursor-pointer enabled:hover:text-foreground">
                      {rowNum}
                    </button>
                  </td>
                  {parsed.headers.map((header, colIdx) => (
                    <td
                      key={colIdx}
                      onClick={event => selectRow(rowNum, event.shiftKey, header || undefined)}
                      className={cn(
                        'border-r border-border/60 px-2.5 py-1 whitespace-pre-wrap text-foreground',
                        canComment && 'cursor-pointer hover:bg-accent/35'
                      )}>
                      {cells[colIdx] ?? ''}
                    </td>
                  ))}
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </div>
  )
}

/**
 * Frames a contiguous run of located lines or rows as one box: every item draws the side edges, the first item draws
 * the top edge, and the last item draws the bottom edge.
 */
export function locatedRunClassName(runStart: boolean, runEnd: boolean) {
  return cn(
    'relative bg-selection/70 before:pointer-events-none before:absolute before:inset-0 before:border-x before:border-primary',
    runStart && 'before:border-t',
    runEnd && 'before:border-b'
  )
}

const MAX_HIGHLIGHT_LINE_CHARS = 2_000

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

type HighlightedToken = {
  content: string
  htmlStyle?: Record<string, string>
}

function useHighlightedCodeLines(lines: string[], language: string | undefined): HighlightedToken[][] | undefined {
  const [highlighted, setHighlighted] = useState<{ key: string; tokens: HighlightedToken[][] }>()

  const sanitizedInput = useMemo(() => {
    if (!language || ['text', 'txt', 'plaintext'].includes(language) || lines.length === 0) return undefined
    return lines
      .map(line =>
        line.length <= MAX_HIGHLIGHT_LINE_CHARS ? line : (line.match(/<\/?(?:style|script)\b[^>]*>/gi) ?? []).join('')
      )
      .join('\n')
  }, [lines, language])

  const cacheKey = sanitizedInput !== undefined && language ? `${language}:${sanitizedInput}` : undefined

  useEffect(() => {
    if (sanitizedInput === undefined || !language || !cacheKey) return
    let active = true
    void import('shiki')
      .then(async shiki => {
        if (!active || !(language in shiki.bundledLanguages)) return
        const result = await shiki.codeToTokens(sanitizedInput, {
          lang: language as keyof typeof shiki.bundledLanguages,
          themes: { light: 'github-light', dark: 'github-dark' }
        })
        if (active) {
          setHighlighted({ key: cacheKey, tokens: result.tokens })
        }
      })
      .catch(() => {
        // Plain monospace lines remain readable if grammar loading fails.
      })
    return () => {
      active = false
    }
  }, [sanitizedInput, language, cacheKey])

  return cacheKey && highlighted?.key === cacheKey ? highlighted.tokens : undefined
}

function captureLineSelectionFromDom(
  root: HTMLElement | null,
  onSelectRange: (startLine: number, endLine: number) => void
) {
  const domSel = window.getSelection()
  if (!domSel || domSel.isCollapsed || domSel.rangeCount === 0) return
  const range = domSel.getRangeAt(0)
  if (!root || !root.contains(range.commonAncestorContainer)) return
  const startEl = (
    range.startContainer instanceof Element ? range.startContainer : range.startContainer.parentElement
  )?.closest<HTMLElement>('[data-file-line]')
  const endEl = (
    range.endContainer instanceof Element ? range.endContainer : range.endContainer.parentElement
  )?.closest<HTMLElement>('[data-file-line]')
  const startLine = Number(startEl?.dataset.fileLine)
  const endLine = Number(endEl?.dataset.fileLine)
  if (Number.isSafeInteger(startLine) && startLine >= 1 && Number.isSafeInteger(endLine) && endLine >= 1) {
    onSelectRange(Math.min(startLine, endLine), Math.max(startLine, endLine))
  }
}

function SourceCodeLinesView({
  lines,
  language,
  wrap,
  canComment,
  isLineSelected,
  isLineHighlighted,
  onSelectLine,
  onCaptureDomRange,
  className
}: {
  lines: string[]
  language: string | undefined
  wrap: boolean
  canComment: boolean
  isLineSelected: (lineNum: number) => boolean
  isLineHighlighted: (lineNum: number) => boolean
  onSelectLine: (lineNum: number, shiftKey: boolean) => void
  onCaptureDomRange: (root: HTMLElement | null) => void
  className?: string
}) {
  const { t } = useTranslation()
  const bodyRef = useRef<HTMLDivElement>(null)
  const tokens = useHighlightedCodeLines(lines, language)

  return (
    <div
      ref={bodyRef}
      translate="no"
      data-immersive-translate-ignore=""
      onMouseUp={() => {
        if (canComment) onCaptureDomRange(bodyRef.current)
      }}
      className={cn('notranslate max-h-[70vh] overflow-auto bg-card font-mono text-xs leading-5', className)}>
      <div className={cn('py-2', wrap ? 'w-full' : 'min-w-full w-fit')}>
        {lines.map((line, index) => {
          const lineNum = index + 1
          const selected = isLineSelected(lineNum)
          const highlighted = isLineHighlighted(lineNum)
          const lineTokens = line.length <= MAX_HIGHLIGHT_LINE_CHARS ? tokens?.[index] : undefined
          return (
            <div
              key={lineNum}
              data-file-line={lineNum}
              className={cn(
                'flex items-start pr-3 transition-colors',
                selected && 'bg-accent/65',
                highlighted &&
                  cn(
                    locatedRunClassName(!isLineHighlighted(lineNum - 1), !isLineHighlighted(lineNum + 1)),
                    'before:z-20'
                  )
              )}>
              <button
                type="button"
                disabled={!canComment}
                onClick={event => onSelectLine(lineNum, event.shiftKey)}
                aria-label={t('pod.document.line_number', { line: lineNum })}
                className={cn(
                  'sticky left-0 z-10 mr-3 w-12 shrink-0 select-none bg-card pl-2 text-right text-fg-tertiary enabled:cursor-pointer enabled:hover:text-foreground',
                  selected && 'bg-accent',
                  highlighted && 'bg-selection'
                )}>
                {lineNum}
              </button>
              <code
                className={cn(
                  'min-w-0 flex-1 font-mono text-foreground',
                  wrap ? 'whitespace-pre-wrap break-all' : 'whitespace-pre'
                )}>
                {lineTokens && lineTokens.length > 0
                  ? lineTokens.map((token, tokenIdx) => (
                      <span
                        key={tokenIdx}
                        style={token.htmlStyle as CSSProperties | undefined}
                        className={token.htmlStyle ? 'dark:text-(--shiki-dark)!' : undefined}>
                        {token.content}
                      </span>
                    ))
                  : line || ' '}
              </code>
            </div>
          )
        })}
      </div>
    </div>
  )
}

export function TextFilePreview({
  pageID,
  url,
  name,
  canComment,
  onRequestComment,
  previewRef,
  initialAnchor
}: {
  pageID: string
  url: string
  name: string
  canComment: boolean
  onRequestComment?: (selection: FileCommentSelection) => void
  previewRef?: Ref<FilePreviewHandle | null>
  initialAnchor?: Extract<FileCommentAnchor, { kind: 'lines' | 'md_section' }>
}) {
  const { t } = useTranslation()
  const containerRef = useRef<HTMLDivElement>(null)
  const [copied, markCopied] = useCopyFeedback(false)
  const [wrap, setWrap] = useState(false)
  const [lineRange, setLineRange] = useState<{ anchorLine: number; startLine: number; endLine: number } | null>(null)
  const [sectionSelection, setSectionSelection] = useState<FileCommentSelection | null>(null)
  const [highlightedLines, setHighlightedLines] = useState<{ start: number; end: number } | null>(null)

  const query = useQuery({
    queryKey: [...contentKeys.page(pageID), 'file-text-preview', url],
    queryFn: async ({ signal }) => {
      const response = await transport(url, { credentials: 'same-origin', signal })
      if (!response.body) {
        throw new Error(t('pod.chat_attachments.preview_unavailable'))
      }
      const result = await readPrefix(response, CODE_SOURCE_PREVIEW_BYTES, signal)
      const decoder = new TextDecoder()
      return {
        text: decoder.decode(result.bytes, { stream: result.truncated }),
        truncated: result.truncated
      }
    },
    gcTime: 0,
    retry: false,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false
  })

  const extension = name.includes('.') ? name.split('.').at(-1)?.toLowerCase() : undefined
  const language = codeLanguageFromFileName(name)
  const isMarkdown = extension === 'md' || extension === 'markdown'
  const lines = useMemo(() => (query.data ? query.data.text.replace(/\r\n?/g, '\n').split('\n') : []), [query.data])
  const mdSections = useMemo(
    () => (isMarkdown && query.data ? extractMarkdownSections(query.data.text) : []),
    [isMarkdown, query.data]
  )

  const activeSelection = useMemo<FileCommentSelection | null>(() => {
    if (sectionSelection) return sectionSelection
    if (!lineRange || lines.length === 0) return null
    const quote = clampCommentQuote(lines.slice(lineRange.startLine - 1, lineRange.endLine).join('\n'))
    return {
      anchor: {
        kind: 'lines',
        start_line: lineRange.startLine,
        end_line: lineRange.endLine
      },
      quote
    }
  }, [sectionSelection, lineRange, lines])

  const resolveAnchorRange = useCallback(
    (anchor: FileCommentAnchor): { start: number; end: number } | undefined => {
      if (anchor.kind === 'lines') {
        return { start: anchor.start_line, end: anchor.end_line }
      }
      if (anchor.kind === 'md_section') {
        if (anchor.start_line && anchor.start_line >= 1) {
          return { start: anchor.start_line, end: anchor.start_line }
        }
        const needle = normalizeSearchQuery(anchor.heading.trim())
        if (!needle) return undefined
        const matched =
          mdSections.find(sec => normalizeSearchQuery(sec.heading.trim()) === needle && sec.level === anchor.level) ??
          mdSections.find(sec => normalizeSearchQuery(sec.heading.trim()) === needle)
        return matched ? { start: matched.start_line, end: matched.start_line } : undefined
      }
      return undefined
    },
    [mdSections]
  )

  const revealTextAnchor = useCallback(
    (anchor: FileCommentAnchor, fallbackToFirstLine = true): HTMLElement | null => {
      const range = resolveAnchorRange(anchor)
      const targetRange =
        range ?? (fallbackToFirstLine && anchor.kind === 'md_section' ? { start: 1, end: 1 } : undefined)
      if (!targetRange) return null
      setHighlightedLines(targetRange)
      const lineEl = containerRef.current?.querySelector<HTMLElement>(`[data-file-line="${targetRange.start}"]`) ?? null
      lineEl?.scrollIntoView({ behavior: 'smooth', block: 'center' })
      return lineEl
    },
    [resolveAnchorRange]
  )

  useImperativeHandle(
    previewRef,
    () => ({
      currentSelection() {
        return activeSelection
      },
      revealAnchor(anchor: FileCommentAnchor) {
        return revealTextAnchor(anchor, true)
      }
    }),
    [activeSelection, revealTextAnchor]
  )

  useEffect(() => {
    if (!highlightedLines) return
    const timer = window.setTimeout(() => setHighlightedLines(null), 3500)
    return () => window.clearTimeout(timer)
  }, [highlightedLines])

  const appliedAnchorKey = useRef<string | undefined>(undefined)
  useEffect(() => {
    if (!initialAnchor || !query.data) return
    const key =
      initialAnchor.kind === 'lines'
        ? `lines:${initialAnchor.start_line}-${initialAnchor.end_line}`
        : `md:${initialAnchor.level}:${initialAnchor.start_line ?? ''}:${initialAnchor.heading}`
    if (appliedAnchorKey.current === key) return
    appliedAnchorKey.current = key
    const range = resolveAnchorRange(initialAnchor)
    if (range && range.start <= lines.length) {
      revealTextAnchor(initialAnchor, false)
    }
  }, [initialAnchor, lines.length, query.data, resolveAnchorRange, revealTextAnchor])

  if (query.isPending) return <ContentSkeleton variant="text" label={t('pod.content.loading_file')} />
  if (query.error) return <ContentError error={query.error} retry={() => void query.refetch()} />

  const resolvedInitialRange = initialAnchor ? resolveAnchorRange(initialAnchor) : undefined
  const targetBeyondPreview = Boolean(
    query.data.truncated && initialAnchor && (!resolvedInitialRange || resolvedInitialRange.start > lines.length)
  )

  const selectLine = (lineNum: number, shiftKey: boolean) => {
    if (!canComment) return
    setSectionSelection(null)
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

  return (
    <div ref={containerRef} className="space-y-2">
      {query.data.truncated && (
        <div
          role="status"
          data-testid="search-truncated-notice"
          className={cn(
            'flex flex-wrap items-center justify-between gap-2 rounded-control px-2.5 py-1.5 text-sm',
            targetBeyondPreview ? 'border border-primary/50 bg-selection/60 text-foreground' : 'text-fg-tertiary'
          )}>
          <span>
            {targetBeyondPreview
              ? t('pod.content.find_truncated_download')
              : t('pod.chat_attachments.preview_truncated')}
          </span>
          {targetBeyondPreview && (
            <a
              className={cn(buttonVariants({ variant: 'outline', size: 'xs' }))}
              href={url}
              download={sanitizeFileName(name)}>
              {t('pod.content.download_original')}
            </a>
          )}
        </div>
      )}
      {canComment && mdSections.length > 0 && (
        <div className="flex flex-wrap items-center gap-1.5 text-xs">
          <span className="text-fg-tertiary">{t('pod.document.markdown_sections', { defaultValue: 'Sections:' })}</span>
          {mdSections.map((sec, idx) => (
            <Button
              key={`${sec.start_line}:${idx}`}
              size="xs"
              variant="outline"
              onClick={() => {
                setLineRange(null)
                setSectionSelection({
                  anchor: {
                    kind: 'md_section',
                    heading: sec.heading,
                    level: sec.level,
                    start_line: sec.start_line
                  },
                  quote: sec.excerpt
                })
                containerRef.current
                  ?.querySelector<HTMLElement>(`[data-file-line="${sec.start_line}"]`)
                  ?.scrollIntoView({ behavior: 'smooth', block: 'center' })
              }}>
              {'#'.repeat(sec.level)} {sec.heading}
            </Button>
          ))}
        </div>
      )}
      {activeSelection && (
        <FileSelectionToolbar
          selection={activeSelection}
          canComment={canComment}
          onComment={onRequestComment}
          onClear={() => {
            setLineRange(null)
            setSectionSelection(null)
          }}
        />
      )}
      <div className="overflow-hidden rounded-control border border-border bg-card">
        <div className="flex items-center justify-between border-b border-border px-3 py-1.5 text-xs text-fg-secondary">
          <span className="font-mono">{extension || 'text'}</span>
          <div className="flex items-center gap-0.5">
            <Button
              type="button"
              size="icon-xs"
              variant="ghost"
              aria-pressed={wrap}
              title={t('pod.chat_timeline.wrap_code')}
              aria-label={t('pod.chat_timeline.wrap_code')}
              onClick={() => setWrap(prev => !prev)}>
              <TextWrapRegular aria-hidden />
            </Button>
            <Button
              type="button"
              size="xs"
              variant="ghost"
              onClick={async () => {
                try {
                  await navigator.clipboard.writeText(query.data.text)
                  markCopied(true)
                } catch {
                  toast.error(t('pod.chat.copy_failed'))
                }
              }}>
              {copied ? <CheckmarkRegular aria-hidden /> : <CopyRegular aria-hidden />}
              {t(copied ? 'pod.chat_timeline.copied' : language && !isMarkdown ? 'pod.chat.copy_code' : 'common.copy')}
            </Button>
          </div>
        </div>
        <SourceCodeLinesView
          lines={lines}
          language={language}
          wrap={wrap}
          canComment={canComment}
          isLineSelected={lineNum =>
            (lineRange !== null && lineNum >= lineRange.startLine && lineNum <= lineRange.endLine) ||
            (sectionSelection?.anchor.kind === 'md_section' && sectionSelection.anchor.start_line === lineNum)
          }
          isLineHighlighted={lineNum =>
            highlightedLines !== null && lineNum >= highlightedLines.start && lineNum <= highlightedLines.end
          }
          onSelectLine={selectLine}
          onCaptureDomRange={root =>
            captureLineSelectionFromDom(root, (lo, hi) => {
              setSectionSelection(null)
              setLineRange({ anchorLine: lo, startLine: lo, endLine: hi })
            })
          }
        />
      </div>
    </div>
  )
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

  return (
    <div ref={containerRef} className={cn('flex min-h-0 flex-col', className)}>
      <Tabs
        value={activeTab}
        onValueChange={value => setActiveTab(value as 'preview' | 'source')}
        className="flex min-h-0 flex-1 flex-col gap-3">
        <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-2">
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
          <ContentSkeleton variant="block" label={t('pod.content.loading_file')} className="min-h-[320px] flex-1" />
        ) : query.error ? (
          <ContentError error={query.error} retry={() => void query.refetch()} />
        ) : (
          <>
            <TabsContent value="preview" keepMounted className="flex min-h-0 flex-1 flex-col [&[hidden]]:hidden">
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
                    'relative flex min-h-[360px] w-full flex-1 flex-col overflow-hidden rounded-control border border-border bg-white',
                    'h-[calc(100dvh-13.5rem)] in-[.pod-inline-page]:h-[480px] in-[.pod-dialog-body]:h-[60dvh] in-[.pod-chat-file-panel-body]:h-full',
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
                    className="block h-full w-full flex-1 border-0 bg-white text-neutral-950"
                  />
                </div>
              )}
            </TabsContent>

            <TabsContent value="source" className="flex min-h-0 flex-1 flex-col gap-2 [&[hidden]]:hidden">
              {query.data.sourceTruncated && (
                <div
                  role="status"
                  data-testid="search-truncated-notice"
                  className={cn(
                    'flex flex-wrap items-center justify-between gap-2 rounded-control px-2.5 py-1.5 text-xs',
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
              <div className="flex min-h-0 flex-1 flex-col overflow-hidden rounded-control border border-border bg-card">
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
                  className="in-[.pod-chat-file-panel-body]:max-h-none in-[.pod-chat-file-panel-body]:flex-1"
                />
              </div>
            </TabsContent>
          </>
        )}
      </Tabs>

      {srcDoc && (
        <Dialog open={dialogFullscreenOpen} onOpenChange={setDialogFullscreenOpen}>
          <DialogContent
            style={{ width: 'calc(100vw - 24px)', maxWidth: 'calc(100vw - 24px)', height: 'calc(100dvh - 24px)' }}
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
