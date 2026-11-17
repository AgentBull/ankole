import {
  isDelimitedTextTable,
  isHtmlFile,
  isLegacyWorkbookFile,
  isOfficeSpreadsheetFile,
  isPresentationFile,
  isTextFile,
  isWordFile,
  previewMediaType
} from '../common/file-preview'
import { formatFileBytes } from '../common/file-format'
import { useTranslation } from 'react-i18next'
import { Button, buttonVariants, cn, Spinner } from '@ankole/uikit'
import { CloudArrowUpRegular } from '@ankole/uikit/icons'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { lazy, Suspense, useImperativeHandle, useRef, useState, type ReactNode, type Ref } from 'react'
import { InternalAPIError } from '../common/internal-api-client'
import { BdiLabel } from '../common/bidi-file-name'
import { sanitizeFileName } from '../common/bidi'
import { ErrorBoundary } from '../common/error-boundary'
import { contentKeys, fileURL, type PageDetail } from './content-api'
import { ContentError, ContentLoading, ContentSkeleton } from './content-primitives'
import { podFiles } from './api/generated/sdk.gen'
import { uploadFile } from './native-transfers'
import type { PodFileCopyResponse } from './api/generated/types.gen'
import type { FileCommentAnchor, FileCommentSelection, FilePreviewHandle } from './file-comment-anchors'
import { HtmlFilePreview } from './html-file-preview'
import { DelimitedTablePreview, ImageFilePreview, MediaFilePreview, TextFilePreview } from './page-file-previews'
import { usePageRealtime } from './use-page-realtime'
import { isRealtimeAccessDenied } from './realtime'
import { officeFileFormat } from './office/office-files'
import type { ParsedSearchTarget } from './search-targets'

export type DriveFile = NonNullable<Awaited<ReturnType<typeof podFiles>>>['files'][number]
export type UploadedFile = PodFileCopyResponse
const SpreadsheetPage = lazy(() => import('./spreadsheet/spreadsheet-page'))
const WordPage = lazy(() => import('./word/word-page'))
const PresentationPage = lazy(() => import('./presentation/presentation-page'))
const SpreadsheetPreview = lazy(() => import('./spreadsheet/spreadsheet-preview'))
const WordPreview = lazy(() => import('./word/word-preview'))
const PresentationPreview = lazy(() => import('./presentation/presentation-preview'))
const LegacySpreadsheetPreview = lazy(() => import('./file-spreadsheet'))
const PdfPreview = lazy(() => import('./file-pdf'))
export const filesQuery = (id: string) => ({
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
  previewRef,
  searchFind = '',
  searchTarget,
  embedded = false
}: {
  detail: PageDetail
  onRequestComment?: (selection: FileCommentSelection) => void
  previewRef?: Ref<FilePreviewHandle | null>
  searchFind?: string
  searchTarget?: ParsedSearchTarget
  embedded?: boolean
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
    entry => !entry.path.startsWith('assets/') && !entry.path.startsWith('attachments/')
  )
  const name = file?.path.split('/').at(-1) ?? t('pod.content.file')
  const officeKind = file ? officeFileFormat(name) : undefined
  const mime = file ? previewMediaType(name, file.content_type) : undefined
  const isHtml = Boolean(file && !officeKind && isHtmlFile(name, mime))
  const fillHtmlPage = isHtml && !embedded
  const findQuery = searchFind.trim()
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
  const replaceButton = canEdit ? (
    <Button type="button" size="sm" variant="outline" disabled={!canUpload} onClick={() => input.current?.click()}>
      {upload.isPending && <Spinner aria-hidden className="size-4" />}
      {upload.isPending ? t('pod.content.uploading') : chooseLabel}
    </Button>
  ) : null
  const downloadLink = file ? (
    // An Office download omits the digest, so the server first writes pending edits into the file.
    <a
      className={cn(buttonVariants({ variant: 'outline', size: 'sm' }))}
      href={officeKind ? fileURL(page.id, file.path) : fileURL(page.id, file.path, file.sha256)}
      download={sanitizeFileName(name)}>
      {officeKind ? t('pod.office.download') : t('pod.content.download_original')}
    </a>
  ) : null
  return (
    <section
      className={cn(
        fillHtmlPage ? 'flex min-h-0 flex-1 flex-col gap-4' : 'space-y-4',
        'rounded-control transition-colors',
        dragOver && canEdit && 'bg-layer-hover/30 ring-2 ring-primary ring-offset-2'
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
      {canEdit && (
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
      )}
      {!isHtml && (
        <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
          {file && (
            <span className="min-w-0 grow basis-full truncate text-sm sm:basis-0" title={sanitizeFileName(name)}>
              <BdiLabel value={name} /> · {formatFileBytes(file.size)}
            </span>
          )}
          {replaceButton && <div className="flex min-w-0 flex-wrap items-center gap-2">{replaceButton}</div>}
          {downloadLink}
        </div>
      )}
      {(() => {
        if (manifest.isPending) return <ContentLoading label={t('pod.content.loading_file')} />
        if (officeKind === 'spreadsheet') {
          // Compaction replaces the object while the editor stays open, so only the page resets it.
          return (
            <ErrorBoundary variant="panel" resetKeys={[page.id]}>
              <Suspense fallback={<ContentSkeleton variant="table" label={t('pod.spreadsheet.loading')} immediate />}>
                <SpreadsheetPage
                  detail={detail}
                  initialSheet={searchTarget?.kind === 'sheet' ? searchTarget.sheet : undefined}
                  initialFind={findQuery || undefined}
                />
              </Suspense>
            </ErrorBoundary>
          )
        }
        if (officeKind === 'word') {
          return (
            <ErrorBoundary variant="panel" resetKeys={[page.id]}>
              <Suspense fallback={<ContentSkeleton variant="page" label={t('pod.word.loading')} immediate />}>
                <WordPage
                  detail={detail}
                  initialPage={searchTarget?.kind === 'page' ? searchTarget.page : undefined}
                  initialFind={findQuery || undefined}
                />
              </Suspense>
            </ErrorBoundary>
          )
        }
        if (officeKind === 'presentation') {
          return (
            <ErrorBoundary variant="panel" resetKeys={[page.id]}>
              <Suspense fallback={<ContentSkeleton variant="page" label={t('pod.presentation.loading')} immediate />}>
                <PresentationPage
                  detail={detail}
                  initialSlide={searchTarget?.kind === 'page' ? searchTarget.page : undefined}
                  initialFind={findQuery || undefined}
                />
              </Suspense>
            </ErrorBoundary>
          )
        }
        if (file) {
          return (
            <ErrorBoundary variant="panel" resetKeys={[page.id, file.path, file.sha256]}>
              <FilePreview
                key={file.object_id}
                pageID={page.id}
                file={file}
                canComment={canComment}
                onRequestComment={onRequestComment}
                previewRef={previewRef}
                searchTarget={searchTarget}
                searchFind={findQuery}
                embedded={embedded}
                fileMeta={
                  isHtml ? (
                    <span title={sanitizeFileName(name)}>
                      <BdiLabel value={name} /> · {formatFileBytes(file.size)}
                    </span>
                  ) : undefined
                }
                fileActions={
                  isHtml ? (
                    <>
                      {replaceButton}
                      {downloadLink}
                    </>
                  ) : undefined
                }
              />
            </ErrorBoundary>
          )
        }
        if (manifest.error) return null
        if (canEdit) {
          return (
            <div
              onClick={() => {
                if (canUpload) input.current?.click()
              }}
              className={cn(
                'flex cursor-pointer flex-col items-center justify-center gap-2 rounded-control border-2 border-dashed px-6 py-12 text-center transition-colors',
                dragOver
                  ? 'border-primary bg-layer-hover/50'
                  : 'border-border-subtle hover:border-border-strong hover:bg-layer-hover/30',
                !canUpload && 'pointer-events-none opacity-60'
              )}>
              <CloudArrowUpRegular aria-hidden className="size-6 text-fg-tertiary" />
              <p className="text-sm text-fg-secondary">
                {t('pod.content.upload_a_file_to_preview_and_download_it_here')}
              </p>
            </div>
          )
        }
        return (
          <p className="rounded-control border border-dashed border-border-subtle px-6 py-10 text-center text-sm text-fg-tertiary">
            {t('pod.content.upload_a_file_to_preview_and_download_it_here')}
          </p>
        )
      })()}
    </section>
  )
}

function resolveFileSearchAnchor(searchTarget?: ParsedSearchTarget): FileCommentAnchor | undefined {
  if (!searchTarget) return undefined
  if (searchTarget.kind === 'file_anchor') return searchTarget.anchor
  if (searchTarget.kind === 'heading') return { kind: 'md_section', heading: searchTarget.heading, level: 1 }
  return undefined
}

function FilePreview({
  pageID,
  file,
  canComment,
  onRequestComment,
  previewRef,
  searchTarget,
  searchFind,
  embedded = false,
  fileMeta,
  fileActions
}: {
  pageID: string
  file: DriveFile
  canComment: boolean
  onRequestComment?: (selection: FileCommentSelection) => void
  previewRef?: Ref<FilePreviewHandle | null>
  searchTarget?: ParsedSearchTarget
  searchFind: string
  embedded?: boolean
  fileMeta?: ReactNode
  fileActions?: ReactNode
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
  const mime = previewMediaType(name, file.content_type)
  const initialAnchor = resolveFileSearchAnchor(searchTarget)
  const fillHtml = !embedded && isHtmlFile(name, mime)
  const renderFileBody = () => {
    if (isDelimitedTextTable(name, mime)) {
      return (
        <DelimitedTablePreview
          key={url}
          cacheKey={contentKeys.page(pageID)}
          url={url}
          name={name}
          canComment={canComment}
          onRequestComment={requestComment}
          previewRef={innerPreview}
          initialAnchor={initialAnchor?.kind === 'csv_rows' ? initialAnchor : undefined}
        />
      )
    }
    if (isOfficeSpreadsheetFile(name, mime)) {
      return (
        <Suspense fallback={<ContentSkeleton variant="table" label={t('pod.spreadsheet.loading')} immediate />}>
          <SpreadsheetPreview
            url={url}
            initialSheet={searchTarget?.kind === 'sheet' ? searchTarget.sheet : undefined}
          />
        </Suspense>
      )
    }
    if (isLegacyWorkbookFile(name, mime)) {
      return (
        <Suspense fallback={<ContentSkeleton variant="table" label={t('pod.content.loading_spreadsheet_preview')} />}>
          <LegacySpreadsheetPreview
            key={url}
            url={url}
            initialSheet={searchTarget?.kind === 'sheet' ? searchTarget.sheet : undefined}
          />
        </Suspense>
      )
    }
    if (isWordFile(name, mime)) {
      return (
        <Suspense fallback={<ContentSkeleton variant="page" label={t('pod.word.preview_loading')} immediate />}>
          <WordPreview
            url={url}
            initialPage={searchTarget?.kind === 'page' ? searchTarget.page : undefined}
            initialFind={searchFind}
          />
        </Suspense>
      )
    }
    if (isPresentationFile(name, mime)) {
      return (
        <Suspense fallback={<ContentSkeleton variant="page" label={t('pod.presentation.preview_loading')} immediate />}>
          <PresentationPreview
            url={url}
            initialSlide={searchTarget?.kind === 'page' ? searchTarget.page : undefined}
            initialFind={searchFind}
          />
        </Suspense>
      )
    }
    if (mime?.startsWith('image/')) return <ImageFilePreview url={url} name={name} />
    if (mime === 'application/pdf') {
      return (
        <Suspense fallback={<ContentLoading label={t('pod.content.loading_file')} />}>
          <PdfPreview
            key={url}
            url={url}
            title={name}
            initialPage={searchTarget?.kind === 'page' ? searchTarget.page : undefined}
          />
        </Suspense>
      )
    }
    if (mime?.startsWith('video/') || mime?.startsWith('audio/')) {
      return (
        <MediaFilePreview
          key={url}
          url={url}
          kind={mime.startsWith('video/') ? 'video' : 'audio'}
          canComment={canComment}
          onRequestComment={requestComment}
          previewRef={innerPreview}
        />
      )
    }
    if (isHtmlFile(name, mime)) {
      return (
        <HtmlFilePreview
          key={url}
          cacheKey={contentKeys.page(pageID)}
          url={url}
          downloadURL={url}
          name={name}
          size={file.size}
          canComment={canComment}
          onRequestComment={requestComment}
          previewRef={innerPreview}
          initialAnchor={initialAnchor?.kind === 'lines' ? initialAnchor : undefined}
          fileMeta={fileMeta}
          fileActions={fileActions}
          layout={embedded ? 'embed' : 'fill'}
        />
      )
    }
    if (isTextFile(name, mime)) {
      return (
        <TextFilePreview
          key={url}
          pageID={pageID}
          url={url}
          name={name}
          canComment={canComment}
          onRequestComment={requestComment}
          previewRef={innerPreview}
          initialAnchor={
            initialAnchor && (initialAnchor.kind === 'lines' || initialAnchor.kind === 'md_section')
              ? initialAnchor
              : undefined
          }
        />
      )
    }
    return (
      <p className="rounded border border-border-subtle p-8 text-sm text-fg-tertiary">
        {t('pod.content.online_preview_is_not_available_for_this_file_download_the')}
      </p>
    )
  }
  return <div className={fillHtml ? 'flex min-h-0 flex-1 flex-col' : 'space-y-3'}>{renderFileBody()}</div>
}
