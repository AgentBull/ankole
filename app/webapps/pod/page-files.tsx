import { useTranslation } from 'react-i18next'
import { Button, buttonVariants, cn } from '@ankole/uikit'
import { RiUploadCloud2Line } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { lazy, Suspense, useRef, useState } from 'react'
import { createClientConfig, InternalAPIError } from '../common/internal-api-client'
import { ErrorBoundary } from '../common/error-boundary'
import { contentKeys, fileURL, type PageDetail } from './content-api'
import { ContentError } from './content-primitives'
import { podFiles } from './api/generated/sdk.gen'
import { uploadFile } from './native-transfers'
import type { PodFileCopyResponse } from './api/generated/types.gen'
import { CodeBlockView } from './chat/code-block-view'
import { usePageRealtime } from './use-page-realtime'
import { isRealtimeAccessDenied } from './realtime'

export type DriveFile = NonNullable<Awaited<ReturnType<typeof podFiles>>>['files'][number]
export type UploadedFile = PodFileCopyResponse
const SpreadsheetPreview = lazy(() => import('./file-spreadsheet'))
const PresentationPreview = lazy(() => import('./file-presentation'))
const transport = createClientConfig({}).fetch!
const TEXT_BYTES = 64 * 1024
const filesQuery = (id: string) => ({
  queryKey: [...contentKeys.page(id), 'files'],
  queryFn: () => podFiles({ path: { id } })
})

export async function uploadPageFile(
  id: string,
  file: File,
  role: 'file' | 'asset' | 'attachment',
  revision?: number
): Promise<UploadedFile> {
  return uploadFile(id, file, role, revision)
}

export function FilePage({ detail }: { detail: PageDetail }) {
  const { t } = useTranslation()
  const { page, actions } = detail
  const canEdit = actions.includes('page_edit')
  const manifest = useQuery(filesQuery(page.id))
  const input = useRef<HTMLInputElement>(null)
  const uploading = useRef(false)
  const [dragOver, setDragOver] = useState(false)
  const client = useQueryClient()
  const connection = usePageRealtime(page.id, page.revision)
  const upload = useMutation({
    mutationFn: async (file: File) => {
      const current =
        manifest.data && !manifest.isFetching ? manifest.data : await client.fetchQuery(filesQuery(page.id))
      return uploadPageFile(page.id, file, 'file', current.revision)
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
          {upload.variables.name}
        </p>
      )}
      <ContentError error={connection.error} retry={connection.retry} />
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
        {file && (
          <span className="min-w-0 grow basis-full truncate text-sm sm:basis-0" title={name}>
            {name} · {Math.ceil(file.size / 1024)} KB
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
            download={name}>
            {t('pod.content.download_original')}
          </a>
        )}
      </div>
      {manifest.isPending ? (
        <p role="status">{t('pod.content.loading_file')}</p>
      ) : file ? (
        <ErrorBoundary variant="panel" resetKeys={[page.id, file.path, file.sha256]}>
          <FilePreview pageID={page.id} file={file} />
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
    /\.(txt|md|json|xml|ya?ml|[cm]?[jt]sx?|py|exs?|rs|go|rb|sh|css|html|sql|toml)$/i.test(name)
  )
}

function FilePreview({ pageID, file }: { pageID: string; file: DriveFile }) {
  const { t } = useTranslation()
  const url = fileURL(pageID, file.path, file.sha256)
  const name = file.path.split('/').at(-1) ?? t('pod.content.file')
  const mime = file.content_type?.split(';')[0]?.trim().toLowerCase()
  return (
    <div className="space-y-3">
      {/\.(xlsx|xls|xlsb|ods|csv|tsv)$/i.test(name) || mime?.includes('spreadsheet') ? (
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
      ) : mime?.startsWith('video/') ? (
        <video controls className="max-h-[70vh] w-full" src={url} />
      ) : mime?.startsWith('audio/') ? (
        <audio controls src={url} />
      ) : isTextFile(name, mime) ? (
        <TextFilePreview key={url} pageID={pageID} url={url} name={name} />
      ) : (
        <p className="rounded border border-border p-8 text-sm text-fg-tertiary">
          {t('pod.content.online_preview_is_not_available_for_this_file_download_the')}
        </p>
      )}
    </div>
  )
}

function TextFilePreview({ pageID, url, name }: { pageID: string; url: string; name: string }) {
  const { t } = useTranslation()
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
  if (query.isPending) return <p role="status">{t('pod.content.loading_file')}</p>
  if (query.error) return <ContentError error={query.error} retry={() => void query.refetch()} />
  const extension = name.includes('.') ? name.split('.').at(-1)?.toLowerCase() : undefined
  return (
    <div className="space-y-2">
      {query.data.truncated && (
        <p role="status" className="text-sm text-fg-tertiary">
          {t('pod.chat_attachments.preview_truncated')}
        </p>
      )}
      <CodeBlockView code={query.data.text} language={extension} />
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
