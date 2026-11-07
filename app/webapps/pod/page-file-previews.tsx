import { useCopyFeedback } from '@ankole/uikit/hooks/use-copy-feedback'
import { TEXT_PREVIEW_BYTES } from '../common/file-preview'
import { readPrefix } from '../common/browser-files'
import { useTranslation } from 'react-i18next'
import { Badge, Button, buttonVariants, cn, toast } from '@ankole/uikit'
import { RiChatQuoteLine, RiFileCopyLine, RiCheckLine } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { useCallback, useEffect, useImperativeHandle, useMemo, useRef, useState, type Ref } from 'react'
import { createClientConfig } from '../common/internal-api-client'
import { sanitizeFileName } from '../common/bidi'
import { contentKeys } from './content-api'
import { ContentError } from './content-primitives'
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
        <Badge variant="outline">{formatFileAnchorLabel(selection.anchor)}</Badge>
        {selection.quote && (
          <span className="max-w-[36ch] truncate text-fg-secondary">{selection.quote.replace(/\s+/g, ' ').trim()}</span>
        )}
      </span>
      <span className="inline-flex items-center gap-1.5">
        <Button size="xs" variant="default" onClick={() => onComment(selection)}>
          <RiChatQuoteLine aria-hidden />
          {t('pod.document.comment_selection', { defaultValue: 'Comment on selection' })}
        </Button>
        <Button size="xs" variant="ghost" onClick={onClear}>
          {t('pod.chat_timeline.clear_selection', { defaultValue: 'Clear' })}
        </Button>
      </span>
    </div>
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
            <RiChatQuoteLine aria-hidden />
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

export function DelimitedTablePreview({
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
    queryKey: [...contentKeys.page(pageID), 'file-delimited-preview', url],
    queryFn: async ({ signal }) => {
      const response = await transport(url, { credentials: 'same-origin', signal })
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
          const rowNum = selectedRange.startRow + idx
          if (selectedRange.column) {
            const colIdx = parsed.headers.indexOf(selectedRange.column)
            const value = colIdx >= 0 ? (cells[colIdx] ?? '') : cells.join(' | ')
            return `Row ${rowNum} (${selectedRange.column}): ${value}`
          }
          return `Row ${rowNum}: ${cells.join(' | ')}`
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
  }, [selectedRange, parsed, visibleRows])

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

  if (query.isPending) return <p role="status">{t('pod.content.loading_file')}</p>
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
                    highlighted && 'bg-selection/70 ring-1 ring-primary'
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

  const extension = name.includes('.') ? name.split('.').at(-1)?.toLowerCase() : undefined
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

  if (query.isPending) return <p role="status">{t('pod.content.loading_file')}</p>
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

  const captureDomLineSelection = () => {
    if (!canComment) return
    const domSel = window.getSelection()
    if (!domSel || domSel.isCollapsed || domSel.rangeCount === 0) return
    const range = domSel.getRangeAt(0)
    const root = containerRef.current
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
      const lo = Math.min(startLine, endLine)
      const hi = Math.max(startLine, endLine)
      setSectionSelection(null)
      setLineRange({ anchorLine: lo, startLine: lo, endLine: hi })
    }
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
      <div
        translate="no"
        data-immersive-translate-ignore=""
        onMouseUp={captureDomLineSelection}
        className="notranslate overflow-hidden rounded-control border border-border bg-card">
        <div className="flex items-center justify-between border-b border-border px-3 py-1.5 text-xs text-fg-secondary">
          <span className="font-mono">{extension || 'text'}</span>
          <Button
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
            {copied ? <RiCheckLine aria-hidden /> : <RiFileCopyLine aria-hidden />}
            {t(copied ? 'pod.chat_timeline.copied' : 'pod.chat.copy_code')}
          </Button>
        </div>
        <div className="max-h-[70vh] overflow-auto py-2 font-mono text-xs leading-5">
          {lines.map((line, index) => {
            const lineNum = index + 1
            const selected =
              (lineRange !== null && lineNum >= lineRange.startLine && lineNum <= lineRange.endLine) ||
              (sectionSelection?.anchor.kind === 'md_section' && sectionSelection.anchor.start_line === lineNum)
            const highlighted =
              highlightedLines !== null && lineNum >= highlightedLines.start && lineNum <= highlightedLines.end
            return (
              <div
                key={lineNum}
                data-file-line={lineNum}
                className={cn(
                  'flex items-start px-2 transition-colors',
                  selected && 'bg-accent/65',
                  highlighted && 'bg-selection/70 ring-1 ring-primary'
                )}>
                <button
                  type="button"
                  disabled={!canComment}
                  onClick={event => selectLine(lineNum, event.shiftKey)}
                  aria-label={t('pod.document.line_number', { line: lineNum })}
                  className="mr-3 w-10 shrink-0 select-none text-right text-fg-tertiary enabled:cursor-pointer enabled:hover:text-foreground">
                  {lineNum}
                </button>
                <span className="min-w-0 flex-1 whitespace-pre-wrap break-all text-foreground">{line || ' '}</span>
              </div>
            )
          })}
        </div>
      </div>
    </div>
  )
}
