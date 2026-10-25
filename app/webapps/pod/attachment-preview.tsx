import { Button, Dialog, DialogContent, DialogFooter, DialogTitle } from '@ankole/uikit'
import { RiFileLine } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { lazy, Suspense, useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { createClientConfig } from '../common/internal-api-client'
import { podKeys } from './api'
import { ContentError } from './content-primitives'
import { isPreviewImage } from './state/chat-attachments'
import { CodeBlockView } from './chat/code-block-view'
import { ImageZoomView } from './chat/zoomable-image'

const SpreadsheetPreview = lazy(() => import('./file-spreadsheet'))
const PresentationPreview = lazy(() => import('./file-presentation'))

export function attachmentPreviewKind(name: string, type?: string) {
  const mime = type?.split(';')[0]?.trim().toLowerCase()
  if (isPreviewImage(mime)) return 'image'
  if (mime === 'application/pdf') return 'pdf'
  if (/\.(xlsx?|csv|tsv|ods)$/i.test(name) || mime?.includes('spreadsheet')) return 'spreadsheet'
  if (/\.pptx$/i.test(name) || mime?.includes('presentationml')) return 'presentation'
  if (
    mime?.startsWith('text/') ||
    ['application/json', 'application/xml', 'application/javascript'].includes(mime ?? '') ||
    /\.(txt|md|json|xml|ya?ml|[cm]?[jt]sx?|py|exs?|rs|go|rb|sh|css|html|sql|toml)$/i.test(name)
  ) {
    return 'text'
  }
  return undefined
}

const transport = createClientConfig({}).fetch!
const TEXT_BYTES = 64 * 1024
const IMAGE_BYTES = 16 * 1024 * 1024

export function AttachmentPreview({
  name,
  type,
  url,
  downloadURL = url,
  conversationID,
  local = false
}: {
  name: string
  type: string | undefined
  url: string
  downloadURL?: string
  conversationID?: string
  local?: boolean
}) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const trigger = useRef<HTMLButtonElement>(null)
  const body = useRef<HTMLDivElement>(null)
  const kind = attachmentPreviewKind(name, type)
  const image = kind === 'image'
  const thumbnail = image ? (
    <img src={url} alt={name} loading="lazy" className="size-12 rounded-control object-cover" />
  ) : (
    <RiFileLine className="size-6 text-fg-tertiary" aria-hidden />
  )
  if (!kind) {
    return local ? (
      thumbnail
    ) : (
      <a href={url} target="_blank" rel="noopener noreferrer" aria-label={t('pod.chat_attachments.preview', { name })}>
        {thumbnail}
      </a>
    )
  }
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <Button
        ref={trigger}
        type="button"
        variant="ghost"
        className="h-auto shrink-0 rounded-control p-0"
        aria-label={t('pod.chat_attachments.preview', { name })}
        onClick={() => setOpen(true)}>
        {thumbnail}
      </Button>
      <DialogContent
        style={{ width: 'min(760px, calc(100vw - 32px))', maxWidth: 'calc(100vw - 32px)' }}
        closeLabel={t('common.close')}
        initialFocus={body}
        finalFocus={trigger}>
        <DialogTitle className="break-words">{name}</DialogTitle>
        <div
          ref={body}
          tabIndex={0}
          className="pod-dialog-body rounded-control outline-none focus-visible:ring-2 focus-visible:ring-ring">
          {open && (
            <Suspense fallback={<p role="status">{t('pod.content.loading_file')}</p>}>
              {kind === 'pdf' ? (
                <iframe className="h-[70dvh] w-full border border-border" src={url} title={name} />
              ) : kind === 'spreadsheet' ? (
                <SpreadsheetPreview url={url} />
              ) : kind === 'presentation' ? (
                <PresentationPreview url={url} />
              ) : (
                <PreviewContent url={url} image={image} name={name} conversationID={conversationID} local={local} />
              )}
            </Suspense>
          )}
        </div>
        <DialogFooter>
          <a href={url} target="_blank" rel="noopener noreferrer" className="link">
            {t('pod.chat_attachments.open_new_tab')}
          </a>
          <a href={downloadURL} download={name} className="link">
            {t('pod.content.download_original')}
          </a>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function PreviewContent({
  url,
  image,
  name,
  conversationID,
  local
}: {
  url: string
  image: boolean
  name: string
  conversationID: string | undefined
  local: boolean
}) {
  const { t } = useTranslation()
  const query = useQuery({
    queryKey: [...(conversationID ? podKeys.detail(conversationID) : podKeys.conversations), 'attachment-preview', url],
    queryFn: async ({ signal }) => {
      const response = await (local ? fetch : transport)(url, { credentials: 'same-origin', signal })
      const mime = response.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase()
      if (!response.body || (image && !isPreviewImage(mime))) {
        await response.body?.cancel()
        throw new Error(t('pod.chat_attachments.preview_unavailable'))
      }
      const result = await readPrefix(response, image ? IMAGE_BYTES : TEXT_BYTES, signal)
      if (image) {
        if (result.truncated) throw new Error(t('pod.chat_attachments.preview_too_large'))
        return { image: new Blob([result.bytes], { type: mime }), text: '', truncated: false }
      }
      const decoder = new TextDecoder()
      return {
        image: null,
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
  if (query.data.image) return <PreviewImage blob={query.data.image} name={name} />
  return (
    <>
      {query.data.truncated && (
        <p role="status" className="mb-3 text-sm text-fg-tertiary">
          {t('pod.chat_attachments.preview_truncated')}
        </p>
      )}
      <CodeBlockView code={query.data.text} language={name.split('.').at(-1)} />
    </>
  )
}

function PreviewImage({ blob, name }: { blob: Blob; name: string }) {
  const { t } = useTranslation()
  const [url, setURL] = useState<string>()
  const [failed, setFailed] = useState(false)
  useEffect(() => {
    const source = URL.createObjectURL(blob)
    setURL(source)
    return () => URL.revokeObjectURL(source)
  }, [blob])
  if (!url) return <p role="status">{t('pod.content.loading_file')}</p>
  return failed ? (
    <p role="alert">{t('pod.chat_attachments.preview_unavailable')}</p>
  ) : (
    <ImageZoomView src={url} alt={name} onError={() => setFailed(true)} />
  )
}

/** Read a bounded prefix and cancel the rest, including a response without a length header. */
async function readPrefix(response: Response, limit: number, signal: AbortSignal) {
  const reader = response.body?.getReader()
  if (!reader) throw new Error('The attachment response has no body')
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
