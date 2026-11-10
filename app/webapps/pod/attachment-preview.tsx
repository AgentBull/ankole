import {
  isDelimitedTextTable,
  isMarkdownFile,
  isPresentationFile,
  isTextFile,
  isWorkbookFile,
  previewMediaType,
  TEXT_PREVIEW_BYTES
} from '../common/file-preview'
import { readPrefix } from '../common/browser-files'
import { Button, Dialog, DialogContent, DialogFooter, DialogTitle } from '@ankole/uikit'
import { RiCloseLine, RiFileLine } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import {
  createContext,
  lazy,
  Suspense,
  use,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode
} from 'react'
import { useTranslation } from 'react-i18next'
import { createClientConfig } from '../common/internal-api-client'
import { BdiLabel } from '../common/bidi-file-name'
import { formatFileBytes } from '../common/file-format'
import { sanitizeFileName, stripBidi } from '../common/bidi'
import { podKeys } from './api'
import { ContentError, ContentLoading } from './content-primitives'
import { isPreviewImage } from './state/chat-attachments'
import { ChatMarkdown } from './chat/chat-markdown'
import { CodeBlockView } from './chat/code-block-view'
import { ImageZoomView } from './chat/zoomable-image'
import { DelimitedTablePreview } from './page-file-previews'
import { PodPanelSurface, popupOpen, type PanelInputEvent } from './panel-motion'

const SpreadsheetPreview = lazy(() => import('./file-spreadsheet'))
const PresentationPreview = lazy(() => import('./file-presentation'))

/**
 * Chooses the in-chat preview from the same format rules as the Pod file page. Attachments from uploads and
 * external channels can lack a media type, so the file extension decides the preview in that case.
 */
export function attachmentPreviewKind(name: string, type?: string) {
  const mime = previewMediaType(name, type)
  if (isPreviewImage(mime)) return 'image'
  if (mime === 'application/pdf') return 'pdf'
  if (isDelimitedTextTable(name, mime)) return 'table'
  if (isWorkbookFile(name, mime)) return 'spreadsheet'
  if (isPresentationFile(name, mime)) return 'presentation'
  if (isMarkdownFile(name, mime)) return 'markdown'
  // A `.ts` source file often arrives as `video/mp2t`, so text detection runs before media.
  if (isTextFile(name, mime)) return 'text'
  if (mime?.startsWith('video/')) return 'video'
  if (mime?.startsWith('audio/')) return 'audio'
  return undefined
}

const transport = createClientConfig({}).fetch!
const IMAGE_BYTES = 16 * 1024 * 1024

/** One file that a chat card can preview. The URL identifies the file, so cards that show the same file share it. */
export type AttachmentPreviewFile = {
  name: string
  type: string | undefined
  size?: number
  url: string
  downloadURL: string
  conversationID?: string
  local: boolean
}

type PreviewHost = {
  open(file: AttachmentPreviewFile, trigger: HTMLElement, event?: PanelInputEvent): void
  /** Counts the cards that show a file, so the preview closes once no card shows its file any more. */
  mount(url: string): () => void
}

const AttachmentPreviewHostContext = createContext<PreviewHost | null>(null)

/**
 * Lets a chat open its file previews in its right sidebar instead of a dialog. The chat owns the sidebar, so this
 * hook keeps the open file and returns the provider value; a chat that renders no sidebar leaves the cards on dialogs.
 */
export function useAttachmentPreviewHost(onOpen: (event?: PanelInputEvent) => void) {
  const [current, setCurrent] = useState<{ file: AttachmentPreviewFile; trigger: HTMLElement } | null>(null)
  const counts = useRef(new Map<string, number>())
  const onOpenRef = useRef(onOpen)
  useLayoutEffect(() => {
    onOpenRef.current = onOpen
  })
  const host = useMemo<PreviewHost>(
    () => ({
      open(file, trigger, event) {
        onOpenRef.current(event)
        setCurrent({ file, trigger })
      },
      mount(url) {
        counts.current.set(url, (counts.current.get(url) ?? 0) + 1)
        return () => {
          const left = (counts.current.get(url) ?? 1) - 1
          if (left > 0) {
            counts.current.set(url, left)
            return
          }
          counts.current.delete(url)
          // The file left the conversation, for example with its message, so its preview goes too.
          setCurrent(previous => (previous?.file.url === url ? null : previous))
        }
      }
    }),
    []
  )
  return { host, file: current?.file ?? null, trigger: current?.trigger ?? null, close: () => setCurrent(null) }
}

export function AttachmentPreviewHost({ host, children }: { host: PreviewHost | null; children: ReactNode }) {
  return <AttachmentPreviewHostContext value={host}>{children}</AttachmentPreviewHostContext>
}

/**
 * The file card's body: selecting it opens the file's preview, which owns the download and open-in-tab actions.
 * Inside a chat with a right sidebar the preview opens there; elsewhere it opens in a dialog. Files that Ankole cannot
 * render still open the preview, which then shows the file's details instead of content.
 */
export function AttachmentPreview({
  name,
  type,
  size,
  url,
  downloadURL = url,
  conversationID,
  local = false,
  children
}: {
  name: string
  type: string | undefined
  size?: number
  url: string
  downloadURL?: string
  conversationID?: string
  local?: boolean
  children?: ReactNode
}) {
  const { t } = useTranslation()
  const host = use(AttachmentPreviewHostContext)
  const [open, setOpen] = useState(false)
  const trigger = useRef<HTMLButtonElement>(null)
  const body = useRef<HTMLDivElement>(null)
  const [thumbnailFailed, setThumbnailFailed] = useState(false)
  const file: AttachmentPreviewFile = { name, type, size, url, downloadURL, conversationID, local }
  const image = attachmentPreviewKind(name, type) === 'image'
  useEffect(() => host?.mount(url), [host, url])
  // The surrounding control already names the file, so the thumbnail is decoration and falls back to the file mark.
  const thumbnail =
    image && !thumbnailFailed ? (
      <img
        src={url}
        alt=""
        loading="lazy"
        className="size-12 shrink-0 rounded-control object-cover"
        onError={() => setThumbnailFailed(true)}
      />
    ) : (
      <RiFileLine className="size-6 shrink-0 text-fg-tertiary" aria-hidden />
    )
  const card = (
    <Button
      ref={trigger}
      type="button"
      variant="ghost"
      className="h-auto min-w-0 shrink justify-start rounded-control p-2 text-left font-normal leading-normal text-foreground"
      aria-label={t('pod.chat_attachments.preview', { name: stripBidi(name) })}
      title={sanitizeFileName(name)}
      onClick={event => (host ? host.open(file, event.currentTarget, event.nativeEvent) : setOpen(true))}>
      {thumbnail}
      {children}
    </Button>
  )
  if (host) return card
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      {card}
      <DialogContent
        style={{ width: 'min(760px, calc(100vw - 32px))', maxWidth: 'calc(100vw - 32px)' }}
        closeLabel={t('common.close')}
        initialFocus={body}
        finalFocus={trigger}>
        <DialogTitle className="break-words">
          <BdiLabel value={name} />
        </DialogTitle>
        <div
          ref={body}
          tabIndex={0}
          className="pod-dialog-body rounded-control outline-none focus-visible:ring-2 focus-visible:ring-ring">
          {open && <AttachmentPreviewBody file={file} />}
        </div>
        <DialogFooter>
          <AttachmentPreviewLinks file={file} />
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

/**
 * A chat's right sidebar showing one file. It takes focus when it opens, Escape or the close button closes it, and
 * focus then returns to the card that opened it.
 */
export function AttachmentPreviewPanel({
  file,
  onClose
}: {
  file: AttachmentPreviewFile
  onClose(event?: PanelInputEvent): void
}) {
  const { t } = useTranslation()
  const body = useRef<HTMLDivElement>(null)
  useLayoutEffect(() => {
    body.current?.focus({ preventScroll: true })
  }, [file.url])
  return (
    <PodPanelSurface
      className="pod-chat-side-panel pod-chat-file-panel"
      aria-label={stripBidi(file.name)}
      onKeyDown={event => {
        if (
          event.key === 'Escape' &&
          !event.defaultPrevented &&
          !event.nativeEvent.isComposing &&
          !popupOpen() &&
          !(event.target as HTMLElement).closest('[role="dialog"], [role="menu"], [role="listbox"]')
        ) {
          event.preventDefault()
          event.stopPropagation()
          onClose()
        }
      }}>
      <header className="pod-chat-file-panel-header">
        <h2 className="pod-chat-file-panel-title" title={sanitizeFileName(file.name)}>
          <BdiLabel value={file.name} />
        </h2>
        <div className="flex shrink-0 items-center gap-3 text-sm">
          <AttachmentPreviewLinks file={file} />
        </div>
        <Button
          type="button"
          variant="ghost"
          size="icon-sm"
          aria-label={t('common.close')}
          title={t('common.close')}
          onClick={event => onClose(event.nativeEvent)}>
          <RiCloseLine aria-hidden />
        </Button>
      </header>
      <div
        ref={body}
        key={file.url}
        tabIndex={0}
        className="pod-chat-file-panel-body outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset">
        <AttachmentPreviewBody file={file} />
      </div>
    </PodPanelSurface>
  )
}

function AttachmentPreviewLinks({ file }: { file: AttachmentPreviewFile }) {
  const { t } = useTranslation()
  return (
    <>
      <a href={file.url} target="_blank" rel="noopener noreferrer" className="link">
        {t('pod.chat_attachments.open_new_tab')}
      </a>
      <a href={file.downloadURL} download={sanitizeFileName(file.name)} className="link">
        {t('pod.content.download_original')}
      </a>
    </>
  )
}

/** The file's content in the format that its kind calls for, or its details when Ankole cannot render it. */
function AttachmentPreviewBody({ file }: { file: AttachmentPreviewFile }) {
  const { t } = useTranslation()
  const { name, type, size, url, conversationID, local } = file
  const kind = attachmentPreviewKind(name, type)
  const details = [type?.split(';')[0]?.trim(), formatFileBytes(size)].filter(Boolean).join(' · ')
  return (
    <Suspense fallback={<ContentLoading label={t('pod.content.loading_file')} />}>
      {kind === 'pdf' ? (
        <iframe
          className="pod-attachment-pdf h-[70dvh] w-full border border-border"
          src={url}
          title={stripBidi(name)}
        />
      ) : kind === 'video' ? (
        <video controls playsInline preload="metadata" className="max-h-[70dvh] w-full rounded" src={url} />
      ) : kind === 'audio' ? (
        <audio controls preload="metadata" className="w-full" src={url} />
      ) : kind === 'table' ? (
        <DelimitedTablePreview
          cacheKey={conversationID ? podKeys.detail(conversationID) : podKeys.conversations}
          url={url}
          name={name}
          local={local}
          canComment={false}
        />
      ) : kind === 'spreadsheet' ? (
        <SpreadsheetPreview url={url} />
      ) : kind === 'presentation' ? (
        <PresentationPreview url={url} />
      ) : kind ? (
        <PreviewContent
          url={url}
          image={kind === 'image'}
          markdown={kind === 'markdown'}
          name={stripBidi(name)}
          conversationID={conversationID}
          local={local}
        />
      ) : (
        <div className="flex flex-col items-center gap-2 py-8 text-center text-sm">
          <RiFileLine className="size-10 text-fg-tertiary" aria-hidden />
          {details && <p className="text-fg-tertiary">{details}</p>}
          <p>{t('pod.chat_attachments.preview_unavailable')}</p>
        </div>
      )}
    </Suspense>
  )
}

function PreviewContent({
  url,
  image,
  markdown,
  name,
  conversationID,
  local
}: {
  url: string
  image: boolean
  markdown: boolean
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
      const result = await readPrefix(response, image ? IMAGE_BYTES : TEXT_PREVIEW_BYTES, signal)
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
  if (query.isPending) return <ContentLoading label={t('pod.content.loading_file')} immediate />
  if (query.error) return <ContentError error={query.error} retry={() => void query.refetch()} />
  if (query.data.image) return <PreviewImage blob={query.data.image} name={name} />
  return (
    <>
      {query.data.truncated && (
        <p role="status" className="mb-3 text-sm text-fg-tertiary">
          {t('pod.chat_attachments.preview_truncated')}
        </p>
      )}
      {markdown ? (
        <ChatMarkdown text={query.data.text} />
      ) : (
        <CodeBlockView code={query.data.text} language={name.split('.').at(-1)} />
      )}
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
  if (!url) return <ContentLoading label={t('pod.content.loading_file')} immediate />
  return failed ? (
    <p role="alert">{t('pod.chat_attachments.preview_unavailable')}</p>
  ) : (
    <ImageZoomView src={url} alt={name} onError={() => setFailed(true)} />
  )
}
