import { useTranslation } from 'react-i18next'
import { Badge, Button, buttonVariants, cn, toast } from '@ankole/uikit'
import { RiChatQuoteLine, RiFileCopyLine, RiCheckLine, RiUploadCloud2Line } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { lazy, Suspense, useEffect, useImperativeHandle, useMemo, useRef, useState, type Ref } from 'react'
import { createClientConfig, InternalAPIError } from '../common/internal-api-client'
import { BdiLabel } from '../common/bidi-file-name'
import { sanitizeFileName } from '../common/bidi'
import { ErrorBoundary } from '../common/error-boundary'
import { contentKeys, fileURL, type PageDetail } from './content-api'
import { ContentError } from './content-primitives'
import { podFiles } from './api/generated/sdk.gen'
import { uploadFile } from './native-transfers'
import type { PodFileCopyResponse } from './api/generated/types.gen'
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
import { usePageRealtime } from './use-page-realtime'
import { isRealtimeAccessDenied } from './realtime'

export type DriveFile = NonNullable<Awaited<ReturnType<typeof podFiles>>>['files'][number]
export type UploadedFile = PodFileCopyResponse
const SpreadsheetPreview = lazy(() => import('./file-spreadsheet'))
const PresentationPreview = lazy(() => import('./file-presentation'))
const transport = createClientConfig({}).fetch!
const TEXT_BYTES = 64 * 1024
const MAX_CSV_PREVIEW_ROWS = 500
const filesQuery = (id: string) => ({
  queryKey: [...contentKeys.page(id), 'files'],
  queryFn: () => podFiles({ path: { id } })
})

export async function uploadPageFile(
  id: string,
  file: File,
  role: 'file' | 'asset' | 'attachment',
  objectID?: string
): Promise<UploadedFile> {
  return uploadFile(id, file, role, objectID)
}

export function FilePage({
  detail,
  onRequestComment,
  previewRef
}: {
  detail: PageDetail
  onRequestComment?: (selection: FileCommentSelection) => void
  previewRef?: Ref<FilePreviewHandle | null>
}) {
  const { t } = useTranslation()
  const { page, actions } = detail
  const canEdit = actions.includes('node_edit')
  const canComment = actions.includes('node_comment') && !page.deleted_at
  const manifest = useQuery(filesQuery(page.id))
  const input = useRef<HTMLInputElement>(null)
  const uploading = useRef(false)
  const [dragOver, setDragOver] = useState(false)
  const client = useQueryClient()
  const connection = usePageRealtime(page.id, page.revision, page.object_id ?? null)
  const upload = useMutation({
    mutationFn: async (file: File) => {
      const current =
        manifest.data && !manifest.isFetching ? manifest.data : await client.fetchQuery(filesQuery(page.id))
      return uploadPageFile(page.id, file, 'file', current.files[0]?.object_id)
    },
    onSuccess: () => {
      if (input.current) input.current.value = ''
      return client.invalidateQueries({ queryKey: contentKeys.page(page.id) })
    },
    onError: async error => {
      if (error instanceof InternalAPIError && error.status === 409) await manifest.refetch()
      if (error instanceof InternalAPIError && error.status === 403) {
        void client.invalidateQueries({ queryKey: contentKeys.page(page.id) })
      }
    },
    onSettled: () => {
      uploading.current = false
    }
  })
  const file = manifest.data?.files.find(
    file => !file.path.startsWith('assets/') && !file.path.startsWith('attachments/')
  )
  const name = file?.path.split('/').at(-1) ?? t('pod.content.file')
  const chooseLabel = file ? t('pod.content.choose_a_replacement_file') : t('pod.content.choose_a_file_to_upload')
  const canUpload = Boolean(manifest.data) && !manifest.isFetching && !upload.isPending
  const submit = (selected: File | undefined) => {
    if (!selected || uploading.current) return
    uploading.current = true
    upload.mutate(selected)
  }
  if (connection.revoked || isRealtimeAccessDenied(manifest.error)) {
    return <ContentError error={new Error(t('pod.content.you_no_longer_have_access_to_this_file'))} />
  }
  return (
    <section
      className={cn(
        'space-y-4 rounded-control transition-colors',
        dragOver && canEdit && 'bg-accent/30 ring-2 ring-primary ring-offset-2'
      )}
      onDragEnter={event => {
        if (canEdit && event.dataTransfer.types.includes('Files')) {
          event.preventDefault()
          setDragOver(true)
        }
      }}
      onDragOver={event => {
        if (canEdit && event.dataTransfer.types.includes('Files')) {
          event.preventDefault()
          if (!dragOver) setDragOver(true)
        }
      }}
      onDragLeave={event => {
        if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setDragOver(false)
      }}
      onDrop={event => {
        setDragOver(false)
        if (!canEdit) return
        event.preventDefault()
        submit(event.dataTransfer.files[0])
      }}>
      <ContentError error={manifest.error} retry={() => void manifest.refetch()} />
      <ContentError error={upload.error} retry={() => submit(upload.variables)} />
      {(upload.isPending || upload.isError) && upload.variables && (
        <p role="status" className="text-sm">
          <BdiLabel value={upload.variables.name} />
        </p>
      )}
      <ContentError error={connection.error} retry={connection.retry} />
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
        {file && (
          <span className="min-w-0 grow basis-full truncate text-sm sm:basis-0" title={sanitizeFileName(name)}>
            <BdiLabel value={name} /> · {Math.ceil(file.size / 1024)} KB
          </span>
        )}
        {canEdit && (
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            <input
              aria-label={chooseLabel}
              type="file"
              ref={input}
              className="hidden"
              tabIndex={-1}
              disabled={upload.isPending}
              onChange={event => {
                submit(event.target.files?.[0])
                event.target.value = ''
              }}
            />
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={!canUpload}
              onClick={() => input.current?.click()}>
              {upload.isPending ? t('pod.content.uploading') : chooseLabel}
            </Button>
          </div>
        )}
        {file && (
          <a
            className={cn(buttonVariants({ variant: 'outline', size: 'sm' }))}
            href={fileURL(page.id, file.path, file.sha256)}
            download={sanitizeFileName(name)}>
            {t('pod.content.download_original')}
          </a>
        )}
      </div>
      {manifest.isPending ? (
        <p role="status">{t('pod.content.loading_file')}</p>
      ) : file ? (
        <ErrorBoundary variant="panel" resetKeys={[page.id, file.path, file.sha256]}>
          <FilePreview
            key={file.object_id}
            pageID={page.id}
            file={file}
            canComment={canComment}
            onRequestComment={onRequestComment}
            previewRef={previewRef}
          />
        </ErrorBoundary>
      ) : canEdit ? (
        <div
          onClick={() => {
            if (canUpload) input.current?.click()
          }}
          className={cn(
            'flex cursor-pointer flex-col items-center justify-center gap-2 rounded-control border-2 border-dashed px-6 py-12 text-center transition-colors',
            dragOver ? 'border-primary bg-accent/50' : 'border-border hover:border-border-strong hover:bg-accent/30',
            !canUpload && 'pointer-events-none opacity-60'
          )}>
          <RiUploadCloud2Line aria-hidden className="size-6 text-fg-tertiary" />
          <p className="text-sm text-fg-secondary">{t('pod.content.upload_a_file_to_preview_and_download_it_here')}</p>
        </div>
      ) : (
        <p className="rounded-control border border-dashed border-border px-6 py-10 text-center text-sm text-fg-tertiary">
          {t('pod.content.upload_a_file_to_preview_and_download_it_here')}
        </p>
      )}
    </section>
  )
}

function isTextFile(name: string, mime?: string) {
  return Boolean(
    mime?.startsWith('text/') ||
    ['application/json', 'application/xml', 'application/javascript'].includes(mime ?? '') ||
    /\.(txt|md|markdown|json|xml|ya?ml|[cm]?[jt]sx?|py|exs?|rs|go|rb|sh|css|html|sql|toml)$/i.test(name)
  )
}

function isDelimitedTextTable(name: string, mime?: string) {
  return /\.(csv|tsv)$/i.test(name) || mime === 'text/csv' || mime === 'text/tab-separated-values'
}

function FilePreview({
  pageID,
  file,
  canComment,
  onRequestComment,
  previewRef
}: {
  pageID: string
  file: DriveFile
  canComment: boolean
  onRequestComment?: (selection: FileCommentSelection) => void
  previewRef?: Ref<FilePreviewHandle | null>
}) {
  const innerPreview = useRef<FilePreviewHandle | null>(null)
  const versioned = (selection: FileCommentSelection): FileCommentSelection => ({
    ...selection,
    anchor: { ...selection.anchor, object_id: file.object_id }
  })
  useImperativeHandle(previewRef, () => ({
    currentSelection() {
      const selection = innerPreview.current?.currentSelection()
      return selection ? versioned(selection) : null
    },
    revealAnchor(anchor) {
      return innerPreview.current?.revealAnchor(anchor) ?? null
    }
  }))
  const requestComment = onRequestComment
    ? (selection: FileCommentSelection) => onRequestComment(versioned(selection))
    : undefined
  const { t } = useTranslation()
  const url = fileURL(pageID, file.path, file.sha256)
  const name = file.path.split('/').at(-1) ?? t('pod.content.file')
  const mime = file.content_type?.split(';')[0]?.trim().toLowerCase()
  return (
    <div className="space-y-3">
      {isDelimitedTextTable(name, mime) ? (
        <DelimitedTablePreview
          key={url}
          pageID={pageID}
          url={url}
          name={name}
          canComment={canComment}
          onRequestComment={requestComment}
          previewRef={innerPreview}
        />
      ) : /\.(xlsx|xls|xlsb|ods)$/i.test(name) || mime?.includes('spreadsheet') ? (
        <Suspense fallback={<p role="status">{t('pod.content.loading_spreadsheet_preview')}</p>}>
          <SpreadsheetPreview key={url} url={url} />
        </Suspense>
      ) : /\.pptx$/i.test(name) || mime?.includes('presentationml') ? (
        <Suspense fallback={<p role="status">{t('pod.content.loading_slide_preview')}</p>}>
          <PresentationPreview key={url} url={url} />
        </Suspense>
      ) : mime?.startsWith('image/') ? (
        <img className="mx-auto max-h-[70vh] max-w-full object-contain" alt={name} src={url} />
      ) : mime === 'application/pdf' ? (
        <iframe className="h-[70vh] w-full rounded border border-border" src={url} title={name} />
      ) : mime?.startsWith('video/') || mime?.startsWith('audio/') ? (
        <MediaFilePreview
          key={url}
          url={url}
          kind={mime.startsWith('video/') ? 'video' : 'audio'}
          canComment={canComment}
          onRequestComment={requestComment}
          previewRef={innerPreview}
        />
      ) : isTextFile(name, mime) ? (
        <TextFilePreview
          key={url}
          pageID={pageID}
          url={url}
          name={name}
          canComment={canComment}
          onRequestComment={requestComment}
          previewRef={innerPreview}
        />
      ) : (
        <p className="rounded border border-border p-8 text-sm text-fg-tertiary">
          {t('pod.content.online_preview_is_not_available_for_this_file_download_the')}
        </p>
      )}
    </div>
  )
}

function FileSelectionToolbar({
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

function MediaFilePreview({
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

function DelimitedTablePreview({
  pageID,
  url,
  name,
  canComment,
  onRequestComment,
  previewRef
}: {
  pageID: string
  url: string
  name: string
  canComment: boolean
  onRequestComment?: (selection: FileCommentSelection) => void
  previewRef?: Ref<FilePreviewHandle | null>
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
      const result = await readPrefix(response, TEXT_BYTES, signal)
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

  useImperativeHandle(
    previewRef,
    () => ({
      currentSelection() {
        return activeSelection
      },
      revealAnchor(anchor: FileCommentAnchor) {
        if (anchor.kind !== 'csv_rows') return null
        setHighlightedRows({ start: anchor.start_row, end: anchor.end_row })
        const rowEl = containerRef.current?.querySelector<HTMLElement>(`[data-csv-row="${anchor.start_row}"]`) ?? null
        rowEl?.scrollIntoView({ behavior: 'smooth', block: 'center' })
        return rowEl
      }
    }),
    [activeSelection]
  )

  useEffect(() => {
    if (!highlightedRows) return
    const timer = window.setTimeout(() => setHighlightedRows(null), 3500)
    return () => window.clearTimeout(timer)
  }, [highlightedRows])

  if (query.isPending) return <p role="status">{t('pod.content.loading_file')}</p>
  if (query.error) return <ContentError error={query.error} retry={() => void query.refetch()} />
  if (!parsed || (parsed.headers.length === 0 && visibleRows.length === 0)) {
    return (
      <p className="text-sm text-fg-tertiary">{t('pod.content.empty_file', { defaultValue: 'Empty table file' })}</p>
    )
  }

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
        <p role="status" className="text-xs text-fg-tertiary">
          {t('pod.chat_attachments.preview_truncated')}
        </p>
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

function TextFilePreview({
  pageID,
  url,
  name,
  canComment,
  onRequestComment,
  previewRef
}: {
  pageID: string
  url: string
  name: string
  canComment: boolean
  onRequestComment?: (selection: FileCommentSelection) => void
  previewRef?: Ref<FilePreviewHandle | null>
}) {
  const { t } = useTranslation()
  const containerRef = useRef<HTMLDivElement>(null)
  const [copied, setCopied] = useState(false)
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
      const result = await readPrefix(response, TEXT_BYTES, signal)
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

  useImperativeHandle(
    previewRef,
    () => ({
      currentSelection() {
        return activeSelection
      },
      revealAnchor(anchor: FileCommentAnchor) {
        if (anchor.kind === 'lines') {
          setHighlightedLines({ start: anchor.start_line, end: anchor.end_line })
          const lineEl =
            containerRef.current?.querySelector<HTMLElement>(`[data-file-line="${anchor.start_line}"]`) ?? null
          lineEl?.scrollIntoView({ behavior: 'smooth', block: 'center' })
          return lineEl
        }
        if (anchor.kind === 'md_section') {
          const matched =
            (anchor.start_line ? { start_line: anchor.start_line } : undefined) ??
            mdSections.find(sec => sec.heading === anchor.heading && sec.level === anchor.level) ??
            mdSections.find(sec => sec.heading === anchor.heading)
          const targetLine = matched?.start_line ?? 1
          setHighlightedLines({ start: targetLine, end: targetLine })
          const lineEl = containerRef.current?.querySelector<HTMLElement>(`[data-file-line="${targetLine}"]`) ?? null
          lineEl?.scrollIntoView({ behavior: 'smooth', block: 'center' })
          return lineEl
        }
        return null
      }
    }),
    [activeSelection, mdSections]
  )

  useEffect(() => {
    if (!highlightedLines) return
    const timer = window.setTimeout(() => setHighlightedLines(null), 3500)
    return () => window.clearTimeout(timer)
  }, [highlightedLines])

  if (query.isPending) return <p role="status">{t('pod.content.loading_file')}</p>
  if (query.error) return <ContentError error={query.error} retry={() => void query.refetch()} />

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
        <p role="status" className="text-sm text-fg-tertiary">
          {t('pod.chat_attachments.preview_truncated')}
        </p>
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
                setCopied(true)
                window.setTimeout(() => setCopied(false), 1500)
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
                  aria-label={`Line ${lineNum}`}
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

async function readPrefix(response: Response, limit: number, signal: AbortSignal) {
  const reader = response.body?.getReader()
  if (!reader) throw new Error('The file response has no body')
  const chunks: Uint8Array[] = []
  let length = 0
  let truncated = false
  try {
    while (true) {
      signal.throwIfAborted()
      const { done, value } = await reader.read()
      if (done) break
      const part = value.slice(0, limit - length)
      chunks.push(part)
      length += part.length
      if (part.length < value.length) {
        truncated = true
        break
      }
    }
  } finally {
    await reader.cancel().catch(() => undefined)
    reader.releaseLock()
  }
  const bytes = new Uint8Array(length)
  let offset = 0
  for (const part of chunks) {
    bytes.set(part, offset)
    offset += part.length
  }
  return { bytes, truncated }
}
