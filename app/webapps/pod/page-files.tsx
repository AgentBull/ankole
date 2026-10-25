import { t } from 'i18next'
import { Button, buttonVariants, cn } from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { lazy, Suspense, useRef, useState } from 'react'
import { InternalAPIError } from '../common/internal-api-client'
import { contentKeys, fileURL, type PageDetail } from './content-api'
import { ContentError } from './content-primitives'
import { podFiles } from './api/generated/sdk.gen'
import { uploadFile } from './native-transfers'
import type { PodFileCopyResponse } from './api/generated/types.gen'
import { usePageRealtime } from './use-page-realtime'
import { isRealtimeAccessDenied } from './realtime'

export type DriveFile = NonNullable<Awaited<ReturnType<typeof podFiles>>>['files'][number]
export type UploadedFile = PodFileCopyResponse
const SpreadsheetPreview = lazy(() => import('./file-spreadsheet'))
const PresentationPreview = lazy(() => import('./file-presentation'))
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
  const { page, actions } = detail
  const manifest = useQuery(filesQuery(page.id))
  const [selected, setSelected] = useState<File>()
  const input = useRef<HTMLInputElement>(null)
  const uploading = useRef(false)
  const client = useQueryClient()
  const connection = usePageRealtime(page.id, page.revision)
  const upload = useMutation({
    mutationFn: ({ file, revision }: { file: File; revision: number }) =>
      uploadPageFile(page.id, file, 'file', revision),
    onSuccess: (_, submitted) => {
      setSelected(current => (current === submitted.file ? undefined : current))
      if (input.current) input.current.value = ''
      return client.invalidateQueries({ queryKey: contentKeys.all })
    },
    onError: error => {
      if (error instanceof InternalAPIError && error.status === 409) void manifest.refetch()
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
  if (connection.revoked || isRealtimeAccessDenied(manifest.error)) {
    return <ContentError error={new Error(t('pod.content.you_no_longer_have_access_to_this_file'))} />
  }
  return (
    <section className="space-y-4">
      <ContentError error={manifest.error} retry={() => void manifest.refetch()} />
      <ContentError error={upload.error} />
      <ContentError error={connection.error} retry={connection.retry} />
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
        {file && (
          <span className="min-w-0 grow basis-full truncate text-sm sm:basis-0" title={name}>
            {name} · {Math.ceil(file.size / 1024)} KB
          </span>
        )}
        {actions.includes('page_edit') && (
          <form
            className="flex min-w-0 flex-wrap items-center gap-2"
            onSubmit={event => {
              event.preventDefault()
              if (!selected || !manifest.data || uploading.current) return
              uploading.current = true
              upload.mutate({ file: selected, revision: manifest.data.revision })
            }}>
            <input
              aria-label={chooseLabel}
              type="file"
              ref={input}
              className="hidden"
              tabIndex={-1}
              disabled={upload.isPending}
              onChange={event => {
                upload.reset()
                setSelected(event.target.files?.[0])
              }}
            />
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={upload.isPending}
              onClick={() => input.current?.click()}>
              {chooseLabel}
            </Button>
            {selected && (
              <span role="status" className="max-w-64 truncate text-xs text-fg-secondary" title={selected.name}>
                {selected.name}
              </span>
            )}
            <Button
              type="submit"
              size="sm"
              variant="outline"
              disabled={!selected || !manifest.data || manifest.isFetching || upload.isPending}>
              {upload.isPending
                ? t('pod.content.uploading')
                : file
                  ? t('pod.content.replace_file')
                  : t('pod.content.upload_file')}
            </Button>
          </form>
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
        <FilePreview pageID={page.id} file={file} />
      ) : (
        <p className="py-10 text-sm text-fg-tertiary">
          {t('pod.content.upload_a_file_to_preview_and_download_it_here')}
        </p>
      )}
    </section>
  )
}

function FilePreview({ pageID, file }: { pageID: string; file: DriveFile }) {
  const url = fileURL(pageID, file.path, file.sha256)
  const name = file.path.split('/').at(-1) ?? t('pod.content.file')
  return (
    <div className="space-y-3">
      {/\.(xlsx|xls|xlsb|ods|csv)$/i.test(name) ? (
        <Suspense fallback={<p role="status">{t('pod.content.loading_spreadsheet_preview')}</p>}>
          <SpreadsheetPreview key={url} url={url} />
        </Suspense>
      ) : /\.pptx$/i.test(name) ? (
        <Suspense fallback={<p role="status">{t('pod.content.loading_slide_preview')}</p>}>
          <PresentationPreview key={url} url={url} />
        </Suspense>
      ) : file.content_type?.startsWith('image/') ? (
        <img className="mx-auto max-h-[70vh] max-w-full object-contain" alt={name} src={url} />
      ) : file.content_type === 'application/pdf' ? (
        <iframe className="h-[70vh] w-full rounded border border-border" src={url} title={name} />
      ) : file.content_type?.startsWith('video/') ? (
        <video controls className="max-h-[70vh] w-full" src={url} />
      ) : file.content_type?.startsWith('audio/') ? (
        <audio controls src={url} />
      ) : (
        <p className="rounded border border-border p-8 text-sm text-fg-tertiary">
          {t('pod.content.online_preview_is_not_available_for_this_file_download_the')}
        </p>
      )}
    </div>
  )
}
