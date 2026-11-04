import { useCopyFeedback } from '@ankole/uikit/hooks/use-copy-feedback'
import { Button, toast } from '@ankole/uikit'
import {
  RiCheckboxMultipleLine,
  RiCheckLine,
  RiDoubleQuotesL,
  RiEditLine,
  RiFileCopyLine,
  RiRestartLine
} from '@remixicon/react'
import { type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'

export function MessageActions({
  text,
  onQuote,
  onSelectMessage,
  onEdit,
  editDisabledReason,
  onRetry,
  alwaysVisible = false,
  children
}: {
  text: string
  onQuote?: (text: string) => void
  onSelectMessage?: () => void
  onEdit?: () => void
  editDisabledReason?: string
  onRetry?: () => void
  alwaysVisible?: boolean
  children?: ReactNode
}) {
  const { t } = useTranslation()
  const [copied, markCopied] = useCopyFeedback(false)
  return (
    <div
      className="pod-chat-message-actions"
      data-visible={alwaysVisible || !!onRetry || undefined}
      role="group"
      aria-label={t('pod.chat_timeline.message_actions')}>
      {!!text && (
        <Button
          variant="ghost"
          size="icon-xs"
          title={t(copied ? 'pod.chat.message_copied' : 'pod.chat.copy_message')}
          aria-label={t(copied ? 'pod.chat.message_copied' : 'pod.chat.copy_message')}
          onClick={async () => {
            try {
              await navigator.clipboard.writeText(text)
              markCopied(true)
            } catch {
              toast.error(t('pod.chat.copy_failed'))
            }
          }}>
          {copied ? <RiCheckLine aria-hidden /> : <RiFileCopyLine aria-hidden />}
        </Button>
      )}
      {onQuote && !!text && (
        <Button
          variant="ghost"
          size="icon-xs"
          title={t('pod.chat_timeline.quote_reply')}
          aria-label={t('pod.chat_timeline.quote_reply')}
          onClick={event => {
            const selection = window.getSelection()
            const message = event.currentTarget.closest('article')
            const selected =
              selection && message?.contains(selection.anchorNode) && message.contains(selection.focusNode)
                ? selection.toString()
                : ''
            onQuote(selected.trim() ? selected : text)
          }}>
          <RiDoubleQuotesL aria-hidden />
        </Button>
      )}
      {onSelectMessage && (
        <Button
          variant="ghost"
          size="icon-xs"
          title={t('pod.chat_timeline.select_messages', { defaultValue: 'Select messages' })}
          aria-label={t('pod.chat_timeline.select_messages', { defaultValue: 'Select messages' })}
          onClick={onSelectMessage}>
          <RiCheckboxMultipleLine aria-hidden />
        </Button>
      )}
      {onEdit && (
        <Button
          variant="ghost"
          size="icon-xs"
          title={`${editDisabledReason || t('pod.chat.edit_last')} · ${t('pod.chat.retry_keeps_artifacts')}`}
          aria-label={t('pod.chat.edit_last')}
          aria-description={editDisabledReason}
          disabled={!!editDisabledReason}
          focusableWhenDisabled
          className={editDisabledReason ? 'opacity-45' : undefined}
          onClick={onEdit}>
          <RiEditLine aria-hidden />
        </Button>
      )}
      {onRetry && (
        <Button variant="ghost" size="xs" title={t('pod.chat.retry_keeps_artifacts')} onClick={onRetry}>
          <RiRestartLine aria-hidden />
          {t('pod.chat.retry_reply')}
        </Button>
      )}
      {children}
    </div>
  )
}
