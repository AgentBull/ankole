import { Button } from '@ankole/uikit'
import { RiAttachment2, RiCloseLine, RiRefreshLine } from '@remixicon/react'
import { useSignals } from '@preact/signals-react/runtime'
import { useRef, type ClipboardEventHandler, type DragEventHandler } from 'react'
import { useTranslation } from 'react-i18next'
import type { ConversationAttachment } from './api'
import { InternalAPIError } from '../common/internal-api-client'
import { conversationAttachmentURL } from './native-transfers'
import type { ChatAttachments } from './state/chat-attachments'
import { AttachmentPreview } from './attachment-preview'

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
        <li key={file.id} className="flex max-w-full items-center gap-2 rounded-control border border-border p-2">
          <AttachmentPreview name={file.file.name} type={file.file.type} url={file.url} local />
          <div className="min-w-0 text-xs">
            <a
              href={file.url}
              download={file.file.name}
              className="block max-w-48 truncate"
              title={file.file.name}
              aria-label={t('pod.chat_attachments.download', { name: file.file.name })}>
              {file.file.name}
            </a>
            {!recovery && (
              <span role={file.state === 'failed' ? 'alert' : 'status'} className="text-fg-tertiary">
                {t(
                  `pod.chat_attachments.${file.error instanceof InternalAPIError && file.error.status === 413 ? 'too_large' : file.state === 'failed' ? 'failed' : file.state === 'uploading' ? 'uploading' : 'ready'}`
                )}
              </span>
            )}
          </div>
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
        </li>
      ))}
    </ul>
  )
}

export function chatAttachmentHandlers(
  model: ChatAttachments,
  disabled = false
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
      if (disabled) return
      model.add(event.dataTransfer.files)
    },
    onPaste(event) {
      if (disabled || !event.clipboardData.files.length) return
      event.preventDefault()
      model.add(event.clipboardData.files)
    }
  }
}

export function MessageAttachments({
  conversationID,
  messageID,
  attachments
}: {
  conversationID: string
  messageID: string
  attachments: ConversationAttachment[]
}) {
  const { t } = useTranslation()
  if (!attachments.length) return null
  return (
    <ul aria-label={t('pod.chat_attachments.files')} className="flex flex-wrap gap-2">
      {attachments.map(attachment => {
        const url = conversationAttachmentURL(conversationID, messageID, attachment.path)
        return (
          <li
            key={attachment.attachment_id ?? attachment.path}
            className="flex max-w-full items-center gap-2 rounded-control border border-border p-2">
            <AttachmentPreview
              name={attachment.name}
              type={attachment.content_type ?? attachment.mime_type ?? undefined}
              url={url}
              downloadURL={conversationAttachmentURL(conversationID, messageID, attachment.path, true)}
              conversationID={conversationID}
            />
            <a
              href={conversationAttachmentURL(conversationID, messageID, attachment.path, true)}
              className="max-w-64 truncate text-xs"
              download={attachment.name}
              title={attachment.name}
              aria-label={t('pod.chat_attachments.download', { name: attachment.name })}>
              {attachment.name}
            </a>
          </li>
        )
      })}
    </ul>
  )
}
