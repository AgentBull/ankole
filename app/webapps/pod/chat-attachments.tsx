import { Button, cn } from '@ankole/uikit'
import { RiAttachment2, RiCheckLine, RiCloseLine, RiFileLine, RiRefreshLine, RiUpload2Line } from '@remixicon/react'
import { useSignals } from '@preact/signals-react/runtime'
import {
  useRef,
  useState,
  type ClipboardEventHandler,
  type ComponentProps,
  type DragEventHandler,
  type ReactNode
} from 'react'
import { useTranslation } from 'react-i18next'
import type { ConversationAttachment } from './api'
import { containsBidi, stripBidi } from '../common/bidi'
import { formatFileBytes } from '../common/file-format'
import { InternalAPIError } from '../common/internal-api-client'
import { conversationAttachmentURL } from './native-transfers'
import type { ChatAttachments } from './state/chat-attachments'
import { AttachmentPreview } from './attachment-preview'

/** Files that share a long prefix differ at the end, so a long name gives way in the middle and keeps its extension. */
function AttachmentName({ name }: { name: string }) {
  const { t } = useTranslation()
  const hasBidi = containsBidi(name)
  const clean = stripBidi(name) || 'file'
  const dot = clean.lastIndexOf('.')
  const split = dot > 0 && clean.length - dot <= 8 ? dot : clean.length
  return (
    <span className="inline-flex min-w-0 max-w-full items-center gap-1">
      <bdi className="inline-flex min-w-0 max-w-full">
        <span className="min-w-0 truncate">{clean.slice(0, split)}</span>
        <span className="shrink-0">{clean.slice(split)}</span>
      </bdi>
      {hasBidi && (
        <span
          role="img"
          aria-label={t('common.bidi_warning_label', {
            defaultValue: 'Bidirectional override characters were stripped from this name'
          })}
          title={t('common.bidi_warning_label', {
            defaultValue: 'Bidirectional override characters were stripped from this name'
          })}
          className="inline-flex shrink-0 items-center rounded-mini bg-warning/15 px-1 py-0.5 text-[10px] font-medium leading-3 text-warning">
          Bidi
        </span>
      )}
    </span>
  )
}

export function ChatAttachmentButton({ model, disabled }: { model: ChatAttachments; disabled?: boolean }) {
  const { t } = useTranslation()
  const input = useRef<HTMLInputElement>(null)
  return (
    <>
      <input
        ref={input}
        type="file"
        multiple
        hidden
        disabled={disabled}
        onChange={event => {
          if (event.currentTarget.files) model.add(event.currentTarget.files)
          event.currentTarget.value = ''
        }}
      />
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        disabled={disabled}
        aria-label={t('pod.chat_attachments.choose')}
        title={t('pod.chat_attachments.choose')}
        onClick={() => input.current?.click()}>
        <RiAttachment2 aria-hidden />
      </Button>
    </>
  )
}

export function ChatAttachmentDrafts({
  model,
  disabled,
  recovery = false
}: {
  model: ChatAttachments
  disabled?: boolean
  recovery?: boolean
}) {
  useSignals()
  const { t } = useTranslation()
  if (!model.files.value.length) return null
  return (
    <ul aria-label={t('pod.chat_attachments.files')} className="flex flex-wrap gap-2 px-3 py-2">
      {model.files.value.map((file, index) => (
        <li
          key={file.id}
          data-upload-state={recovery ? undefined : file.state}
          style={recovery ? undefined : { animationDelay: `${Math.min(index, 3) * 50}ms` }}
          className={cn(
            'group/upload grid max-w-full grid-rows-[1fr]',
            !recovery && 'motion-safe:animate-[pod-attachment-enter_420ms_cubic-bezier(.22,1,.36,1)_both]'
          )}>
          <div className="flex min-h-0 max-w-full items-center gap-1 rounded-control border border-border pr-1 motion-safe:group-data-[upload-state=failed]/upload:animate-[pod-attachment-shake_380ms_both]">
            <AttachmentPreview name={file.file.name} type={file.file.type} size={file.file.size} url={file.url} local>
              <span className="grid min-w-0 text-xs">
                <span className="flex max-w-48 items-center gap-1">
                  <AttachmentName name={file.file.name} />
                  {!recovery && file.state === 'ready' && (
                    <RiCheckLine
                      aria-hidden
                      className="size-3.5 shrink-0 text-success motion-safe:animate-[pod-attachment-ready_260ms_cubic-bezier(.22,1,.36,1)_both]"
                    />
                  )}
                </span>
                {!recovery &&
                  (file.state === 'failed' ? (
                    <span role="alert" className="text-destructive">
                      {t(
                        `pod.chat_attachments.${file.error instanceof InternalAPIError && file.error.status === 413 ? 'too_large' : 'failed'}`
                      )}
                    </span>
                  ) : (
                    <span className="tabular-nums text-fg-tertiary">
                      {file.state === 'uploading' && `${formatFileBytes((file.progress ?? 0) * file.file.size)} / `}
                      {formatFileBytes(file.file.size)}
                      <span role="status" className="sr-only">
                        {t(`pod.chat_attachments.${file.state}`)}
                      </span>
                    </span>
                  ))}
                {!recovery && file.state !== 'ready' && (
                  <span
                    aria-hidden
                    className="mt-0.5 block h-0.5 w-full min-w-12 overflow-hidden rounded-full bg-muted">
                    <span
                      className={cn(
                        'block h-full origin-left rounded-full motion-safe:[transition:scale_200ms_cubic-bezier(.22,1,.36,1)]',
                        file.state === 'failed' ? 'bg-destructive' : 'bg-info'
                      )}
                      style={{ scale: `${file.progress ?? 0} 1` }}
                    />
                  </span>
                )}
              </span>
            </AttachmentPreview>
            {!recovery && (
              <>
                {file.state === 'failed' && (
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon-sm"
                    disabled={disabled}
                    aria-label={t('pod.chat_attachments.retry', { name: file.file.name })}
                    onClick={() => model.retry(file.id)}>
                    <RiRefreshLine aria-hidden />
                  </Button>
                )}
                <Button
                  type="button"
                  variant="ghost"
                  size="icon-sm"
                  disabled={disabled}
                  aria-label={t('pod.chat_attachments.remove', { name: file.file.name })}
                  onClick={() => model.remove(file.id)}>
                  <RiCloseLine aria-hidden />
                </Button>
              </>
            )}
          </div>
        </li>
      ))}
    </ul>
  )
}

export function chatAttachmentHandlers(
  model: ChatAttachments,
  disabled = false,
  onBlocked?: () => void
): {
  onDragOver: DragEventHandler
  onDrop: DragEventHandler
  onPaste: ClipboardEventHandler
} {
  return {
    onDragOver(event) {
      if ([...event.dataTransfer.types].includes('Files')) event.preventDefault()
    },
    onDrop(event) {
      if (!event.dataTransfer.files.length) return
      event.preventDefault()
      if (disabled) {
        onBlocked?.()
        return
      }
      model.add(event.dataTransfer.files)
    },
    onPaste(event) {
      if (!event.clipboardData.files.length) return
      event.preventDefault()
      if (disabled) {
        onBlocked?.()
        return
      }
      model.add(event.clipboardData.files)
    }
  }
}

export function ChatAttachmentDropzone({
  model,
  disabled = false,
  onBlocked,
  children,
  className,
  ...formProps
}: ComponentProps<'form'> & { model: ChatAttachments; disabled?: boolean; onBlocked?: () => void }) {
  const { t } = useTranslation()
  const dragDepth = useRef(0)
  const [fileCount, setFileCount] = useState<number | null>(null)
  const handlers = chatAttachmentHandlers(model, disabled, onBlocked)
  const active = !disabled && fileCount !== null

  return (
    <form
      {...formProps}
      {...handlers}
      className={cn('relative', className)}
      onDragEnter={event => {
        if (disabled || !event.dataTransfer.types.includes('Files')) return
        dragDepth.current += 1
        setFileCount([...event.dataTransfer.items].filter(item => item.kind === 'file').length)
      }}
      onDragLeave={() => {
        dragDepth.current = Math.max(0, dragDepth.current - 1)
        if (dragDepth.current === 0) setFileCount(null)
      }}
      onDrop={event => {
        dragDepth.current = 0
        setFileCount(null)
        handlers.onDrop(event)
      }}>
      {children}
      <div
        aria-hidden
        data-slot="attachment-drop-feedback"
        data-active={active || undefined}
        className="group/drop pointer-events-none absolute inset-0 z-20 flex flex-col items-center justify-center gap-1 rounded-control border border-dashed border-transparent bg-background/95 opacity-0 motion-safe:[transition:opacity_160ms,border-color_160ms] motion-reduce:transition-none data-active:border-info data-active:opacity-100">
        <div className="absolute inset-0 rounded-control bg-info-subtle opacity-0 motion-safe:transition-opacity motion-safe:duration-160 group-data-active/drop:opacity-80" />
        <div className="relative h-9 w-16 text-info">
          <div className="absolute inset-y-1 left-1/2 grid w-5 -translate-x-1/2 place-items-center rounded-mini border border-current bg-background [transform:translate(-12px,2px)_rotate(-10deg)] motion-safe:[transition:transform_420ms_cubic-bezier(.22,1,.36,1)] group-data-active/drop:[transform:translateX(-28px)_rotate(-16deg)]">
            <RiFileLine className="size-3.5" />
          </div>
          <div className="absolute inset-y-1 left-1/2 grid w-5 -translate-x-1/2 place-items-center rounded-mini border border-current bg-background [transform:translate(12px,2px)_rotate(10deg)] motion-safe:[transition:transform_420ms_cubic-bezier(.22,1,.36,1)] group-data-active/drop:[transform:translateX(28px)_rotate(16deg)]">
            <RiFileLine className="size-3.5" />
          </div>
          <div className="absolute inset-y-0 left-1/2 grid w-6 -translate-x-1/2 place-items-center rounded-mini border border-current bg-background [transform:translateY(-2px)] motion-safe:[transition:transform_420ms_cubic-bezier(.22,1,.36,1)] group-data-active/drop:[transform:translateY(-8px)_scale(1.05)]">
            <RiUpload2Line className="size-4 motion-safe:group-data-active/drop:animate-[pod-attachment-bob_900ms_ease-in-out_infinite]" />
          </div>
        </div>
        {active && (
          <span className="relative text-sm font-medium text-foreground motion-safe:animate-[pod-attachment-label_260ms_cubic-bezier(.22,1,.36,1)_both]">
            {fileCount ? t('pod.chat_attachments.drop_count', { count: fileCount }) : t('pod.chat_attachments.drop')}
          </span>
        )}
      </div>
    </form>
  )
}

export function MessageAttachments({
  conversationID,
  messageID,
  attachments,
  renderAction
}: {
  conversationID: string
  messageID: string
  attachments: ConversationAttachment[]
  renderAction?: (attachment: ConversationAttachment) => ReactNode
}) {
  const { t } = useTranslation()
  if (!attachments.length) return null
  return (
    <ul aria-label={t('pod.chat_attachments.files')} className="flex flex-wrap gap-2">
      {attachments.map(attachment => (
        <li
          key={attachment.attachment_id ?? attachment.path}
          className="flex max-w-full items-center gap-1 rounded-control border border-border pr-1">
          <AttachmentPreview
            name={attachment.name}
            type={attachment.content_type ?? attachment.mime_type ?? undefined}
            size={attachment.size}
            url={conversationAttachmentURL(conversationID, messageID, attachment.position)}
            downloadURL={conversationAttachmentURL(conversationID, messageID, attachment.position, true)}
            conversationID={conversationID}>
            <span className="grid min-w-0 text-xs">
              <span className="flex max-w-64">
                <AttachmentName name={attachment.name} />
              </span>
              <span className="tabular-nums text-fg-tertiary">{formatFileBytes(attachment.size)}</span>
            </span>
          </AttachmentPreview>
          {renderAction?.(attachment)}
        </li>
      ))}
    </ul>
  )
}
