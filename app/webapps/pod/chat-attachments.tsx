import { Button, cn, ProgressRing } from '@ankole/uikit'
import { RiAttachment2, RiCloseLine, RiRefreshLine } from '@remixicon/react'
import { useSignals } from '@preact/signals-react/runtime'
import { useRef, type ClipboardEventHandler, type DragEventHandler, type ReactNode } from 'react'
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
      {model.files.value.map(file => (
        <li key={file.id} className="flex max-w-full items-center gap-1 rounded-control border border-border pr-1">
          <AttachmentPreview name={file.file.name} type={file.file.type} size={file.file.size} url={file.url} local>
            <span className="grid min-w-0 text-xs">
              <span className="flex max-w-48">
                <AttachmentName name={file.file.name} />
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
                className="group/remove"
                aria-label={t('pod.chat_attachments.remove', { name: file.file.name })}
                onClick={() => model.remove(file.id)}>
                {/* While a file uploads, the remove control shows its progress and turns into the cross on hover or focus. */}
                {file.state === 'uploading' && (
                  <ProgressRing
                    aria-hidden
                    value={(file.progress ?? 0) * 100}
                    className="group-hover/remove:hidden group-focus-visible/remove:hidden"
                  />
                )}
                <RiCloseLine
                  aria-hidden
                  className={cn(
                    file.state === 'uploading' && 'hidden group-hover/remove:block group-focus-visible/remove:block'
                  )}
                />
              </Button>
            </>
          )}
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
