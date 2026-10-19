import { Button, Dialog, DialogContent, DialogFooter, DialogTitle } from '@ankole/uikit'
import { RiFileLine } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { createClientConfig } from '../common/internal-api-client'
import { podKeys } from './api'
import { ContentError } from './content-primitives'
import { isPreviewImage } from './state/chat-attachments'

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
  const mime = type?.split(';')[0]?.trim().toLowerCase()
  const image = isPreviewImage(mime)
  const text =
    mime?.startsWith('text/') || ['application/json', 'application/xml', 'application/javascript'].includes(mime ?? '')
  const thumbnail = image ? (
    <img src={url} alt={name} loading="lazy" className="size-12 rounded-control object-cover" />
  ) : (
    <RiFileLine className="size-6 text-fg-tertiary" aria-hidden />
  )
  if (!image && !text) {
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
          {open && <PreviewContent url={url} image={image} name={name} conversationID={conversationID} local={local} />}
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
      <pre className="whitespace-pre-wrap break-words font-mono text-sm leading-6">{query.data.text}</pre>
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
    <img
      src={url}
      alt={name}
      className="mx-auto max-h-[70dvh] max-w-full object-contain"
      onError={() => setFailed(true)}
    />
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
